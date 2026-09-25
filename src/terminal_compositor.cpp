#include "terminal_compositor.h"
#include "terminal_surface_item.h"
#include "clipboard_bridge.h"
#include <QAbstractEventDispatcher>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QKeyEvent>
#include <QQuickWindow>
#include <QScopedValueRollback>
#include <QSocketNotifier>
#include <QtGui/qguiapplication_platform.h>
#include <QtMath>
#include <wayland-client.h>
#include <linux/input-event-codes.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <algorithm>
#include <utility>

namespace {
quint64 keyIdentity(const QKeyEvent *event) {
    return event->nativeScanCode() ? event->nativeScanCode() : (quint64(1) << 32) | quint32(event->key());
}
QString shortcutAction(const QKeyEvent *event) {
    const auto mods = event->modifiers() & (Qt::ControlModifier | Qt::ShiftModifier | Qt::AltModifier | Qt::MetaModifier);
    if (mods == Qt::ControlModifier && event->key() == Qt::Key_R) return "rename";
    if (mods == (Qt::ControlModifier | Qt::ShiftModifier)) {
        switch (event->key()) {
        case Qt::Key_N: return "newSession";
        case Qt::Key_F: return "search";
        case Qt::Key_B: return "toggleFolders";
        case Qt::Key_L: return "toggleSessions";
        case Qt::Key_W: return "closeSession";
        case Qt::Key_Q: return "quit";
        default: break;
        }
    } else if (mods == (Qt::ControlModifier | Qt::AltModifier)) {
        switch (event->key()) {
        case Qt::Key_N: return "newFolder";
        case Qt::Key_PageUp: return "previous";
        case Qt::Key_PageDown: return "next";
        case Qt::Key_U: return "attention";
        default: break;
        }
    }
    return {};
}
}

TerminalCompositor::TerminalCompositor(const QString &profileHash, QObject *parent) : QObject(parent) {
    m_socket = QString("cinmux-%1-%2").arg(profileHash).arg(QCoreApplication::applicationPid()).toUtf8();
    m_hiddenFrames.setInterval(100);
    connect(&m_hiddenFrames, &QTimer::timeout, this, [this] { if (m_server) { cm_server_frames(m_server, false); dispatch(); } });
}

TerminalCompositor::~TerminalCompositor() {
    m_shuttingDown = true;
    qApp->removeEventFilter(this);
    m_hiddenFrames.stop();
    delete m_notifier;
    m_notifier = nullptr;
    releaseHostSeat();
    if (m_hostRegistry) wl_registry_destroy(m_hostRegistry);
    auto *clipboard = m_clipboard;
    m_clipboard = nullptr;
    delete clipboard;
    if (m_server) cm_server_destroy(m_server);
    m_server = nullptr;
}

void TerminalCompositor::setError(const QString &error) {
    if (m_error == error) return;
    m_error = error; emit errorChanged();
}

