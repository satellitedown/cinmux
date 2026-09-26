#include "state_store.h"
#include "tui_input.h"
#include "tui_screen.h"
#include "tui_terminal.h"

#include <QProcess>
#include <QProcessEnvironment>
#include <QScopeGuard>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>
#include <QUuid>

using tui::InputEvent;
using tui::Key;
using tui::MouseAction;
using tui::MouseButton;

namespace {
std::vector<InputEvent> feed(tui::InputParser &parser, const QByteArray &bytes) {
    return parser.feed(bytes.constData(), size_t(bytes.size()));
}
std::vector<InputEvent> feedBytewise(tui::InputParser &parser, const QByteArray &bytes) {
    std::vector<InputEvent> events;
    for (const char byte : bytes) {
        const auto next = parser.feed(&byte, 1);
        events.insert(events.end(), next.begin(), next.end());
    }
    return events;
}
bool tmux(const QStringList &arguments) {
    QProcess process;
    auto environment = QProcessEnvironment::systemEnvironment();
    environment.remove(QStringLiteral("TMUX"));
    process.setProcessEnvironment(environment);
    process.start(QStringLiteral("tmux"), arguments);
    return process.waitForFinished(5000) && process.exitStatus() == QProcess::NormalExit && process.exitCode() == 0;
}
QString screenText(const TuiTerminals &terminals, const QString &id) {
    tui::Surface surface;
    surface.resize(80, 24);
    terminals.paint(id, surface, 0, 0, 80, 24);
    QString text;
    for (int y = 0; y < surface.rows(); ++y) {
        for (int x = 0; x < surface.cols(); ++x) if (surface.at(x, y).width) text += QString::fromUcs4(surface.at(x, y).chars, 1);
        text += QLatin1Char('\n');
    }
    return text;
}
}

class TuiTest : public QObject {
    Q_OBJECT
private slots:
    void keysSurviveSplitReads_data();
    void keysSurviveSplitReads();
    void escapeWaitsForTimeout();
    void pasteKeepsEscapesAcrossReads();
    void mouseDistinguishesHoverDragAndWheel();
    void surfaceNeverStoresControlCharacters();
    void viewShowsOutputAndReportsLoss();
};

void TuiTest::keysSurviveSplitReads_data() {
    QTest::addColumn<QByteArray>("bytes");
    QTest::addColumn<int>("key");
    QTest::addColumn<uint>("codepoint");
    QTest::addColumn<int>("modifiers");
    const int ctrl = tui::Ctrl, alt = tui::Alt, shift = tui::Shift;
    QTest::newRow("kitty Ctrl+Shift+N") << QByteArray("\x1b[110;6u") << int(Key::Character) << uint('n') << (ctrl | shift);
    QTest::newRow("modifyOtherKeys Ctrl+Shift+N") << QByteArray("\x1b[27;6;110~") << int(Key::Character) << uint('n') << (ctrl | shift);
    QTest::newRow("legacy Ctrl+Alt+N") << QByteArray("\x1b\x0e") << int(Key::Character) << uint('n') << (ctrl | alt);
    QTest::newRow("Ctrl+R") << QByteArray("\x12") << int(Key::Character) << uint('r') << ctrl;
    QTest::newRow("Ctrl+Alt+PageUp") << QByteArray("\x1b[5;7~") << int(Key::PageUp) << 0u << (ctrl | alt);
    QTest::newRow("Shift+F10") << QByteArray("\x1b[21;2~") << int(Key::Function) << 10u << shift;
    QTest::newRow("Ctrl+Alt+Left") << QByteArray("\x1b[1;7D") << int(Key::Left) << 0u << (ctrl | alt);
    QTest::newRow("SS3 Up") << QByteArray("\x1bOA") << int(Key::Up) << 0u << 0;
    QTest::newRow("kitty Shift+Enter") << QByteArray("\x1b[13;2u") << int(Key::Enter) << 0u << shift;
    QTest::newRow("shifted text") << QByteArray("\x1b[27;2;97~") << int(Key::Character) << uint('A') << 0;
    QTest::newRow("UTF-8") << QByteArray("\xe4\xb8\xad") << int(Key::Character) << uint(0x4e2d) << 0;
}

