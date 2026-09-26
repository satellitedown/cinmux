#include "session_controller.h"
#include "terminal_renderer.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QSaveFile>
#include <QStandardPaths>
#include <QUuid>
#include <algorithm>
#include <pwd.h>
#include <unistd.h>

namespace {
QString newId() { return QUuid::createUuid().toString(QUuid::WithoutBraces); }
QString exactTarget(const QString &id) { return QStringLiteral("=") + StateStore::sessionName(id); }
QString processError(const QByteArray &error) {
    const QString text = QString::fromUtf8(error).trimmed();
    return text.isEmpty() ? QStringLiteral("Command failed without an error message") : text;
}
bool needsAttention(const SessionRecord &record) {
    return record.noticeSequence > record.readSequence || record.activity == QStringLiteral("waiting");
}
qint64 attentionAt(const SessionRecord &record) {
    return qMax(record.noticeSequence > record.readSequence ? record.noticeAt : 0,
                record.activity == QStringLiteral("waiting") ? record.activityAt : 0);
}
}

SessionController::SessionController(StateStore *store, TerminalRenderer *renderer, QObject *parent)
    : QObject(parent), m_store(store), m_renderer(renderer), m_model(this), m_hostEnvironment(QProcessEnvironment::systemEnvironment()) {
    m_hostEnvironment.remove(QStringLiteral("TMUX"));
    m_hostEnvironment.remove(QStringLiteral("TMUX_PANE"));
    m_hostEnvironment.remove(QStringLiteral("WAYLAND_SOCKET"));
    m_tmuxProgram = QStandardPaths::findExecutable(QStringLiteral("tmux"));
    QFile config(QStringLiteral(":/cinmux/cinmux.tmux.conf"));
    QSaveFile destination(store->stateDirectory() + QStringLiteral("/cinmux.tmux.conf"));
    if (config.open(QIODevice::ReadOnly) && destination.open(QIODevice::WriteOnly)) {
        destination.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
        const auto bytes = config.readAll();
        if (destination.write(bytes) == bytes.size() && destination.commit()) m_tmuxConfig = destination.fileName();
    }
    // Sample before reading: a concurrent CLI commit must remain visible to the next poll.
    qint64 initialVersion = -1;
    if (m_store->dataVersion(&initialVersion) && readState()) m_dataVersion = initialVersion;
    else {
        const QString error = m_store->error();
        QTimer::singleShot(0, this, [this, error] { fail({}, error); });
    }
    connect(&m_metadataTimer, &QTimer::timeout, this, &SessionController::refresh);
    m_metadataTimer.start(1000);
    connect(&m_databaseTimer, &QTimer::timeout, this, [this] {
        qint64 version = 0;
        if (!m_store->dataVersion(&version)) { fail({}, m_store->error()); return; }
        if (version != m_dataVersion && readState()) m_dataVersion = version;
    });
    m_databaseTimer.start(250);
    if (m_renderer) {
        connect(m_renderer, &TerminalRenderer::ready, this, [this](const QString &id) {
            const auto s = m_sessions.value(id);
            if (!s) return;
            s->terminalError.clear(); publish();
        });
        connect(m_renderer, &TerminalRenderer::lost, this, [this](const QString &id, const QString &message) {
            const auto s = m_sessions.value(id);
            if (!s || m_shuttingDown) return;
            // Blocks automatic reattachment while the snapshot decides.
            s->terminalError = message;
            publish();
            // A view also ends when its tmux session does (last pane closed,
            // server exited): that is a stop the snapshot reports, not a failure.
            snapshot([this, id, message](bool ok, const QList<TmuxPane> &panes) {
                const auto current = m_sessions.value(id);
                if (!current || m_shuttingDown) return;
                const bool ended = ok && std::none_of(panes.cbegin(), panes.cend(), [&id](const TmuxPane &p) { return p.sessionName == StateStore::sessionName(id); });
                if (ended) { if (current->terminalError == message) current->terminalError.clear(); }
                else if (!current->closing) fail(id, message);
                if (ok) applySnapshot(panes);
                else publish();
            });
        });
        connect(m_renderer, &TerminalRenderer::interacted, this, [this](const QString &id) {
            const auto s = m_sessions.value(id);
            if (s) acknowledge(id, s->record.noticeSequence);
        });
    }
    QTimer::singleShot(0, this, [this] {
        if (m_tmuxProgram.isEmpty()) fail({}, QStringLiteral("tmux is not installed or is not on PATH"));
        else if (m_tmuxConfig.isEmpty()) fail({}, QStringLiteral("Cannot materialize the embedded tmux configuration"));
        else refresh();
    });
}