void TerminalCompositor::create() {
    if (m_server) return;
    if (QGuiApplication::platformName() != "wayland") {
        setError("Cinmux requires a Wayland desktop; set QT_QPA_PLATFORM=wayland."); return;
    }
    const auto runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
    struct stat st {};
    const auto path = QFile::encodeName(runtime);
    if (!QDir::isAbsolutePath(runtime) || ::stat(path.constData(), &st) != 0 || !S_ISDIR(st.st_mode)
        || st.st_uid != ::getuid() || (st.st_mode & 0077) || ::access(path.constData(), W_OK | X_OK)) {
        setError("XDG_RUNTIME_DIR must be a writable user-owned directory with mode 0700."); return;
    }
    const auto socket = path + '/' + m_socket;
    if (socket.size() >= qsizetype(sizeof(sockaddr_un::sun_path))) { setError("The nested Wayland socket path is too long."); return; }
    if (::lstat(socket.constData(), &st) == 0) { setError("The nested Wayland socket already exists."); return; }
    cm_callbacks callbacks {};
    callbacks.view_added = [](void *ctx, const char *id) { static_cast<TerminalCompositor *>(ctx)->addView(QString::fromUtf8(id)); };
    callbacks.view_ready = [](void *ctx, const char *id) {
        auto *self = static_cast<TerminalCompositor *>(ctx);
        auto *view = self->m_views.value(QString::fromUtf8(id));
        if (!view) return;
        view->m_ready = true; emit view->readyChanged(); emit self->viewReady(view->m_id); self->updateFocus();
    };
    callbacks.view_lost = [](void *ctx, const char *id, const char *error) {
        static_cast<TerminalCompositor *>(ctx)->removeView(QString::fromUtf8(id), QString::fromUtf8(error));
    };
    callbacks.frame = [](void *ctx, const char *id, const void *pixels, int w, int h, int stride, bool alpha, int lw, int lh) {
        auto *self = static_cast<TerminalCompositor *>(ctx);
        auto *view = self->m_views.value(QString::fromUtf8(id));
        if (!view || !pixels || w <= 0 || h <= 0) return;
        // One owned snapshot crosses from wlroots' GUI-thread buffer lifetime
        // into Qt's render thread. Hidden surfaces never enter this callback.
        view->m_image = QImage(static_cast<const uchar *>(pixels), w, h, stride,
                               alpha ? QImage::Format_ARGB32_Premultiplied : QImage::Format_RGB32).copy();
        view->m_logicalSize = QSize(lw, lh); ++view->m_frameRevision; emit view->frameChanged();
    };
    callbacks.cursor = [](void *ctx, const char *id, const void *pixels, int w, int h, int stride, int lw, int lh, int hx, int hy) {
        auto *self = static_cast<TerminalCompositor *>(ctx);
        auto *view = self->m_views.value(QString::fromUtf8(id));
        if (!view) return;
        view->m_cursorImage = pixels && w > 0 && h > 0 ? QImage(static_cast<const uchar *>(pixels), w, h, stride, QImage::Format_ARGB32_Premultiplied).copy() : QImage();
        view->m_cursorSize = QSize(lw, lh); view->m_hotspot = QPoint(hx, hy); view->m_cursorKnown = true;
        ++view->m_cursorRevision; emit view->cursorChanged();
    };
    callbacks.selection = [](void *ctx, uint64_t generation, const char *const *mimes, size_t count) {
        auto *self = static_cast<TerminalCompositor *>(ctx);
        if (!self->m_clipboard) return;
        QStringList formats;
        for (size_t i = 0; i < count; ++i) formats.append(QString::fromLatin1(mimes[i]));
        self->m_clipboard->nestedSelection(generation, formats);
    };
    callbacks.send_selection = [](void *ctx, uint64_t token, const char *mime, int fd) {
        auto *self = static_cast<TerminalCompositor *>(ctx);
        if (self->m_clipboard) self->m_clipboard->sendSelection(token, QString::fromLatin1(mime), fd); else ::close(fd);
    };
    callbacks.selection_released = [](void *ctx, uint64_t token) {
        auto *self = static_cast<TerminalCompositor *>(ctx);
        if (self->m_clipboard) self->m_clipboard->releaseSelection(token);
    };
    char error[1024] {};
    m_server = cm_server_create(m_socket.constData(), &callbacks, this, error, sizeof(error));
    if (!m_server) { setError(QString::fromUtf8(error)); return; }
    m_clipboard = new ClipboardBridge(m_server, this);
    m_notifier = new QSocketNotifier(cm_server_fd(m_server), QSocketNotifier::Read, this);
    connect(m_notifier, &QSocketNotifier::activated, this, [this] { dispatch(); });
    connect(QAbstractEventDispatcher::instance(), &QAbstractEventDispatcher::aboutToBlock, this, &TerminalCompositor::dispatch);
}

