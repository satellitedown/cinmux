#include "tui_terminal.h"
#include "state_store.h"
#include <QProcess>
#include <QSocketNotifier>
#include <QStandardPaths>
#include <QTimer>
#include <cerrno>
#include <cstdlib>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <utility>
#include <vterm.h>

namespace {
bool openPty(int cols, int rows, int *master, int *slave, QString *error) {
    const auto fail = [error](const QString &step) {
        *error = QStringLiteral("Cannot open a pseudo-terminal (%1): %2").arg(step, qt_error_string(errno));
        return false;
    };
    *master = ::posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (*master < 0) return fail(QStringLiteral("posix_openpt"));
    char name[128];
    const auto failAndClose = [&](const QString &step) { const int saved = errno; ::close(*master); errno = saved; return fail(step); };
    if (::grantpt(*master) != 0) return failAndClose(QStringLiteral("grantpt"));
    if (::unlockpt(*master) != 0) return failAndClose(QStringLiteral("unlockpt"));
    if (const int code = ::ptsname_r(*master, name, sizeof name)) { errno = code; return failAndClose(QStringLiteral("ptsname_r")); }
    *slave = ::open(name, O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (*slave < 0) return failAndClose(QStringLiteral("open"));
    const winsize size{ushort(rows), ushort(cols), 0, 0};
    const int flags = ::fcntl(*master, F_GETFL);
    if (::ioctl(*slave, TIOCSWINSZ, &size) != 0 || flags < 0 || ::fcntl(*master, F_SETFL, flags | O_NONBLOCK) != 0) {
        const int saved = errno; ::close(*slave); errno = saved;
        return failAndClose(QStringLiteral("setup"));
    }
    return true;
}
tui::Color color(const VTermColor &value, bool isDefault) {
    if (isDefault) return {};
    if (VTERM_COLOR_IS_INDEXED(&value)) return tui::Color::indexed(value.indexed.idx);
    return tui::Color::rgb(value.rgb.red, value.rgb.green, value.rgb.blue);
}
// libvterm marks the right half of a wide character with this code point.
constexpr uint32_t wideContinuation = uint32_t(-1);
}

struct TuiTerminals::View {
    View(TuiTerminals *owner, const QString &id, quint64 generation, int master, int cols, int rows);
    ~View();
    View(const View &) = delete;
    View &operator=(const View &) = delete;
    // Feeds pending pty output to libvterm; true when bytes arrived.
    bool drain();
    QString lastLine() const;

    static int damage(VTermRect, void *user) { static_cast<View *>(user)->changed = true; return 1; }
    static int moveCursor(VTermPos position, VTermPos, int visible, void *user) {
        auto *view = static_cast<View *>(user);
        view->cursor = position; view->cursorVisible = visible; view->changed = true;
        return 1;
    }
    // Every property must be accepted: libvterm only stores values the callback agrees to.
    static int setTermProp(VTermProp property, VTermValue *value, void *user) {
        auto *view = static_cast<View *>(user);
        switch (property) {
        case VTERM_PROP_CURSORVISIBLE: view->cursorVisible = value->boolean; break;
        case VTERM_PROP_CURSORBLINK: view->cursorBlink = value->boolean; break;
        case VTERM_PROP_CURSORSHAPE: view->cursorShape = value->number; view->shapeSet = true; break;
        case VTERM_PROP_MOUSE: view->mouse = value->number; break;
        default: return 1;
        }
        view->changed = true;
        return 1;
    }
    static int ring(void *user) { static_cast<View *>(user)->rang = true; return 1; }
    // libvterm hands over the decoded selection bytes, split at the buffer size.
    static int setSelection(VTermSelectionMask, VTermStringFragment fragment, void *user) {
        auto *view = static_cast<View *>(user);
        if (fragment.initial) view->selection.clear();
        view->selection.append(fragment.str, qsizetype(fragment.len));
        if (fragment.final) view->clipboards.append(std::exchange(view->selection, {}).toBase64());
        return 1;
    }
    static int querySelection(VTermSelectionMask, void *) { return 0; }
    static void output(const char *bytes, size_t size, void *user) { static_cast<View *>(user)->input.append(bytes, qsizetype(size)); }

