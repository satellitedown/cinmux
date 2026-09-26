#pragma once

#include "terminal_renderer.h"
#include <QHash>
#include <QPointer>
#include <QProcessEnvironment>

class QProcess;
class StateStore;
class TerminalCompositor;

// GUI renderer: one Foot client per displayed session, connected to the
// in-process nested compositor and running `tmux attach-session`.
class FootRenderer final : public TerminalRenderer {
    Q_OBJECT
public:
    FootRenderer(StateStore *store, TerminalCompositor *compositor, QObject *parent = nullptr);
    ~FootRenderer() override;
    // Foot's initial color theme for views started afterwards: "light" or "dark".
    void setColorMode(const QString &mode);
    void attach(const QString &id, bool force) override;
    void detach(const QString &id) override;
    bool attached(const QString &id) const override;
private:
    struct View {
        QPointer<QProcess> process;
        QByteArray stderrOutput;
        quint64 generation = 0;
    };
    StateStore *m_store;
    TerminalCompositor *m_compositor;
    QProcessEnvironment m_hostEnvironment;
    QString m_footProgram;
    QString m_tmuxProgram;
    QString m_colorMode = QStringLiteral("dark");
    QHash<QString, View> m_views;
    quint64 m_generation = 0;
    bool m_shuttingDown = false;
};