void TuiTest::keysSurviveSplitReads() {
    QFETCH(QByteArray, bytes);
    QFETCH(int, key);
    QFETCH(uint, codepoint);
    QFETCH(int, modifiers);
    tui::InputParser parser;
    auto events = feedBytewise(parser, bytes);
    QVERIFY(!parser.pending());
    QCOMPARE(events.size(), size_t(1));
    const InputEvent &event = events.front();
    QCOMPARE(event.type, InputEvent::Type::Key);
    QCOMPARE(int(event.key), key);
    QCOMPARE(int(event.modifiers), modifiers);
    if (event.key == Key::Function) QCOMPARE(uint(event.function), codepoint);
    else if (event.key == Key::Character) QCOMPARE(uint(event.codepoint), codepoint);
}

void TuiTest::escapeWaitsForTimeout() {
    tui::InputParser parser;
    QVERIFY(feed(parser, "\x1b").empty());
    QVERIFY(parser.pending());
    auto events = parser.flush();
    QCOMPARE(events.size(), size_t(1));
    QCOMPARE(events.front().key, Key::Escape);
    QCOMPARE(int(events.front().modifiers), 0);
    QVERIFY(!parser.pending());
    // Two quick presses share one read: the chrome treats Alt+Escape as Escape.
    QVERIFY(feed(parser, "\x1b\x1b").empty());
    events = parser.flush();
    QCOMPARE(events.size(), size_t(1));
    QCOMPARE(events.front().key, Key::Escape);
    QCOMPARE(int(events.front().modifiers), int(tui::Alt));
    // Replies to the startup keyboard query never become keys.
    events = feed(parser, "\x1b[?1u\x1b[?62;22c");
    QCOMPARE(events.size(), size_t(2));
    QCOMPARE(events[0].type, InputEvent::Type::KeyboardFlags);
    QCOMPARE(events[0].flags, 1);
    QCOMPARE(events[1].type, InputEvent::Type::PrimaryAttributes);
    // Key releases and bare modifier keys (kitty) are not input.
    QVERIFY(feed(parser, "\x1b[97;1:3u\x1b[57441;2u").empty());
}

void TuiTest::pasteKeepsEscapesAcrossReads() {
    tui::InputParser parser;
    std::vector<InputEvent> events;
    for (const QByteArray chunk : {QByteArray("\x1b[200~ab"), QByteArray("\x1b[Ac\n"), QByteArray("d\x1b[20"), QByteArray("1~x")}) {
        const auto next = feed(parser, chunk);
        events.insert(events.end(), next.begin(), next.end());
        if (chunk.endsWith("20")) QVERIFY(parser.pasting());
    }
    QCOMPARE(events.size(), size_t(2));
    QCOMPARE(events[0].type, InputEvent::Type::Paste);
    QCOMPARE(events[0].text, QByteArray("ab\x1b[Ac\nd"));
    QCOMPARE(events[1].key, Key::Character);
    QCOMPARE(uint(events[1].codepoint), uint('x'));
    QVERIFY(!parser.pending());
}

void TuiTest::mouseDistinguishesHoverDragAndWheel() {
    tui::InputParser parser;
    const auto events = feed(parser, "\x1b[<35;10;5M\x1b[<32;11;5M\x1b[<0;1;1M\x1b[<0;1;1m\x1b[<65;3;4M\x1b[<18;2;2M");
    QCOMPARE(events.size(), size_t(6));
    for (const auto &event : events) QCOMPARE(event.type, InputEvent::Type::Mouse);
    QCOMPARE(events[0].action, MouseAction::Move);
    QCOMPARE(events[0].button, MouseButton::None);
    QCOMPARE(events[0].x, 9);
    QCOMPARE(events[0].y, 4);
    QCOMPARE(events[1].action, MouseAction::Move);
    QCOMPARE(events[1].button, MouseButton::Left);
    QCOMPARE(events[2].action, MouseAction::Press);
    QCOMPARE(events[2].x, 0);
    QCOMPARE(events[3].action, MouseAction::Release);
    QCOMPARE(events[3].button, MouseButton::Left);
    QCOMPARE(events[4].action, MouseAction::WheelDown);
    QCOMPARE(events[5].action, MouseAction::Press);
    QCOMPARE(events[5].button, MouseButton::Right);
    QCOMPARE(int(events[5].modifiers), int(tui::Ctrl));
}

