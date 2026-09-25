#include "session_controller.h"
#include "state_store.h"

#include <QCoreApplication>
#include <QProcess>
#include <QProcessEnvironment>
#include <QScopeGuard>
#include <QSignalSpy>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QTest>
#include <QUuid>
#include <algorithm>

namespace {
QString uuid() { return QUuid::createUuid().toString(QUuid::WithoutBraces); }
SessionRecord record(const QString &cwd, const QString &folder = {}) {
    SessionRecord result;
    result.id = uuid(); result.title = QStringLiteral("Terminal"); result.cwd = cwd; result.folderId = folder; result.createdAt = 1;
    return result;
}
struct PrivateServer {
    QString socket;
    ~PrivateServer() { run({QStringLiteral("kill-server")}); }
    QByteArray run(const QStringList &arguments, bool *ok = nullptr) const {
        QProcess process;
        auto env = QProcessEnvironment::systemEnvironment();
        env.remove(QStringLiteral("TMUX")); env.remove(QStringLiteral("TMUX_PANE"));
        process.setProcessEnvironment(env);
        QStringList args{QStringLiteral("-S"), socket}; args.append(arguments);
        process.start(QStringLiteral("tmux"), args);
        const bool finished = process.waitForStarted(5000) && process.waitForFinished(5000);
        if (!finished) { process.kill(); process.waitForFinished(1000); }
        if (ok) *ok = finished && process.exitStatus() == QProcess::NormalExit && process.exitCode() == 0;
        return process.readAllStandardOutput();
    }
    QList<TmuxPane> panes() const {
        QList<TmuxPane> result;
        QString error;
        StateStore::parsePanes(run({QStringLiteral("list-panes"), QStringLiteral("-a"), QStringLiteral("-F"), StateStore::paneFormat()}), &result, &error);
        return result;
    }
    QList<TmuxPane> owned(const QString &id) const {
        QList<TmuxPane> result;
        for (const auto &pane : panes()) if (pane.sessionName == StateStore::sessionName(id)) result.append(pane);
        return result;
    }
};
}

class BackendTest : public QObject {
    Q_OBJECT
private slots:
    void notificationAcknowledgesOnlyObservedSequence();
    void notificationReloadRetriesAfterReadFailure();
    void folderDeletionPreservesEntryIdentity();
    void lifecyclePreservesShellsAndClosesOnlyOwnedSession();
    void terminalPreservesUtf8Locale();
    void activityMigratesVersionOneWithoutLosingRecords();
    void activityRejectsUnrecognizedSchemas_data();
    void activityRejectsUnrecognizedSchemas();
    void activityAggregatesIndependentReporters();
    void waitingSurvivesSelectionAndAcknowledgement();
    void activityReconcilesDeadAndReusedReporters();
};

void BackendTest::notificationAcknowledgesOnlyObservedSequence() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    StateStore gui(directory.path());
    QVERIFY2(gui.open(), qPrintable(gui.error()));
    auto session = record(directory.path());
    QVERIFY(gui.insertSession(session));
    StateStore cli(directory.path(), false);
    QVERIFY2(cli.open(), qPrintable(cli.error()));
    bool found = false;
    QVERIFY(cli.notify(session.id, QStringLiteral("First"), QStringLiteral("Observed"), &found));
    QVERIFY(found);
    QList<SessionRecord> observed;
    QVERIFY(gui.sessions(&observed));
    QCOMPARE(observed.first().noticeSequence, 1);
    const QString literal = QStringLiteral("<b>not markup</b> '$()'\nsecond line");
    QVERIFY(cli.notify(session.id, QStringLiteral("Second"), literal, &found));
    QVERIFY(gui.acknowledge(session.id, observed.first().noticeSequence));
    QList<SessionRecord> after;
    QVERIFY(gui.sessions(&after));
    QCOMPARE(after.first().noticeSequence - after.first().readSequence, 1);
    QCOMPARE(after.first().noticeTitle, QStringLiteral("Second"));
    QCOMPARE(after.first().noticeBody, literal);
    QVERIFY(gui.acknowledge(session.id, 0));
    QVERIFY(gui.sessions(&after));
    QCOMPARE(after.first().noticeSequence - after.first().readSequence, 1);
    QVERIFY(gui.acknowledge(session.id, 999));
    QVERIFY(gui.sessions(&after));
    QCOMPARE(after.first().readSequence, after.first().noticeSequence);
}

