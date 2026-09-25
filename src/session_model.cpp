#include "session_model.h"

SessionModel::SessionModel(QObject *parent) : QAbstractListModel(parent) {}
int SessionModel::rowCount(const QModelIndex &parent) const { return parent.isValid() ? 0 : m_rows.size(); }
QHash<int, QByteArray> SessionModel::roleNames() const {
    return {{SessionId, "sessionId"}, {Title, "title"}, {FolderId, "folderId"}, {Pinned, "pinned"}, {Cwd, "cwd"}, {Branch, "branch"}, {Status, "status"}, {UnreadCount, "unreadCount"}, {NoticeTitle, "noticeTitle"}, {NoticeBody, "noticeBody"}, {NoticeSequence, "noticeSequence"}, {TerminalError, "terminalError"}, {Activity, "activity"}, {ActivityDetail, "activityDetail"}};
}
QVariant SessionModel::data(const QModelIndex &index, int role) const {
    if (!index.isValid() || index.row() < 0 || index.row() >= m_rows.size()) return {};
    const auto names = roleNames();
    const auto name = names.constFind(role);
    return name == names.cend() ? QVariant() : m_rows.at(index.row()).value(QString::fromLatin1(*name));
}
void SessionModel::setRows(const QList<QVariantMap> &rows) {
    bool sameIds = rows.size() == m_rows.size();
    for (int i = 0; sameIds && i < rows.size(); ++i) sameIds = rows[i].value("sessionId") == m_rows[i].value("sessionId");
    if (!sameIds) {
        const int oldCount = m_rows.size();
        beginResetModel(); m_rows = rows; endResetModel();
        if (oldCount != m_rows.size()) emit countChanged();
        return;
    }
    for (int i = 0; i < rows.size(); ++i) {
        if (m_rows[i] == rows[i]) continue;
        m_rows[i] = rows[i];
        emit dataChanged(index(i), index(i));
    }
}
QVariantMap SessionModel::get(int index) const { return index >= 0 && index < m_rows.size() ? m_rows.at(index) : QVariantMap(); }
QStringList SessionModel::ids() const {
    QStringList result;
    result.reserve(m_rows.size());
    for (const auto &row : m_rows) result.append(row.value("sessionId").toString());
    return result;
}
