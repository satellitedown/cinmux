#pragma once

#include "terminal_renderer.h"
#include "tui_input.h"
#include "tui_screen.h"
#include <QHash>
#include <QProcessEnvironment>
#include <memory>

class StateStore;

// `cinmux tui` renderer: one pseudo-terminal per displayed session running
// `tmux -u -S <socket> attach-session -E -t =cinmux-<id>`, emulated with
// libvterm. Views are retained until detached, like Foot views in the GUI.
class TuiTerminals final : public TerminalRenderer {
    Q_OBJECT
public:
    explicit TuiTerminals(StateStore *store, QObject *parent = nullptr);
    ~TuiTerminals() override;
    void attach(const QString &id, bool force) override;
    void detach(const QString &id) override;
    bool attached(const QString &id) const override;

    // Terminal area size in cells. The selected view is resized at once;
    // other views are resized when they become selected. New views start at
    // this size.
    void setSize(int cols, int rows);
    void setSelected(const QString &id);
    // Keyboard focus of the selected view, for VT focus reporting.
    void setFocused(bool focused);
    // True once the view has received output from its tmux client. (Not
    // `ready`, which would hide the inherited TerminalRenderer::ready signal.)
    bool hasOutput(const QString &id) const;
    // Copies the view's screen to `surface` at (x, y), clipped to
    // width x height. False when there is no view.
    bool paint(const QString &id, tui::Surface &surface, int x, int y, int width, int height) const;
    struct Cursor {
        int x = 0;
        int y = 0;
        bool visible = false;
        int shape = 0; // DECSCUSR value: 0 default, 1..6
    };
    // Cursor relative to the view's top-left cell.
    Cursor cursor(const QString &id) const;
    // True when the tmux client enabled mouse reporting.
    bool wantsMouse(const QString &id) const;
    // Input for the view; each emits interacted(id).
    void sendKey(const QString &id, const tui::InputEvent &event);
    void sendPaste(const QString &id, const QByteArray &text);
    // Coordinates are relative to the view's top-left cell. Press, Release
    // and wheel actions emit interacted(id).
    void sendMouse(const QString &id, const tui::InputEvent &event, int col, int row);
signals:
    // Screen content, cursor or mouse mode changed.
    void updated(const QString &id);
    void bell(const QString &id);
    // An OSC 52 clipboard write from a tmux client, as standard base64.
    void clipboard(const QByteArray &base64);
private:
    struct View;
    View *view(const QString &id) const;
    void readOutput(View *view);
    void flushInput(View *view);
    // Applies the current size to the view; true when it changed.
    bool resize(View *view);
    void finished(const QString &id, quint64 generation, int code);
    StateStore *m_store;
    QProcessEnvironment m_environment;
    QString m_tmuxProgram;
    QHash<QString, std::shared_ptr<View>> m_views;
    QString m_selected;
    bool m_focused = false;
    int m_cols = 80;
    int m_rows = 24;
    quint64 m_generation = 0;
};