void BackendTest::notificationReloadRetriesAfterReadFailure() {
    QTemporaryDir directory;
    StateStore gui(directory.path());
    QVERIFY2(gui.open(), qPrintable(gui.error()));
    auto session = record(directory.path());
    QVERIFY(gui.insertSession(session));
    auto connection = [&directory](const QString &except = {}) {
        for (const auto &name : QSqlDatabase::connectionNames()) {
            auto db = QSqlDatabase::database(name);
            if (name != except && db.databaseName() == directory.path() + "/state.sqlite") return db;
        }
        return QSqlDatabase();
    };
    auto guiConnection = connection();
    QVERIFY(guiConnection.isValid());
    StateStore cli(directory.path(), false);
    QVERIFY2(cli.open(), qPrintable(cli.error()));
    SessionController controller(&gui, nullptr);
    QSignalSpy errors(&controller, &SessionController::operationFailed);
    bool found = false;
    QVERIFY(cli.notify(session.id, QStringLiteral("Needs input"), {}, &found));
    QVERIFY(found);
    // Interrupt a reload after the notification commits, then repair through the
    // reader's connection: its data_version does not change for its own commits.
    QSqlQuery interrupt(connection(guiConnection.connectionName()));
    QVERIFY(interrupt.exec("ALTER TABLE folders RENAME TO unavailable_folders"));
    QTRY_VERIFY_WITH_TIMEOUT(!errors.isEmpty(), 1500);
    QCOMPARE(controller.attentionCount(), 0);
    QSqlQuery repair(guiConnection);
    QVERIFY(repair.exec("ALTER TABLE unavailable_folders RENAME TO folders"));
    QTRY_COMPARE_WITH_TIMEOUT(controller.attentionCount(), 1, 1500);
}

void BackendTest::folderDeletionPreservesEntryIdentity() {
    QTemporaryDir directory;
    StateStore store(directory.path());
    QVERIFY2(store.open(), qPrintable(store.error()));
    const QString folder = uuid();
    QVERIFY(store.createFolder(folder, QStringLiteral("Straße")));
    QVERIFY(!store.createFolder(uuid(), QStringLiteral("STRASSE")));
    auto session = record(directory.path(), folder);
    QVERIFY(store.insertSession(session));
    bool found = false;
    QVERIFY(store.notify(session.id, QStringLiteral("Needs attention"), QStringLiteral("Keep this"), &found));
    QVERIFY(found);
    QVERIFY(store.deleteFolder(folder));
    QList<SessionRecord> after;
    QVERIFY(store.sessions(&after));
    QCOMPARE(after.size(), 1);
    QCOMPARE(after.first().id, session.id);
    QCOMPARE(after.first().cwd, session.cwd);
    QVERIFY(after.first().folderId.isEmpty());
    QCOMPARE(after.first().noticeSequence - after.first().readSequence, 1);
}

