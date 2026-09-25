#pragma once
#include <QObject>
#include <QHash>
#include <QImage>
#include <QPointer>
#include <QSet>
#include <QTimer>
#include <QVariantList>
#include "native_server.h"
#include <deque>

class QQuickWindow;
class QKeyEvent;
class QSocketNotifier;
class TerminalSurfaceItem;
class ClipboardBridge;
struct wl_keyboard;
struct wl_registry;
struct wl_seat;

class TerminalView final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString sessionId READ sessionId CONSTANT)
    Q_PROPERTY(bool ready READ ready NOTIFY readyChanged)
public:
    TerminalView(const QString &id, QObject *parent) : QObject(parent), m_id(id) {}
    QString sessionId() const { return m_id; }
    bool ready() const { return m_ready; }
signals:
    void frameChanged();
    void cursorChanged();
    void readyChanged();
private:
    friend class TerminalCompositor;
    friend class TerminalSurfaceItem;
    QString m_id;
    bool m_ready = false;
    QImage m_image;
    QSize m_logicalSize;
    quint64 m_frameRevision = 0;
    QImage m_cursorImage;
    QSize m_cursorSize;
    QPoint m_hotspot;
    bool m_cursorKnown = false;
    quint64 m_cursorRevision = 0;
    QPointer<TerminalSurfaceItem> m_item;
};

class TerminalCompositor final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList views READ views NOTIFY viewsChanged)
    Q_PROPERTY(QString selectedId READ selectedId WRITE setSelectedId NOTIFY selectedIdChanged)
    Q_PROPERTY(bool inputEnabled READ inputEnabled WRITE setInputEnabled NOTIFY inputEnabledChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
public:
    explicit TerminalCompositor(const QString &profileHash, QObject *parent = nullptr);
    ~TerminalCompositor() override;
    void create();
    bool isCreated() const { return m_server != nullptr; }
    QByteArray socketName() const { return m_socket; }
    void initialize(QQuickWindow *window);
    int bufferScale() const { return m_scale; }
    void expectClient(QString id, qint64 pid);
    void forgetClient(QString id);
    QVariantList views() const { return m_viewObjects; }
    QString selectedId() const { return m_selectedId; }
    void setSelectedId(const QString &id);
    bool inputEnabled() const { return m_inputEnabled; }
    void setInputEnabled(bool enabled);
    QString error() const { return m_error; }
    Q_INVOKABLE void configure(QString id, int width, int height);
    Q_INVOKABLE void focusTerminal(QString id);
    Q_INVOKABLE void clearFocus();
    void registerItem(TerminalView *view, TerminalSurfaceItem *item);
    void pointerMove(const QString &id, const QPointF &point, quint32 time);
    void pointerLeave();
    void pointerButton(Qt::MouseButton button, bool pressed, quint32 time);
    void pointerScroll(const QPoint &angle, const QPoint &pixels, quint32 time);
    void inputMethod(const QString &preedit, int cursor, const QString &commit);
    void interact(const QString &id);
signals:
    void viewsChanged();
    void selectedIdChanged();
    void inputEnabledChanged();
    void errorChanged();
    void viewReady(QString id);
    void viewLost(QString id, QString error);
    void shortcutTriggered(QString action);
    void terminalInteracted(QString id);
protected:
    bool eventFilter(QObject *watched, QEvent *event) override;
private:
    void dispatch();
    void updateOutput();
    void updateFocus();
    bool terminalHasFocus() const;
    void setError(const QString &error);
    void observeHostSeat();
    void releaseHostSeat();
    void attachHostKeyboard();
    struct KeyboardState {
        QByteArray keymap;
        quint64 revision = 0;
        quint32 depressed = 0, latched = 0, locked = 0, group = 0;
    };
    struct PendingKey {
        quint32 time, code;
        bool pressed;
        KeyboardState state;
    };
    void applyKeyboardState(const KeyboardState &state);
    void forwardKey(const QKeyEvent *key, bool deliver);
    void releaseKeys();
    void addView(const QString &id);
    void removeView(const QString &id, const QString &error);
    cm_server *m_server = nullptr;
    QByteArray m_socket;
    QPointer<QQuickWindow> m_window;
    QSocketNotifier *m_notifier = nullptr;
    ClipboardBridge *m_clipboard = nullptr;
    wl_registry *m_hostRegistry = nullptr;
    wl_seat *m_hostSeat = nullptr;
    quint32 m_hostSeatName = 0;
    wl_keyboard *m_hostKeyboard = nullptr;
    QHash<QString, TerminalView *> m_views;
    QVariantList m_viewObjects;
    QHash<QString, quint64> m_generations;
    QSet<quint64> m_consumedKeys;
    QSet<quint32> m_pressed;
    KeyboardState m_hostState;
    quint64 m_appliedKeymap = 0;
    std::deque<PendingKey> m_pendingKeys;
    QTimer m_hiddenFrames;
    QString m_selectedId;
    QString m_error;
    bool m_inputEnabled = false;
    bool m_focusPending = false;
    bool m_updatingFocus = false;
    bool m_dispatching = false;
    bool m_shuttingDown = false;
    int m_scale = 1;
};
