#include "cli.h"
#include "state_store.h"

#include <QCoreApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QSet>
#include <QStandardPaths>
#include <QTextStream>

namespace {
int error(int code, const QString &message) { QTextStream(stderr) << "cinmux: " << message << '\n'; return code; }
int help() {
    QTextStream(stdout) << "Cinmux — persistent terminal workspaces\n\n"
        "Usage:\n"
        "  cinmux                         Open the workspace window\n"
        "  cinmux tui                     Open the workspace in this terminal (e.g. over SSH)\n"
        "  cinmux notify [--session UUID] --title TEXT [--body TEXT]\n"
        "  cinmux activity --state idle|working|waiting|done --pid PID\n"
        "                  [--detail TEXT] [--session UUID]\n"
        "  cinmux list --json\n"
        "  cinmux --help\n"
        "  cinmux --version\n\n"
        "notify and activity use CINMUX_SESSION_ID when --session is omitted.\n"
        "CINMUX_STATE_DIR selects an absolute, isolated state directory.\n"
        "Notifications remain durable when the GUI is closed. OSC notifications\n"
        "require a live Foot renderer; this CLI does not.\n"
        "Activity --pid is the reporting OMP process, not this CLI process.\n"
        "Activity detail is plain text, limited to 1024 characters.\n";
    return 0;
}
bool snapshot(StateStore &store, QList<TmuxPane> *panes, QString *message) {
    const QString executable = QStandardPaths::findExecutable(QStringLiteral("tmux"));
    if (executable.isEmpty()) { *message = QStringLiteral("tmux is not installed or is not on PATH"); return false; }
    QProcess process;
    auto environment = QProcessEnvironment::systemEnvironment();
    environment.remove(QStringLiteral("TMUX")); environment.remove(QStringLiteral("TMUX_PANE")); environment.remove(QStringLiteral("WAYLAND_SOCKET"));
    environment.insert(QStringLiteral("LC_ALL"), QStringLiteral("C"));
    process.setProcessEnvironment(environment);
    process.start(executable, {QStringLiteral("-S"), store.tmuxSocket(), QStringLiteral("list-panes"), QStringLiteral("-a"), QStringLiteral("-F"), StateStore::paneFormat()});
    if (!process.waitForStarted(5000)) { *message = process.errorString(); return false; }
    if (!process.waitForFinished(5000)) {
        process.kill(); process.waitForFinished(1000);
        *message = QStringLiteral("tmux status request timed out"); return false;
    }
    const QByteArray stderrOutput = process.readAllStandardError();
    if (process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0) {
        if (StateStore::serverAbsent(store.tmuxSocket(), stderrOutput)) return true;
        *message = QString::fromUtf8(stderrOutput).trimmed(); return false;
    }
    return StateStore::parsePanes(process.readAllStandardOutput(), panes, message);
}
}

