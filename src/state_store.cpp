#include "state_store.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>
#include <QSqlError>
#include <QSqlQuery>
#include <QUuid>
#include <limits>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <unicode/stringoptions.h>
#include <unicode/ustring.h>

namespace {
const QFileDevice::Permissions privateDirectory = QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner;
QVariant nullableId(const QString &value) { return value.isEmpty() ? QVariant(QMetaType::fromType<QString>()) : QVariant(value); }
bool ownedDirectory(const QString &path, QString *error) {
    struct stat st {};
    const auto encoded = QFile::encodeName(path);
    if (::lstat(encoded.constData(), &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != ::getuid()) {
        *error = QStringLiteral("Directory is missing, not a real directory, or not owned by this user: %1").arg(path);
        return false;
    }
    return true;
}
bool bootIdentity(QString *bootId, QString *error) {
    QFile file(QStringLiteral("/proc/sys/kernel/random/boot_id"));
    if (!file.open(QIODevice::ReadOnly)) {
        *error = QStringLiteral("Cannot read Linux boot identity: %1").arg(file.errorString());
        return false;
    }
    *bootId = QString::fromLatin1(file.read(128)).trimmed();
    if (!StateStore::validId(*bootId)) {
        *error = QStringLiteral("Invalid Linux boot identity");
        return false;
    }
    return true;
}
bool readProcessIdentity(qint64 pid, const QString &bootId, ActivityReporter *reporter, QString *error) {
    if (pid <= 0 || pid > std::numeric_limits<pid_t>::max()) {
        *error = QStringLiteral("--pid must identify a live process owned by this user");
        return false;
    }
    QFile file(QStringLiteral("/proc/%1/stat").arg(pid));
    struct stat metadata {};
    if (!file.open(QIODevice::ReadOnly) || ::fstat(file.handle(), &metadata) != 0 || metadata.st_uid != ::getuid()) {
        *error = QStringLiteral("Cannot inspect live user-owned process %1").arg(pid);
        return false;
    }
    // comm is parenthesized but may itself contain spaces, ')' and newlines.
    const QByteArray stat = file.read(65536);
    const auto opening = stat.indexOf('(');
    const auto closing = stat.lastIndexOf(") ");
    bool validPid = false;
    const qint64 observedPid = stat.left(opening).trimmed().toLongLong(&validPid);
    const auto fields = closing >= 0 ? stat.mid(closing + 2).split(' ') : QList<QByteArray>();
    bool validTicks = false;
    const qint64 ticks = fields.size() > 19 ? fields[19].toLongLong(&validTicks) : 0;
    if (opening < 0 || closing < opening || !validPid || observedPid != pid || !validTicks || ticks <= 0 ||
        fields[0] == "Z" || fields[0] == "X" || fields[0] == "x") {
        *error = QStringLiteral("Process %1 is no longer live or has an invalid Linux identity").arg(pid);
        return false;
    }
    *reporter = {pid, bootId, ticks};
    return true;
}
}

StateStore::StateStore(const QString &directory, bool create) : m_directory(directory), m_create(create) {}
StateStore::~StateStore() {
    if (m_db.isValid()) m_db.close();
    m_db = QSqlDatabase();
    if (!m_connection.isEmpty()) QSqlDatabase::removeDatabase(m_connection);
}
bool StateStore::fail(const QString &message) { m_error = message; return false; }

bool StateStore::open() {
    if (m_db.isOpen()) return m_opened;
    m_error.clear();
    if (m_directory.isEmpty()) {
        m_directory = qEnvironmentVariable("CINMUX_STATE_DIR");
        if (m_directory.isEmpty()) {
            QString data = qEnvironmentVariable("XDG_DATA_HOME");
            if (data.isEmpty()) data = QDir::homePath() + QStringLiteral("/.local/share");
            m_directory = data + QStringLiteral("/cinmux");
        }
    }
    if (!QDir::isAbsolutePath(m_directory)) return fail(QStringLiteral("CINMUX_STATE_DIR must be an absolute path"));
    m_directory = QDir::cleanPath(m_directory);
    if (!QFileInfo::exists(m_directory)) {
        if (!m_create) return true;
        if (!QDir().mkpath(m_directory)) return fail(QStringLiteral("Cannot create state directory: %1").arg(m_directory));
    }
    const QString canonical = QFileInfo(m_directory).canonicalFilePath();
    if (canonical.isEmpty()) return fail(QStringLiteral("Cannot resolve state directory: %1").arg(m_directory));
    m_directory = canonical;
    if (!ownedDirectory(m_directory, &m_error)) return false;
    if (m_create && !QFile::setPermissions(m_directory, privateDirectory)) return fail(QStringLiteral("Cannot secure state directory: %1").arg(m_directory));
    m_hash = QString::fromLatin1(QCryptographicHash::hash(m_directory.toUtf8(), QCryptographicHash::Sha256).toHex().left(16));
    const QString database = m_directory + QStringLiteral("/state.sqlite");
    m_exists = QFileInfo::exists(database);
    if (!m_create && !m_exists) return true;
    const QString runtimeRoot = qEnvironmentVariable("XDG_RUNTIME_DIR");
    if (!QDir::isAbsolutePath(runtimeRoot) || !ownedDirectory(runtimeRoot, &m_error))
        return fail(QStringLiteral("XDG_RUNTIME_DIR must be an existing user-owned absolute directory: %1").arg(runtimeRoot));
    m_runtime = runtimeRoot + QStringLiteral("/cinmux-") + m_hash;
    if (!QFileInfo::exists(m_runtime) && !QDir().mkdir(m_runtime)) return fail(QStringLiteral("Cannot create runtime directory: %1").arg(m_runtime));
    if (!ownedDirectory(m_runtime, &m_error)) return false;
    if (!QFile::setPermissions(m_runtime, privateDirectory)) return fail(QStringLiteral("Cannot secure runtime directory: %1").arg(m_runtime));
    if (QFile::encodeName(tmuxSocket()).size() >= int(sizeof(sockaddr_un::sun_path)))
        return fail(QStringLiteral("The Cinmux tmux socket path is too long: %1").arg(tmuxSocket()));
    struct stat st {};
    const auto dbName = QFile::encodeName(database);
    if (::lstat(dbName.constData(), &st) == 0 && (!S_ISREG(st.st_mode) || st.st_uid != ::getuid()))
        return fail(QStringLiteral("State database is not a regular file owned by this user"));
    m_connection = QStringLiteral("cinmux-") + QUuid::createUuid().toString(QUuid::WithoutBraces);
    m_db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), m_connection);
    m_db.setDatabaseName(database);
    m_db.setConnectOptions(QStringLiteral("QSQLITE_BUSY_TIMEOUT=2000"));
    if (!m_db.open()) return fail(m_db.lastError().text());
    if (!execute(QStringLiteral("PRAGMA busy_timeout=2000")) || !execute(QStringLiteral("PRAGMA foreign_keys=ON"))) return false;
    QSqlQuery version(m_db);
    if (!version.exec(QStringLiteral("PRAGMA user_version")) || !version.next()) return fail(version.lastError().text());
    const int schema = version.value(0).toInt();
    version.finish();
    if (schema > 2) return fail(QStringLiteral("This state database uses a newer Cinmux schema (%1)").arg(schema));
    if (schema < 0) return fail(QStringLiteral("Invalid state database schema"));
    if (!execute(QStringLiteral("PRAGMA journal_mode=WAL"))) return false;
    if (schema < 2) {
        // Serialize first-open migrations across the GUI and independent CLI writers.
        if (!execute(QStringLiteral("BEGIN IMMEDIATE"))) return false;
        auto migrate = [this] {
            QSqlQuery version(m_db);
            if (!version.exec(QStringLiteral("PRAGMA user_version")) || !version.next()) return fail(version.lastError().text());
            const int current = version.value(0).toInt();
            version.finish();
            if (current == 2) return true;
            if (current < 0 || current > 2) return fail(QStringLiteral("Unsupported state database schema (%1)").arg(current));
            if (current == 0) {
                QSqlQuery tables(m_db);
                if (!tables.exec(QStringLiteral("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"))) return fail(tables.lastError().text());
                if (tables.next()) return fail(QStringLiteral("Refusing to replace an unrecognized state database"));
                tables.finish();
                if (!execute(QStringLiteral("CREATE TABLE folders(id TEXT PRIMARY KEY, name TEXT NOT NULL, position INTEGER NOT NULL)")) ||
                    !execute(QStringLiteral("CREATE TABLE sessions(id TEXT PRIMARY KEY, folder_id TEXT REFERENCES folders(id) ON DELETE SET NULL, title TEXT NOT NULL, pinned INTEGER NOT NULL DEFAULT 0, cwd TEXT NOT NULL, created_at INTEGER NOT NULL, notice_seq INTEGER NOT NULL DEFAULT 0, read_seq INTEGER NOT NULL DEFAULT 0, notice_title TEXT NOT NULL DEFAULT '', notice_body TEXT NOT NULL DEFAULT '', notice_at INTEGER NOT NULL DEFAULT 0)"))) return false;
            } else {
                // Do not label an incomplete/unrecognized v1 database as migrated.
                if (!execute(QStringLiteral("SELECT id, name, position FROM folders LIMIT 0")) ||
                    !execute(QStringLiteral("SELECT id, folder_id, title, pinned, cwd, created_at, notice_seq, read_seq, notice_title, notice_body, notice_at FROM sessions LIMIT 0"))) return false;
            }
            return execute(QStringLiteral("CREATE TABLE session_activity(session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, pid INTEGER NOT NULL CHECK(pid>0), boot_id TEXT NOT NULL, start_ticks INTEGER NOT NULL CHECK(start_ticks>0), state TEXT NOT NULL CHECK(state IN ('working','waiting','done')), detail TEXT NOT NULL DEFAULT '' CHECK(length(detail)<=1024), updated_at INTEGER NOT NULL, PRIMARY KEY(session_id,pid,boot_id,start_ticks))")) &&
                   execute(QStringLiteral("PRAGMA user_version=2"));
        };
        if (!migrate()) { m_db.rollback(); return false; }
        if (!m_db.commit()) { const QString message = m_db.lastError().text(); m_db.rollback(); return fail(message); }
    }
    if (!QFile::setPermissions(database, QFileDevice::ReadOwner | QFileDevice::WriteOwner)) return fail(QStringLiteral("Cannot secure state database"));
    m_exists = true;
    QList<SessionRecord> entries;
    QList<FolderRecord> labels;
    m_opened = sessions(&entries) && folders(&labels);
    return m_opened;
}