void TerminalCompositor::initialize(QQuickWindow *window) {
    if (!m_server || m_window || !window) return;
    m_window = window;
    observeHostSeat();
    connect(window, &QWindow::widthChanged, this, &TerminalCompositor::updateOutput);
    connect(window, &QWindow::heightChanged, this, &TerminalCompositor::updateOutput);
    connect(window, &QWindow::screenChanged, this, &TerminalCompositor::updateOutput);
    connect(window, &QWindow::activeChanged, this, [this] {
        if (!m_window->isActive()) { releaseKeys(); m_consumedKeys.clear(); }
        updateFocus();
    });
    connect(window, &QQuickWindow::activeFocusItemChanged, this, [this] {
        if (!m_updatingFocus && m_window->isActive()) {
            if (!terminalHasFocus()) m_focusPending = false;
            setInputEnabled(terminalHasFocus());
        }
        updateFocus();
    });
    connect(window, &QQuickWindow::frameSwapped, this, [this] { if (m_server) { cm_server_frames(m_server, true); dispatch(); } }, Qt::QueuedConnection);
    connect(window, &QQuickWindow::sceneGraphError, this, [this](QQuickWindow::SceneGraphError, const QString &error) {
        setError("Terminal rendering failed: " + error);
        const auto ids = m_views.keys();
        for (const auto &id : ids) { forgetClient(id); emit viewLost(id, m_error); }
    });
    qApp->installEventFilter(this);
    m_hiddenFrames.start();
    updateOutput();
}