SessionController::~SessionController() {
    m_shuttingDown = true;
    m_metadataTimer.stop(); m_databaseTimer.stop();
    const auto ids = m_sessions.keys();
    for (const auto &id : ids) stopRenderer(id);
    const auto processes = m_commands;
    for (auto *process : processes) { process->disconnect(this); process->kill(); }
    for (auto *process : processes) process->waitForFinished(1000);
}

void SessionController::command(const QString &program, const QStringList &args, const QProcessEnvironment &environment, ResultCallback callback) {
    if (m_shuttingDown) return;
    auto *process = new QProcess(this);
    auto *timer = new QTimer(process);
    timer->setSingleShot(true);
    process->setProcessEnvironment(environment);
    m_commands.insert(process);
    const auto finished = std::make_shared<bool>(false);
    const auto timedOut = std::make_shared<bool>(false);
    auto complete = [this, process, timer, finished, callback](bool ok, bool timedOut, const QByteArray &extra) {
        if (*finished) return;
        *finished = true; timer->stop();
        CommandResult result{ok, timedOut, process->readAllStandardOutput(), process->readAllStandardError()};
        if (!extra.isEmpty()) { if (!result.error.isEmpty()) result.error += '\n'; result.error += extra; }
        m_commands.remove(process); process->deleteLater();
        if (!m_shuttingDown) callback(result);
        if (timedOut && !m_shuttingDown) QTimer::singleShot(0, this, &SessionController::refresh);
    };
    connect(process, &QProcess::finished, this, [complete, timedOut](int code, QProcess::ExitStatus status) {
        complete(!*timedOut && code == 0 && status == QProcess::NormalExit, *timedOut,
                 *timedOut ? QByteArrayLiteral("Command timed out after 5 seconds") : QByteArray());
    });
    connect(process, &QProcess::errorOccurred, this, [process, complete](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart) complete(false, false, process->errorString().toUtf8());
    });
    connect(timer, &QTimer::timeout, this, [process, timedOut] { *timedOut = true; process->kill(); });
    process->start(program, args);
    timer->start(5000);
}
void SessionController::tmux(const QStringList &args, ResultCallback callback) {
    if (m_tmuxProgram.isEmpty() || m_tmuxConfig.isEmpty()) {
        callback({false, false, {}, QByteArrayLiteral("tmux or the embedded tmux configuration is unavailable")}); return;
    }
    QStringList commandArgs{QStringLiteral("-S"), m_store->tmuxSocket(), QStringLiteral("-f"), m_tmuxConfig};
    for (QString argument : args) {
        // tmux also recognizes a trailing semicolon in an argv element as a
        // command separator. Preserve literal directory/environment values.
        if (argument.endsWith(';')) argument.insert(argument.size() - 1, '\\');
        commandArgs.append(argument);
    }
    // Bootstrap tmux with the host locale: its global environment is inherited by shells.
    command(m_tmuxProgram, commandArgs, m_hostEnvironment, std::move(callback));
}
void SessionController::enqueue(const QString &id, Operation operation) {
    if (!m_sessions.contains(id)) { fail(id, QStringLiteral("Unknown session")); return; }
    m_operations[id].enqueue(std::move(operation));
    if (!m_busy.contains(id)) nextOperation(id);
}
void SessionController::nextOperation(const QString &id) {
    if (m_shuttingDown) return;
    auto it = m_operations.find(id);
    if (it == m_operations.end() || it->isEmpty() || !m_sessions.contains(id)) {
        m_operations.remove(id); m_busy.remove(id); return;
    }
    m_busy.insert(id);
    auto operation = it->dequeue();
    const auto completed = std::make_shared<bool>(false);
    operation([this, id, completed] {
        if (*completed || m_shuttingDown) return;
        *completed = true;
        QTimer::singleShot(0, this, [this, id] { nextOperation(id); });
    });
}
void SessionController::fail(const QString &id, const QString &message) { emit operationFailed(id, message); }
bool SessionController::checked(const QString &id, bool result) { if (!result) fail(id, m_store->error()); return result; }