    TuiTerminals *const owner;
    const QString id;
    const quint64 generation;
    const int master;
    int cols;
    int rows;
    VTerm *const vt;
    VTermScreen *const screen;
    VTermState *const state;
    QSocketNotifier *const reader;
    QSocketNotifier *const writer;
    QProcess *process = nullptr;
    // Bytes for the tmux client in order: keyboard, mouse and terminal replies.
    QByteArray input;
    QByteArray selection;
    QList<QByteArray> clipboards;
    char selectionBuffer[4096];
    VTermPos cursor{0, 0};
    bool cursorVisible = true;
    bool cursorBlink = true;
    // DECSCUSR is reported only once the client chose a shape; otherwise the
    // outer terminal keeps its configured cursor.
    bool shapeSet = false;
    int cursorShape = VTERM_PROP_CURSORSHAPE_BLOCK;
    int mouse = VTERM_PROP_MOUSE_NONE;
    bool ready = false;
    bool changed = false;
    bool rang = false;
};

TuiTerminals::View::View(TuiTerminals *owner, const QString &id, quint64 generation, int master, int cols, int rows)
    : owner(owner), id(id), generation(generation), master(master), cols(cols), rows(rows), vt(vterm_new(rows, cols)),
      screen(vterm_obtain_screen(vt)), state(vterm_obtain_state(vt)),
      reader(new QSocketNotifier(master, QSocketNotifier::Read, owner)), writer(new QSocketNotifier(master, QSocketNotifier::Write, owner)) {
    static const VTermScreenCallbacks screenCallbacks{&View::damage, nullptr, &View::moveCursor, &View::setTermProp, &View::ring,
                                                      nullptr, nullptr, nullptr, nullptr};
    static const VTermSelectionCallbacks selectionCallbacks{&View::setSelection, &View::querySelection};
    vterm_set_utf8(vt, 1);
    vterm_output_set_callback(vt, &View::output, this);
    vterm_screen_set_callbacks(screen, &screenCallbacks, this);
    vterm_screen_set_damage_merge(screen, VTERM_DAMAGE_SCREEN);
    vterm_screen_enable_altscreen(screen, 1);
    vterm_screen_reset(screen, 1);
    vterm_state_set_selection_callbacks(state, &selectionCallbacks, this, selectionBuffer, sizeof selectionBuffer);
    shapeSet = false;
    changed = false;
    writer->setEnabled(false);
    QObject::connect(reader, &QSocketNotifier::activated, owner, [owner, this] { owner->readOutput(this); });
    QObject::connect(writer, &QSocketNotifier::activated, owner, [owner, this] { owner->flushInput(this); });
}

TuiTerminals::View::~View() {
    reader->setEnabled(false); reader->deleteLater();
    writer->setEnabled(false); writer->deleteLater();
    if (process) process->disconnect(owner);
    // Hangs up the client before it is asked to terminate.
    ::close(master);
    if (process) {
        if (process->state() == QProcess::NotRunning) process->deleteLater();
        else {
            QObject::connect(process, &QProcess::stateChanged, process, [process = process](QProcess::ProcessState state) {
                if (state == QProcess::NotRunning) process->deleteLater();
            });
            process->terminate();
            QTimer::singleShot(1000, process, [process = process] { process->kill(); });
        }
    }
    vterm_free(vt);
}

bool TuiTerminals::View::drain() {
    char buffer[16384];
    bool received = false;
    // Bounded so a flooding client cannot starve the event loop; the notifier fires again.
    for (int reads = 0; reads < 64; ++reads) {
        const ssize_t size = ::read(master, buffer, sizeof buffer);
        if (size > 0) { vterm_input_write(vt, buffer, size_t(size)); received = true; continue; }
        if (size < 0 && errno == EINTR) continue;
        if (size == 0 || (errno != EAGAIN && errno != EWOULDBLOCK)) reader->setEnabled(false);
        break;
    }
    vterm_screen_flush_damage(screen);
    return received;
}

QString TuiTerminals::View::lastLine() const {
    QByteArray text(qsizetype(cols) * VTERM_MAX_CHARS_PER_CELL * 4, Qt::Uninitialized);
    for (int row = rows - 1; row >= 0; --row) {
        const size_t size = vterm_screen_get_text(screen, text.data(), size_t(text.size()), VTermRect{row, row + 1, 0, cols});
        const QString line = QString::fromUtf8(text.constData(), qsizetype(size)).trimmed();
        if (!line.isEmpty()) return line;
    }
    return {};
}

TuiTerminals::TuiTerminals(StateStore *store, QObject *parent)
    : TerminalRenderer(parent), m_store(store), m_environment(QProcessEnvironment::systemEnvironment()) {
    m_environment.remove(QStringLiteral("TMUX"));
    m_environment.remove(QStringLiteral("TMUX_PANE"));
    m_environment.remove(QStringLiteral("WAYLAND_SOCKET"));
    // The private server's configuration grants RGB, clipboard and extended keys to this TERM.
    m_environment.insert(QStringLiteral("TERM"), QStringLiteral("xterm-256color"));
    m_environment.insert(QStringLiteral("COLORTERM"), QStringLiteral("truecolor"));
    m_tmuxProgram = QStandardPaths::findExecutable(QStringLiteral("tmux"));
}

TuiTerminals::~TuiTerminals() = default;

TuiTerminals::View *TuiTerminals::view(const QString &id) const {
    const auto it = m_views.constFind(id);
    return it == m_views.cend() ? nullptr : it->get();
}

void TuiTerminals::attach(const QString &id, bool force) {
    if (m_views.contains(id)) {
        if (!force) return;
        detach(id);
    }
    if (m_tmuxProgram.isEmpty()) { emit lost(id, QStringLiteral("tmux is not installed or is not on PATH")); return; }
    int master = -1;
    int slave = -1;
    QString error;
    if (!openPty(m_cols, m_rows, &master, &slave, &error)) { emit lost(id, error); return; }
    const quint64 generation = ++m_generation;
    View *current = m_views.insert(id, std::make_shared<View>(this, id, generation, master, m_cols, m_rows)).value().get();
    auto *process = new QProcess(this);
    current->process = process;
    auto environment = m_environment;
    environment.insert(QStringLiteral("CINMUX_STATE_DIR"), m_store->stateDirectory());
    environment.insert(QStringLiteral("CINMUX_SESSION_ID"), id);
    environment.insert(QStringLiteral("CINMUX_TMUX_SOCKET"), m_store->tmuxSocket());
    process->setProcessEnvironment(environment);
    process->setInputChannelMode(QProcess::ForwardedInputChannel);
    process->setProcessChannelMode(QProcess::ForwardedChannels);
    // The TUI ignores SIGPIPE, which would otherwise survive exec.
    process->setUnixProcessParameters(QProcess::UnixProcessFlag::ResetSignalHandlers);
    process->setChildProcessModifier([process, slave] {
        ::setsid();
        if (::ioctl(slave, TIOCSCTTY, 0) != 0) process->failChildProcessModifier("TIOCSCTTY", errno);
        for (int fd = 0; fd < 3; ++fd)
            if (::dup2(slave, fd) < 0) process->failChildProcessModifier("dup2", errno);
    });
    connect(process, &QProcess::finished, this, [this, id, generation](int code) { finished(id, generation, code); });
    connect(process, &QProcess::errorOccurred, this, [this, id, generation, process](QProcess::ProcessError failure) {
        const View *failed = view(id);
        if (failure != QProcess::FailedToStart || !failed || failed->generation != generation) return;
        const QString message = process->errorString();
        m_views.remove(id);
        emit lost(id, message);
    });
    // FailedToStart may be reported synchronously: `current` must not be used past start().
    process->start(m_tmuxProgram, {QStringLiteral("-u"), QStringLiteral("-S"), m_store->tmuxSocket(), QStringLiteral("attach-session"),
                                   QStringLiteral("-E"), QStringLiteral("-t"), QLatin1Char('=') + StateStore::sessionName(id)});
    ::close(slave);
}

void TuiTerminals::detach(const QString &id) {
    m_views.remove(id);
}

bool TuiTerminals::attached(const QString &id) const {
    return m_views.contains(id);
}

void TuiTerminals::finished(const QString &id, quint64 generation, int code) {
    View *current = view(id);
    if (!current || current->generation != generation) return;
    current->drain();
    QString message = current->lastLine();
    // tmux reports ordinary exits in brackets, e.g. "[exited]" or "[detached …]"; errors are plain text.
    if (message.isEmpty() || message.startsWith(QLatin1Char('[')))
        message = QStringLiteral("Terminal client exited (code %1). The tmux session is unaffected; reconnect to view it.").arg(code);
    const QString session = id;
    m_views.remove(session);
    emit lost(session, message);
}

void TuiTerminals::readOutput(View *current) {
    const bool received = current->drain();
    flushInput(current);
    const QString id = current->id;
    const quint64 generation = current->generation;
    const bool becameReady = received && !current->ready;
    if (received) current->ready = true;
    const bool rang = std::exchange(current->rang, false);
    const bool changed = std::exchange(current->changed, false);
    const QList<QByteArray> clipboards = std::exchange(current->clipboards, {});
    // Handlers may detach or replace the view.
    const auto alive = [this, &id, generation] { const View *v = view(id); return v && v->generation == generation; };
    if (becameReady) emit ready(id);
    if (rang && alive()) emit bell(id);
    for (const auto &base64 : clipboards) emit clipboard(base64);
    if (changed && alive()) emit updated(id);
}

void TuiTerminals::flushInput(View *current) {
    qsizetype written = 0;
    while (written < current->input.size()) {
        const ssize_t size = ::write(current->master, current->input.constData() + written, size_t(current->input.size() - written));
        if (size > 0) { written += size; continue; }
        if (size < 0 && errno == EINTR) continue;
        // The client is gone: its input is moot.
        if (size < 0 && errno != EAGAIN && errno != EWOULDBLOCK) written = current->input.size();
        break;
    }
    current->input.remove(0, written);
    current->writer->setEnabled(!current->input.isEmpty());
}

bool TuiTerminals::resize(View *current) {
    if (current->cols == m_cols && current->rows == m_rows) return false;
    current->cols = m_cols;
    current->rows = m_rows;
    vterm_set_size(current->vt, m_rows, m_cols);
    vterm_screen_flush_damage(current->screen);
    current->changed = false;
    const winsize size{ushort(m_rows), ushort(m_cols), 0, 0};
    ::ioctl(current->master, TIOCSWINSZ, &size);
    return true;
}

void TuiTerminals::setSize(int cols, int rows) {
    m_cols = qMax(1, cols);
    m_rows = qMax(1, rows);
    View *current = view(m_selected);
    if (!current || !resize(current)) return;
    const QString id = m_selected;
    emit updated(id);
}

void TuiTerminals::setSelected(const QString &id) {
    if (id == m_selected) return;
    if (View *previous = view(m_selected); previous && m_focused) {
        vterm_state_focus_out(previous->state);
        flushInput(previous);
    }
    m_selected = id;
    View *current = view(id);
    if (!current) return;
    if (m_focused) {
        vterm_state_focus_in(current->state);
        flushInput(current);
    }
    if (resize(current)) {
        const QString selected = id;
        emit updated(selected);
    }
}

void TuiTerminals::setFocused(bool focused) {
    if (focused == m_focused) return;
    m_focused = focused;
    View *current = view(m_selected);
    if (!current) return;
    if (focused) vterm_state_focus_in(current->state);
    else vterm_state_focus_out(current->state);
    flushInput(current);
}

bool TuiTerminals::hasOutput(const QString &id) const {
    const View *current = view(id);
    return current && current->ready;
}

bool TuiTerminals::paint(const QString &id, tui::Surface &surface, int x, int y, int width, int height) const {
    const View *current = view(id);
    if (!current) return false;
    const int cols = qMin(qMin(width, current->cols), surface.cols() - x);
    const int rows = qMin(qMin(height, current->rows), surface.rows() - y);
    VTermScreenCell source;
    for (int row = 0; row < rows; ++row) {
        for (int col = 0; col < cols; ++col) {
            vterm_screen_get_cell(current->screen, VTermPos{row, col}, &source);
            if (source.chars[0] == wideContinuation) continue;
            tui::Cell cell;
            if (source.chars[0] != 0 && !(source.width == 2 && col + 1 >= cols)) {
                for (int i = 0; i < tui::Cell::maxChars && i < VTERM_MAX_CHARS_PER_CELL && source.chars[i] != 0; ++i) cell.chars[i] = source.chars[i];
                cell.width = uint8_t(source.width);
            }
            cell.style.fg = color(source.fg, VTERM_COLOR_IS_DEFAULT_FG(&source.fg));
            cell.style.bg = color(source.bg, VTERM_COLOR_IS_DEFAULT_BG(&source.bg));
            const VTermScreenCellAttrs &attrs = source.attrs;
            uint16_t attributes = 0;
            if (attrs.bold) attributes |= tui::Bold;
            if (attrs.italic) attributes |= tui::Italic;
            if (attrs.blink) attributes |= tui::Blink;
            if (attrs.reverse) attributes |= tui::Reverse;
            if (attrs.conceal) attributes |= tui::Conceal;
            if (attrs.strike) attributes |= tui::Strike;
            switch (attrs.underline) {
            case VTERM_UNDERLINE_SINGLE: attributes |= tui::Underline; break;
            case VTERM_UNDERLINE_DOUBLE: attributes |= tui::DoubleUnderline; break;
            case VTERM_UNDERLINE_CURLY: attributes |= tui::CurlyUnderline; break;
            default: break;
            }
            cell.style.attributes = attributes;
            surface.put(x + col, y + row, cell);
        }
    }
    return true;
}

TuiTerminals::Cursor TuiTerminals::cursor(const QString &id) const {
    const View *current = view(id);
    if (!current) return {};
    Cursor result{current->cursor.col, current->cursor.row, current->cursorVisible, 0};
    if (current->shapeSet) {
        const int steady = current->cursorBlink ? 0 : 1;
        switch (current->cursorShape) {
        case VTERM_PROP_CURSORSHAPE_UNDERLINE: result.shape = 3 + steady; break;
        case VTERM_PROP_CURSORSHAPE_BAR_LEFT: result.shape = 5 + steady; break;
        default: result.shape = 1 + steady; break;
        }
    }
    return result;
}

bool TuiTerminals::wantsMouse(const QString &id) const {
    const View *current = view(id);
    return current && current->mouse != VTERM_PROP_MOUSE_NONE;
}

void TuiTerminals::sendKey(const QString &id, const tui::InputEvent &event) {
    View *current = view(id);
    if (!current || event.type != tui::InputEvent::Type::Key) return;
    const auto modifiers = VTermModifier(event.modifiers & VTERM_ALL_MODS_MASK);
    VTermKey key = VTERM_KEY_NONE;
    switch (event.key) {
    case tui::Key::Character: vterm_keyboard_unichar(current->vt, uint32_t(event.codepoint), modifiers); break;
    case tui::Key::Enter: key = VTERM_KEY_ENTER; break;
    case tui::Key::Tab: key = VTERM_KEY_TAB; break;
    case tui::Key::Backspace: key = VTERM_KEY_BACKSPACE; break;
    case tui::Key::Escape: key = VTERM_KEY_ESCAPE; break;
    case tui::Key::Up: key = VTERM_KEY_UP; break;
    case tui::Key::Down: key = VTERM_KEY_DOWN; break;
    case tui::Key::Left: key = VTERM_KEY_LEFT; break;
    case tui::Key::Right: key = VTERM_KEY_RIGHT; break;
    case tui::Key::Insert: key = VTERM_KEY_INS; break;
    case tui::Key::Delete: key = VTERM_KEY_DEL; break;
    case tui::Key::Home: key = VTERM_KEY_HOME; break;
    case tui::Key::End: key = VTERM_KEY_END; break;
    case tui::Key::PageUp: key = VTERM_KEY_PAGEUP; break;
    case tui::Key::PageDown: key = VTERM_KEY_PAGEDOWN; break;
    case tui::Key::Function: key = VTermKey(VTERM_KEY_FUNCTION(event.function)); break;
    case tui::Key::None:
    case tui::Key::Menu: return;
    }
    if (key != VTERM_KEY_NONE) vterm_keyboard_key(current->vt, key, modifiers);
    flushInput(current);
    emit interacted(id);
}

void TuiTerminals::sendPaste(const QString &id, const QByteArray &text) {
    View *current = view(id);
    if (!current) return;
    QByteArray bytes = text;
    bytes.replace("\r\n", "\r").replace('\n', '\r');
    // Removal can join fragments into a new terminator, so repeat until none remains.
    while (bytes.contains("\x1b[201~")) bytes.replace("\x1b[201~", "");
    vterm_keyboard_start_paste(current->vt);
    current->input.append(bytes);
    vterm_keyboard_end_paste(current->vt);
    flushInput(current);
    emit interacted(id);
}

void TuiTerminals::sendMouse(const QString &id, const tui::InputEvent &event, int col, int row) {
    View *current = view(id);
    if (!current || event.type != tui::InputEvent::Type::Mouse) return;
    const auto modifiers = VTermModifier(event.modifiers & VTERM_ALL_MODS_MASK);
    // Reports carry the last moved-to position, so every event moves first.
    vterm_mouse_move(current->vt, row, col, modifiers);
    int button = 0;
    bool pressed = true;
    switch (event.action) {
    case tui::MouseAction::Press:
    case tui::MouseAction::Release:
        pressed = event.action == tui::MouseAction::Press;
        button = event.button == tui::MouseButton::Left ? 1 : event.button == tui::MouseButton::Middle ? 2 : event.button == tui::MouseButton::Right ? 3 : 0;
        break;
    case tui::MouseAction::Move: break;
    case tui::MouseAction::WheelUp: button = 4; break;
    case tui::MouseAction::WheelDown: button = 5; break;
    case tui::MouseAction::WheelLeft: button = 6; break;
    case tui::MouseAction::WheelRight: button = 7; break;
    }
    if (button) vterm_mouse_button(current->vt, button, pressed, modifiers);
    flushInput(current);
    if (button) emit interacted(id);
}