void BackendTest::lifecyclePreservesShellsAndClosesOnlyOwnedSession() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    StateStore store(directory.path());
    QVERIFY2(store.open(), qPrintable(store.error()));
    PrivateServer server{store.tmuxSocket()};
    const QByteArray oldShell = qgetenv("SHELL");
    qputenv("SHELL", "/bin/sh");
    QString first;
    QString second;
    qint64 firstPid = 0;
    qint64 secondPid = 0;
    {
        SessionController controller(&store, nullptr);
        controller.createSession({}, directory.path());
        first = controller.selectedId();
        QVERIFY(StateStore::validId(first));
        QTRY_COMPARE_WITH_TIMEOUT(controller.selected().value("status").toString(), QStringLiteral("running"), 10000);
        QTRY_COMPARE_WITH_TIMEOUT(server.owned(first).size(), 1, 10000);
        firstPid = server.owned(first).first().pid;
        controller.createSession({}, directory.path());
        second = controller.selectedId();
        QTRY_COMPARE_WITH_TIMEOUT(controller.selected().value("status").toString(), QStringLiteral("running"), 10000);
        QTRY_COMPARE_WITH_TIMEOUT(server.owned(second).size(), 1, 10000);
        secondPid = server.owned(second).first().pid;
        controller.createFolder(QStringLiteral("Live"));
        const QString folder = controller.folders().first().toMap().value("id").toString();
        controller.moveSession(first, folder);
        controller.deleteFolder(folder);
        QList<SessionRecord> entries;
        QVERIFY(store.sessions(&entries));
        const auto a = std::find_if(entries.cbegin(), entries.cend(), [&first](const auto &r) { return r.id == first; });
        QVERIFY(a != entries.cend());
        QVERIFY(a->folderId.isEmpty());
        QCOMPARE(server.owned(first).first().pid, firstPid);
    }
    QCOMPARE(server.owned(first).first().pid, firstPid);
    QCOMPARE(server.owned(second).first().pid, secondPid);
    {
        SessionController reopened(&store, nullptr);
        reopened.selectSession(first);
        QTRY_COMPARE_WITH_TIMEOUT(reopened.selected().value("status").toString(), QStringLiteral("running"), 10000);
        reopened.reconnectTerminal(first);
        reopened.startSession(first, {});
        reopened.splitActive(QStringLiteral("right"));
        QTRY_COMPARE_WITH_TIMEOUT(server.owned(first).size(), 2, 10000);
        const auto panes = server.owned(first);
        QVERIFY(std::any_of(panes.cbegin(), panes.cend(), [firstPid](const auto &p) { return p.pid == firstPid; }));
        QCOMPARE(server.owned(second).first().pid, secondPid);
        reopened.closeSession(first);
        QTRY_COMPARE_WITH_TIMEOUT(reopened.totalCount(), 1, 10000);
        QVERIFY(server.owned(first).isEmpty());
        QCOMPARE(server.owned(second).first().pid, secondPid);
        bool killed = false;
        server.run({QStringLiteral("kill-session"), QStringLiteral("-t"), '=' + StateStore::sessionName(second)}, &killed);
        QVERIFY(killed);
    }
    {
        SessionController stopped(&store, nullptr);
        stopped.selectSession(second);
        stopped.refresh();
        QTest::qWait(1200);
        QCOMPARE(stopped.selected().value("status").toString(), QStringLiteral("stopped"));
        QVERIFY(server.owned(second).isEmpty());
        QCOMPARE(stopped.totalCount(), 1);
        stopped.startSession(second, {});
        QTRY_COMPARE_WITH_TIMEOUT(stopped.selected().value("status").toString(), QStringLiteral("running"), 10000);
        QTRY_COMPARE_WITH_TIMEOUT(server.owned(second).size(), 1, 10000);
        QVERIFY(server.owned(second).first().pid != secondPid);
    }
    if (oldShell.isNull()) qunsetenv("SHELL"); else qputenv("SHELL", oldShell);
}

void BackendTest::terminalPreservesUtf8Locale() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto previousShell = qgetenv("SHELL");
    const auto previousLanguage = qgetenv("LANG");
    const auto previousLocale = qgetenv("LC_ALL");
    const auto previousCharacterType = qgetenv("LC_CTYPE");
    const auto restoreEnvironment = qScopeGuard([&] {
        if (previousShell.isNull()) qunsetenv("SHELL"); else qputenv("SHELL", previousShell);
        if (previousLanguage.isNull()) qunsetenv("LANG"); else qputenv("LANG", previousLanguage);
        if (previousLocale.isNull()) qunsetenv("LC_ALL"); else qputenv("LC_ALL", previousLocale);
        if (previousCharacterType.isNull()) qunsetenv("LC_CTYPE"); else qputenv("LC_CTYPE", previousCharacterType);
    });
    qputenv("SHELL", "/bin/sh");
    qputenv("LANG", "C.UTF-8");
    qunsetenv("LC_ALL");
    qunsetenv("LC_CTYPE");
    StateStore store(directory.path());
    QVERIFY2(store.open(), qPrintable(store.error()));
    PrivateServer server{store.tmuxSocket()};
    SessionController controller(&store, nullptr);
    controller.createSession({}, directory.path());
    QTRY_COMPARE_WITH_TIMEOUT(controller.selected().value("status").toString(), QStringLiteral("running"), 10000);
    QTRY_COMPARE_WITH_TIMEOUT(server.owned(controller.selectedId()).size(), 1, 10000);
    const QString target = server.owned(controller.selectedId()).first().paneId;
    bool sent = false;
    server.run({QStringLiteral("send-keys"), QStringLiteral("-t"), target, QStringLiteral("locale charmap"), QStringLiteral("Enter")}, &sent);
    QVERIFY(sent);
    QTRY_VERIFY_WITH_TIMEOUT(server.run({QStringLiteral("capture-pane"), QStringLiteral("-p"), QStringLiteral("-t"), target}).split('\n').contains("UTF-8"), 1500);
}