bool SessionController::readState() {
    QList<SessionRecord> records;
    QList<FolderRecord> folders;
    if (!checked({}, m_store->sessions(&records)) || !checked({}, m_store->folders(&folders))) {
        m_dataVersion = -1;
        return false;
    }
    QSet<QString> present;
    for (const auto &record : records) {
        present.insert(record.id);
        auto &session = m_sessions[record.id];
        if (!session) session = std::make_shared<Session>();
        if (session->record.cwd != record.cwd) session->branch.clear();
        session->record = record;
    }
    const auto ids = m_sessions.keys();
    for (const auto &id : ids) if (!present.contains(id)) { stopRenderer(id); m_sessions.remove(id); m_operations.remove(id); }
    m_folderRecords = folders;
    if (!m_selectedId.isEmpty() && !m_sessions.contains(m_selectedId)) m_selectedId.clear();
    if (m_view != QStringLiteral("all") && m_view != QStringLiteral("attention")) {
        const bool found = std::any_of(folders.cbegin(), folders.cend(), [this](const FolderRecord &folder) { return folder.id == m_view; });
        if (!found) { m_view = QStringLiteral("all"); emit viewChanged(); }
    }
    publish();
    return true;
}
QVariantMap SessionController::row(const Session &s) const {
    const auto &r = s.record;
    return {{QStringLiteral("sessionId"), r.id}, {QStringLiteral("title"), r.title}, {QStringLiteral("folderId"), r.folderId}, {QStringLiteral("pinned"), r.pinned}, {QStringLiteral("cwd"), r.cwd}, {QStringLiteral("branch"), s.branch}, {QStringLiteral("status"), s.status}, {QStringLiteral("unreadCount"), qMax<qint64>(0, r.noticeSequence - r.readSequence)}, {QStringLiteral("noticeTitle"), r.noticeTitle}, {QStringLiteral("noticeBody"), r.noticeBody}, {QStringLiteral("noticeSequence"), r.noticeSequence}, {QStringLiteral("terminalError"), s.terminalError}, {QStringLiteral("activity"), r.activity}, {QStringLiteral("activityDetail"), r.activityDetail}};
}
QVariantMap SessionController::selected() const { const auto s = m_sessions.value(m_selectedId); return s ? row(*s) : QVariantMap(); }
int SessionController::attentionCount() const {
    int result = 0;
    for (const auto &s : m_sessions) if (needsAttention(s->record)) ++result;
    return result;
}
void SessionController::publish() {
    auto sorted = m_sessions.values();
    std::sort(sorted.begin(), sorted.end(), [](const auto &a, const auto &b) {
        if (a->record.pinned != b->record.pinned) return a->record.pinned;
        if (a->record.createdAt != b->record.createdAt) return a->record.createdAt > b->record.createdAt;
        return a->record.id < b->record.id;
    });
    QList<QVariantMap> rows;
    const auto search = m_search.toCaseFolded();
    for (const auto &s : sorted) {
        if (!search.isEmpty()) {
            if (!s->record.title.toCaseFolded().contains(search) && !s->record.cwd.toCaseFolded().contains(search) && !s->branch.toCaseFolded().contains(search)) continue;
        } else if (m_view == QStringLiteral("attention")) {
            if (!needsAttention(s->record)) continue;
        } else if (m_view != QStringLiteral("all") && s->record.folderId != m_view) continue;
        rows.append(row(*s));
    }
    m_model.setRows(rows);
    QVariantList folders;
    for (const auto &folder : m_folderRecords) {
        int count = 0;
        for (const auto &s : m_sessions) if (s->record.folderId == folder.id) ++count;
        folders.append(QVariantMap{{QStringLiteral("id"), folder.id}, {QStringLiteral("name"), folder.name}, {QStringLiteral("count"), count}});
    }
    if (folders != m_folders) { m_folders = folders; emit foldersChanged(); }
    emit stateChanged(); emit selectionChanged();
}
void SessionController::setSearch(const QString &value) { if (value == m_search) return; m_search = value; publish(); emit searchChanged(); refreshBranches(); }
void SessionController::setView(const QString &value) {
    if (value != QStringLiteral("all") && value != QStringLiteral("attention") && !std::any_of(m_folderRecords.cbegin(), m_folderRecords.cend(), [&value](const auto &f) { return f.id == value; })) return;
    if (value == m_view) return;
    m_view = value; publish(); emit viewChanged(); refreshBranches();
}

