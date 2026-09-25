#pragma once

#include <QAbstractListModel>
#include <QVariantMap>

class SessionModel : public QAbstractListModel {
    Q_OBJECT
    Q_PROPERTY(int count READ rowCount NOTIFY countChanged)
public:
    enum Role { SessionId = Qt::UserRole + 1, Title, FolderId, Pinned, Cwd, Branch, Status, UnreadCount, NoticeTitle, NoticeBody, NoticeSequence, TerminalError, Activity, ActivityDetail };
    Q_ENUM(Role)
    explicit SessionModel(QObject *parent = nullptr);
    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;
    void setRows(const QList<QVariantMap> &rows);
    Q_INVOKABLE QVariantMap get(int index) const;
    QStringList ids() const;
signals:
    void countChanged();
private:
    QList<QVariantMap> m_rows;
};