void BackendTest::activityMigratesVersionOneWithoutLosingRecords() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const QString folder = uuid();
    auto first = record(directory.path(), folder);
    auto second = record(directory.path());
    const QString connection = uuid();
    {
        auto database = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connection);
        database.setDatabaseName(directory.path() + QStringLiteral("/state.sqlite"));
        QVERIFY(database.open());
        QSqlQuery query(database);
        QVERIFY(query.exec("CREATE TABLE folders(id TEXT PRIMARY KEY, name TEXT NOT NULL, position INTEGER NOT NULL)"));
        QVERIFY(query.exec("CREATE TABLE sessions(id TEXT PRIMARY KEY, folder_id TEXT REFERENCES folders(id) ON DELETE SET NULL, title TEXT NOT NULL, pinned INTEGER NOT NULL DEFAULT 0, cwd TEXT NOT NULL, created_at INTEGER NOT NULL, notice_seq INTEGER NOT NULL DEFAULT 0, read_seq INTEGER NOT NULL DEFAULT 0, notice_title TEXT NOT NULL DEFAULT '', notice_body TEXT NOT NULL DEFAULT '', notice_at INTEGER NOT NULL DEFAULT 0)"));
        QVERIFY(query.prepare("INSERT INTO folders VALUES(?, 'Saved folder', 7)"));
        query.addBindValue(folder);
        QVERIFY(query.exec());
        QVERIFY(query.prepare("INSERT INTO sessions VALUES(?, ?, 'Pinned session', 1, ?, 123, 9, 7, 'Review', 'Keep <literal> content', 456)"));
        query.addBindValue(first.id); query.addBindValue(folder); query.addBindValue(directory.path());
        QVERIFY(query.exec());
        QVERIFY(query.prepare("INSERT INTO sessions(id,title,cwd,created_at) VALUES(?,'Unfiled',?,789)"));
        query.addBindValue(second.id); query.addBindValue(directory.path());
        QVERIFY(query.exec());
        QVERIFY(query.exec("PRAGMA user_version=1"));
    }
    QSqlDatabase::removeDatabase(connection);
    StateStore migrated(directory.path(), false);
    QVERIFY2(migrated.open(), qPrintable(migrated.error()));
    QList<SessionRecord> entries;
    QList<FolderRecord> folders;
    QVERIFY(migrated.sessions(&entries));
    QVERIFY(migrated.folders(&folders));
    QCOMPARE(entries.size(), 2);
    QCOMPARE(entries[0].id, first.id);
    QCOMPARE(entries[0].folderId, folder);
    QCOMPARE(entries[0].title, QStringLiteral("Pinned session"));
    QVERIFY(entries[0].pinned);
    QCOMPARE(entries[0].cwd, directory.path());
    QCOMPARE(entries[0].createdAt, 123);
    QCOMPARE(entries[0].noticeSequence, 9);
    QCOMPARE(entries[0].readSequence, 7);
    QCOMPARE(entries[0].noticeTitle, QStringLiteral("Review"));
    QCOMPARE(entries[0].noticeBody, QStringLiteral("Keep <literal> content"));
    QCOMPARE(entries[0].noticeAt, 456);
    QCOMPARE(entries[1].id, second.id);
    QVERIFY(entries[1].folderId.isEmpty());
    QCOMPARE(entries[1].title, QStringLiteral("Unfiled"));
    QCOMPARE(entries[1].createdAt, 789);
    QCOMPARE(folders.size(), 1);
    QCOMPARE(folders[0].id, folder);
    QCOMPARE(folders[0].name, QStringLiteral("Saved folder"));
    QCOMPARE(folders[0].position, 7);
    StateStore writer(directory.path(), false);
    QVERIFY2(writer.open(), qPrintable(writer.error()));
    ActivityReporter reporter;
    QString message;
    QVERIFY2(StateStore::processIdentity(QCoreApplication::applicationPid(), &reporter, &message), qPrintable(message));
    bool found = false;
    QVERIFY(writer.setActivity(first.id, QStringLiteral("waiting"), reporter, QStringLiteral("Choose permission"), &found));
    QVERIFY(found);
    QVERIFY(writer.notify(first.id, QStringLiteral("New notice"), {}, &found));
    QVERIFY(migrated.acknowledge(first.id, 9));
    QVERIFY(migrated.sessions(&entries));
    QCOMPARE(entries[0].noticeSequence - entries[0].readSequence, 1);
    QCOMPARE(entries[0].activity, QStringLiteral("waiting"));
    QCOMPARE(entries[0].activityDetail, QStringLiteral("Choose permission"));
}