void SessionController::selectSession(const QString &id) {
    const auto s = m_sessions.value(id);
    if (!s) { if (id.isEmpty()) { m_selectedId.clear(); publish(); } return; }
    const qint64 observed = s->record.noticeSequence;
    m_selectedId = id;
    // The initial pre-reconcile selection restores the GUI, not user intent.
    if (s->reconciled) acknowledge(id, observed);
    publish();
    if (s->reconciled && !s->panes.isEmpty() && s->terminalError.isEmpty()) attach(id);
    refreshBranches();
}
void SessionController::navigate(int delta) {
    const auto ids = m_model.ids();
    if (ids.isEmpty() || delta == 0) return;
    int index = ids.indexOf(m_selectedId);
    if (index < 0) index = delta > 0 ? -1 : 0;
    index = (index + (delta > 0 ? 1 : -1) + ids.size()) % ids.size();
    selectSession(ids[index]);
}
void SessionController::renameSession(const QString &id, const QString &title) { if (checked(id, m_store->renameSession(id, title))) readState(); }
void SessionController::setPinned(const QString &id, bool pinned) { if (checked(id, m_store->setPinned(id, pinned))) readState(); }
void SessionController::moveSession(const QString &id, const QString &folderId) { if (checked(id, m_store->moveSession(id, folderId))) readState(); }
void SessionController::createFolder(const QString &name) { if (checked({}, m_store->createFolder(newId(), name))) readState(); }
void SessionController::renameFolder(const QString &id, const QString &name) { if (checked({}, m_store->renameFolder(id, name))) readState(); }
void SessionController::deleteFolder(const QString &id) { if (checked({}, m_store->deleteFolder(id))) readState(); }
void SessionController::acknowledge(const QString &id, qint64 observedSequence) {
    const auto s = m_sessions.value(id);
    if (!s || observedSequence <= s->record.readSequence) return;
    if (checked(id, m_store->acknowledge(id, observedSequence))) readState();
}
void SessionController::selectNextAttention() {
    std::shared_ptr<Session> newest;
    for (const auto &s : m_sessions) {
        if (!needsAttention(s->record)) continue;
        if (!newest || attentionAt(s->record) > attentionAt(newest->record) ||
            (attentionAt(s->record) == attentionAt(newest->record) && s->record.id < newest->record.id)) newest = s;
    }
    if (!newest) return;
    setSearch({}); setView(QStringLiteral("all")); selectSession(newest->record.id);
}

