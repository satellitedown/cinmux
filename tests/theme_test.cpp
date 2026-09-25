#include "theme.h"
#include <QTest>
#include <QColor>
#include <QTemporaryDir>
#include <QDir>
#include <QFile>

class ThemeTest : public QObject {
    Q_OBJECT
private slots:
    void precedence() {
        const auto palette = Theme::parse("background='#123'\nbg='#456'\nforeground='#def'\nfg='#fff'\naccent='invalid'\nblue='#aBc'\ncolor4='#000'\nmode='dark'\ntheme_type='light'", true);
        QVERIFY(palette);
        QCOMPARE(palette->mode, "dark");
        QCOMPARE(palette->colors["bg"].value<QColor>(), QColor("#112233"));
        QCOMPARE(palette->colors["text"].value<QColor>(), QColor("#ddeeff"));
        QCOMPARE(palette->colors["accent"].value<QColor>(), QColor("#aabbcc"));
        QCOMPARE(palette->colors["selectionText"].value<QColor>(), QColor(Qt::black));
        const auto legacy = Theme::parse("mode='auto'\ntheme_type='light'\ncolor0='#111'\ncolor7='#eee'", false);
        QVERIFY(legacy); QCOMPARE(legacy->mode, "light");
        const auto marker = Theme::parse("background='#111'\nforeground='#eee'", true);
        QVERIFY(marker); QCOMPARE(marker->mode, "light");
        const auto threshold = Theme::parse("background='#7f7f7f'\nforeground='#eee'", false);
        QVERIFY(threshold); QCOMPARE(threshold->mode, "dark");
        QVERIFY(!Theme::parse("background='red'\nforeground='#fff'", false));
        QVERIFY(!Theme::parse(QByteArray(65537, ' '), false));
    }
    void lastGoodThroughReplacement() {
        QTemporaryDir temp;
        QVERIFY(temp.isValid());
        Theme theme(temp.path() + "/current");
        QCOMPARE(theme.colors()["bg"].value<QColor>(), QColor("#151719"));
        auto put = [](const QString &path, const QByteArray &bytes) {
            QFile file(path); return file.open(QIODevice::WriteOnly) && file.write(bytes) == bytes.size();
        };
        QDir root(temp.path());
        QVERIFY(root.mkdir("dark"));
        QVERIFY(put(temp.path() + "/dark/colors.toml", "background='#101010'\nforeground='#f0f0f0'"));
        QVERIFY(QFile::link(temp.path() + "/dark", temp.path() + "/current"));
        theme.refresh(); QCOMPARE(theme.colors()["bg"].value<QColor>(), QColor("#101010"));
        QVERIFY(put(temp.path() + "/dark/colors.toml", "background='"));
        theme.refresh(); QCOMPARE(theme.colors()["bg"].value<QColor>(), QColor("#101010"));
        QVERIFY(QFile::remove(temp.path() + "/current"));
        theme.refresh(); QCOMPARE(theme.colors()["bg"].value<QColor>(), QColor("#101010"));
        QVERIFY(root.mkdir("light"));
        QVERIFY(put(temp.path() + "/light/colors.toml", "background='#eff1f5'\nforeground='#4c4f69'\nlighter_background='#dce0e8'"));
        QVERIFY(QFile::link(temp.path() + "/light", temp.path() + "/current"));
        theme.refresh(); QCOMPARE(theme.mode(), "light");
        QCOMPARE(theme.colors()["bgRaised"].value<QColor>(), QColor("#dce0e8"));
        QVERIFY(put(temp.path() + "/light/colors.toml", "background='#101010'\nforeground='#f0f0f0'"));
        QVERIFY(put(temp.path() + "/light/light.mode", ""));
        theme.refresh(); QCOMPARE(theme.mode(), "light");
        QVERIFY(QFile::remove(temp.path() + "/light/light.mode"));
        theme.refresh(); QCOMPARE(theme.mode(), "dark");
    }
};
QTEST_GUILESS_MAIN(ThemeTest)
#include "theme_test.moc"