void TerminalCompositor::observeHostSeat() {
    auto *native = qGuiApp->nativeInterface<QNativeInterface::QWaylandApplication>();
    if (!native || !native->display()) { setError("The host Wayland display is unavailable."); return; }
    // Observe a separate binding of the default (first) seat on Qt's connection.
    // Requesting a keyboard before this seat has advertised that capability is
    // a fatal Wayland protocol error, including on keyboard-less remote desktops.
    m_hostRegistry = wl_display_get_registry(native->display());
    static const wl_registry_listener registryListener = {
        [](void *data, wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
            auto *self = static_cast<TerminalCompositor *>(data);
            if (self->m_hostSeat || QByteArrayView(interface) != "wl_seat") return;
            self->m_hostSeatName = name;
            self->m_hostSeat = static_cast<wl_seat *>(wl_registry_bind(registry, name, &wl_seat_interface,
                std::min(version, uint32_t(wl_seat_interface.version))));
            static const wl_seat_listener seatListener = {
                [](void *data, wl_seat *, uint32_t capabilities) {
                    auto *self = static_cast<TerminalCompositor *>(data);
                    if ((capabilities & WL_SEAT_CAPABILITY_KEYBOARD) && !self->m_hostKeyboard)
                        self->attachHostKeyboard();
                },
                [](void *, wl_seat *, const char *) {}
            };
            wl_seat_add_listener(self->m_hostSeat, &seatListener, self);
        },
        [](void *data, wl_registry *, uint32_t name) {
            auto *self = static_cast<TerminalCompositor *>(data);
            if (name == self->m_hostSeatName) self->releaseHostSeat();
        }
    };
    wl_registry_add_listener(m_hostRegistry, &registryListener, this);
    wl_display_flush(native->display());
}
void TerminalCompositor::releaseHostSeat() {
    releaseKeys();
    if (m_hostKeyboard) {
        if (wl_keyboard_get_version(m_hostKeyboard) >= WL_KEYBOARD_RELEASE_SINCE_VERSION) wl_keyboard_release(m_hostKeyboard);
        else wl_keyboard_destroy(m_hostKeyboard);
        m_hostKeyboard = nullptr;
    }
    if (m_hostSeat) {
        if (wl_seat_get_version(m_hostSeat) >= WL_SEAT_RELEASE_SINCE_VERSION) wl_seat_release(m_hostSeat);
        else wl_seat_destroy(m_hostSeat);
        m_hostSeat = nullptr;
    }
    m_hostSeatName = 0;
}
void TerminalCompositor::attachHostKeyboard() {
    // Retain this keyboard across hotplug; its protocol object stays valid when
    // the capability temporarily disappears. Ordinary key delivery remains Qt's
    // responsibility; this observer supplies each event's real keymap.
    m_hostKeyboard = wl_seat_get_keyboard(m_hostSeat);
    static const wl_keyboard_listener listener = {
        [](void *data, wl_keyboard *, uint32_t format, int32_t fd, uint32_t size) {
            auto *self = static_cast<TerminalCompositor *>(data);
            if (format == WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 && size) {
                void *mapping = ::mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0);
                if (mapping != MAP_FAILED) {
                    self->m_hostState.keymap = QByteArray(static_cast<const char *>(mapping), size);
                    ++self->m_hostState.revision;
                    if (self->m_pendingKeys.empty()) self->applyKeyboardState(self->m_hostState);
                    ::munmap(mapping, size);
                }
            }
            ::close(fd);
        },
        [](void *data, wl_keyboard *, uint32_t, wl_surface *, wl_array *keys) {
            auto *self = static_cast<TerminalCompositor *>(data);
            self->releaseKeys();
            const auto *values = static_cast<const uint32_t *>(keys->data);
            for (size_t i = 0; i < keys->size / sizeof(uint32_t); ++i) {
                self->m_pressed.insert(values[i]);
                cm_server_key(self->m_server, values[i], true, false, 0);
            }
        },
        [](void *data, wl_keyboard *, uint32_t, wl_surface *) { static_cast<TerminalCompositor *>(data)->releaseKeys(); },
        [](void *data, wl_keyboard *, uint32_t, uint32_t time, uint32_t key, uint32_t state) {
            auto *self = static_cast<TerminalCompositor *>(data);
            // Qt queues QKeyEvents after dispatching Wayland events. Retain the
            // key's own map and modifier snapshot: a layout can change again
            // before that QKeyEvent reaches the window (e.g. virtual keyboards).
            self->m_pendingKeys.push_back({time, key, state == WL_KEYBOARD_KEY_STATE_PRESSED, self->m_hostState});
        },
        [](void *data, wl_keyboard *, uint32_t, uint32_t depressed, uint32_t latched, uint32_t locked, uint32_t group) {
            auto *self = static_cast<TerminalCompositor *>(data);
            self->m_hostState.depressed = depressed;
            self->m_hostState.latched = latched;
            self->m_hostState.locked = locked;
            self->m_hostState.group = group;
            if (self->m_pendingKeys.empty()) self->applyKeyboardState(self->m_hostState);
        },
        [](void *, wl_keyboard *, int32_t, int32_t) {}
    };
    wl_keyboard_add_listener(m_hostKeyboard, &listener, this);
}
void TerminalCompositor::applyKeyboardState(const KeyboardState &state) {
    if (!m_server) return;
    if (state.revision != m_appliedKeymap) {
        cm_server_keymap(m_server, state.keymap.constData());
        m_appliedKeymap = state.revision;
    }
    cm_server_modifiers(m_server, state.depressed, state.latched, state.locked, state.group);
}
void TerminalCompositor::forwardKey(const QKeyEvent *key, bool deliver) {
    if (key->isAutoRepeat() || key->nativeScanCode() < 8 || !m_server) return;
    const auto code = key->nativeScanCode() - 8;
    const bool pressed = key->type() == QEvent::KeyPress;
    auto it = std::find_if(m_pendingKeys.begin(), m_pendingKeys.end(), [&](const PendingKey &pending) {
        // Input methods may replay a native key without preserving its timestamp.
        // In that case, correlate ordered scan-code transitions, not a fabricated time.
        return (!key->timestamp() || pending.time == key->timestamp())
            && pending.code == code && pending.pressed == pressed;
    });
    if (it == m_pendingKeys.end()) return;
    applyKeyboardState(it->state);
    const auto time = it->time;
    // Older entries may have been consumed by Qt's input method, not a window.
    m_pendingKeys.erase(m_pendingKeys.begin(), std::next(it));
    if (pressed) m_pressed.insert(code); else m_pressed.remove(code);
    cm_server_key(m_server, code, pressed, deliver, time);
    if (m_pendingKeys.empty()) applyKeyboardState(m_hostState);
}