bool SessionController::usableCwd(const QString &id, const QString &cwd) {
    const QFileInfo info(cwd);
    if (!info.isAbsolute() || !info.isDir() || !info.isReadable() || ::access(QFile::encodeName(cwd).constData(), X_OK) != 0) {
        fail(id, QStringLiteral("Working directory is missing or inaccessible: %1. Choose another directory or cancel.").arg(cwd)); return false;
    }
    return true;
}
QString SessionController::shell() const {
    auto usable = [](const QString &value) { const QFileInfo info(value); return info.isAbsolute() && info.isFile() && info.isExecutable(); };
    const QString fromEnvironment = m_hostEnvironment.value(QStringLiteral("SHELL"));
    if (usable(fromEnvironment)) return fromEnvironment;
    if (const auto *user = ::getpwuid(::getuid())) { const QString fromPasswd = QString::fromLocal8Bit(user->pw_shell); if (usable(fromPasswd)) return fromPasswd; }
    return QStringLiteral("/bin/sh");
}
const TmuxPane *SessionController::activePane(const QList<TmuxPane> &panes) {
    for (const auto &pane : panes) if (pane.windowActive && pane.paneActive) return &pane;
    return nullptr;
}
QString SessionController::activeCwd(const Session &session) const {
    if (const auto *pane = activePane(session.panes); pane && !pane->dead) {
        const QString path = QFileInfo(QStringLiteral("/proc/%1/cwd").arg(pane->pid)).symLinkTarget();
        if (QDir::isAbsolutePath(path) && QFileInfo(path).isDir()) return path;
    }
    return session.record.cwd;
}
void SessionController::createSession(const QString &folderId, const QString &requestedCwd) {
    QString cwd = requestedCwd;
    if (cwd.isEmpty()) { const auto active = m_sessions.value(m_selectedId); cwd = active ? activeCwd(*active) : QDir::homePath(); }
    if (!usableCwd({}, cwd)) { emit directoryRequired({}, folderId, cwd); return; }
    int number = 1;
    QSet<QString> titles;
    for (const auto &session : m_sessions) titles.insert(session->record.title);
    while (titles.contains(QStringLiteral("Terminal %1").arg(number))) ++number;
    SessionRecord record;
    record.id = newId(); record.folderId = folderId; record.cwd = cwd;
    record.title = QStringLiteral("Terminal %1").arg(number); record.createdAt = QDateTime::currentMSecsSinceEpoch();
    if (!checked({}, m_store->insertSession(record))) return;
    if (!readState()) return;
    setSearch({}); setView(folderId.isEmpty() ? QStringLiteral("all") : folderId);
    m_selectedId = record.id;
    auto s = m_sessions.value(record.id); s->status = QStringLiteral("starting"); publish();
    enqueue(record.id, [this, id = record.id, cwd](Done done) { startOwned(id, cwd, std::move(done)); });
}
void SessionController::startSession(const QString &id, const QString &requestedCwd) {
    enqueue(id, [this, id, requestedCwd](Done done) {
        const auto s = m_sessions.value(id);
        if (!s) { done(); return; }
        const QString cwd = requestedCwd.isEmpty() ? s->record.cwd : requestedCwd;
        if (!usableCwd(id, cwd)) { emit directoryRequired(id, {}, cwd); done(); return; }
        startOwned(id, cwd, std::move(done));
    });
}

