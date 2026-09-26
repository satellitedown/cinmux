#pragma once

#include <QObject>
#include <QString>

// Displays the private tmux sessions reconciled by SessionController. The GUI
// renders Foot clients inside the nested compositor; `cinmux tui` renders
// libvterm views of tmux clients inside the user's terminal.
class TerminalRenderer : public QObject {
    Q_OBJECT
public:
    using QObject::QObject;
    // Starts a view attached to the session's tmux session. A live view is
    // kept unless `force` replaces it (reconnect). Failures are reported via
    // lost(), possibly before this call returns.
    virtual void attach(const QString &id, bool force) = 0;
    // Stops the view without affecting the tmux session. Emits nothing.
    virtual void detach(const QString &id) = 0;
    // True while a view process exists for the session.
    virtual bool attached(const QString &id) const = 0;
signals:
    // The view is displayable.
    void ready(const QString &id);
    // The view failed or its process exited; the tmux session is unaffected.
    void lost(const QString &id, const QString &message);
    // User input reached the session's view.
    void interacted(const QString &id);
};
