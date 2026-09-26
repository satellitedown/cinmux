#include "foot_renderer.h"
#include "state_store.h"
#include "terminal_compositor.h"

#include <QCoreApplication>
#include <QFileInfo>
#include <QProcess>
#include <QStandardPaths>

namespace {
QString launcherQuote(QString argument) {
    argument.replace('\\', QStringLiteral("\\\\"));
    argument.replace('"', QStringLiteral("\\\""));
    return '"' + argument + '"';
}
// Foot warns about every optional protocol the nested compositor lacks; only
// its errors (or unprefixed output) explain why it exited.
QString footErrors(const QByteArray &output) {
    QStringList lines;
    for (const auto &line : QString::fromUtf8(output).split(QLatin1Char('\n'))) {
        const QString text = line.trimmed();
        if (text.isEmpty() || text.startsWith(QLatin1String("warn:")) || text.startsWith(QLatin1String("info:")) || text.startsWith(QLatin1String("dbg:"))) continue;
        lines.append(text);
    }
    return lines.join(QLatin1Char('\n'));
}
}

FootRenderer::FootRenderer(StateStore *store, TerminalCompositor *compositor, QObject *parent)
    : TerminalRenderer(parent), m_store(store), m_compositor(compositor), m_hostEnvironment(QProcessEnvironment::systemEnvironment()) {
    m_hostEnvironment.remove(QStringLiteral("TMUX"));
    m_hostEnvironment.remove(QStringLiteral("TMUX_PANE"));
    m_hostEnvironment.remove(QStringLiteral("WAYLAND_SOCKET"));
    m_footProgram = QStandardPaths::findExecutable(QStringLiteral("foot"));
    m_tmuxProgram = QStandardPaths::findExecutable(QStringLiteral("tmux"));
    connect(m_compositor, &TerminalCompositor::viewReady, this, &TerminalRenderer::ready);
    connect(m_compositor, &TerminalCompositor::viewLost, this, &TerminalRenderer::lost);
    connect(m_compositor, &TerminalCompositor::terminalInteracted, this, &TerminalRenderer::interacted);
}

FootRenderer::~FootRenderer() {
    m_shuttingDown = true;
    const auto ids = m_views.keys();
    for (const auto &id : ids) detach(id);
}

void FootRenderer::setColorMode(const QString &mode) { if (mode == QStringLiteral("light") || mode == QStringLiteral("dark")) m_colorMode = mode; }
bool FootRenderer::attached(const QString &id) const { return m_views.value(id).process; }

void FootRenderer::detach(const QString &id) {
    const auto view = m_views.take(id);
    m_compositor->forgetClient(id);
    if (auto *process = view.process.data()) {
        process->disconnect(this);
        if (process->state() == QProcess::NotRunning) process->deleteLater();
        else {
            connect(process, &QProcess::finished, process, &QObject::deleteLater);
            process->kill();
            if (m_shuttingDown) process->waitForFinished(1000);
        }
    }
}

void FootRenderer::attach(const QString &id, bool force) {
    if (!force && attached(id)) return;
    if (force) detach(id);
    if (m_footProgram.isEmpty()) { emit lost(id, QStringLiteral("Foot is not installed or is not on PATH")); return; }
    if (m_compositor->socketName().isEmpty()) { emit lost(id, QStringLiteral("The nested Wayland compositor has no socket")); return; }
    if (!QFileInfo::exists(qEnvironmentVariable("XDG_RUNTIME_DIR") + '/' + QString::fromUtf8(m_compositor->socketName()))) {
        emit lost(id, QStringLiteral("The nested Wayland compositor socket is unavailable")); return;
    }
    auto *process = new QProcess(this);
    const quint64 generation = ++m_generation;
    m_views.insert(id, {process, {}, generation});
    const QString binary = QCoreApplication::applicationFilePath();
    QStringList args{QStringLiteral("--app-id=io.niay.cinmux.session.") + id};
    const QStringList overrides{
        QStringLiteral("initial-window-mode=windowed"), QStringLiteral("initial-color-theme=") + m_colorMode,
        QStringLiteral("colors-dark.alpha=1"), QStringLiteral("colors-light.alpha=1"),
        QStringLiteral("colors-dark.blur=no"), QStringLiteral("colors-light.blur=no"),
        QStringLiteral("key-bindings.spawn-terminal=none"),
        QStringLiteral("url.launch=") + launcherQuote(binary) + QStringLiteral(" --host-exec xdg-open ${url}"),
        QStringLiteral("desktop-notifications.command=") + launcherQuote(binary) + QStringLiteral(" notify --session ") + id + QStringLiteral(" --title ${title} --body ${body}"),
        QStringLiteral("desktop-notifications.inhibit-when-focused=no")};
    for (const auto &value : overrides) args << QStringLiteral("--override") << value;
    args << QStringLiteral("--") << binary << QStringLiteral("--host-exec") << m_tmuxProgram << QStringLiteral("-S") << m_store->tmuxSocket()
         << QStringLiteral("attach-session") << QStringLiteral("-E") << QStringLiteral("-t") << QStringLiteral("=") + StateStore::sessionName(id);
    auto environment = m_hostEnvironment;
    environment.insert(QStringLiteral("CINMUX_HOST_WAYLAND_DISPLAY"), m_hostEnvironment.value(QStringLiteral("WAYLAND_DISPLAY")));
    environment.insert(QStringLiteral("WAYLAND_DISPLAY"), QString::fromUtf8(m_compositor->socketName()));
    environment.insert(QStringLiteral("CINMUX_STATE_DIR"), m_store->stateDirectory());
    environment.insert(QStringLiteral("CINMUX_SESSION_ID"), id);
    environment.insert(QStringLiteral("CINMUX_TMUX_SOCKET"), m_store->tmuxSocket());
    process->setProcessEnvironment(environment);
    connect(process, &QProcess::started, this, [this, id, generation, process] {
        if (m_views.value(id).generation == generation) m_compositor->expectClient(id, process->processId());
    });
    connect(process, &QProcess::readyReadStandardError, this, [this, id, generation, process] {
        const auto view = m_views.find(id);
        if (view == m_views.end() || view->generation != generation) return;
        view->stderrOutput += process->readAllStandardError();
        view->stderrOutput = view->stderrOutput.right(16384);
    });
    auto exited = [this, id, generation, process](const QString &reason) {
        const auto view = m_views.find(id);
        if (view == m_views.end() || view->generation != generation) return;
        const QByteArray output = view->stderrOutput + process->readAllStandardError();
        m_views.erase(view);
        m_compositor->forgetClient(id);
        process->deleteLater();
        QString message = footErrors(output);
        if (message.isEmpty()) message = reason;
        emit lost(id, message);
    };
    connect(process, &QProcess::finished, this, [exited](int code, QProcess::ExitStatus) { exited(QStringLiteral("Terminal renderer exited (code %1). The tmux session is unaffected; reconnect to view it.").arg(code)); });
    connect(process, &QProcess::errorOccurred, this, [process, exited](QProcess::ProcessError error) { if (error == QProcess::FailedToStart) exited(process->errorString()); });
    process->start(m_footProgram, args);
}