bool StateStore::execute(const QString &sql, const QVariantList &values) {
    QSqlQuery query(m_db);
    if (!query.prepare(sql)) return fail(query.lastError().text());
    for (const auto &value : values) query.addBindValue(value);
    if (!query.exec()) return fail(query.lastError().text());
    return true;
}

bool StateStore::sessions(QList<SessionRecord> *result) {
    result->clear();
    if (!m_exists) return true;
    QSqlQuery query(m_db);
    if (!query.exec(QStringLiteral("SELECT id, folder_id, title, pinned, cwd, created_at, notice_seq, read_seq, notice_title, notice_body, notice_at FROM sessions ORDER BY pinned DESC, created_at DESC, id ASC"))) return fail(query.lastError().text());
    while (query.next()) {
        SessionRecord r;
        r.id = query.value(0).toString(); r.folderId = query.value(1).toString(); r.title = query.value(2).toString();
        r.pinned = query.value(3).toBool(); r.cwd = query.value(4).toString(); r.createdAt = query.value(5).toLongLong();
        r.noticeSequence = query.value(6).toLongLong(); r.readSequence = query.value(7).toLongLong();
        r.noticeTitle = query.value(8).toString(); r.noticeBody = query.value(9).toString(); r.noticeAt = query.value(10).toLongLong();
        if (!validId(r.id) || (!r.folderId.isEmpty() && !validId(r.folderId))) return fail(QStringLiteral("Invalid session identity in state database"));
        result->append(r);
    }
    query.finish();
    QHash<QString, SessionActivity> activity;
    if (!activities(&activity)) return false;
    for (auto &record : *result) {
        const auto value = activity.constFind(record.id);
        if (value == activity.cend()) continue;
        record.activity = value->state;
        record.activityDetail = value->detail;
        record.activityAt = value->updatedAt;
    }
    return true;
}
bool StateStore::folders(QList<FolderRecord> *result) {
    result->clear();
    if (!m_exists) return true;
    QSqlQuery query(m_db);
    if (!query.exec(QStringLiteral("SELECT id, name, position FROM folders ORDER BY position, id"))) return fail(query.lastError().text());
    while (query.next()) result->append({query.value(0).toString(), query.value(1).toString(), query.value(2).toInt()});
    return true;
}
bool StateStore::insertSession(const SessionRecord &r) {
    if (!validId(r.id) || r.title.trimmed().isEmpty() || !QDir::isAbsolutePath(r.cwd)) return fail(QStringLiteral("Invalid session record"));
    return execute(QStringLiteral("INSERT INTO sessions(id,folder_id,title,pinned,cwd,created_at) VALUES(?,?,?,?,?,?)"), {r.id, nullableId(r.folderId), r.title.trimmed(), r.pinned, r.cwd, r.createdAt});
}
bool StateStore::renameSession(const QString &id, const QString &title) {
    if (title.trimmed().isEmpty()) return fail(QStringLiteral("Session title cannot be blank"));
    return execute(QStringLiteral("UPDATE sessions SET title=? WHERE id=?"), {title.trimmed(), id});
}
bool StateStore::setPinned(const QString &id, bool pinned) { return execute(QStringLiteral("UPDATE sessions SET pinned=? WHERE id=?"), {pinned, id}); }
bool StateStore::moveSession(const QString &id, const QString &folderId) { return execute(QStringLiteral("UPDATE sessions SET folder_id=? WHERE id=?"), {nullableId(folderId), id}); }
bool StateStore::updateCwd(const QString &id, const QString &cwd) { return execute(QStringLiteral("UPDATE sessions SET cwd=? WHERE id=?"), {cwd, id}); }
bool StateStore::deleteSession(const QString &id) { return execute(QStringLiteral("DELETE FROM sessions WHERE id=?"), {id}); }
bool StateStore::validateFolderName(const QString &name, const QString &except) {
    if (name.trimmed().isEmpty()) return fail(QStringLiteral("Folder name cannot be blank"));
    QList<FolderRecord> all;
    if (!folders(&all)) return false;
    const QString candidate = name.trimmed();
    for (const auto &folder : all) {
        if (folder.id == except) continue;
        UErrorCode status = U_ZERO_ERROR;
        const int comparison = u_strCaseCompare(
            reinterpret_cast<const UChar *>(candidate.utf16()), candidate.size(),
            reinterpret_cast<const UChar *>(folder.name.utf16()), folder.name.size(),
            U_FOLD_CASE_DEFAULT, &status);
        if (U_FAILURE(status)) return fail(QStringLiteral("Cannot compare Unicode folder names: %1").arg(QString::fromLatin1(u_errorName(status))));
        if (comparison == 0) return fail(QStringLiteral("A folder with that name already exists"));
    }
    return true;
}
bool StateStore::createFolder(const QString &id, const QString &name) {
    if (!validId(id)) return fail(QStringLiteral("Invalid folder identity"));
    if (!validateFolderName(name)) return false;
    return execute(QStringLiteral("INSERT INTO folders(id,name,position) VALUES(?,?,COALESCE((SELECT MAX(position)+1 FROM folders),0))"), {id, name.trimmed()});
}
bool StateStore::renameFolder(const QString &id, const QString &name) {
    if (!validateFolderName(name, id)) return false;
    return execute(QStringLiteral("UPDATE folders SET name=? WHERE id=?"), {name.trimmed(), id});
}
bool StateStore::deleteFolder(const QString &id) { return execute(QStringLiteral("DELETE FROM folders WHERE id=?"), {id}); }
bool StateStore::notify(const QString &id, const QString &title, const QString &body, bool *found) {
    if (found) *found = false;
    if (!validId(id) || title.trimmed().isEmpty()) return fail(QStringLiteral("A valid session UUID and nonblank title are required"));
    if (!m_exists) return true;
    QSqlQuery query(m_db);
    if (!query.prepare(QStringLiteral("UPDATE sessions SET notice_seq=notice_seq+1, notice_title=?, notice_body=?, notice_at=? WHERE id=?"))) return fail(query.lastError().text());
    query.addBindValue(title); query.addBindValue(body.isNull() ? QStringLiteral("") : body); query.addBindValue(QDateTime::currentMSecsSinceEpoch()); query.addBindValue(id);
    if (!query.exec()) return fail(query.lastError().text());
    if (found) *found = query.numRowsAffected() == 1;
    return true;
}
bool StateStore::acknowledge(const QString &id, qint64 observedSequence) {
    return execute(QStringLiteral("UPDATE sessions SET read_seq=MAX(read_seq,MIN(?,notice_seq)) WHERE id=?"), {observedSequence, id});
}
bool StateStore::validActivity(const QString &state) {
    return state == QStringLiteral("idle") || state == QStringLiteral("working") ||
           state == QStringLiteral("waiting") || state == QStringLiteral("done");
}
bool StateStore::processIdentity(qint64 pid, ActivityReporter *reporter, QString *error) {
    QString bootId;
    return bootIdentity(&bootId, error) && readProcessIdentity(pid, bootId, reporter, error);
}
bool StateStore::setActivity(const QString &id, const QString &state, const ActivityReporter &reporter,
                             const QString &detail, bool *found, bool *invalidReporter) {
    if (found) *found = false;
    if (invalidReporter) *invalidReporter = false;
    if (!validId(id) || !validActivity(state) || detail.size() > activityDetailLimit)
        return fail(QStringLiteral("A valid session UUID, activity state and detail of at most %1 characters are required").arg(activityDetailLimit));
    if (!m_exists) return true;
    if (!execute(QStringLiteral("BEGIN IMMEDIATE"))) return false;
    auto update = [this, &id, &state, &reporter, &detail, found, invalidReporter] {
        QSqlQuery session(m_db);
        if (!session.prepare(QStringLiteral("SELECT 1 FROM sessions WHERE id=?"))) return fail(session.lastError().text());
        session.addBindValue(id);
        if (!session.exec()) return fail(session.lastError().text());
        if (!session.next()) return true;
        session.finish();
        // Recheck after obtaining the write lock: PID reuse while waiting must not
        // transfer a previous process's pending report to a new owner.
        ActivityReporter current;
        QString message;
        if (!processIdentity(reporter.pid, &current, &message) || current != reporter) {
            if (invalidReporter) *invalidReporter = true;
            return fail(message.isEmpty() ? QStringLiteral("Reporter process identity changed") : message);
        }
        if (found) *found = true;
        if (state == QStringLiteral("idle"))
            return execute(QStringLiteral("DELETE FROM session_activity WHERE session_id=? AND pid=? AND boot_id=? AND start_ticks=?"),
                           {id, reporter.pid, reporter.bootId, reporter.startTicks});
        return execute(QStringLiteral("INSERT INTO session_activity(session_id,pid,boot_id,start_ticks,state,detail,updated_at) VALUES(?,?,?,?,?,?,?) ON CONFLICT(session_id,pid,boot_id,start_ticks) DO UPDATE SET state=excluded.state,detail=excluded.detail,updated_at=excluded.updated_at"),
                       {id, reporter.pid, reporter.bootId, reporter.startTicks, state, detail.isNull() ? QStringLiteral("") : detail, QDateTime::currentMSecsSinceEpoch()});
    };
    if (!update()) { m_db.rollback(); return false; }
    if (!m_db.commit()) { const QString message = m_db.lastError().text(); m_db.rollback(); return fail(message); }
    return true;
}
bool StateStore::activities(QHash<QString, SessionActivity> *result) {
    result->clear();
    QSqlQuery query(m_db);
    if (!query.exec(QStringLiteral("SELECT session_id,pid,boot_id,start_ticks,state,detail,updated_at FROM session_activity ORDER BY CASE state WHEN 'waiting' THEN 3 WHEN 'working' THEN 2 ELSE 1 END DESC,updated_at DESC,pid ASC,boot_id ASC,start_ticks ASC"))) return fail(query.lastError().text());
    QString bootId;
    QHash<qint64, ActivityReporter> processes;
    QList<QVariantList> stale;
    while (query.next()) {
        if (bootId.isEmpty() && !bootIdentity(&bootId, &m_error)) return false;
        const QString id = query.value(0).toString();
        const ActivityReporter reporter{query.value(1).toLongLong(), query.value(2).toString(), query.value(3).toLongLong()};
        auto process = processes.constFind(reporter.pid);
        if (process == processes.cend()) {
            ActivityReporter current;
            QString ignored;
            readProcessIdentity(reporter.pid, bootId, &current, &ignored);
            processes.insert(reporter.pid, current);
            process = processes.constFind(reporter.pid);
        }
        if (*process != reporter) {
            stale.append({id, reporter.pid, reporter.bootId, reporter.startTicks});
            continue;
        }
        if (!result->contains(id))
            result->insert(id, {query.value(4).toString(), query.value(5).toString(), query.value(6).toLongLong()});
    }
    query.finish();
    if (stale.isEmpty()) return true;
    if (!execute(QStringLiteral("BEGIN IMMEDIATE"))) return false;
    for (const auto &identity : stale) {
        // Exact identity deletion cannot erase a new report from a reused PID.
        if (!execute(QStringLiteral("DELETE FROM session_activity WHERE session_id=? AND pid=? AND boot_id=? AND start_ticks=?"), identity)) {
            m_db.rollback();
            return false;
        }
    }
    if (!m_db.commit()) { const QString message = m_db.lastError().text(); m_db.rollback(); return fail(message); }
    return true;
}
bool StateStore::dataVersion(qint64 *version) {
    QSqlQuery query(m_db);
    if (!query.exec(QStringLiteral("PRAGMA data_version")) || !query.next()) return fail(query.lastError().text());
    *version = query.value(0).toLongLong();
    return true;
}
bool StateStore::validId(const QString &id) {
    static const QRegularExpression re(QStringLiteral("\\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\z"));
    return re.match(id).hasMatch();
}
QString StateStore::sessionName(const QString &id) { return QStringLiteral("cinmux-") + id; }
QString StateStore::paneFormat() {
    // tmux sanitizes literal control characters in command arguments. These
    // fields contain only our UUID names, numeric IDs and boolean flags.
    return QStringLiteral("#{session_name}|#{session_id}|#{pane_id}|#{window_id}|#{pane_pid}|#{window_active}|#{pane_active}|#{pane_dead}");
}
bool StateStore::parsePanes(const QByteArray &output, QList<TmuxPane> *panes, QString *error) {
    panes->clear();
    for (const auto &line : output.split('\n')) {
        if (line.isEmpty()) continue;
        const auto fields = line.split('|');
        if (!fields[0].startsWith("cinmux-") || !validId(QString::fromLatin1(fields[0].mid(7)))) continue;
        if (fields.size() != 8) { *error = QStringLiteral("Invalid tmux pane snapshot"); return false; }
        bool ok = false;
        const qint64 pid = fields[4].toLongLong(&ok);
        if (!ok || !fields[1].startsWith('$') || !fields[2].startsWith('%') || !fields[3].startsWith('@')) { *error = QStringLiteral("Invalid tmux pane identity"); return false; }
        panes->append({QString::fromUtf8(fields[0]), QString::fromLatin1(fields[1]), QString::fromLatin1(fields[2]), QString::fromLatin1(fields[3]), pid, fields[5] == "1", fields[6] == "1", fields[7] == "1"});
    }
    return true;
}
bool StateStore::serverAbsent(const QString &socket, const QByteArray &stderrOutput) {
    return !QFileInfo::exists(socket) || stderrOutput.contains("no server running on") || stderrOutput.contains("Connection refused") || stderrOutput.contains("No such file or directory");
}
