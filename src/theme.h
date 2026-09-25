#pragma once
#include <QObject>
#include <QVariantMap>
#include <QTimer>
#include <optional>

struct ThemePalette {
    QString mode;
    QVariantMap colors;
    bool operator==(const ThemePalette &) const = default;
};

class Theme final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantMap colors READ colors NOTIFY changed)
    Q_PROPERTY(QString mode READ mode NOTIFY changed)
public:
    explicit Theme(const QString &directory = {}, QObject *parent = nullptr);
    QVariantMap colors() const { return m_palette.colors; }
    QString mode() const { return m_palette.mode; }
    static ThemePalette defaultPalette();
    static std::optional<ThemePalette> parse(const QByteArray &text, bool lightMarker);
public slots:
    void refresh();
signals:
    void changed();
private:
    QString m_directory;
    ThemePalette m_palette = defaultPalette();
    QTimer m_timer;
};