int runCli(const QStringList &args) {
    if (args.size() < 2) return help();
    const QString action = args[1];
    if (action == QStringLiteral("--help") || action == QStringLiteral("-h") || action == QStringLiteral("help")) return help();
    if (action == QStringLiteral("--version")) {
        const QString version = QCoreApplication::applicationVersion();
        QTextStream(stdout) << "cinmux " << (version.isEmpty() ? QStringLiteral("0.1.0") : version) << '\n'; return 0;
    }
    if (action != QStringLiteral("notify") && action != QStringLiteral("activity") && action != QStringLiteral("list")) return error(2, QStringLiteral("unknown command; use --help"));
    QString id = qEnvironmentVariable("CINMUX_SESSION_ID");
    QString title;
    QString body;
    QString activity;
    QString detail;
    ActivityReporter reporter;
    if (action == QStringLiteral("notify")) {
        QSet<QString> supplied;
        for (int i = 2; i < args.size(); ++i) {
            const QString option = args[i];
            if (option == QStringLiteral("--help") || option == QStringLiteral("-h")) return help();
            if (option != QStringLiteral("--session") && option != QStringLiteral("--title") && option != QStringLiteral("--body")) return error(2, QStringLiteral("unknown notify option: %1").arg(option));
            if (supplied.contains(option)) return error(2, QStringLiteral("duplicate option: %1").arg(option));
            supplied.insert(option);
            if (++i >= args.size()) return error(2, QStringLiteral("missing value for %1").arg(option));
            if (option == QStringLiteral("--session")) id = args[i];
            else if (option == QStringLiteral("--title")) title = args[i];
            else body = args[i];
        }
        if (!StateStore::validId(id)) return error(2, QStringLiteral("provide a lowercase session UUID with --session or CINMUX_SESSION_ID"));
        if (title.trimmed().isEmpty()) return error(2, QStringLiteral("--title must be nonblank"));
    } else if (action == QStringLiteral("activity")) {
        QString pidText;
        QSet<QString> supplied;
        for (int i = 2; i < args.size(); ++i) {
            const QString option = args[i];
            if (option == QStringLiteral("--help") || option == QStringLiteral("-h")) return help();
            if (option != QStringLiteral("--session") && option != QStringLiteral("--state") && option != QStringLiteral("--pid") && option != QStringLiteral("--detail"))
                return error(2, QStringLiteral("unknown activity option: %1").arg(option));
            if (supplied.contains(option)) return error(2, QStringLiteral("duplicate option: %1").arg(option));
            supplied.insert(option);
            if (++i >= args.size()) return error(2, QStringLiteral("missing value for %1").arg(option));
            if (option == QStringLiteral("--session")) id = args[i];
            else if (option == QStringLiteral("--state")) activity = args[i];
            else if (option == QStringLiteral("--pid")) pidText = args[i];
            else detail = args[i];
        }
        if (!StateStore::validId(id)) return error(2, QStringLiteral("provide a lowercase session UUID with --session or CINMUX_SESSION_ID"));
        if (!StateStore::validActivity(activity)) return error(2, QStringLiteral("--state must be idle, working, waiting or done"));
        if (detail.size() > StateStore::activityDetailLimit) return error(2, QStringLiteral("--detail must contain at most %1 characters").arg(StateStore::activityDetailLimit));
        static const QRegularExpression pidPattern(QStringLiteral("\\A[1-9][0-9]*\\z"));
        bool validPid = false;
        const qint64 pid = pidText.toLongLong(&validPid);
        if (!validPid || !pidPattern.match(pidText).hasMatch()) return error(2, QStringLiteral("--pid must be a positive process ID"));
        QString message;
        if (!StateStore::processIdentity(pid, &reporter, &message)) return error(2, message);
    } else if (args.size() != 3 || args[2] != QStringLiteral("--json")) {
        if (args.size() == 3 && (args[2] == QStringLiteral("--help") || args[2] == QStringLiteral("-h"))) return help();
        return error(2, QStringLiteral("usage: cinmux list --json"));
    }
    StateStore store({}, false);
    if (!store.open()) return error(1, store.error());
    if (action == QStringLiteral("notify")) {
        bool found = false;
        if (!store.notify(id, title, body, &found)) return error(1, store.error());
        return found ? 0 : error(2, QStringLiteral("unknown session UUID: %1").arg(id));
    }
    if (action == QStringLiteral("activity")) {
        bool found = false;
        bool invalidReporter = false;
        if (!store.setActivity(id, activity, reporter, detail, &found, &invalidReporter)) return error(invalidReporter ? 2 : 1, store.error());
        return found ? 0 : error(2, QStringLiteral("unknown session UUID: %1").arg(id));
    }
    QList<SessionRecord> records;
    if (!store.sessions(&records)) return error(1, store.error());
    QList<TmuxPane> panes;
    QString message;
    if (!records.isEmpty() && !snapshot(store, &panes, &message)) return error(1, message);
    QSet<QString> running;
    for (const auto &pane : panes) if (!pane.dead) running.insert(pane.sessionName);
    QJsonArray array;
    for (const auto &record : records) {
        QJsonObject object;
        object.insert(QStringLiteral("id"), record.id);
        object.insert(QStringLiteral("title"), record.title);
        object.insert(QStringLiteral("folderId"), record.folderId.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(record.folderId));
        object.insert(QStringLiteral("cwd"), record.cwd);
        object.insert(QStringLiteral("status"), running.contains(StateStore::sessionName(record.id)) ? QStringLiteral("running") : QStringLiteral("stopped"));
        object.insert(QStringLiteral("unreadCount"), qMax<qint64>(0, record.noticeSequence - record.readSequence));
        object.insert(QStringLiteral("activity"), record.activity);
        object.insert(QStringLiteral("activityDetail"), record.activityDetail);
        array.append(object);
    }
    QTextStream(stdout) << QJsonDocument(array).toJson(QJsonDocument::Compact) << '\n';
    return 0;
}
