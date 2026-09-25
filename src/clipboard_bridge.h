#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <memory>

struct cm_server;

class ClipboardBridge final : public QObject {
public:
    explicit ClipboardBridge(cm_server *server, QObject *parent = nullptr);
    ~ClipboardBridge() override;

    // Native MIME names use a lossless QString::fromLatin1/toLatin1 round trip.
    void nestedSelection(quint64 generation, const QStringList &formats);
    void sendSelection(quint64 token, const QString &mime, int fd);
    void releaseSelection(quint64 token);
    void refresh();

private:
    class Private;
    std::unique_ptr<Private> d;
};