void TuiTest::surfaceNeverStoresControlCharacters() {
    tui::Surface surface;
    surface.resize(8, 1);
    // Session titles and notification text come from any local process.
    QCOMPARE(surface.text(0, 0, QStringLiteral("a\x1b[2J\a\u009bz"), tui::Style{}), 8);
    for (int x = 0; x < surface.cols(); ++x) {
        const char32_t c = surface.at(x, 0).chars[0];
        QVERIFY2(c >= 0x20 && (c < 0x7f || c > 0x9f), qPrintable(QStringLiteral("control U+%1 at column %2").arg(uint(c), 4, 16, QLatin1Char('0')).arg(x)));
    }
    QCOMPARE(surface.at(1, 0).chars[0], U'\uFFFD');
    // A wide character never straddles the right edge.
    surface.text(7, 0, QStringLiteral("中"), tui::Style{});
    QCOMPARE(surface.at(7, 0).chars[0], U' ');
    QCOMPARE(int(surface.at(7, 0).width), 1);
}

void TuiTest::viewShowsOutputAndReportsLoss() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    StateStore store(directory.path());
    QVERIFY2(store.open(), qPrintable(store.error()));
    const QString id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    const QString socket = store.tmuxSocket();
    auto cleanup = qScopeGuard([&socket] { tmux({QStringLiteral("-S"), socket, QStringLiteral("kill-server")}); });
    QVERIFY(tmux({QStringLiteral("-S"), socket, QStringLiteral("-f"), QStringLiteral("/dev/null"), QStringLiteral("new-session"), QStringLiteral("-d"),
                  QStringLiteral("-s"), StateStore::sessionName(id), QStringLiteral("-x"), QStringLiteral("80"), QStringLiteral("-y"), QStringLiteral("24"),
                  QStringLiteral("/bin/sh")}));

    TuiTerminals terminals(&store);
    QSignalSpy ready(&terminals, &TerminalRenderer::ready);
    QSignalSpy lost(&terminals, &TerminalRenderer::lost);
    QSignalSpy interacted(&terminals, &TerminalRenderer::interacted);
    terminals.setSize(80, 24);
    terminals.setSelected(id);
    terminals.attach(id, false);
    QTRY_COMPARE_WITH_TIMEOUT(ready.count(), 1, 10000);

    for (const char c : QByteArrayLiteral("echo tui-$((6*7))")) {
        InputEvent key;
        key.key = Key::Character;
        key.codepoint = char32_t(c);
        terminals.sendKey(id, key);
    }
    InputEvent enter;
    enter.key = Key::Enter;
    terminals.sendKey(id, enter);
    QVERIFY(interacted.count() > 0);
    // The shell's own expansion proves the keys reached it and its output came back.
    QTRY_VERIFY_WITH_TIMEOUT(screenText(terminals, id).contains(QStringLiteral("tui-42")), 10000);

    terminals.detach(id);
    QVERIFY(!terminals.attached(id));
    QTest::qWait(300);
    QCOMPARE(lost.count(), 0);

    terminals.attach(id, false);
    QTRY_VERIFY_WITH_TIMEOUT(terminals.hasOutput(id), 10000);
    QVERIFY(tmux({QStringLiteral("-S"), socket, QStringLiteral("kill-session"), QStringLiteral("-t"), QStringLiteral("=") + StateStore::sessionName(id)}));
    QTRY_COMPARE_WITH_TIMEOUT(lost.count(), 1, 10000);
    QCOMPARE(lost.first().at(0).toString(), id);
    QVERIFY(!lost.first().at(1).toString().isEmpty());
    QVERIFY(!terminals.attached(id));
}

QTEST_GUILESS_MAIN(TuiTest)
#include "tui_test.moc"