void BackendTest::activityRejectsUnrecognizedSchemas_data() {
    QTest::addColumn<int>("version");
    QTest::newRow("unversioned-nonempty") << 0;
    QTest::newRow("incomplete-v1") << 1;
    QTest::newRow("unsupported-future") << 3;
}

void BackendTest::activityRejectsUnrecognizedSchemas() {
    QFETCH(int, version);
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const QString connection = uuid();
    {
        auto database = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connection);
        database.setDatabaseName(directory.path() + QStringLiteral("/state.sqlite"));
        QVERIFY(database.open());
        QSqlQuery query(database);
        QVERIFY(query.exec("CREATE TABLE irreplaceable(value TEXT)"));
        QVERIFY(query.exec("INSERT INTO irreplaceable VALUES('preserve me')"));
        QVERIFY(query.exec(QStringLiteral("PRAGMA user_version=%1").arg(version)));
        StateStore incompatible(directory.path(), false);
        QVERIFY(!incompatible.open());
        QVERIFY(query.exec("SELECT value FROM irreplaceable"));
        QVERIFY(query.next());
        QCOMPARE(query.value(0).toString(), QStringLiteral("preserve me"));
        query.finish();
        QVERIFY(query.exec("PRAGMA user_version"));
        QVERIFY(query.next());
        QCOMPARE(query.value(0).toInt(), version);
    }
    QSqlDatabase::removeDatabase(connection);
}