void SessionController::snapshot(std::function<void(bool, const QList<TmuxPane> &)> callback) {
    tmux({QStringLiteral("list-panes"), QStringLiteral("-a"), QStringLiteral("-F"), StateStore::paneFormat()}, [this, callback](const CommandResult &result) {
        QList<TmuxPane> panes;
        if (!result.ok) {
            if (!result.timedOut && StateStore::serverAbsent(m_store->tmuxSocket(), result.error)) { callback(true, panes); return; }
            fail({}, processError(result.error)); callback(false, panes); return;
        }
        QString error;
        if (!StateStore::parsePanes(result.output, &panes, &error)) { fail({}, error); callback(false, {}); return; }
        callback(true, panes);
    });
}
void SessionController::applySnapshot(const QList<TmuxPane> &panes) {
    for (const auto &s : m_sessions) {
        if (m_busy.contains(s->record.id)) continue;
        QList<TmuxPane> owned;
        for (const auto &pane : panes) if (pane.sessionName == StateStore::sessionName(s->record.id)) owned.append(pane);
        s->panes = owned; s->reconciled = true;
        const bool live = std::any_of(owned.cbegin(), owned.cend(), [](const TmuxPane &p) { return !p.dead; });
        s->status = live ? QStringLiteral("running") : QStringLiteral("stopped");
        const QString cwd = activeCwd(*s);
        if (cwd != s->record.cwd && checked(s->record.id, m_store->updateCwd(s->record.id, cwd))) { s->record.cwd = cwd; s->branch.clear(); }
    }
    publish();
    const auto active = m_sessions.value(m_selectedId);
    if (active && active->reconciled && !active->panes.isEmpty() && active->terminalError.isEmpty() && !m_busy.contains(m_selectedId)) attach(m_selectedId);
    refreshBranches();
}
void SessionController::refresh() {
    if (m_shuttingDown) return;
    // Process exit does not change SQLite's data_version. Reconcile activity at
    // the normal metadata cadence even while a tmux request is still pending.
    readState();
    if (m_refreshing) return;
    m_refreshing = true;
    snapshot([this](bool ok, const QList<TmuxPane> &panes) { m_refreshing = false; if (ok) applySnapshot(panes); });
}

void SessionController::startOwned(const QString &id, const QString &cwd, Done done) {
    snapshot([this, id, cwd, done](bool ok, const QList<TmuxPane> &all) {
        const auto s = m_sessions.value(id);
        if (!s) { done(); return; }
        if (!ok) {
            if (s->status == QStringLiteral("starting")) { s->status = QStringLiteral("stopped"); publish(); }
            done();
            return;
        }
        QList<TmuxPane> owned;
        for (const auto &pane : all) if (pane.sessionName == StateStore::sessionName(id)) owned.append(pane);
        s->panes = owned; s->reconciled = true;
        if (std::any_of(owned.cbegin(), owned.cend(), [](const TmuxPane &p) { return !p.dead; })) {
            s->status = QStringLiteral("running"); publish(); attach(id); done(); return;
        }
        s->status = QStringLiteral("starting"); publish();
        auto complete = [this, id, cwd, done](const CommandResult &result) {
            const auto current = m_sessions.value(id);
            if (!current) { done(); return; }
            if (!result.ok) { current->status = QStringLiteral("stopped"); fail(id, processError(result.error)); }
            else {
                current->status = QStringLiteral("running");
                if (checked(id, m_store->updateCwd(id, cwd))) current->record.cwd = cwd;
                current->terminalError.clear(); attach(id);
            }
            publish(); done(); QTimer::singleShot(0, this, &SessionController::refresh);
        };
        if (owned.isEmpty()) {
            QStringList args{QStringLiteral("new-session"), QStringLiteral("-d"), QStringLiteral("-s"), StateStore::sessionName(id), QStringLiteral("-n"), QStringLiteral("terminal"), QStringLiteral("-c"), cwd};
            QProcessEnvironment env = m_hostEnvironment;
            env.insert(QStringLiteral("CINMUX_SESSION_ID"), id);
            env.insert(QStringLiteral("CINMUX_STATE_DIR"), m_store->stateDirectory());
            env.insert(QStringLiteral("CINMUX_TMUX_SOCKET"), m_store->tmuxSocket());
            env.insert(QStringLiteral("PATH"), QCoreApplication::applicationDirPath() + ':' + env.value(QStringLiteral("PATH")));
            for (const auto &key : env.keys()) args << QStringLiteral("-e") << key + '=' + env.value(key);
            args << shell() << QStringLiteral("-l");
            tmux(args, complete);
        } else {
            respawnPanes(owned, 0, cwd, complete);
        }
    });
}

