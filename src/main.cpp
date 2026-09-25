#include "cli.h"
#include "session_controller.h"
#include "state_store.h"
#include "terminal_compositor.h"
#include "terminal_surface_item.h"
#include "theme.h"
#include <QCoreApplication>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QQuickStyle>
#include <QLockFile>
#include <QLocalServer>
#include <QLocalSocket>
#include <QSettings>
#include <QTimer>
#include <QFileInfo>
#include <QFont>
#include <cstdio>
#include <unistd.h>
#include <vector>

static int hostExec(int argc, char **argv)
{
    if (argc < 3) { std::fprintf(stderr, "cinmux: --host-exec requires a program\n"); return 2; }
    if (const char *host = std::getenv("CINMUX_HOST_WAYLAND_DISPLAY")) {
        if (*host) setenv("WAYLAND_DISPLAY", host, 1); else unsetenv("WAYLAND_DISPLAY");
    }
    unsetenv("WAYLAND_SOCKET"); unsetenv("TMUX"); unsetenv("TMUX_PANE");
    execvp(argv[2], argv + 2);
    std::perror("cinmux: exec"); return 1;
}

static int startupFailure(QGuiApplication &app, Theme &theme, const QString &message)
{
    std::fprintf(stderr, "cinmux: %s\n", qPrintable(message));
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("themeService", &theme);
    engine.rootContext()->setContextProperty("startupError", message);
    engine.loadFromModule("Cinmux", "StartupError");
    if (!engine.rootObjects().isEmpty()) app.exec();
    return 1;
}

int main(int argc, char **argv)
{
    if (argc > 1 && QByteArray(argv[1]) == "--host-exec") return hostExec(argc, argv);
    QCoreApplication::setApplicationName("cinmux");
    QCoreApplication::setOrganizationName("niay");
    QCoreApplication::setApplicationVersion("1.0.0");
    if (argc > 1) {
        QCoreApplication app(argc, argv);
        return runCli(app.arguments());
    }
    QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
    QQuickWindow::setDefaultAlphaBuffer(true);
    QQuickStyle::setStyle("Basic");
    QGuiApplication app(argc, argv);
    app.setDesktopFileName("io.niay.cinmux");
    app.setApplicationDisplayName("Cinmux");
    QFont font("Noto Sans"); font.setPixelSize(13); font.setStyleHint(QFont::SansSerif); app.setFont(font);
    qmlRegisterType<TerminalSurfaceItem>("Cinmux.Native", 1, 0, "TerminalSurfaceItem");
    Theme theme;
    StateStore store;
    if (!store.open()) return startupFailure(app, theme, store.error());
    QLockFile lock(store.runtimeDirectory() + "/ui.lock");
    lock.setStaleLockTime(0);
    if (!lock.tryLock()) {
        QLocalSocket peer;
        peer.connectToServer(store.runtimeDirectory() + "/ui.sock");
        if (!peer.waitForConnected(2000)) return startupFailure(app, theme, "The existing Cinmux window is not responding.");
        peer.write("activate\n"); peer.waitForBytesWritten(2000); return 0;
    }
    QLocalServer server;
    server.setSocketOptions(QLocalServer::UserAccessOption);
    QLocalServer::removeServer(store.runtimeDirectory() + "/ui.sock");
    if (!server.listen(store.runtimeDirectory() + "/ui.sock")) return startupFailure(app, theme, server.errorString());
    QSettings settings(store.stateDirectory() + "/ui.ini", QSettings::IniFormat);
    QVariantMap preferences;
    const QStringList keys = {"window/width", "window/height", "window/maximized", "panes/foldersVisible", "panes/sessionsVisible", "panes/foldersWidth", "panes/sessionsWidth"};
    const QVariantList defaults = {1280, 840, false, true, true, 220, 300};
    for (int i = 0; i < keys.size(); ++i) preferences[keys[i]] = settings.value(keys[i], defaults[i]);
    TerminalCompositor compositor(store.profileHash());
    compositor.create();
    if (!compositor.isCreated()) return startupFailure(app, theme, compositor.error());
    SessionController controller(&store, &compositor);
    controller.setColorMode(theme.mode());
    QObject::connect(&theme, &Theme::changed, &controller, [&] { controller.setColorMode(theme.mode()); });
    controller.setView(settings.value("selection/view", "all").toString());
    const QString selected = settings.value("selection/session").toString();
    if (!selected.isEmpty()) controller.selectSession(selected);
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("controller", &controller);
    engine.rootContext()->setContextProperty("terminalCompositor", &compositor);
    engine.rootContext()->setContextProperty("initialUi", preferences);
    engine.rootContext()->setContextProperty("themeService", &theme);
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.loadFromModule("Cinmux", "Main");
    if (engine.rootObjects().isEmpty()) return 1;
    auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
    if (!window) return 1;
    compositor.initialize(window);
    std::fprintf(stderr, "Cinmux native output: DPR %.3f, buffer scale %d\n", window->devicePixelRatio(), compositor.bufferScale());
    QObject::connect(&server, &QLocalServer::newConnection, &app, [&] {
        while (auto *socket = server.nextPendingConnection()) {
            QObject::connect(socket, &QLocalSocket::readyRead, socket, [socket, window] {
                if (socket->bytesAvailable() > 32) { socket->disconnectFromServer(); return; }
                if (socket->canReadLine()) {
                    if (socket->readLine() == "activate\n") { window->show(); window->raise(); window->requestActivate(); }
                    socket->disconnectFromServer();
                }
            });
            QObject::connect(socket, &QLocalSocket::disconnected, socket, &QObject::deleteLater);
            QTimer::singleShot(2000, socket, [socket] { socket->disconnectFromServer(); });
        }
    });
    QObject::connect(&app, &QCoreApplication::aboutToQuit, &app, [&] {
        if (window->visibility() != QWindow::Maximized) {
            settings.setValue("window/width", window->width()); settings.setValue("window/height", window->height());
        }
        settings.setValue("window/maximized", window->visibility() == QWindow::Maximized);
        settings.setValue("panes/foldersVisible", window->property("wideFolders"));
        settings.setValue("panes/sessionsVisible", window->property("wideSessions"));
        settings.setValue("panes/foldersWidth", window->property("desiredFoldersWidth"));
        settings.setValue("panes/sessionsWidth", window->property("desiredSessionsWidth"));
        settings.setValue("selection/view", controller.view()); settings.setValue("selection/session", controller.selectedId());
        settings.sync();
        if (settings.status() != QSettings::NoError) std::fprintf(stderr, "cinmux: could not save GUI preferences\n");
    });
    return app.exec();
}