void BackendTest::activityAggregatesIndependentReporters() {
    QTemporaryDir directory;
    StateStore gui(directory.path());
    QVERIFY2(gui.open(), qPrintable(gui.error()));
    const auto session = record(directory.path());
    QVERIFY(gui.insertSession(session));
    StateStore cli(directory.path(), false);
    QVERIFY2(cli.open(), qPrintable(cli.error()));
    QProcess child;
    child.start(QStringLiteral("sleep"), {QStringLiteral("60")});
    QVERIFY(child.waitForStarted());
    const auto cleanup = qScopeGuard([&] { child.kill(); child.waitForFinished(1000); });
    ActivityReporter first;
    ActivityReporter second;
    QString message;
    QVERIFY2(StateStore::processIdentity(QCoreApplication::applicationPid(), &first, &message), qPrintable(message));
    QVERIFY2(StateStore::processIdentity(child.processId(), &second, &message), qPrintable(message));
    const QString literal = QStringLiteral("<b>not markup</b> '$()'\nChoose");
    bool found = false;
    QVERIFY(gui.setActivity(session.id, QStringLiteral("working"), first, QStringLiteral("First"), &found));
    QVERIFY(found);
    QVERIFY(cli.setActivity(session.id, QStringLiteral("working"), second, QStringLiteral("Second"), &found));
    QVERIFY(found);
    QVERIFY(gui.setActivity(session.id, QStringLiteral("idle"), first, {}));
    QList<SessionRecord> entries;
    QVERIFY(gui.sessions(&entries));
    QCOMPARE(entries.first().activity, QStringLiteral("working"));
    QCOMPARE(entries.first().activityDetail, QStringLiteral("Second"));
    QVERIFY(gui.setActivity(session.id, QStringLiteral("done"), first, {}));
    QVERIFY(gui.sessions(&entries));
    QCOMPARE(entries.first().activity, QStringLiteral("working"));
    QVERIFY(cli.setActivity(session.id, QStringLiteral("waiting"), second, literal));
    QVERIFY(gui.setActivity(session.id, QStringLiteral("working"), first, QStringLiteral("First")));
    QVERIFY(gui.sessions(&entries));
    QCOMPARE(entries.first().activity, QStringLiteral("waiting"));
    QCOMPARE(entries.first().activityDetail, literal);
    QVERIFY(cli.setActivity(session.id, QStringLiteral("done"), second, QStringLiteral("Completed")));
    QVERIFY(gui.sessions(&entries));
    QCOMPARE(entries.first().activity, QStringLiteral("working"));
    QVERIFY(gui.setActivity(session.id, QStringLiteral("idle"), first, {}));
    StateStore reopened(directory.path(), false);
    QVERIFY2(reopened.open(), qPrintable(reopened.error()));
    QVERIFY(reopened.sessions(&entries));
    QCOMPARE(entries.first().activity, QStringLiteral("done"));
    QCOMPARE(entries.first().activityDetail, QStringLiteral("Completed"));
    QVERIFY(cli.setActivity(session.id, QStringLiteral("idle"), second, {}));
    QVERIFY(reopened.sessions(&entries));
    QCOMPARE(entries.first().activity, QStringLiteral("idle"));
    QVERIFY(entries.first().activityDetail.isEmpty());
}

void BackendTest::waitingSurvivesSelectionAndAcknowledgement() {
    QTemporaryDir directory;
    StateStore gui(directory.path());
    QVERIFY2(gui.open(), qPrintable(gui.error()));
    const auto waiting = record(directory.path());
    const auto other = record(directory.path());
    QVERIFY(gui.insertSession(waiting));
    QVERIFY(gui.insertSession(other));
    SessionController controller(&gui, nullptr);
    StateStore cli(directory.path(), false);
    QVERIFY2(cli.open(), qPrintable(cli.error()));
    ActivityReporter reporter;
    QString message;
    QVERIFY2(StateStore::processIdentity(QCoreApplication::applicationPid(), &reporter, &message), qPrintable(message));
    QVERIFY(cli.setActivity(waiting.id, QStringLiteral("waiting"), reporter, QStringLiteral("Needs permission")));
    QVERIFY(cli.notify(waiting.id, QStringLiteral("Review"), {}));
    QTRY_COMPARE_WITH_TIMEOUT(controller.attentionCount(), 1, 1500);
    // Repeating the user action also waits for initial tmux reconciliation, when
    // selection starts acknowledging notifications rather than restoring state.
    QTRY_VERIFY_WITH_TIMEOUT(([&] {
        controller.selectSession(waiting.id);
        return controller.selected().value("unreadCount").toLongLong() == 0;
    })(), 1500);
    QCOMPARE(controller.selected().value("activity").toString(), QStringLiteral("waiting"));
    QCOMPARE(controller.selected().value("activityDetail").toString(), QStringLiteral("Needs permission"));
    QCOMPARE(controller.attentionCount(), 1);
    controller.setView(QStringLiteral("attention"));
    QCOMPARE(controller.model()->ids(), QStringList{waiting.id});
    controller.selectSession(other.id);
    controller.selectNextAttention();
    QCOMPARE(controller.selectedId(), waiting.id);
    QCOMPARE(controller.attentionCount(), 1);
    QVERIFY(cli.setActivity(waiting.id, QStringLiteral("done"), reporter, {}));
    QTRY_COMPARE_WITH_TIMEOUT(controller.selected().value("activity").toString(), QStringLiteral("done"), 1500);
    QCOMPARE(controller.attentionCount(), 0);
    controller.selectSession(other.id);
    controller.selectSession(waiting.id);
    QCOMPARE(controller.selected().value("activity").toString(), QStringLiteral("done"));
}