void SessionController::respawnPanes(const QList<TmuxPane> &panes, int index, const QString &cwd, ResultCallback callback) {
    if (index == panes.size()) { callback({true, false, {}, {}}); return; }
    tmux({QStringLiteral("respawn-pane"), QStringLiteral("-t"), panes[index].paneId, QStringLiteral("-c"), cwd, shell(), QStringLiteral("-l")},
         [this, panes, index, cwd, callback](const CommandResult &result) {
             if (!result.ok) callback(result);
             else respawnPanes(panes, index + 1, cwd, callback);
         });
}

void SessionController::stopRenderer(const QString &id) { if (m_renderer) m_renderer->detach(id); }
void SessionController::attach(const QString &id, bool force) {
    const auto s = m_sessions.value(id);
    if (!s || m_shuttingDown || !m_renderer) return;
    if (!force && m_renderer->attached(id)) return;
    s->terminalError.clear();
    m_renderer->attach(id, force);
    publish();
}
void SessionController::reconnectTerminal(const QString &id) {
    enqueue(id, [this, id](Done done) {
        snapshot([this, id, done](bool ok, const QList<TmuxPane> &panes) {
            if (ok) {
                const auto s = m_sessions.value(id);
                const bool exists = std::any_of(panes.cbegin(), panes.cend(), [&id](const TmuxPane &p) { return p.sessionName == StateStore::sessionName(id); });
                if (s && exists) attach(id, true);
                else fail(id, QStringLiteral("This session is stopped. Use Start session to create a shell."));
            }
            done();
        });
    });
}

void SessionController::splitActive(const QString &direction) {
    const QString id = m_selectedId;
    if (direction != QStringLiteral("right") && direction != QStringLiteral("down")) { fail(id, QStringLiteral("Split direction must be right or down")); return; }
    enqueue(id, [this, id, direction](Done done) {
        snapshot([this, id, direction, done](bool ok, const QList<TmuxPane> &all) {
            const auto s = m_sessions.value(id);
            if (!ok || !s) { done(); return; }
            QList<TmuxPane> owned;
            for (const auto &p : all) if (p.sessionName == StateStore::sessionName(id)) owned.append(p);
            const auto *pane = activePane(owned);
            if (!pane || pane->dead) { fail(id, QStringLiteral("No running active pane to split")); done(); return; }
            const QString cwd = QFileInfo(QStringLiteral("/proc/%1/cwd").arg(pane->pid)).symLinkTarget();
            if (!usableCwd(id, cwd)) { done(); return; }
            tmux({QStringLiteral("split-window"), direction == QStringLiteral("right") ? QStringLiteral("-h") : QStringLiteral("-v"), QStringLiteral("-t"), pane->paneId, QStringLiteral("-c"), cwd, shell(), QStringLiteral("-l")}, [this, id, done](const CommandResult &result) {
                if (!result.ok) fail(id, processError(result.error));
                done(); QTimer::singleShot(0, this, &SessionController::refresh);
            });
        });
    });
}
void SessionController::closeActivePane() {
    const QString id = m_selectedId;
    enqueue(id, [this, id](Done done) {
        snapshot([this, id, done](bool ok, const QList<TmuxPane> &all) {
            if (!ok) { done(); return; }
            QList<TmuxPane> owned;
            for (const auto &p : all) if (p.sessionName == StateStore::sessionName(id)) owned.append(p);
            if (owned.size() <= 1) { closeOwned(id, done); return; }
            const auto *pane = activePane(owned);
            if (!pane) { fail(id, QStringLiteral("No active pane to close")); done(); return; }
            tmux({QStringLiteral("kill-pane"), QStringLiteral("-t"), pane->paneId}, [this, id, done](const CommandResult &result) {
                if (!result.ok) fail(id, processError(result.error));
                done(); QTimer::singleShot(0, this, &SessionController::refresh);
            });
        });
    });
}
void SessionController::closeSession(const QString &id) { enqueue(id, [this, id](Done done) { closeOwned(id, std::move(done)); }); }
void SessionController::closeOwned(const QString &id, Done done) {
    const auto session = m_sessions.value(id);
    if (!session) { done(); return; }
    done = [session, done = std::move(done)] {
        session->closing = false;
        done();
    };
    snapshot([this, id, session, done](bool ok, const QList<TmuxPane> &before) {
        if (!ok) { done(); return; }
        // Killing tmux normally disconnects the terminal view before the verification returns.
        session->closing = true;
        const bool exists = std::any_of(before.cbegin(), before.cend(), [&id](const auto &p) { return p.sessionName == StateStore::sessionName(id); });
        auto verify = [this, id, done](const CommandResult &result) {
            if (result.ok) stopRenderer(id);
            snapshot([this, id, done, result](bool checkedSnapshot, const QList<TmuxPane> &after) {
                if (!checkedSnapshot) { done(); return; }
                const bool remaining = std::any_of(after.cbegin(), after.cend(), [&id](const auto &p) { return p.sessionName == StateStore::sessionName(id); });
                if (remaining) { fail(id, !result.ok ? processError(result.error) : QStringLiteral("Session is still present; its entry was not removed")); done(); return; }
                if (checked(id, m_store->deleteSession(id))) {
                    stopRenderer(id); m_sessions.remove(id);
                    if (m_selectedId == id) m_selectedId.clear();
                    readState();
                }
                done();
            });
        };
        if (!exists) verify({true, false, {}, {}});
        else tmux({QStringLiteral("kill-session"), QStringLiteral("-t"), exactTarget(id)}, verify);
    });
}

