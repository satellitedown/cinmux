#pragma once

#include "session_model.h"
#include "state_store.h"
#include <QProcessEnvironment>
#include <QPointer>
#include <QQueue>
#include <QSet>
#include <QTimer>
#include <functional>
#include <memory>

class TerminalCompositor;
class QProcess;

class SessionController : public QObject {
    Q_OBJECT
    Q_PROPERTY(SessionModel *model READ model CONSTANT)
    Q_PROPERTY(QVariantList folders READ folders NOTIFY foldersChanged)
    Q_PROPERTY(QString selectedId READ selectedId NOTIFY selectionChanged)
    Q_PROPERTY(QVariantMap selected READ selected NOTIFY selectionChanged)
    Q_PROPERTY(QString search READ search WRITE setSearch NOTIFY searchChanged)
    Q_PROPERTY(QString view READ view WRITE setView NOTIFY viewChanged)
    Q_PROPERTY(int totalCount READ totalCount NOTIFY stateChanged)
    Q_PROPERTY(int attentionCount READ attentionCount NOTIFY stateChanged)
public:
    explicit SessionController(StateStore *store, TerminalCompositor *compositor, QObject *parent = nullptr);
    ~SessionController() override;
    SessionModel *model() { return &m_model; }
    QVariantList folders() const { return m_folders; }
    QString selectedId() const { return m_selectedId; }
    QVariantMap selected() const;
    QString search() const { return m_search; }
    void setSearch(const QString &search);
    QString view() const { return m_view; }
    void setView(const QString &view);
    int totalCount() const { return m_sessions.size(); }
    int attentionCount() const;
    void setColorMode(const QString &mode);
    Q_INVOKABLE void createSession(const QString &folderId, const QString &cwd);
    Q_INVOKABLE void selectSession(const QString &id);
    Q_INVOKABLE void renameSession(const QString &id, const QString &title);
    Q_INVOKABLE void setPinned(const QString &id, bool pinned);
    Q_INVOKABLE void moveSession(const QString &id, const QString &folderId);
    Q_INVOKABLE void startSession(const QString &id, const QString &cwd);
    Q_INVOKABLE void reconnectTerminal(const QString &id);
    Q_INVOKABLE void splitActive(const QString &direction);
    Q_INVOKABLE void closeActivePane();
    Q_INVOKABLE void closeSession(const QString &id);
    Q_INVOKABLE void createFolder(const QString &name);
    Q_INVOKABLE void renameFolder(const QString &id, const QString &name);
    Q_INVOKABLE void deleteFolder(const QString &id);
    Q_INVOKABLE void acknowledge(const QString &id, qint64 observedSequence);
    Q_INVOKABLE void selectNextAttention();
    Q_INVOKABLE void refresh();
    Q_INVOKABLE void navigate(int delta);
signals:
    void foldersChanged();
    void selectionChanged();
    void searchChanged();
    void viewChanged();
    void stateChanged();
    void operationFailed(QString sessionId, QString message);
    void directoryRequired(QString sessionId, QString folderId, QString path);
private:
    struct Session {
        SessionRecord record;
        QString status = QStringLiteral("stopped");
        QString branch;
        QString terminalError;
        QList<TmuxPane> panes;
        QPointer<QProcess> foot;
        QByteArray footStderr;
        quint64 rendererGeneration = 0;
        bool mapped = false;
        bool reconciled = false;
        bool closing = false;
    };
    struct CommandResult { bool ok = false; bool timedOut = false; QByteArray output; QByteArray error; };
    struct GitEntry { QString branch; qint64 checkedAt = 0; bool pending = false; };
    using ResultCallback = std::function<void(const CommandResult &)>;
    using Done = std::function<void()>;
    using Operation = std::function<void(Done)>;
    void command(const QString &program, const QStringList &args, const QProcessEnvironment &environment, ResultCallback callback);
    void tmux(const QStringList &args, ResultCallback callback);
    void enqueue(const QString &id, Operation operation);
    void nextOperation(const QString &id);
    bool readState();
    void publish();
    QVariantMap row(const Session &session) const;
    void fail(const QString &id, const QString &message);
    bool checked(const QString &id, bool result);
    bool usableCwd(const QString &id, const QString &cwd);
    void snapshot(std::function<void(bool, const QList<TmuxPane> &)> callback);
    void applySnapshot(const QList<TmuxPane> &panes);
    void startOwned(const QString &id, const QString &cwd, Done done);
    void respawnPanes(const QList<TmuxPane> &panes, int index, const QString &cwd, ResultCallback callback);
    void attach(const QString &id, bool force = false);
    void stopRenderer(const QString &id);
    void closeOwned(const QString &id, Done done);
    void refreshBranches();
    void updateBranch(const QString &cwd, const QString &branch);
    QString shell() const;
    QString activeCwd(const Session &session) const;
    static const TmuxPane *activePane(const QList<TmuxPane> &panes);
    StateStore *m_store;
    TerminalCompositor *m_compositor;
    SessionModel m_model;
    QHash<QString, std::shared_ptr<Session>> m_sessions;
    QList<FolderRecord> m_folderRecords;
    QVariantList m_folders;
    QHash<QString, QQueue<Operation>> m_operations;
    QSet<QString> m_busy;
    QHash<QString, GitEntry> m_git;
    QSet<QProcess *> m_commands;
    QProcessEnvironment m_hostEnvironment;
    QTimer m_metadataTimer;
    QTimer m_databaseTimer;
    QString m_selectedId;
    QString m_search;
    QString m_view = QStringLiteral("all");
    QString m_colorMode = QStringLiteral("dark");
    QString m_tmuxConfig;
    QString m_tmuxProgram;
    QString m_footProgram;
    qint64 m_dataVersion = -1;
    bool m_refreshing = false;
    bool m_shuttingDown = false;
};