void TerminalCompositor::releaseKeys() {
    if (m_server) for (auto key : std::as_const(m_pressed)) cm_server_key(m_server, key, false, false, 0);
    m_pendingKeys.clear();
    m_pressed.clear();
}
void TerminalCompositor::dispatch() {
    if (!m_server || m_dispatching || m_shuttingDown) return;
    QScopedValueRollback guard(m_dispatching, true);
    cm_server_dispatch(m_server);
}
void TerminalCompositor::updateOutput() {
    if (!m_window || !m_server) return;
    m_scale = qMax(1, qCeil(m_window->devicePixelRatio()));
    cm_server_output(m_server, qMax(1, m_window->width()), qMax(1, m_window->height()), m_scale);
    cm_server_select(m_server, m_selectedId.toUtf8().constData(), m_window->isExposed());
}
void TerminalCompositor::expectClient(QString id, qint64 pid) {
    if (!m_server) return;
    cm_server_expect(m_server, id.toUtf8().constData(), pid);
    if (id == m_selectedId) cm_server_select(m_server, id.toUtf8().constData(), m_window && m_window->isExposed());
    const auto generation = ++m_generations[id];
    QTimer::singleShot(5000, this, [this, id, generation] {
        if (m_shuttingDown || m_generations.value(id) != generation) return;
        auto *view = m_views.value(id);
        if (view && view->m_ready) return;
        forgetClient(id);
        emit viewLost(id, "Foot did not map a terminal within five seconds. The tmux session is still running.");
    });
}
void TerminalCompositor::forgetClient(QString id) {
    ++m_generations[id];
    if (m_server) cm_server_forget(m_server, id.toUtf8().constData());
    removeView(id, {});
}
void TerminalCompositor::addView(const QString &id) {
    if (m_views.contains(id)) return;
    auto *view = new TerminalView(id, this);
    m_views.insert(id, view); m_viewObjects.append(QVariant::fromValue(static_cast<QObject *>(view)));
    emit viewsChanged();
}
void TerminalCompositor::removeView(const QString &id, const QString &error) {
    if (auto *view = m_views.take(id)) {
        // Replacing the QVariantList rebuilds QML items even for surviving views.
        // Preserve terminal focus only when it belonged to a surviving view.
        if (terminalHasFocus()) m_focusPending = true;
        m_viewObjects.removeOne(QVariant::fromValue(static_cast<QObject *>(view)));
        {
            QScopedValueRollback guard(m_updatingFocus, true);
            emit viewsChanged();
        }
        view->deleteLater();
    }
    ++m_generations[id];
    if (!error.isEmpty() && !m_shuttingDown) emit viewLost(id, error);
}
void TerminalCompositor::configure(QString id, int width, int height) {
    if (m_server && width > 0 && height > 0) cm_server_configure(m_server, id.toUtf8().constData(), width, height);
}
void TerminalCompositor::setSelectedId(const QString &id) {
    if (m_selectedId == id) return;
    m_selectedId = id; m_focusPending = false;
    if (m_server) cm_server_select(m_server, id.toUtf8().constData(), m_window && m_window->isExposed());
    emit selectedIdChanged(); updateFocus();
}
void TerminalCompositor::setInputEnabled(bool enabled) {
    if (m_inputEnabled == enabled) return;
    m_inputEnabled = enabled;
    if (!enabled) m_focusPending = false;
    emit inputEnabledChanged(); updateFocus();
}
void TerminalCompositor::focusTerminal(QString id) {
    setSelectedId(id); m_focusPending = true; setInputEnabled(true); updateFocus();
}
void TerminalCompositor::clearFocus() { m_focusPending = false; setInputEnabled(false); updateFocus(); }
void TerminalCompositor::registerItem(TerminalView *view, TerminalSurfaceItem *item) {
    if (!view) return;
    view->m_item = item;
    QTimer::singleShot(0, this, &TerminalCompositor::updateFocus);
}
bool TerminalCompositor::terminalHasFocus() const {
    if (!m_window) return false;
    auto *view = m_views.value(m_selectedId);
    return view && view->m_item && view->m_item->hasActiveFocus();
}
void TerminalCompositor::updateFocus() {
    if (!m_server || m_updatingFocus || m_shuttingDown) return;
    QScopedValueRollback guard(m_updatingFocus, true);
    auto *view = m_views.value(m_selectedId);
    const bool eligible = m_window && m_window->isActive() && m_inputEnabled && view && view->m_ready;
    if (eligible && m_focusPending && m_consumedKeys.isEmpty() && view->m_item && view->m_item->isVisible()) {
        view->m_item->forceActiveFocus(); m_focusPending = false;
    }
    cm_server_focus(m_server, m_selectedId.toUtf8().constData(), eligible && terminalHasFocus());
}
void TerminalCompositor::pointerMove(const QString &id, const QPointF &point, quint32 time) {
    if (m_server && id == m_selectedId) cm_server_pointer(m_server, id.toUtf8().constData(), point.x(), point.y(), time);
}
void TerminalCompositor::pointerLeave() { if (m_server) cm_server_pointer_leave(m_server); }
void TerminalCompositor::pointerButton(Qt::MouseButton button, bool pressed, quint32 time) {
    uint32_t code = 0;
    switch (button) {
    case Qt::LeftButton: code = BTN_LEFT; break;
    case Qt::RightButton: code = BTN_RIGHT; break;
    case Qt::MiddleButton: code = BTN_MIDDLE; break;
    case Qt::BackButton: code = BTN_SIDE; break;
    case Qt::ForwardButton: code = BTN_EXTRA; break;
    default: return;
    }
    if (m_server) cm_server_button(m_server, code, pressed, time);
}
void TerminalCompositor::pointerScroll(const QPoint &angle, const QPoint &pixels, quint32 time) {
    if (!m_server) return;
    cm_server_scroll(m_server, pixels.isNull() ? -angle.x() / 12. : -pixels.x(), pixels.isNull() ? -angle.y() / 12. : -pixels.y(), -angle.x() / 120, -angle.y() / 120, time);
}
void TerminalCompositor::inputMethod(const QString &preedit, int cursor, const QString &commit) {
    if (m_server && m_inputEnabled) {
        const auto utf8 = preedit.toUtf8();
        const auto byteCursor = preedit.left(cursor).toUtf8().size();
        cm_server_text(m_server, utf8.constData(), byteCursor, byteCursor, commit.toUtf8().constData());
    }
}
void TerminalCompositor::interact(const QString &id) { if (id == m_selectedId) emit terminalInteracted(id); }