void SessionController::refreshBranches() {
    QSet<QString> paths;
    for (const auto &id : m_model.ids()) if (const auto s = m_sessions.value(id)) paths.insert(s->record.cwd);
    if (const auto s = m_sessions.value(m_selectedId)) paths.insert(s->record.cwd);
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    for (const auto &cwd : paths) {
        auto &entry = m_git[cwd];
        if (entry.pending) continue;
        if (entry.checkedAt && now - entry.checkedAt < 5000) { updateBranch(cwd, entry.branch); continue; }
        entry.pending = true;
        command(QStringLiteral("git"), {QStringLiteral("-C"), cwd, QStringLiteral("symbolic-ref"), QStringLiteral("--quiet"), QStringLiteral("--short"), QStringLiteral("HEAD")}, m_hostEnvironment, [this, cwd](const CommandResult &result) {
            auto finish = [this, cwd](const QString &branch) {
                auto &entry = m_git[cwd]; entry.branch = branch; entry.checkedAt = QDateTime::currentMSecsSinceEpoch(); entry.pending = false;
                updateBranch(cwd, branch);
            };
            if (result.ok) { finish(QString::fromUtf8(result.output).trimmed()); return; }
            if (result.timedOut) { finish({}); return; }
            command(QStringLiteral("git"), {QStringLiteral("-C"), cwd, QStringLiteral("rev-parse"), QStringLiteral("--short"), QStringLiteral("HEAD")}, m_hostEnvironment, [finish](const CommandResult &detached) {
                finish(detached.ok ? QStringLiteral("detached:") + QString::fromUtf8(detached.output).trimmed() : QString());
            });
        });
    }
}
void SessionController::updateBranch(const QString &cwd, const QString &branch) {
    bool changed = false;
    for (const auto &s : m_sessions) if (s->record.cwd == cwd && s->branch != branch) { s->branch = branch; changed = true; }
    if (changed) publish();
}
