#pragma once

#include <QHash>
#include <QObject>
#include <QSqlDatabase>
#include <QStringList>
#include <QVariant>

struct FolderRecord {
    QString id;
    QString name;
    int position = 0;
};

struct SessionRecord {
    QString id;
    QString folderId;
    QString title;
    bool pinned = false;
    QString cwd;
    qint64 createdAt = 0;
    qint64 noticeSequence = 0;
    qint64 readSequence = 0;
    QString noticeTitle;
    QString noticeBody;
    qint64 noticeAt = 0;
    QString activity = QStringLiteral("idle");
    QString activityDetail;
    qint64 activityAt = 0;
};

struct TmuxPane {
    QString sessionName;
    QString sessionId;
    QString paneId;
    QString windowId;
    qint64 pid = 0;
    bool windowActive = false;
    bool paneActive = false;
    bool dead = false;
};

struct ActivityReporter {
    qint64 pid = 0;
    QString bootId;
    qint64 startTicks = 0;
    bool operator==(const ActivityReporter &) const = default;
};

struct SessionActivity {
    QString state = QStringLiteral("idle");
    QString detail;
    qint64 updatedAt = 0;
};

class StateStore : public QObject {
    Q_OBJECT
public:
    explicit StateStore(const QString &directory = QString(), bool create = true);
    ~StateStore() override;
    bool open();
    QString error() const { return m_error; }
    QString stateDirectory() const { return m_directory; }
    QString runtimeDirectory() const { return m_runtime; }
    QString profileHash() const { return m_hash; }
    QString tmuxSocket() const { return m_runtime + QStringLiteral("/tmux.sock"); }
    bool exists() const { return m_exists; }
    bool sessions(QList<SessionRecord> *result);
    bool folders(QList<FolderRecord> *result);
    bool insertSession(const SessionRecord &record);
    bool renameSession(const QString &id, const QString &title);
    bool setPinned(const QString &id, bool pinned);
    bool moveSession(const QString &id, const QString &folderId);
    bool updateCwd(const QString &id, const QString &cwd);
    bool deleteSession(const QString &id);
    bool createFolder(const QString &id, const QString &name);
    bool renameFolder(const QString &id, const QString &name);
    bool deleteFolder(const QString &id);
    bool notify(const QString &id, const QString &title, const QString &body, bool *found = nullptr);
    bool acknowledge(const QString &id, qint64 observedSequence);
    static constexpr int activityDetailLimit = 1024;
    static bool validActivity(const QString &state);
    static bool processIdentity(qint64 pid, ActivityReporter *reporter, QString *error);
    bool setActivity(const QString &id, const QString &state, const ActivityReporter &reporter,
                     const QString &detail, bool *found = nullptr, bool *invalidReporter = nullptr);
    bool dataVersion(qint64 *version);
    static bool validId(const QString &id);
    static QString sessionName(const QString &id);
    static QString paneFormat();
    static bool parsePanes(const QByteArray &output, QList<TmuxPane> *panes, QString *error);
    static bool serverAbsent(const QString &socket, const QByteArray &stderrOutput);

private:
    bool execute(const QString &sql, const QVariantList &values = {});
    bool validateFolderName(const QString &name, const QString &except = QString());
    bool activities(QHash<QString, SessionActivity> *result);
    bool fail(const QString &message);
    QString m_directory;
    QString m_runtime;
    QString m_hash;
    QString m_error;
    QString m_connection;
    QSqlDatabase m_db;
    bool m_create;
    bool m_exists = false;
    bool m_opened = false;
};