bool TerminalCompositor::eventFilter(QObject *watched, QEvent *event) {
    if (!m_window || watched != m_window) return false;
    if (event->type() == QEvent::DevicePixelRatioChange || event->type() == QEvent::Expose) updateOutput();
    const auto type = event->type();
    if (type != QEvent::ShortcutOverride && type != QEvent::KeyPress && type != QEvent::KeyRelease) return false;
    auto *key = static_cast<QKeyEvent *>(event);
    const auto identity = keyIdentity(key);
    const auto action = shortcutAction(key);
    const bool consumed = m_consumedKeys.contains(identity);
    if (type == QEvent::ShortcutOverride) {
        if (consumed || !action.isEmpty() || (m_inputEnabled && terminalHasFocus())) { key->accept(); return true; }
        return false;
    }
    const bool deliver = m_inputEnabled && terminalHasFocus();
    forwardKey(key, deliver && !consumed && action.isEmpty());
    if (type == QEvent::KeyRelease && consumed) {
        if (!key->isAutoRepeat()) { m_consumedKeys.remove(identity); QTimer::singleShot(0, this, &TerminalCompositor::updateFocus); }
        key->accept(); return true;
    }
    if (type == QEvent::KeyPress && (consumed || !action.isEmpty())) {
        if (!consumed && !key->isAutoRepeat()) { m_consumedKeys.insert(identity); emit shortcutTriggered(action); }
        key->accept(); return true;
    }
    if (deliver) {
        const bool modifier = (key->key() >= Qt::Key_Shift && key->key() <= Qt::Key_ScrollLock) || key->key() == Qt::Key_AltGr;
        if (type == QEvent::KeyPress && !modifier) emit terminalInteracted(m_selectedId);
        key->accept(); return true;
    }
    return false;
}