void BackendTest::activityReconcilesDeadAndReusedReporters() {
    QTemporaryDir directory;
    StateStore gui(directory.path());
    QVERIFY2(gui.open(), qPrintable(gui.error()));
    const auto session = record(directory.path());
    QVERIFY(gui.insertSession(session));
    QProcess child;
    child.start(QStringLiteral("sleep"), {QStringLiteral("60")});
    QVERIFY(child.waitForStarted());
    const auto cleanup = qScopeGuard([&] {
        if (child.state() != QProcess::NotRunning) { child.kill(); child.waitForFinished(1000); }
    });
    ActivityReporter parentReporter;
    ActivityReporter childReporter;
    QString message;
    QVERIFY2(StateStore::processIdentity(QCoreApplication::applicationPid(), &parentReporter, &message), qPrintable(message));
    QVERIFY2(StateStore::processIdentity(child.processId(), &childReporter, &message), qPrintable(message));
    QVERIFY(gui.setActivity(session.id, QStringLiteral("working"), parentReporter, QStringLiteral("Still working")));
    QVERIFY(gui.setActivity(session.id, QStringLiteral("waiting"), childReporter, QStringLiteral("Child prompt")));
    SessionController controller(&gui, nullptr);
    controller.selectSession(session.id);
    QCOMPARE(controller.selected().value("activity").toString(), QStringLiteral("waiting"));
    child.kill();
    QVERIFY(child.waitForFinished(1000));
    // No external database write accompanies this exit: the GUI cadence must
    // notice liveness and expose the remaining reporter rather than Idle/Done.
    QTRY_COMPARE_WITH_TIMEOUT(controller.selected().value("activity").toString(), QStringLiteral("working"), 2000);
    QCOMPARE(controller.selected().value("activityDetail").toString(), QStringLiteral("Still working"));
    QCOMPARE(controller.attentionCount(), 0);
    bool invalidReporter = false;
    auto forged = parentReporter;
    ++forged.startTicks;
    QVERIFY(!gui.setActivity(session.id, QStringLiteral("done"), forged, {}, nullptr, &invalidReporter));
    QVERIFY(invalidReporter);
    QList<SessionRecord> entries;
    QVERIFY(gui.sessions(&entries));
    QCOMPARE(entries.first().activity, QStringLiteral("working"));
    QSqlDatabase database;
    for (const auto &name : QSqlDatabase::connectionNames()) {
        const auto candidate = QSqlDatabase::database(name);
        if (candidate.databaseName() == directory.path() + QStringLiteral("/state.sqlite")) { database = candidate; break; }
    }
    QVERIFY(database.isValid());
    QSqlQuery tamper(database);
    // Simulate a saved record referring to an earlier owner of this live PID.
    QVERIFY(tamper.exec("UPDATE session_activity SET start_ticks=start_ticks+1"));
    QVERIFY(gui.sessions(&entries));
    QCOMPARE(entries.first().activity, QStringLiteral("idle"));
    QVERIFY(gui.setActivity(session.id, QStringLiteral("done"), parentReporter, {}));
    QVERIFY(tamper.prepare("UPDATE session_activity SET boot_id=?"));
    tamper.addBindValue(uuid());
    QVERIFY(tamper.exec());
    QVERIFY(gui.sessions(&entries));
    QCOMPARE(entries.first().activity, QStringLiteral("idle"));
    child.start(QStringLiteral("sleep"), {QStringLiteral("60")});
    QVERIFY(child.waitForStarted());
    QVERIFY2(StateStore::processIdentity(child.processId(), &childReporter, &message), qPrintable(message));
    QVERIFY(gui.setActivity(session.id, QStringLiteral("done"), childReporter, {}));
    child.kill();
    QVERIFY(child.waitForFinished(1000));
    StateStore reopened(directory.path(), false);
    QVERIFY2(reopened.open(), qPrintable(reopened.error()));
    QVERIFY(reopened.sessions(&entries));
    QCOMPARE(entries.first().activity, QStringLiteral("idle"));
    QVERIFY(!StateStore::processIdentity(childReporter.pid, &forged, &message));
}

QTEST_GUILESS_MAIN(BackendTest)
#include "backend_test.moc"
