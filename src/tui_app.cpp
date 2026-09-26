#include "tui_app.h"

#include "session_controller.h"
#include "state_store.h"
#include "theme.h"
#include "tui_input.h"
#include "tui_screen.h"
#include "tui_terminal.h"

#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QSettings>
#include <QSocketNotifier>
#include <QTextStream>
#include <QTimer>
#include <algorithm>
#include <cerrno>
#include <csignal>
#include <functional>
#include <memory>
#include <optional>
#include <sys/stat.h>
#include <unistd.h>

namespace {
using tui::Color;
using tui::InputEvent;
using tui::Key;
using tui::MouseAction;
using tui::MouseButton;
using tui::Style;

// Cell equivalents of the GUI's pixel metrics (1050px wide threshold, 150-460px
// folders, 210-540px sessions, 260px minimum terminal).
constexpr int wideColumns = 110;
constexpr int minimumTerminal = 30;
constexpr int minimumFolders = 16;
constexpr int maximumFolders = 48;
constexpr int minimumSessions = 24;
constexpr int maximumSessions = 60;
constexpr int defaultFolders = 24;
constexpr int defaultSessions = 34;
constexpr int escapeTimeout = 50;
constexpr int pasteTimeout = 1000;
constexpr int tooltipDelay = 700;
constexpr int frameInterval = 16;

const QString glyphPanelLeft = QStringLiteral("◧");
const QString glyphPanelRight = QStringLiteral("◨");
const QString glyphPlus = QStringLiteral("+");
const QString glyphSplitRight = QStringLiteral("◫");
const QString glyphSplitDown = QStringLiteral("⊟");
const QString glyphBell = QStringLiteral("⚑");
const QString glyphSearch = QStringLiteral("⌕");
const QString glyphMore = QStringLiteral("⋯");
const QString glyphClose = QStringLiteral("✕");
const QString glyphTabs = QStringLiteral("▣");
const QString glyphFolder = QStringLiteral("▢");
const QString glyphPin = QStringLiteral("✦");
const QString glyphPencil = QStringLiteral("✎");
const QString glyphCheck = QStringLiteral("✓");
const QString glyphIdle = QStringLiteral("○");
const QString glyphWaiting = QStringLiteral("?");
const QString glyphError = QStringLiteral("●");
const QString glyphChevron = QStringLiteral("›");
const QString glyphQuit = QStringLiteral("←");
const QString glyphMarker = QStringLiteral("▎");
const QStringList spinner = {QStringLiteral("⠋"), QStringLiteral("⠙"), QStringLiteral("⠹"), QStringLiteral("⠸"), QStringLiteral("⠼"),
                             QStringLiteral("⠴"), QStringLiteral("⠦"), QStringLiteral("⠧"), QStringLiteral("⠇"), QStringLiteral("⠏")};

QColor mix(const QColor &a, const QColor &b, double amount) {
    return QColor(qRound(a.red() + (b.red() - a.red()) * amount), qRound(a.green() + (b.green() - a.green()) * amount),
                  qRound(a.blue() + (b.blue() - a.blue()) * amount));
}
QColor onColor(const QColor &color) {
    return color.red() * 299 + color.green() * 587 + color.blue() * 114 > 150000 ? QColor(Qt::black) : QColor(Qt::white);
}
Color toward(const Color &color, const Color &target, double amount) {
    if (color.kind != Color::Kind::Rgb || target.kind != Color::Kind::Rgb) return color;
    return Color::rgb(mix(QColor(color.r, color.g, color.b), QColor(target.r, target.g, target.b), amount));
}
Color darken(const Color &color, double amount) { return toward(color, Color::rgb(0, 0, 0), amount); }

struct Palette {
    double overlay = .45;
    Color chrome, terminal, raised, raisedHover, raisedBorder, hover, border, text, muted, accent, accentDim, selected,
        danger, dangerDim, warning, onAccent, onDanger, selectionBg, selectionText;
};
// Mirrors qml/Theme.qml: fixed text colors per mode, translucent overlays
// flattened onto the theme background.
Palette palette(const Theme &theme) {
    const auto colors = theme.colors();
    auto color = [&colors](const char *key) { return colors.value(QLatin1String(key)).value<QColor>(); };
    const bool dark = theme.mode() != QStringLiteral("light");
    const QColor bg = color("bg");
    const QColor text = dark ? QColor(0xed, 0xed, 0xee) : QColor(0x25, 0x25, 0x28);
    const QColor muted = dark ? QColor(0xaa, 0xaa, 0xb0) : QColor(0x66, 0x66, 0x6e);
    const QColor raised = mix(dark ? QColor(0x2b, 0x2b, 0x2e) : QColor(Qt::white), color("bgRaised"), .035);
    Palette p;
    p.overlay = dark ? .45 : .30;
    p.chrome = p.terminal = Color::rgb(bg);
    p.raised = Color::rgb(raised);
    p.raisedHover = Color::rgb(mix(raised, text, dark ? .08 : .06));
    p.raisedBorder = Color::rgb(mix(raised, text, dark ? .16 : .18));
    p.hover = Color::rgb(mix(bg, text, dark ? .055 : .045));
    p.border = Color::rgb(mix(bg, text, dark ? .10 : .11));
    p.text = Color::rgb(text);
    p.muted = Color::rgb(muted);
    p.accent = Color::rgb(color("accent"));
    p.accentDim = Color::rgb(mix(bg, color("accent"), .12));
    p.selected = Color::rgb(mix(bg, text, dark ? .10 : .075));
    p.danger = Color::rgb(color("danger"));
    p.dangerDim = Color::rgb(mix(raised, color("danger"), .10));
    p.warning = Color::rgb(color("warning"));
    p.onAccent = Color::rgb(color("onAccent"));
    p.onDanger = Color::rgb(onColor(color("danger")));
    p.selectionBg = Color::rgb(color("selectionBg"));
    p.selectionText = Color::rgb(color("selectionText"));
    return p;
}

Style style(const Color &fg, const Color &bg, uint16_t attributes = 0) { return Style{fg, bg, attributes}; }
bool menuKey(const InputEvent &e) {
    return e.key == Key::Menu || (e.key == Key::Function && e.function == 10 && e.modifiers == tui::Shift);
}
bool plainKey(const InputEvent &e, Key key) { return e.key == key && !(e.modifiers & (tui::Ctrl | tui::Alt)); }
// Two quick Escape presses arrive as one `ESC ESC` read, decoded as Alt+Escape.
bool escape(const InputEvent &e) { return e.key == Key::Escape && !(e.modifiers & tui::Ctrl); }
bool character(const InputEvent &e, char32_t c) { return e.key == Key::Character && !e.modifiers && e.codepoint == c; }

struct LineEdit {
    enum Result { Ignored, Moved, Changed };
    QString text;
    int cursor = 0;
    bool selected = false; // the whole text; typing replaces it
    void set(const QString &value, bool select = false) {
        text = value; cursor = int(text.size()); selected = select && !text.isEmpty();
    }
    void insert(QString value) {
        value.replace(QLatin1Char('\t'), QLatin1Char(' ')).replace(QLatin1Char('\n'), QLatin1Char(' ')).remove(QLatin1Char('\r'));
        if (selected) { text.clear(); cursor = 0; selected = false; }
        text.insert(cursor, value);
        cursor += int(value.size());
    }
    int previous(int i) const {
        if (i <= 0) return 0;
        --i;
        if (i > 0 && text[i].isLowSurrogate() && text[i - 1].isHighSurrogate()) --i;
        return i;
    }
    int next(int i) const {
        if (i >= text.size()) return int(text.size());
        ++i;
        if (i < text.size() && text[i].isLowSurrogate() && text[i - 1].isHighSurrogate()) ++i;
        return i;
    }
    int wordStart(int i) const {
        while (i > 0 && text[i - 1].isSpace()) --i;
        while (i > 0 && !text[i - 1].isSpace()) --i;
        return i;
    }
    int wordEnd(int i) const {
        while (i < text.size() && text[i].isSpace()) ++i;
        while (i < text.size() && !text[i].isSpace()) ++i;
        return i;
    }
    Result handle(const InputEvent &e) {
        const uint8_t mods = e.modifiers & (tui::Ctrl | tui::Alt);
        const int size = int(text.size());
        auto move = [this](int to) { cursor = to; selected = false; return Moved; };
        auto erase = [this](int from, int to) {
            if (selected) { text.clear(); cursor = 0; selected = false; return Changed; }
            if (from >= to) return Moved;
            text.remove(from, to - from); cursor = from;
            return Changed;
        };
        switch (e.key) {
        case Key::Character:
            if (!mods) { insert(QString::fromUcs4(&e.codepoint, 1)); return Changed; }
            if (mods == tui::Ctrl) {
                switch (e.codepoint) {
                case U'a': return move(0);
                case U'e': return move(size);
                case U'b': return move(previous(cursor));
                case U'f': return move(next(cursor));
                case U'u': return erase(0, cursor);
                case U'k': return erase(cursor, size);
                case U'w': return erase(wordStart(cursor), cursor);
                case U'h': return erase(previous(cursor), cursor);
                case U'd': return erase(cursor, next(cursor));
                default: return Ignored;
                }
            }
            if (mods == tui::Alt) {
                switch (e.codepoint) {
                case U'b': return move(wordStart(cursor));
                case U'f': return move(wordEnd(cursor));
                case U'd': return erase(cursor, wordEnd(cursor));
                default: return Ignored;
                }
            }
            return Ignored;
        case Key::Backspace: return mods ? erase(wordStart(cursor), cursor) : erase(previous(cursor), cursor);
        case Key::Delete: return mods ? erase(cursor, wordEnd(cursor)) : erase(cursor, next(cursor));
        case Key::Left: return move(mods ? wordStart(cursor) : previous(cursor));
        case Key::Right: return move(mods ? wordEnd(cursor) : next(cursor));
        case Key::Home: return move(0);
        case Key::End: return move(size);
        default: return Ignored;
        }
    }
};

enum class Focus : uint8_t { Terminal, Search, Folders, Sessions, FolderEditor, SessionEditor };
enum class Action : uint8_t {
    None, NewSession, NewFolder, Search, ToggleFolders, ToggleSessions, Rename, CloseSession, Previous, Next, Attention, Quit, FocusSessions
};
enum class Target : uint8_t {
    None, FoldersToggle, SessionsToggle, NewTab, SplitRight, SplitDown, Attention, Search, SearchClear, More,
    FoldersPane, Nav, FolderAdd, FolderMore, FolderEditor, FoldersDivider,
    SessionsPane, SessionRow, SessionTrash, SessionEditor, SessionsDivider,
    Terminal, TerminalButton, MenuSurface, MenuItem, SubmenuItem, DialogSurface, DialogInput, DialogButton, Backdrop
};
enum TerminalButtonIndex { CreateButton, StartButton, ReconnectButton };

struct Hit {
    int x = 0, y = 0, w = 0, h = 0;
    Target target = Target::None;
    QString id;
    int index = -1;
    QString tooltip;
    bool contains(int px, int py) const { return px >= x && py >= y && px < x + w && py < y + h; }
    bool same(const Hit &other) const { return target == other.target && id == other.id && index == other.index; }
};

struct MenuItem {
    QString icon, text, hint;
    bool enabled = true;
    bool destructive = false;
    bool checked = false;
    bool separator = false;
    std::function<void()> action;
    std::vector<MenuItem> submenu;
    static MenuItem line() { MenuItem item; item.separator = true; return item; }
    bool selectable() const { return !separator && enabled; }
};
struct Menu {
    std::vector<MenuItem> items;
    int x = 0, y = 0;
    bool alignRight = false; // x is the right edge (toolbar menu)
    int highlighted = -1;
    int open = -1;           // item whose submenu is shown
    int subHighlighted = -1;
    bool inSubmenu = false;
    Target anchor = Target::None;
    QString sessionId, folderId; // row whose menu is open
    Focus restore = Focus::Terminal;
};

struct DialogButton {
    enum Role : uint8_t { Normal, Accent, Destructive };
    QString label;
    Role role = Normal;
    std::function<void(const QString &input)> action;
};
struct Dialog {
    enum Kind : uint8_t { Confirm, Error, Directory };
    Kind kind = Confirm;
    QString title, message;
    std::vector<DialogButton> buttons;
    int focus = 0; // button index, or -1 for the input
    bool hasInput = false;
    LineEdit input;
    QString placeholder;
    QString paneTarget; // a "Close pane" confirmation's session
    Focus restore = Focus::Terminal;
};

struct SessionEdit {
    QString id;
    LineEdit edit;
    QString error;
    bool submitting = false;
};
struct FolderEdit {
    bool editing = false;
    bool creating = false;
    QString id;
    LineEdit edit;
    QString error;
    bool submitting = false;
};
struct Drag {
    bool pressed = false;
    bool active = false;
    QString sessionId, caption;
    int x = 0, y = 0;
};

QString expandPath(QString path) {
    path = path.trimmed();
    if (path == QStringLiteral("~")) return QDir::homePath();
    if (path.startsWith(QStringLiteral("~/"))) path = QDir::homePath() + path.mid(1);
    return QDir::isAbsolutePath(path) ? QDir::cleanPath(path) : path;
}
QString existingDirectory(const QString &path) {
    QString current = QDir::isAbsolutePath(path) ? QDir::cleanPath(path) : QDir::homePath();
    while (!QFileInfo(current).isDir() && current != QStringLiteral("/")) current = QFileInfo(current).path();
    return current == QStringLiteral("/") ? current : current + QLatin1Char('/');
}
// Shell-style completion of the last path component to a directory.
bool completeDirectory(LineEdit &edit) {
    const QString text = edit.text;
    const int slash = int(text.lastIndexOf(QLatin1Char('/')));
    if (slash < 0) return false;
    const QString parent = text.left(slash + 1);
    const QString prefix = text.mid(slash + 1);
    QDir::Filters filters = QDir::Dirs | QDir::NoDotAndDotDot;
    if (prefix.startsWith(QLatin1Char('.'))) filters |= QDir::Hidden;
    QStringList matches;
    for (const auto &name : QDir(expandPath(parent)).entryList(filters, QDir::Name))
        if (name.startsWith(prefix)) matches.append(name);
    if (matches.isEmpty()) return false;
    QString common = matches.first();
    for (const auto &name : std::as_const(matches)) {
        int length = 0;
        while (length < common.size() && length < name.size() && common[length] == name[length]) ++length;
        common.truncate(length);
    }
    if (matches.size() == 1) common += QLatin1Char('/');
    if (common.size() <= prefix.size() && matches.size() > 1) return false;
    edit.set(parent + common);
    return true;
}

void ensureRuntimeDirectory() {
    if (!qEnvironmentVariableIsEmpty("XDG_RUNTIME_DIR")) return;
    // SSH sessions without pam_systemd lack the variable; the GUI's server
    // lives in the logind directory, which is only used when it is ours.
    const QByteArray candidate = QByteArray("/run/user/") + QByteArray::number(::getuid());
    struct stat st {};
    if (::lstat(candidate.constData(), &st) == 0 && S_ISDIR(st.st_mode) && st.st_uid == ::getuid()) qputenv("XDG_RUNTIME_DIR", candidate);
}

class TuiApp final : public QObject {
public:
    explicit TuiApp(QCoreApplication &app) : m_app(app) {}
    bool start(QString *error);
    void shutdown();

private:
    // Terminal I/O
    void onInput();
    void onSignals();
    void handle(const std::vector<InputEvent> &events);
    void scheduleRender();
    void render();
    // Layout
    bool foldersVisible() const { return m_wide ? m_wideFolders : m_narrowFolders; }
    bool sessionsVisible() const { return m_wide ? m_wideSessions : m_narrowSessions; }
    void layoutPanes();
    void setFoldersVisible(bool visible);
    void setSessionsVisible(bool visible);
    void resizePane(bool folders, int value);
    void keepFocusVisible();
    // Painting
    void addHit(Hit hit) { m_hits.push_back(std::move(hit)); }
    Hit hitAt(int x, int y) const;
    void paintHeader();
    void paintHeaderButton(int x, Target target, const QString &glyph, bool enabled, bool toggled, const QString &tooltip);
    void paintSearch(int x, int width);
    void paintEdit(const LineEdit &edit, int x, int y, int width, const Style &base, const QString &placeholder, bool focused);
    void paintDivider(int x, Target target, bool active);
    void paintFolders();
    void paintSessions();
    void paintSessionRow(const QVariantMap &row, int y, int x0, int inner);
    void paintTerminal();
    void paintButton(int x, int y, const QString &label, DialogButton::Role role, bool focused, bool hovered);
    void paintBox(int x, int y, int width, int height, const Color &bg, const Color &border);
    void paintMenuBox(const std::vector<MenuItem> &items, int x, int y, int highlighted, int open, Target target);
    void paintMenu();
    void paintDialog();
    void paintTooltip();
    void paintDrag();
    void paintEditError(const QString &message, int x, int y, int width);
    // Input
    Action shortcut(const InputEvent &e) const;
    QString hint(Action action) const;
    void perform(Action action);
    void handleKey(const InputEvent &e);
    void handleMouse(const InputEvent &e);
    void handlePaste(const QByteArray &text);
    void hover(const Hit &hit, const InputEvent &e);
    void press(const Hit &hit, const InputEvent &e);
    void contextMenu(const Hit &hit, const InputEvent &e);
    void wheel(const Hit &hit, const InputEvent &e);
    void forwardMouse(const InputEvent &e);
    void terminalKey(const InputEvent &e);
    void searchKey(const InputEvent &e);
    void foldersKey(const InputEvent &e);
    void sessionsKey(const InputEvent &e);
    void folderEditorKey(const InputEvent &e);
    void sessionEditorKey(const InputEvent &e);
    void menuKeyPress(const InputEvent &e);
    void dialogKey(const InputEvent &e);
    void cycleFocus(int direction);
    // Actions (mirroring qml/Main.qml)
    QString selectedId() const { return m_controller->selectedId(); }
    QVariantMap selected() const { return m_controller->selected(); }
    bool terminalReady() const;
    QStringList navIds() const;
    QString folderName(const QString &id) const;
    void focus(Focus focus);
    void focusTerminal();
    void focusSearch();
    void focusSessions();
    void syncTerminalFocus();
    void hideTooltip();
    void newSession();
    void newFolder();
    void renameSession();
    void nextAttention();
    void activateSession(const QString &id);
    void chooseView(const QString &id);
    void split(const QString &direction);
    void terminalButton(int index);
    void beginSessionRename(const QString &id, const QString &title);
    void submitSessionEdit();
    void cancelSessionEdit(bool restoreTerminal);
    void beginFolderCreate();
    void beginFolderRename(const QString &id, const QString &name);
    void submitFolderEdit();
    void cancelFolderEdit(bool restoreTerminal);
    void cancelEdits();
    void cancelDrag();
    // Menus and dialogs
    void openMenu(Menu menu, bool keyboard);
    void closeMenu();
    void activateMenuItem(const MenuItem &item);
    void openMoreMenu(bool keyboard);
    void openSidebarMenu(int x, int y, bool keyboard);
    void openFolderMenu(const QString &id, int x, int y, bool keyboard);
    void openSessionMenu(const QString &id, int x, int y, bool keyboard);
    void openDialog(Dialog dialog);
    void closeDialog();
    void activateDialogButton(int index);
    void confirm(const QString &title, const QString &message, const QString &confirmText, std::function<void()> accept, const QString &paneTarget = {});
    void confirmCloseSession(const QString &id, const QString &title);
    void confirmClosePane();
    void confirmDeleteFolder(const QString &id, const QString &name);
    void showError(const QString &message);
    void chooseDirectory(const QString &sessionId, const QString &folderId, const QString &path);

    QCoreApplication &m_app;
    tui::Terminal m_tty;
    StateStore m_store;
    Theme m_theme;
    std::unique_ptr<QSettings> m_settings;
    std::unique_ptr<TuiTerminals> m_terminals;
    std::unique_ptr<SessionController> m_controller;
    tui::Surface m_frame;
    tui::InputParser m_parser;
    Palette m_p;
    QSocketNotifier *m_input = nullptr;
    QSocketNotifier *m_signals = nullptr;
    QTimer m_escapeTimer, m_renderTimer, m_spinnerTimer, m_tooltipTimer;
    QElapsedTimer m_sinceFrame;
    std::vector<Hit> m_hits;
    // Layout
    bool m_wide = true, m_wideFolders = true, m_wideSessions = true, m_narrowFolders = false, m_narrowSessions = true;
    int m_desiredFolders = defaultFolders, m_desiredSessions = defaultSessions;
    int m_foldersWidth = 0, m_sessionsWidth = 0, m_termX = 0, m_termY = 1, m_termW = 0, m_termH = 0;
    int m_folderScroll = 0, m_sessionScroll = 0;
    bool m_revealSelected = true, m_revealFolder = false;
    QHash<int, int> m_navRowY;       // nav index -> screen row, from the last frame
    QHash<QString, int> m_sessionRowY; // session id -> screen row, from the last frame
    // State
    Focus m_focus = Focus::Terminal;
    int m_folderCursor = 0;
    LineEdit m_search;
    SessionEdit m_sessionEdit;
    FolderEdit m_folderEdit;
    std::optional<Menu> m_menu;
    std::optional<Dialog> m_dialog;
    Drag m_drag;
    QString m_dropTarget;
    int m_resizing = 0; // 1 folders divider, 2 sessions divider
    bool m_terminalCapture = false;
    Hit m_hover;
    int m_mouseX = -1, m_mouseY = -1;
    bool m_tooltipVisible = false;
    QString m_tooltipText;
    int m_tooltipX = 0, m_tooltipY = 0;
    bool m_ttyFocused = true;
    bool m_kittyKeyboard = false, m_keyboardKnown = false;
    bool m_spinning = false;
    int m_spinnerFrame = 0;
    QString m_lastSelected;
};

bool TuiApp::start(QString *error) {
    if (!m_store.open()) { *error = m_store.error(); return false; }
    if (!m_tty.open(error)) return false;
    m_settings = std::make_unique<QSettings>(m_store.stateDirectory() + QStringLiteral("/ui.ini"), QSettings::IniFormat);
    auto &settings = *m_settings;
    m_wideFolders = settings.value(QStringLiteral("tui/foldersVisible"), true).toBool();
    m_wideSessions = settings.value(QStringLiteral("tui/sessionsVisible"), true).toBool();
    m_narrowSessions = m_wideSessions;
    m_desiredFolders = qBound(minimumFolders, settings.value(QStringLiteral("tui/foldersWidth"), defaultFolders).toInt(), maximumFolders);
    m_desiredSessions = qBound(minimumSessions, settings.value(QStringLiteral("tui/sessionsWidth"), defaultSessions).toInt(), maximumSessions);
    // A first TUI visit continues where the GUI left off.
    const QString view = settings.value(QStringLiteral("tui/view"), settings.value(QStringLiteral("selection/view"), QStringLiteral("all"))).toString();
    const QString session = settings.value(QStringLiteral("tui/session"), settings.value(QStringLiteral("selection/session"))).toString();

    m_p = palette(m_theme);
    m_terminals = std::make_unique<TuiTerminals>(&m_store);
    m_controller = std::make_unique<SessionController>(&m_store, m_terminals.get());
    auto *controller = m_controller.get();
    connect(controller, &SessionController::stateChanged, this, [this] { scheduleRender(); });
    connect(controller, &SessionController::foldersChanged, this, [this] { scheduleRender(); });
    connect(controller, &SessionController::viewChanged, this, [this] { scheduleRender(); });
    connect(controller, &SessionController::searchChanged, this, [this] {
        if (m_search.text != m_controller->search()) m_search.set(m_controller->search());
        scheduleRender();
    });
    connect(controller, &SessionController::selectionChanged, this, [this] {
        const QString id = selectedId();
        m_terminals->setSelected(id);
        if (id != m_lastSelected) {
            m_lastSelected = id;
            m_revealSelected = true;
            if (m_dialog && !m_dialog->paneTarget.isEmpty() && m_dialog->paneTarget != id) closeDialog();
        }
        syncTerminalFocus();
        scheduleRender();
    });
    connect(controller, &SessionController::operationFailed, this, [this](const QString &id, const QString &message) {
        if (m_folderEdit.submitting && id.isEmpty()) { m_folderEdit.error = message; return; }
        if (m_sessionEdit.submitting && id == m_sessionEdit.id) { m_sessionEdit.error = message; return; }
        showError(message);
    });
    connect(controller, &SessionController::directoryRequired, this, [this](const QString &sessionId, const QString &folderId, const QString &path) {
        if (!m_dialog || m_dialog->kind != Dialog::Error) return;
        m_dialog->buttons = {{QStringLiteral("Cancel"), DialogButton::Normal, {}},
                             {QStringLiteral("Choose directory"), DialogButton::Accent,
                              [this, sessionId, folderId, path](const QString &) { chooseDirectory(sessionId, folderId, path); }}};
        m_dialog->focus = 0;
        scheduleRender();
    });
    connect(&m_theme, &Theme::changed, this, [this] { m_p = palette(m_theme); m_tty.invalidate(); scheduleRender(); });
    connect(m_terminals.get(), &TuiTerminals::updated, this, [this](const QString &id) { if (id == selectedId()) scheduleRender(); });
    connect(m_terminals.get(), &TuiTerminals::bell, this, [this](const QString &id) { if (id == selectedId()) m_tty.write(QByteArrayLiteral("\a")); });
    connect(m_terminals.get(), &TuiTerminals::clipboard, this, [this](const QByteArray &base64) {
        m_tty.write(QByteArrayLiteral("\x1b]52;c;") + base64 + QByteArrayLiteral("\a"));
    });

    m_input = new QSocketNotifier(m_tty.inputFd(), QSocketNotifier::Read, this);
    connect(m_input, &QSocketNotifier::activated, this, [this] { onInput(); });
    m_signals = new QSocketNotifier(m_tty.signalFd(), QSocketNotifier::Read, this);
    connect(m_signals, &QSocketNotifier::activated, this, [this] { onSignals(); });
    m_escapeTimer.setSingleShot(true);
    connect(&m_escapeTimer, &QTimer::timeout, this, [this] { handle(m_parser.flush()); });
    m_renderTimer.setSingleShot(true);
    connect(&m_renderTimer, &QTimer::timeout, this, [this] { render(); });
    m_spinnerTimer.setInterval(100);
    connect(&m_spinnerTimer, &QTimer::timeout, this, [this] { m_spinnerFrame = (m_spinnerFrame + 1) % int(spinner.size()); scheduleRender(); });
    m_tooltipTimer.setSingleShot(true);
    connect(&m_tooltipTimer, &QTimer::timeout, this, [this] {
        if (m_hover.tooltip.isEmpty() || m_menu || m_dialog || m_drag.active) return;
        m_tooltipVisible = true; m_tooltipText = m_hover.tooltip; m_tooltipX = m_mouseX; m_tooltipY = m_mouseY;
        scheduleRender();
    });

    controller->setView(view);
    if (!session.isEmpty()) controller->selectSession(session);
    m_search.set(controller->search());
    m_lastSelected = selectedId();
    m_terminals->setSelected(m_lastSelected);
    layoutPanes();
    syncTerminalFocus();
    render();
    return true;
}

void TuiApp::shutdown() {
    if (m_settings && m_controller) {
        auto &settings = *m_settings;
        settings.setValue(QStringLiteral("tui/foldersVisible"), m_wideFolders);
        settings.setValue(QStringLiteral("tui/sessionsVisible"), m_wideSessions);
        settings.setValue(QStringLiteral("tui/foldersWidth"), m_desiredFolders);
        settings.setValue(QStringLiteral("tui/sessionsWidth"), m_desiredSessions);
        settings.setValue(QStringLiteral("tui/view"), m_controller->view());
        settings.setValue(QStringLiteral("tui/session"), m_controller->selectedId());
        settings.sync();
    }
    delete m_input; m_input = nullptr;
    delete m_signals; m_signals = nullptr;
    m_controller.reset();
    m_terminals.reset();
    m_tty.restore();
    if (m_settings && m_settings->status() != QSettings::NoError) std::fprintf(stderr, "cinmux: could not save TUI preferences\n");
}

void TuiApp::onInput() {
    char buffer[65536];
    const ssize_t count = ::read(m_tty.inputFd(), buffer, sizeof buffer);
    if (count == 0 || (count < 0 && errno != EINTR && errno != EAGAIN)) { m_app.quit(); return; }
    if (count > 0) handle(m_parser.feed(buffer, std::size_t(count)));
    if (m_parser.pending()) m_escapeTimer.start(m_parser.pasting() ? pasteTimeout : escapeTimeout);
    else m_escapeTimer.stop();
}

void TuiApp::onSignals() {
    for (const int signal : m_tty.takeSignals()) {
        if (signal == SIGWINCH) {
            if (m_tty.updateSize()) { hideTooltip(); scheduleRender(); }
        } else {
            m_app.quit();
        }
    }
}

void TuiApp::handle(const std::vector<InputEvent> &events) {
    for (const auto &e : events) {
        switch (e.type) {
        case InputEvent::Type::Key: handleKey(e); break;
        case InputEvent::Type::Mouse: handleMouse(e); break;
        case InputEvent::Type::Paste: handlePaste(e.text); break;
        case InputEvent::Type::FocusIn: m_ttyFocused = true; syncTerminalFocus(); break;
        case InputEvent::Type::FocusOut: m_ttyFocused = false; syncTerminalFocus(); break;
        case InputEvent::Type::KeyboardFlags: m_kittyKeyboard = true; break;
        case InputEvent::Type::PrimaryAttributes: m_keyboardKnown = true; break;
        }
    }
    if (!events.empty()) scheduleRender();
}

void TuiApp::scheduleRender() {
    if (m_renderTimer.isActive()) return;
    const qint64 elapsed = m_sinceFrame.isValid() ? m_sinceFrame.elapsed() : frameInterval;
    m_renderTimer.start(int(qMax<qint64>(0, frameInterval - elapsed)));
}

void TuiApp::layoutPanes() {
    const int width = m_tty.cols();
    const bool wide = width >= wideColumns;
    if (wide != m_wide && !wide) { m_narrowFolders = false; m_narrowSessions = m_wideSessions; }
    m_wide = wide;
    const bool folders = foldersVisible(), sessions = sessionsVisible();
    m_foldersWidth = folders ? qMax(0, qMin(m_desiredFolders, width - minimumTerminal - (sessions ? minimumSessions : 0))) : 0;
    if (m_foldersWidth < 8) m_foldersWidth = 0;
    m_sessionsWidth = sessions ? qMax(0, qMin(m_desiredSessions, width - minimumTerminal - m_foldersWidth)) : 0;
    if (m_sessionsWidth < 10) m_sessionsWidth = 0;
    m_termX = m_foldersWidth + m_sessionsWidth;
    m_termY = 1;
    m_termW = qMax(0, width - m_termX);
    m_termH = qMax(0, m_tty.rows() - 1);
    m_terminals->setSize(qMax(1, m_termW), qMax(1, m_termH));
    keepFocusVisible();
}

void TuiApp::setFoldersVisible(bool visible) {
    if (m_wide) m_wideFolders = visible;
    else { m_narrowFolders = visible; if (visible) m_narrowSessions = false; }
    layoutPanes();
    scheduleRender();
}
void TuiApp::setSessionsVisible(bool visible) {
    if (m_wide) m_wideSessions = visible;
    else { m_narrowSessions = visible; if (visible) m_narrowFolders = false; }
    layoutPanes();
    scheduleRender();
}
void TuiApp::resizePane(bool folders, int value) {
    const int width = m_tty.cols();
    if (folders) m_desiredFolders = qBound(minimumFolders, value, qMax(minimumFolders, qMin(maximumFolders, width - minimumTerminal - m_sessionsWidth)));
    else m_desiredSessions = qBound(minimumSessions, value, qMax(minimumSessions, qMin(maximumSessions, width - minimumTerminal - m_foldersWidth)));
    layoutPanes();
    scheduleRender();
}
// A hidden pane cannot keep keyboard focus (the GUI moves it to the toolbar).
void TuiApp::keepFocusVisible() {
    if (m_foldersWidth == 0 && (m_focus == Focus::Folders || m_focus == Focus::FolderEditor)) {
        if (m_folderEdit.editing) m_folderEdit = {};
        m_focus = Focus::Terminal;
        syncTerminalFocus();
    }
    if (m_sessionsWidth == 0 && (m_focus == Focus::Sessions || m_focus == Focus::SessionEditor)) {
        m_sessionEdit = {};
        m_focus = Focus::Terminal;
        syncTerminalFocus();
    }
}

Hit TuiApp::hitAt(int x, int y) const {
    for (auto it = m_hits.rbegin(); it != m_hits.rend(); ++it) if (it->contains(x, y)) return *it;
    return {};
}

void TuiApp::render() {
    m_renderTimer.stop();
    m_sinceFrame.restart();
    const int width = m_tty.cols(), height = m_tty.rows();
    if (m_frame.cols() != width || m_frame.rows() != height) m_frame.resize(width, height);
    m_frame.fill(0, 0, width, height, style(m_p.text, m_p.chrome));
    m_frame.cursor = {};
    m_hits.clear();
    m_navRowY.clear();
    m_sessionRowY.clear();
    m_spinning = false;
    layoutPanes();
    paintHeader();
    paintFolders();
    paintSessions();
    paintTerminal();
    if (m_drag.active) paintDrag();
    if (m_menu) paintMenu();
    if (m_dialog) paintDialog();
    else if (m_tooltipVisible && !m_menu) paintTooltip();
    m_tty.present(m_frame);
    if (m_spinning && !m_spinnerTimer.isActive()) m_spinnerTimer.start();
    else if (!m_spinning) m_spinnerTimer.stop();
}

void TuiApp::paintHeaderButton(int x, Target target, const QString &glyph, bool enabled, bool toggled, const QString &tooltip) {
    const bool hovered = enabled && m_hover.target == target;
    const bool open = m_menu && m_menu->anchor == target;
    const Color bg = toggled || open ? m_p.selected : hovered ? m_p.hover : m_p.chrome;
    const Color fg = !enabled ? m_p.muted : toggled ? m_p.accent : hovered || open ? m_p.text : m_p.muted;
    const Style st = style(fg, bg, enabled ? 0 : tui::Faint);
    m_frame.fill(x, 0, 3, 1, st);
    m_frame.text(x + 1, 0, glyph, st, 1);
    addHit({x, 0, 3, 1, target, {}, -1, tooltip});
}

void TuiApp::paintHeader() {
    const int width = m_frame.cols();
    m_frame.fill(0, 0, width, 1, style(m_p.text, m_p.chrome));
    const bool running = selected().value(QStringLiteral("status")).toString() == QStringLiteral("running");
    const int attention = m_controller->attentionCount();
    int left = 1;
    paintHeaderButton(left, Target::FoldersToggle, glyphPanelLeft, true, false,
                      (foldersVisible() ? QStringLiteral("Hide folders") : QStringLiteral("Show folders")) + QStringLiteral(" (%1)").arg(hint(Action::ToggleFolders)));
    left += 3;
    paintHeaderButton(left, Target::SessionsToggle, glyphPanelRight, true, false,
                      (sessionsVisible() ? QStringLiteral("Hide sessions") : QStringLiteral("Show sessions")) + QStringLiteral(" (%1)").arg(hint(Action::ToggleSessions)));
    left += 3;
    paintHeaderButton(left, Target::NewTab, glyphPlus, true, false, QStringLiteral("New tab (%1)").arg(hint(Action::NewSession)));
    left += 3;
    int right = width - 1;
    if (right - 3 < left) return;
    right -= 3;
    paintHeaderButton(right, Target::More, glyphMore, true, false, QStringLiteral("More"));
    const int available = right - left - 1;
    int searchWidth = qBound(12, width / 5, 28);
    if (available < searchWidth + 1 + 9) searchWidth = available - 1 - 9;
    if (searchWidth >= 8) { right -= searchWidth + 1; paintSearch(right, searchWidth); }
    if (right - 9 <= left) return;
    right -= 3;
    paintHeaderButton(right, Target::Attention, glyphBell, attention > 0, attention > 0, QStringLiteral("Next attention (%1)").arg(hint(Action::Attention)));
    right -= 3;
    paintHeaderButton(right, Target::SplitDown, glyphSplitDown, running, false, QStringLiteral("Split down"));
    right -= 3;
    paintHeaderButton(right, Target::SplitRight, glyphSplitRight, running, false, QStringLiteral("Split right"));
}

void TuiApp::paintEdit(const LineEdit &edit, int x, int y, int width, const Style &base, const QString &placeholder, bool focused) {
    if (width <= 0) return;
    m_frame.fill(x, y, width, 1, base);
    if (edit.text.isEmpty()) {
        if (!placeholder.isEmpty()) m_frame.text(x, y, tui::elide(placeholder, width), style(m_p.muted, base.bg), width);
        if (focused) m_frame.cursor = {x, y, true, 5};
        return;
    }
    // Scroll horizontally so the cursor keeps a visible cell.
    int start = 0;
    while (start < edit.cursor && tui::textWidth(edit.text.mid(start, edit.cursor - start)) > width - 1) start = edit.next(start);
    const Style textStyle = edit.selected ? style(m_p.selectionText, m_p.selectionBg, base.attributes) : base;
    m_frame.text(x, y, edit.text.mid(start), textStyle, width);
    if (focused) m_frame.cursor = {x + tui::textWidth(edit.text.mid(start, edit.cursor - start)), y, true, 5};
}

void TuiApp::paintSearch(int x, int width) {
    const bool focused = m_focus == Focus::Search;
    const Color bg = m_p.hover;
    m_frame.fill(x, 0, width, 1, style(m_p.text, bg));
    m_frame.text(x + 1, 0, glyphSearch, style(focused ? m_p.accent : m_p.muted, bg), 1);
    const bool clear = !m_search.text.isEmpty();
    addHit({x, 0, width, 1, Target::Search});
    paintEdit(m_search, x + 3, 0, width - 4 - (clear ? 2 : 0), style(m_p.text, bg), QStringLiteral("Search sessions"), focused);
    if (clear) {
        const bool hovered = m_hover.target == Target::SearchClear;
        m_frame.text(x + width - 2, 0, glyphClose, style(hovered ? m_p.text : m_p.muted, bg), 1);
        addHit({x + width - 3, 0, 3, 1, Target::SearchClear, {}, -1, QStringLiteral("Clear search")});
    }
}

void TuiApp::paintDivider(int x, Target target, bool active) {
    const bool hovered = m_hover.target == target;
    const Style st = style(active ? m_p.accent : hovered ? m_p.muted : m_p.border, m_p.chrome);
    for (int y = 1; y < m_frame.rows(); ++y) m_frame.text(x, y, QStringLiteral("│"), st, 1);
    addHit({x, 1, 1, m_frame.rows() - 1, target});
}

void TuiApp::paintEditError(const QString &message, int x, int y, int width) {
    const QStringList lines = tui::wrap(message, qMax(4, width - 2));
    for (int i = 0; i < lines.size() && y + i < m_frame.rows(); ++i) {
        m_frame.fill(x, y + i, width, 1, style(m_p.danger, m_p.raised));
        m_frame.text(x + 1, y + i, lines[i], style(m_p.danger, m_p.raised), width - 2);
    }
}

void TuiApp::paintFolders() {
    const int width = m_foldersWidth;
    if (width <= 0) return;
    const int height = m_frame.rows() - 1, inner = width - 1;
    m_frame.fill(0, 1, inner, height, style(m_p.text, m_p.chrome));
    addHit({0, 1, inner, height, Target::FoldersPane});
    paintDivider(width - 1, Target::FoldersDivider, m_resizing == 1);

    struct Row { enum Kind { Nav, Blank, Heading, Editor, Error } kind; int nav = -1; QString id, name, error; int count = 0; };
    std::vector<Row> rows;
    rows.push_back({Row::Nav, 0, QStringLiteral("all"), QStringLiteral("Tabs"), {}, m_controller->totalCount()});
    rows.push_back({Row::Nav, 1, QStringLiteral("attention"), QStringLiteral("Needs Attention"), {}, m_controller->attentionCount()});
    rows.push_back({Row::Blank});
    rows.push_back({Row::Heading});
    auto editor = [&] {
        rows.push_back({Row::Editor});
        for (const auto &line : tui::wrap(m_folderEdit.error, qMax(4, inner - 4))) if (!m_folderEdit.error.isEmpty()) rows.push_back({Row::Error, -1, {}, {}, line});
    };
    if (m_folderEdit.editing && m_folderEdit.creating) editor();
    const auto folders = m_controller->folders();
    for (int i = 0; i < folders.size(); ++i) {
        const auto folder = folders[i].toMap();
        const QString id = folder.value(QStringLiteral("id")).toString();
        if (m_folderEdit.editing && !m_folderEdit.creating && m_folderEdit.id == id) editor();
        else rows.push_back({Row::Nav, 2 + i, id, folder.value(QStringLiteral("name")).toString(), {}, folder.value(QStringLiteral("count")).toInt()});
    }
    int focusRow = -1;
    for (int i = 0; i < int(rows.size()); ++i) {
        if ((m_focus == Focus::FolderEditor && rows[i].kind == Row::Editor) || (m_focus == Focus::Folders && rows[i].kind == Row::Nav && rows[i].nav == m_folderCursor))
            focusRow = i;
    }
    if (m_revealFolder || m_focus == Focus::FolderEditor) {
        if (focusRow >= 0 && focusRow < m_folderScroll) m_folderScroll = focusRow;
        else if (focusRow >= m_folderScroll + height) m_folderScroll = focusRow - height + 1;
        m_revealFolder = false;
    }
    m_folderScroll = qBound(0, m_folderScroll, qMax(0, int(rows.size()) - height));

    const QString view = m_controller->view();
    const bool searching = !m_controller->search().isEmpty();
    for (int i = m_folderScroll; i < int(rows.size()) && i - m_folderScroll < height; ++i) {
        const Row &row = rows[i];
        const int y = 1 + i - m_folderScroll;
        switch (row.kind) {
        case Row::Blank: break;
        case Row::Heading: {
            m_frame.text(1, y, QStringLiteral("Folders"), style(m_p.muted, m_p.chrome, tui::Bold), inner - 4);
            const bool hovered = m_hover.target == Target::FolderAdd;
            m_frame.fill(inner - 3, y, 3, 1, style(m_p.text, hovered ? m_p.hover : m_p.chrome));
            m_frame.text(inner - 2, y, glyphPlus, style(hovered ? m_p.text : m_p.muted, hovered ? m_p.hover : m_p.chrome), 1);
            addHit({inner - 3, y, 3, 1, Target::FolderAdd, {}, -1, QStringLiteral("New folder")});
            break;
        }
        case Row::Editor: {
            const bool failed = !m_folderEdit.error.isEmpty();
            m_frame.text(0, y, glyphMarker, style(failed ? m_p.danger : m_p.accent, m_p.chrome), 1);
            paintEdit(m_folderEdit.edit, 1, y, inner - 2, style(m_p.text, m_p.terminal), QStringLiteral("Folder name"), m_focus == Focus::FolderEditor);
            addHit({0, y, inner, 1, Target::FolderEditor});
            break;
        }
        case Row::Error:
            m_frame.text(2, y, row.error, style(m_p.danger, m_p.chrome), inner - 3);
            break;
        case Row::Nav: {
            m_navRowY.insert(row.nav, y);
            const bool folder = row.nav >= 2;
            const bool active = view == row.id && !searching;
            const bool hovered = (m_hover.target == Target::Nav || m_hover.target == Target::FolderMore) && m_hover.id == row.id;
            const bool drop = m_drag.active && m_dropTarget == row.id;
            const bool keyboard = m_focus == Focus::Folders && m_folderCursor == row.nav;
            const bool menuOpen = m_menu && m_menu->folderId == row.id;
            const Color bg = drop || active ? m_p.selected : hovered || menuOpen ? m_p.hover : m_p.chrome;
            m_frame.fill(0, y, inner, 1, style(m_p.text, bg));
            if (keyboard || drop) m_frame.text(0, y, glyphMarker, style(m_p.accent, bg), 1);
            m_frame.text(1, y, row.nav == 0 ? glyphTabs : row.nav == 1 ? glyphBell : glyphFolder, style(m_p.muted, bg), 1);
            int end = inner - 1;
            if (folder) {
                if (hovered || keyboard || menuOpen) {
                    const bool overMore = m_hover.target == Target::FolderMore && m_hover.id == row.id;
                    m_frame.text(end - 1, y, glyphMore, style(overMore ? m_p.text : m_p.muted, bg), 1);
                }
                end -= 2;
            }
            if (row.count > 0) {
                const QString count = QString::number(row.count);
                end -= int(count.size());
                m_frame.text(end, y, count, style(m_p.muted, bg), int(count.size()));
                end -= 1;
            }
            const QString caption = tui::elide(row.name, end - 3);
            m_frame.text(3, y, caption, style(m_p.text, bg, active ? tui::Bold : 0), end - 3);
            addHit({0, y, inner, 1, Target::Nav, row.id, row.nav, caption == row.name ? QString() : row.name});
            if (folder) addHit({inner - 3, y, 3, 1, Target::FolderMore, row.id, row.nav, QStringLiteral("Folder actions for %1").arg(row.name)});
            break;
        }
        }
    }
}

void TuiApp::paintSessions() {
    const int x0 = m_foldersWidth, width = m_sessionsWidth;
    if (width <= 0) return;
    const int inner = width - 1, bottom = m_frame.rows();
    m_frame.fill(x0, 1, inner, bottom - 1, style(m_p.text, m_p.chrome));
    addHit({x0, 1, inner, bottom - 1, Target::SessionsPane});
    paintDivider(x0 + width - 1, Target::SessionsDivider, m_resizing == 2);

    const QString view = m_controller->view();
    const bool searching = !m_controller->search().isEmpty();
    QString heading;
    if (searching) heading = QStringLiteral("Search results");
    else if (view == QStringLiteral("attention")) heading = QStringLiteral("Needs Attention");
    else if (view != QStringLiteral("all")) heading = folderName(view);
    auto *model = m_controller->model();
    const int count = model->rowCount();
    int top = 1;
    if (!heading.isEmpty()) {
        const QString number = QString::number(count);
        m_frame.text(x0 + 2, 1, tui::elide(heading, inner - 5 - int(number.size())), style(m_p.muted, m_p.chrome, tui::Bold));
        m_frame.text(x0 + inner - 1 - int(number.size()), 1, number, style(m_p.muted, m_p.chrome));
        top = 2;
    }
    if (count == 0) {
        const QString message = searching ? QStringLiteral("No matching sessions")
                                : view == QStringLiteral("attention") ? QStringLiteral("No sessions need attention") : QStringLiteral("No sessions");
        int y = top + 1;
        for (const auto &line : tui::wrap(message, qMax(4, inner - 2))) m_frame.text(x0 + 1, y++, line, style(m_p.muted, m_p.chrome), inner - 2);
        return;
    }
    const int visible = qMax(1, bottom - top);
    const QStringList ids = model->ids();
    int reveal = -1;
    if (!m_sessionEdit.id.isEmpty()) reveal = int(ids.indexOf(m_sessionEdit.id));
    else if (m_revealSelected) reveal = int(ids.indexOf(selectedId()));
    if (reveal >= 0) {
        if (reveal < m_sessionScroll) m_sessionScroll = reveal;
        else if (reveal >= m_sessionScroll + visible) m_sessionScroll = reveal - visible + 1;
    }
    m_revealSelected = false;
    m_sessionScroll = qBound(0, m_sessionScroll, qMax(0, count - visible));
    for (int i = m_sessionScroll; i < count && i - m_sessionScroll < visible; ++i) paintSessionRow(model->get(i), top + i - m_sessionScroll, x0, inner);
    // The GUI shows a rename failure as a tooltip under the title field.
    if (!m_sessionEdit.error.isEmpty() && m_sessionRowY.contains(m_sessionEdit.id))
        paintEditError(m_sessionEdit.error, x0 + 1, m_sessionRowY.value(m_sessionEdit.id) + 1, inner - 2);
}

void TuiApp::paintSessionRow(const QVariantMap &row, int y, int x0, int inner) {
    const QString id = row.value(QStringLiteral("sessionId")).toString();
    const QString title = row.value(QStringLiteral("title")).toString();
    const QString status = row.value(QStringLiteral("status")).toString();
    const QString activity = row.value(QStringLiteral("activity")).toString();
    const QString activityDetail = row.value(QStringLiteral("activityDetail")).toString();
    const QString terminalError = row.value(QStringLiteral("terminalError")).toString();
    const QString cwd = row.value(QStringLiteral("cwd")).toString();
    const QString branch = row.value(QStringLiteral("branch")).toString();
    const QString noticeTitle = row.value(QStringLiteral("noticeTitle")).toString();
    const QString noticeBody = row.value(QStringLiteral("noticeBody")).toString();
    const bool pinned = row.value(QStringLiteral("pinned")).toBool();
    const qint64 unread = row.value(QStringLiteral("unreadCount")).toLongLong();
    m_sessionRowY.insert(id, y);

    const bool isSelected = id == selectedId();
    const bool renaming = m_sessionEdit.id == id;
    const bool hovered = (m_hover.target == Target::SessionRow || m_hover.target == Target::SessionTrash) && m_hover.id == id;
    const bool menuOpen = m_menu && m_menu->sessionId == id;
    const bool keyboard = m_focus == Focus::Sessions && isSelected;
    const Color bg = isSelected ? m_p.selected : hovered || menuOpen ? m_p.hover : m_p.chrome;
    m_frame.fill(x0, y, inner, 1, style(m_p.text, bg));
    if (keyboard || renaming) m_frame.text(x0, y, glyphMarker, style(renaming && !m_sessionEdit.error.isEmpty() ? m_p.danger : m_p.accent, bg), 1);

    // qml/SessionList.qml labels and colors.
    const bool running = status == QStringLiteral("running");
    const QString statusLabel = status == QStringLiteral("starting") ? QStringLiteral("Starting") : running ? QStringLiteral("Running") : QStringLiteral("Stopped");
    const QString activityLabel = !running ? statusLabel
        : activity == QStringLiteral("working") ? QStringLiteral("Working")
        : activity == QStringLiteral("waiting") ? QStringLiteral("Needs input")
        : activity == QStringLiteral("done") ? QStringLiteral("Done") : QStringLiteral("Idle");
    const bool working = status == QStringLiteral("starting") || (running && activity == QStringLiteral("working"));
    const Color activityColor = !running ? m_p.muted : activity == QStringLiteral("waiting") ? m_p.warning
        : activity == QStringLiteral("working") || activity == QStringLiteral("done") ? m_p.accent : m_p.muted;
    const QString activityGlyph = working ? spinner[m_spinnerFrame] : !running ? glyphIdle
        : activity == QStringLiteral("waiting") ? glyphWaiting : activity == QStringLiteral("done") ? glyphCheck : glyphIdle;
    if (working) m_spinning = true;

    int x = x0 + 1;
    int end = x0 + inner - 1;
    const bool trash = !renaming && (hovered || keyboard);
    const int trashX = end - 1;
    if (trash) {
        const bool over = m_hover.target == Target::SessionTrash && m_hover.id == id;
        m_frame.text(trashX, y, glyphClose, style(over ? m_p.danger : m_p.muted, bg), 1);
    }
    end -= 2;
    if (inner >= 30) {
        const int labelWidth = tui::textWidth(activityLabel);
        end -= labelWidth;
        m_frame.text(end, y, activityLabel, style(activityColor, bg), labelWidth);
        end -= 1;
    }
    end -= 1;
    m_frame.text(end, y, activityGlyph, style(activityColor, bg), 1);
    end -= 1;
    if (!terminalError.isEmpty()) { end -= 1; m_frame.text(end, y, glyphError, style(m_p.danger, bg), 1); end -= 1; }
    if (unread > 0) {
        const QString number = QString::number(unread);
        end -= int(number.size());
        m_frame.text(end, y, number, style(m_p.accent, bg, tui::Bold), int(number.size()));
        end -= 1;
    }
    if (pinned) { m_frame.text(x, y, glyphPin, style(m_p.muted, bg), 1); x += 2; }
    const uint16_t weight = isSelected ? tui::Bold : 0;
    if (renaming) {
        paintEdit(m_sessionEdit.edit, x, y, qMax(1, end - x), style(m_sessionEdit.error.isEmpty() ? m_p.text : m_p.danger, bg, weight), {},
                  m_focus == Focus::SessionEditor);
        addHit({x0, y, inner, 1, Target::SessionEditor, id});
        return;
    }
    m_frame.text(x, y, tui::elide(title, end - x), style(m_p.text, bg, weight), end - x);
    QString details = title + QLatin1Char('\n') + cwd + (branch.isEmpty() ? QString() : QLatin1Char('\n') + branch) + QLatin1Char('\n') + statusLabel;
    if (running) details += QLatin1Char('\n') + activityLabel + (activityDetail.isEmpty() ? QString() : QStringLiteral(": ") + activityDetail);
    if (pinned) details += QStringLiteral("\nPinned");
    if (unread > 0) details += QStringLiteral("\n%1 unread notifications").arg(unread);
    if (!noticeTitle.isEmpty()) details += QLatin1Char('\n') + noticeTitle + (noticeBody.isEmpty() ? QString() : QLatin1Char('\n') + noticeBody);
    if (!terminalError.isEmpty()) details += QLatin1Char('\n') + terminalError;
    addHit({x0, y, inner, 1, Target::SessionRow, id, -1, details});
    if (trash) addHit({trashX - 1, y, 3, 1, Target::SessionTrash, id, -1, QStringLiteral("Close session %1").arg(title)});
}

void TuiApp::paintButton(int x, int y, const QString &label, DialogButton::Role role, bool focused, bool hovered) {
    Color fg = m_p.text, bg = m_p.raisedHover;
    uint16_t attributes = 0;
    if (role == DialogButton::Destructive) { fg = m_p.danger; bg = m_p.dangerDim; }
    else if (role == DialogButton::Accent) { fg = m_p.onAccent; bg = m_p.accent; }
    if (hovered) bg = toward(bg, m_p.text, .08);
    if (focused) {
        attributes |= tui::Bold;
        if (role == DialogButton::Destructive) { fg = m_p.onDanger; bg = m_p.danger; }
        else if (role == DialogButton::Accent) attributes |= tui::Underline;
        else { fg = m_p.onAccent; bg = m_p.accent; }
    }
    const int width = tui::textWidth(label) + 4;
    m_frame.fill(x, y, width, 1, style(fg, bg, attributes));
    m_frame.text(x + 2, y, label, style(fg, bg, attributes), width - 4);
}

void TuiApp::paintTerminal() {
    const int x0 = m_termX, y0 = m_termY, width = m_termW, height = m_termH;
    if (width <= 0 || height <= 0) return;
    const Style base = style(m_p.text, m_p.terminal);
    addHit({x0, y0, width, height, Target::Terminal});
    const QString id = selectedId();
    const bool focused = m_focus == Focus::Terminal && !m_menu && !m_dialog;
    auto centeredButton = [&](const QString &label, int index, int y) {
        const int buttonWidth = tui::textWidth(label) + 4;
        const int x = x0 + qMax(0, (width - buttonWidth) / 2);
        paintButton(x, y, label, DialogButton::Normal, focused, m_hover.target == Target::TerminalButton && m_hover.index == index);
        addHit({x, y, buttonWidth, 1, Target::TerminalButton, {}, index});
    };
    if (id.isEmpty()) {
        m_frame.fill(x0, y0, width, height, base);
        centeredButton(QStringLiteral("Create a terminal session"), CreateButton, y0 + height / 2);
        return;
    }
    const auto session = selected();
    const QString status = session.value(QStringLiteral("status")).toString();
    const QString error = session.value(QStringLiteral("terminalError")).toString();
    if (error.isEmpty() && m_terminals->hasOutput(id)) {
        m_frame.fill(x0, y0, width, height, Style{});
        m_terminals->paint(id, m_frame, x0, y0, width, height);
        if (status == QStringLiteral("stopped")) {
            const QString label = QStringLiteral("Start session");
            const int buttonWidth = tui::textWidth(label) + 4;
            const int x = x0 + qMax(0, width - 2 - buttonWidth);
            paintButton(x, y0 + 1, label, DialogButton::Normal, focused, m_hover.target == Target::TerminalButton && m_hover.index == StartButton);
            addHit({x, y0 + 1, buttonWidth, 1, Target::TerminalButton, {}, StartButton});
        } else if (focused) {
            const auto cursor = m_terminals->cursor(id);
            if (cursor.visible && cursor.x < width && cursor.y < height) m_frame.cursor = {x0 + cursor.x, y0 + cursor.y, true, cursor.shape};
        }
        return;
    }
    m_frame.fill(x0, y0, width, height, base);
    const QString title = !error.isEmpty() ? QStringLiteral("Terminal unavailable")
        : status == QStringLiteral("starting") ? QStringLiteral("Starting session…")
        : status == QStringLiteral("stopped") ? QStringLiteral("Session stopped") : QStringLiteral("Connecting terminal…");
    const QString message = !error.isEmpty()
        ? error + (status == QStringLiteral("running") ? QStringLiteral("\nThe session and its jobs are still running.") : QString())
        : status == QStringLiteral("stopped") ? QStringLiteral("Start a fresh shell in the saved working directory. Previous commands will not be replayed.") : QString();
    const int columnWidth = qMax(4, qMin(width - 4, 56));
    const QStringList titleLines = tui::wrap(title, columnWidth);
    const QStringList lines = message.isEmpty() ? QStringList() : tui::wrap(message, columnWidth);
    const bool button = status == QStringLiteral("stopped") || !error.isEmpty();
    const int total = int(titleLines.size()) + (lines.isEmpty() ? 0 : 1 + int(lines.size())) + (button ? 2 : 0);
    int y = y0 + qMax(0, (height - total) / 2);
    for (const auto &line : titleLines) {
        m_frame.text(x0 + qMax(0, (width - tui::textWidth(line)) / 2), y++, line, style(m_p.text, m_p.terminal, tui::Bold), width);
    }
    if (!lines.isEmpty()) {
        ++y;
        for (const auto &line : lines) m_frame.text(x0 + qMax(0, (width - tui::textWidth(line)) / 2), y++, line, style(m_p.muted, m_p.terminal), width);
    }
    if (button) {
        ++y;
        if (status == QStringLiteral("stopped")) centeredButton(QStringLiteral("Start session"), StartButton, y);
        else centeredButton(QStringLiteral("Reconnect terminal"), ReconnectButton, y);
    }
}

void TuiApp::paintBox(int x, int y, int width, int height, const Color &bg, const Color &border) {
    const Style fill = style(m_p.text, bg), line = style(border, bg);
    m_frame.fill(x, y, width, height, fill);
    for (int col = x + 1; col < x + width - 1; ++col) {
        m_frame.text(col, y, QStringLiteral("─"), line, 1);
        m_frame.text(col, y + height - 1, QStringLiteral("─"), line, 1);
    }
    for (int row = y + 1; row < y + height - 1; ++row) {
        m_frame.text(x, row, QStringLiteral("│"), line, 1);
        m_frame.text(x + width - 1, row, QStringLiteral("│"), line, 1);
    }
    m_frame.text(x, y, QStringLiteral("╭"), line, 1);
    m_frame.text(x + width - 1, y, QStringLiteral("╮"), line, 1);
    m_frame.text(x, y + height - 1, QStringLiteral("╰"), line, 1);
    m_frame.text(x + width - 1, y + height - 1, QStringLiteral("╯"), line, 1);
}

int menuWidth(const std::vector<MenuItem> &items) {
    int inner = 18;
    for (const auto &item : items) {
        if (item.separator) continue;
        inner = qMax(inner, 4 + tui::textWidth(item.text) + (item.hint.isEmpty() ? 0 : 3 + tui::textWidth(item.hint)) + (item.submenu.empty() ? 0 : 2) + 1);
    }
    return inner + 2;
}

// Draws a menu with its top-left corner near (x, y), kept on screen.
void TuiApp::paintMenuBox(const std::vector<MenuItem> &items, int x, int y, int highlighted, int open, Target target) {
    const int width = qMin(menuWidth(items), m_frame.cols()), height = qMin(int(items.size()) + 2, m_frame.rows());
    x = qBound(0, x, qMax(0, m_frame.cols() - width));
    y = qBound(0, y, qMax(0, m_frame.rows() - height));
    paintBox(x, y, width, height, m_p.raised, m_p.raisedBorder);
    addHit({x, y, width, height, Target::MenuSurface});
    for (int i = 0; i < int(items.size()) && i < height - 2; ++i) {
        const MenuItem &item = items[i];
        const int row = y + 1 + i;
        if (item.separator) {
            const Style line = style(m_p.raisedBorder, m_p.raised);
            m_frame.text(x, row, QStringLiteral("├"), line, 1);
            for (int col = x + 1; col < x + width - 1; ++col) m_frame.text(col, row, QStringLiteral("─"), line, 1);
            m_frame.text(x + width - 1, row, QStringLiteral("┤"), line, 1);
            continue;
        }
        const bool lit = item.enabled && (i == highlighted || i == open);
        const Color bg = lit ? (item.destructive ? m_p.dangerDim : m_p.raisedHover) : m_p.raised;
        const uint16_t attributes = item.enabled ? 0 : tui::Faint;
        const Color fg = !item.enabled ? m_p.muted : item.destructive ? m_p.danger : m_p.text;
        m_frame.fill(x + 1, row, width - 2, 1, style(fg, bg, attributes));
        m_frame.text(x + 2, row, item.checked ? glyphCheck : item.icon, style(item.destructive ? m_p.danger : m_p.muted, bg, attributes), 1);
        int end = x + width - 2;
        if (!item.submenu.empty()) { m_frame.text(end - 1, row, glyphChevron, style(m_p.muted, bg, attributes), 1); end -= 2; }
        if (!item.hint.isEmpty()) {
            const int hintWidth = tui::textWidth(item.hint);
            m_frame.text(end - hintWidth, row, item.hint, style(m_p.muted, bg, attributes), hintWidth);
            end -= hintWidth + 2;
        }
        m_frame.text(x + 4, row, tui::elide(item.text, end - x - 4), style(fg, bg, attributes), end - x - 4);
        if (item.enabled) addHit({x + 1, row, width - 2, 1, target, {}, i});
    }
}

void TuiApp::paintMenu() {
    const Menu &menu = *m_menu;
    const int x = menu.alignRight ? menu.x - menuWidth(menu.items) : menu.x;
    paintMenuBox(menu.items, x, menu.y, menu.inSubmenu ? -1 : menu.highlighted, menu.open, Target::MenuItem);
    if (menu.open < 0 || menu.open >= int(menu.items.size())) return;
    // The parent box may have been shifted on screen; recover its row from the hit map.
    Hit parent;
    for (const auto &hit : m_hits) if (hit.target == Target::MenuItem && hit.index == menu.open) parent = hit;
    const auto &sub = menu.items[menu.open].submenu;
    const int subWidth = menuWidth(sub);
    int subX = parent.x + parent.w;
    if (subX + subWidth > m_frame.cols()) subX = qMax(0, parent.x - 1 - subWidth);
    paintMenuBox(sub, subX, parent.y - 1, menu.subHighlighted, -1, Target::SubmenuItem);
}

void TuiApp::paintDialog() {
    const int screenWidth = m_frame.cols(), screenHeight = m_frame.rows();
    const double amount = m_p.overlay;
    m_frame.restyle(0, 0, screenWidth, screenHeight, [amount](Style &s) {
        s.fg = darken(s.fg, amount);
        s.bg = darken(s.bg, amount);
        if (s.fg.kind != Color::Kind::Rgb) s.attributes |= tui::Faint;
    });
    m_frame.cursor = {};
    addHit({0, 0, screenWidth, screenHeight, Target::Backdrop});
    Dialog &dialog = *m_dialog;
    const int width = qMax(20, qMin(screenWidth - 2, dialog.hasInput ? 66 : 58));
    const int inner = width - 6;
    QStringList title = tui::wrap(dialog.title, inner);
    if (title.size() > 3) { title = title.mid(0, 3); title[2] = tui::elide(title[2] + QStringLiteral("…"), inner); }
    int buttonsWidth = 0;
    for (const auto &button : dialog.buttons) buttonsWidth += tui::textWidth(button.label) + 4 + 2;
    buttonsWidth -= 2;
    const int fixed = 2 + int(title.size()) + 1 + (dialog.hasInput ? 2 : 0) + 1 + 2;
    QStringList message = tui::wrap(dialog.message, inner);
    const int room = qMax(0, screenHeight - fixed - 1);
    if (message.size() > room) { message = message.mid(0, room); if (room > 0) message[room - 1] = tui::elide(message[room - 1] + QStringLiteral("…"), inner); }
    const int height = fixed + (message.isEmpty() ? 0 : int(message.size()) + 1);
    const int x = qMax(0, (screenWidth - width) / 2), y = qMax(0, (screenHeight - height) / 2);
    paintBox(x, y, width, height, m_p.raised, m_p.raisedBorder);
    addHit({x, y, width, height, Target::DialogSurface});
    int row = y + 2;
    for (const auto &line : title) m_frame.text(x + 3, row++, line, style(m_p.text, m_p.raised, tui::Bold), inner);
    ++row;
    for (const auto &line : message) m_frame.text(x + 3, row++, line, style(m_p.muted, m_p.raised), inner);
    if (!message.isEmpty()) ++row;
    if (dialog.hasInput) {
        paintEdit(dialog.input, x + 3, row, inner, style(m_p.text, m_p.terminal), dialog.placeholder, dialog.focus == -1);
        if (dialog.focus == -1) m_frame.text(x + 2, row, glyphMarker, style(m_p.accent, m_p.raised), 1);
        addHit({x + 3, row, inner, 1, Target::DialogInput});
        row += 2;
    }
    int buttonX = x + width - 3 - buttonsWidth;
    for (int i = 0; i < int(dialog.buttons.size()); ++i) {
        const auto &button = dialog.buttons[i];
        const int buttonWidth = tui::textWidth(button.label) + 4;
        paintButton(buttonX, row, button.label, button.role, dialog.focus == i, m_hover.target == Target::DialogButton && m_hover.index == i);
        addHit({buttonX, row, buttonWidth, 1, Target::DialogButton, {}, i});
        buttonX += buttonWidth + 2;
    }
}

void TuiApp::paintTooltip() {
    QStringList lines;
    for (const auto &paragraph : m_tooltipText.split(QLatin1Char('\n'))) lines += tui::wrap(paragraph, 48);
    int width = 0;
    for (const auto &line : std::as_const(lines)) width = qMax(width, tui::textWidth(line));
    width += 4;
    const int height = int(lines.size()) + 2;
    int x = m_tooltipX + 1, y = m_tooltipY + 1;
    if (x + width > m_frame.cols()) x = qMax(0, m_frame.cols() - width);
    if (y + height > m_frame.rows()) y = qMax(0, m_tooltipY - height);
    paintBox(x, y, width, height, m_p.raised, m_p.raisedBorder);
    for (int i = 0; i < lines.size(); ++i) m_frame.text(x + 2, y + 1 + i, lines[i], style(m_p.text, m_p.raised), width - 4);
}

void TuiApp::paintDrag() {
    const QString caption = tui::elide(m_drag.caption, 24);
    const int width = tui::textWidth(caption) + 4;
    const int x = qBound(0, m_mouseX + 1, qMax(0, m_frame.cols() - width));
    const int y = qBound(0, m_mouseY, qMax(0, m_frame.rows() - 1));
    m_frame.fill(x, y, width, 1, style(m_p.text, m_p.raisedHover));
    m_frame.text(x + 2, y, caption, style(m_p.text, m_p.raisedHover, tui::Bold), width - 4);
}

Action TuiApp::shortcut(const InputEvent &e) const {
    const uint8_t mods = e.modifiers;
    if (e.key == Key::Character) {
        const char32_t c = QChar::toLower(e.codepoint);
        if (mods == tui::Ctrl && c == U'r') return Action::Rename;
        if (mods == (tui::Ctrl | tui::Shift)) {
            switch (c) {
            case U'n': return Action::NewSession;
            case U'f': return Action::Search;
            case U'b': return Action::ToggleFolders;
            case U'l': return Action::ToggleSessions;
            case U'w': return Action::CloseSession;
            case U'q': return Action::Quit;
            case U'e': return Action::FocusSessions;
            default: break;
            }
        }
        if (mods == (tui::Ctrl | tui::Alt)) {
            if (c == U'n') return Action::NewFolder;
            if (c == U'u') return Action::Attention;
            // Terminals without the kitty keyboard protocol cannot tell
            // Ctrl+Shift+letter from Ctrl+letter; Ctrl+Alt stands in.
            if (!m_kittyKeyboard) {
                switch (c) {
                case U't': return Action::NewSession;
                case U'f': return Action::Search;
                case U'b': return Action::ToggleFolders;
                case U'l': return Action::ToggleSessions;
                case U'w': return Action::CloseSession;
                case U'q': return Action::Quit;
                case U'e': return Action::FocusSessions;
                default: break;
                }
            }
        }
    } else if (mods == (tui::Ctrl | tui::Alt)) {
        if (e.key == Key::PageUp) return Action::Previous;
        if (e.key == Key::PageDown) return Action::Next;
    }
    return Action::None;
}

QString TuiApp::hint(Action action) const {
    const bool legacy = m_keyboardKnown && !m_kittyKeyboard;
    auto shifted = [legacy](char gui, char fallback) {
        return legacy ? QStringLiteral("Ctrl+Alt+%1").arg(QLatin1Char(fallback)) : QStringLiteral("Ctrl+Shift+%1").arg(QLatin1Char(gui));
    };
    switch (action) {
    case Action::NewSession: return shifted('N', 'T');
    case Action::NewFolder: return QStringLiteral("Ctrl+Alt+N");
    case Action::Search: return shifted('F', 'F');
    case Action::ToggleFolders: return shifted('B', 'B');
    case Action::ToggleSessions: return shifted('L', 'L');
    case Action::Rename: return QStringLiteral("Ctrl+R");
    case Action::CloseSession: return shifted('W', 'W');
    case Action::Previous: return QStringLiteral("Ctrl+Alt+PageUp");
    case Action::Next: return QStringLiteral("Ctrl+Alt+PageDown");
    case Action::Attention: return QStringLiteral("Ctrl+Alt+U");
    case Action::Quit: return shifted('Q', 'Q');
    case Action::FocusSessions: return shifted('E', 'E');
    case Action::None: break;
    }
    return {};
}

void TuiApp::perform(Action action) {
    switch (action) {
    case Action::NewSession: newSession(); break;
    case Action::NewFolder: newFolder(); break;
    case Action::Search: focusSearch(); break;
    case Action::ToggleFolders: setFoldersVisible(!foldersVisible()); break;
    case Action::ToggleSessions: setSessionsVisible(!sessionsVisible()); break;
    case Action::Rename: renameSession(); break;
    case Action::CloseSession: confirmCloseSession(selectedId(), selected().value(QStringLiteral("title")).toString()); break;
    case Action::Previous: m_controller->navigate(-1); focusTerminal(); break;
    case Action::Next: m_controller->navigate(1); focusTerminal(); break;
    case Action::Attention: nextAttention(); break;
    case Action::Quit: m_app.quit(); break;
    case Action::FocusSessions: focusSessions(); break;
    case Action::None: break;
    }
}

void TuiApp::handleKey(const InputEvent &e) {
    hideTooltip();
    const Action action = shortcut(e);
    if (m_dialog) {
        if (action == Action::Quit) m_app.quit();
        else dialogKey(e);
        return;
    }
    if (action != Action::None) {
        closeMenu();
        cancelDrag();
        if (action != Action::Rename || !selectedId().isEmpty()) cancelEdits();
        perform(action);
        return;
    }
    if (m_menu) { menuKeyPress(e); return; }
    if (m_drag.active && escape(e)) { cancelDrag(); return; }
    switch (m_focus) {
    case Focus::Terminal: terminalKey(e); break;
    case Focus::Search: searchKey(e); break;
    case Focus::Folders: foldersKey(e); break;
    case Focus::Sessions: sessionsKey(e); break;
    case Focus::FolderEditor: folderEditorKey(e); break;
    case Focus::SessionEditor: sessionEditorKey(e); break;
    }
}

void TuiApp::terminalKey(const InputEvent &e) {
    const QString id = selectedId();
    if (id.isEmpty()) {
        if (plainKey(e, Key::Enter)) newSession();
        return;
    }
    const auto session = selected();
    const QString status = session.value(QStringLiteral("status")).toString();
    const QString error = session.value(QStringLiteral("terminalError")).toString();
    // Dead panes and failed views take no input; Enter triggers their button.
    if (plainKey(e, Key::Enter) && status == QStringLiteral("stopped")) { m_controller->startSession(id, {}); return; }
    if (plainKey(e, Key::Enter) && !error.isEmpty()) { m_controller->reconnectTerminal(id); return; }
    if (error.isEmpty() && m_terminals->hasOutput(id)) m_terminals->sendKey(id, e);
}

void TuiApp::searchKey(const InputEvent &e) {
    if (plainKey(e, Key::Enter)) { focusTerminal(); return; }
    if (escape(e)) { m_controller->setSearch({}); focusTerminal(); return; }
    if (plainKey(e, Key::Down)) { focusSessions(); return; }
    if (e.key == Key::Tab && !(e.modifiers & (tui::Ctrl | tui::Alt))) { cycleFocus(e.modifiers & tui::Shift ? -1 : 1); return; }
    if (menuKey(e)) { openMoreMenu(true); return; }
    if (m_search.handle(e) == LineEdit::Changed) m_controller->setSearch(m_search.text);
}

void TuiApp::foldersKey(const InputEvent &e) {
    const QStringList ids = navIds();
    m_folderCursor = qBound(0, m_folderCursor, int(ids.size()) - 1);
    const int y = m_navRowY.value(m_folderCursor, 1);
    if (plainKey(e, Key::Up)) { m_folderCursor = qMax(0, m_folderCursor - 1); m_revealFolder = true; }
    else if (plainKey(e, Key::Down)) { m_folderCursor = qMin(int(ids.size()) - 1, m_folderCursor + 1); m_revealFolder = true; }
    else if (plainKey(e, Key::Home)) { m_folderCursor = 0; m_revealFolder = true; }
    else if (plainKey(e, Key::End)) { m_folderCursor = int(ids.size()) - 1; m_revealFolder = true; }
    else if (plainKey(e, Key::Enter) || character(e, U' ')) chooseView(ids[m_folderCursor]);
    else if (escape(e)) focusTerminal();
    else if (e.key == Key::Tab && !(e.modifiers & (tui::Ctrl | tui::Alt))) cycleFocus(e.modifiers & tui::Shift ? -1 : 1);
    else if (menuKey(e)) {
        if (m_folderCursor >= 2) openFolderMenu(ids[m_folderCursor], 2, y + 1, true);
        else openSidebarMenu(2, y + 1, true);
    }
}

void TuiApp::sessionsKey(const InputEvent &e) {
    const QStringList ids = m_controller->model()->ids();
    const QString id = selectedId();
    auto select = [this, &ids](int index) {
        if (ids.isEmpty()) return;
        m_controller->selectSession(ids[qBound(0, index, int(ids.size()) - 1)]);
        m_revealSelected = true;
    };
    const int index = int(ids.indexOf(id));
    const int page = qMax(1, m_frame.rows() - 3);
    if (plainKey(e, Key::Up)) select(index < 0 ? 0 : index - 1);
    else if (plainKey(e, Key::Down)) select(index < 0 ? 0 : index + 1);
    else if (plainKey(e, Key::Home)) select(0);
    else if (plainKey(e, Key::End)) select(int(ids.size()) - 1);
    else if (plainKey(e, Key::PageUp)) select(index - page);
    else if (plainKey(e, Key::PageDown)) select(index + page);
    else if (plainKey(e, Key::Enter) || escape(e)) focusTerminal();
    else if (plainKey(e, Key::Delete)) confirmCloseSession(id, selected().value(QStringLiteral("title")).toString());
    else if (e.key == Key::Tab && !(e.modifiers & (tui::Ctrl | tui::Alt))) cycleFocus(e.modifiers & tui::Shift ? -1 : 1);
    else if (menuKey(e)) {
        if (!id.isEmpty() && m_sessionRowY.contains(id)) openSessionMenu(id, m_foldersWidth + 2, m_sessionRowY.value(id) + 1, true);
        else openSidebarMenu(m_foldersWidth + 2, 2, true);
    }
}

void TuiApp::folderEditorKey(const InputEvent &e) {
    if (plainKey(e, Key::Enter)) submitFolderEdit();
    else if (escape(e)) cancelFolderEdit(false);
    else if (m_folderEdit.edit.handle(e) == LineEdit::Changed) m_folderEdit.error.clear();
}

void TuiApp::sessionEditorKey(const InputEvent &e) {
    if (plainKey(e, Key::Enter)) submitSessionEdit();
    else if (escape(e)) cancelSessionEdit(false);
    else if (m_sessionEdit.edit.handle(e) == LineEdit::Changed) m_sessionEdit.error.clear();
}

void TuiApp::menuKeyPress(const InputEvent &e) {
    Menu &menu = *m_menu;
    const bool sub = menu.inSubmenu && menu.open >= 0;
    const std::vector<MenuItem> &items = sub ? menu.items[menu.open].submenu : menu.items;
    int &current = sub ? menu.subHighlighted : menu.highlighted;
    auto step = [&items, &current](int delta) {
        const int count = int(items.size());
        for (int i = 1; i <= count; ++i) {
            const int candidate = ((current < 0 ? (delta > 0 ? -1 : 0) : current) + delta * i + count * 2) % count;
            if (items[candidate].selectable()) { current = candidate; return; }
        }
    };
    auto first = [&items]() { for (int i = 0; i < int(items.size()); ++i) if (items[i].selectable()) return i; return -1; };
    if (plainKey(e, Key::Up)) step(-1);
    else if (plainKey(e, Key::Down)) step(1);
    else if (plainKey(e, Key::Home)) current = first();
    else if (plainKey(e, Key::End)) { current = -1; step(-1); }
    else if (escape(e) || (plainKey(e, Key::Left) && sub)) {
        if (sub && !(e.modifiers & tui::Alt)) { menu.inSubmenu = false; menu.open = -1; menu.subHighlighted = -1; }
        else closeMenu();
    } else if ((plainKey(e, Key::Right) || plainKey(e, Key::Enter) || character(e, U' ')) && current >= 0 && current < int(items.size())) {
        if (!sub && !items[current].submenu.empty()) {
            menu.open = current; menu.inSubmenu = true; menu.subHighlighted = -1;
            const auto &subItems = menu.items[current].submenu;
            for (int i = 0; i < int(subItems.size()); ++i) if (subItems[i].selectable()) { menu.subHighlighted = i; break; }
        } else if (!plainKey(e, Key::Right)) {
            activateMenuItem(items[current]);
        }
    }
}

void TuiApp::dialogKey(const InputEvent &e) {
    Dialog &dialog = *m_dialog;
    const int count = int(dialog.buttons.size());
    auto move = [&dialog, count](int delta) {
        const int first = dialog.hasInput ? -1 : 0;
        const int span = count - first;
        dialog.focus = first + ((dialog.focus - first + delta) % span + span) % span;
    };
    const bool tab = e.key == Key::Tab && !(e.modifiers & (tui::Ctrl | tui::Alt));
    if (escape(e)) { activateDialogButton(-1); return; }
    if (dialog.focus == -1) {
        if (plainKey(e, Key::Enter)) { activateDialogButton(count - 1); return; }
        if (tab && !(e.modifiers & tui::Shift)) { if (!completeDirectory(dialog.input)) move(1); return; }
        if (tab) { move(-1); return; }
        dialog.input.handle(e);
        return;
    }
    if (tab) move(e.modifiers & tui::Shift ? -1 : 1);
    else if (plainKey(e, Key::Right)) move(1);
    else if (plainKey(e, Key::Left)) move(-1);
    else if (plainKey(e, Key::Enter) || character(e, U' ')) activateDialogButton(dialog.focus);
}

void TuiApp::cycleFocus(int direction) {
    std::vector<Focus> order{Focus::Search};
    if (m_foldersWidth > 0) order.push_back(Focus::Folders);
    if (m_sessionsWidth > 0) order.push_back(Focus::Sessions);
    order.push_back(Focus::Terminal);
    const auto it = std::find(order.begin(), order.end(), m_focus);
    const int index = it == order.end() ? 0 : int(it - order.begin());
    const int next = (index + direction + int(order.size())) % int(order.size());
    if (order[next] == Focus::Search) focusSearch();
    else if (order[next] == Focus::Sessions) focusSessions();
    else if (order[next] == Focus::Folders) { m_folderCursor = qMax(0, int(navIds().indexOf(m_controller->view()))); m_revealFolder = true; focus(Focus::Folders); }
    else focusTerminal();
}

void TuiApp::handlePaste(const QByteArray &text) {
    hideTooltip();
    const QString value = QString::fromUtf8(text);
    if (m_dialog) {
        if (m_dialog->focus == -1) m_dialog->input.insert(value.trimmed());
        return;
    }
    if (m_menu) return;
    switch (m_focus) {
    case Focus::Search:
        m_search.insert(value);
        m_controller->setSearch(m_search.text);
        break;
    case Focus::FolderEditor: m_folderEdit.edit.insert(value); m_folderEdit.error.clear(); break;
    case Focus::SessionEditor: m_sessionEdit.edit.insert(value); m_sessionEdit.error.clear(); break;
    case Focus::Terminal:
        if (terminalReady()) m_terminals->sendPaste(selectedId(), text);
        break;
    case Focus::Folders:
    case Focus::Sessions: break;
    }
}

void TuiApp::handleMouse(const InputEvent &e) {
    m_mouseX = e.x;
    m_mouseY = e.y;
    const Hit hit = hitAt(e.x, e.y);
    const bool isPress = e.action == MouseAction::Press, isRelease = e.action == MouseAction::Release;
    const bool isWheel = e.action == MouseAction::WheelUp || e.action == MouseAction::WheelDown
        || e.action == MouseAction::WheelLeft || e.action == MouseAction::WheelRight;
    if (isPress || isRelease || isWheel) hideTooltip();
    // An active gesture owns the pointer until its button is released.
    if (m_resizing) {
        if (e.action == MouseAction::Move) resizePane(m_resizing == 1, m_resizing == 1 ? e.x + 1 : e.x - m_foldersWidth + 1);
        else if (isRelease) m_resizing = 0;
        scheduleRender();
        return;
    }
    if (m_terminalCapture) {
        forwardMouse(e);
        if (isRelease) m_terminalCapture = false;
        return;
    }
    if (m_drag.pressed && (e.action == MouseAction::Move || isRelease)) {
        if (e.action == MouseAction::Move) {
            if (!m_drag.active && (e.x != m_drag.x || e.y != m_drag.y)) m_drag.active = true;
            if (m_drag.active) {
                m_dropTarget = hit.target == Target::Nav && hit.index != 1 ? hit.id : QString();
                scheduleRender();
            }
            return;
        }
        const Drag drag = m_drag;
        const QString target = m_dropTarget;
        m_drag = {};
        m_dropTarget.clear();
        if (!drag.active) activateSession(drag.sessionId);
        else if (!target.isEmpty()) m_controller->moveSession(drag.sessionId, target == QStringLiteral("all") ? QString() : target);
        scheduleRender();
        return;
    }
    if (e.action == MouseAction::Move) { hover(hit, e); return; }
    if (m_dialog) {
        if (isPress && e.button == MouseButton::Left) {
            if (hit.target == Target::DialogButton) activateDialogButton(hit.index);
            else if (hit.target == Target::DialogInput && m_dialog->hasInput) m_dialog->focus = -1;
        }
        return;
    }
    if (m_menu) {
        if (!isPress) return;
        if (hit.target == Target::MenuItem && hit.index < int(m_menu->items.size())) {
            const MenuItem &item = m_menu->items[hit.index];
            if (!item.submenu.empty()) { m_menu->open = m_menu->open == hit.index ? -1 : hit.index; m_menu->inSubmenu = false; }
            else activateMenuItem(item);
        } else if (hit.target == Target::SubmenuItem && m_menu->open >= 0) {
            const auto &sub = m_menu->items[m_menu->open].submenu;
            if (hit.index < int(sub.size())) activateMenuItem(sub[hit.index]);
        } else if (hit.target != Target::MenuSurface) {
            closeMenu();
        }
        return;
    }
    if (isWheel) { wheel(hit, e); return; }
    if (isPress) press(hit, e);
    else if (isRelease && hit.target == Target::Terminal) forwardMouse(e);
}

void TuiApp::hover(const Hit &hit, const InputEvent &e) {
    if (m_menu) {
        if (hit.target == Target::MenuItem) {
            m_menu->highlighted = hit.index;
            m_menu->inSubmenu = false;
            if (hit.index < int(m_menu->items.size()) && !m_menu->items[hit.index].submenu.empty()) { m_menu->open = hit.index; m_menu->subHighlighted = -1; }
            else m_menu->open = -1;
        } else if (hit.target == Target::SubmenuItem) {
            m_menu->subHighlighted = hit.index;
            m_menu->inSubmenu = true;
        }
    }
    if (!hit.same(m_hover)) {
        m_hover = hit;
        m_tooltipVisible = false;
        m_tooltipTimer.stop();
        if (!hit.tooltip.isEmpty() && !m_menu && !m_dialog) m_tooltipTimer.start(tooltipDelay);
        scheduleRender();
    } else if (m_menu) {
        scheduleRender();
    }
    // Motion reports are sent only when the tmux client requested them.
    if (hit.target == Target::Terminal && !m_menu && !m_dialog) forwardMouse(e);
}

void TuiApp::press(const Hit &hit, const InputEvent &e) {
    if (m_sessionEdit.id.size() && hit.target != Target::SessionEditor) cancelSessionEdit(false);
    if (m_folderEdit.editing && hit.target != Target::FolderEditor) cancelFolderEdit(false);
    if (e.button == MouseButton::Right) { contextMenu(hit, e); return; }
    if (e.button == MouseButton::Middle) {
        if (hit.target == Target::Terminal) { focusTerminal(); forwardMouse(e); }
        return;
    }
    if (e.button != MouseButton::Left) return;
    const bool running = selected().value(QStringLiteral("status")).toString() == QStringLiteral("running");
    switch (hit.target) {
    case Target::FoldersToggle: setFoldersVisible(!foldersVisible()); break;
    case Target::SessionsToggle: setSessionsVisible(!sessionsVisible()); break;
    case Target::NewTab: newSession(); break;
    case Target::SplitRight: if (running) split(QStringLiteral("right")); break;
    case Target::SplitDown: if (running) split(QStringLiteral("down")); break;
    case Target::Attention: if (m_controller->attentionCount() > 0) nextAttention(); break;
    case Target::More: openMoreMenu(false); break;
    case Target::Search: m_search.selected = false; m_search.cursor = int(m_search.text.size()); focus(Focus::Search); break;
    case Target::SearchClear: m_controller->setSearch({}); m_search.set({}); focus(Focus::Search); break;
    case Target::Nav: chooseView(hit.id); break;
    case Target::FolderAdd: beginFolderCreate(); break;
    case Target::FolderMore: openFolderMenu(hit.id, hit.x, hit.y + 1, false); break;
    case Target::FolderEditor: focus(Focus::FolderEditor); break;
    case Target::FoldersDivider: m_resizing = 1; break;
    case Target::SessionsDivider: m_resizing = 2; break;
    case Target::SessionRow:
        // The GUI selects on click; a press may instead start dragging the row to a folder.
        m_drag = {true, false, hit.id, m_controller->model()->get(int(m_controller->model()->ids().indexOf(hit.id))).value(QStringLiteral("title")).toString(), e.x, e.y};
        focus(Focus::Sessions);
        break;
    case Target::SessionTrash: {
        const int index = int(m_controller->model()->ids().indexOf(hit.id));
        confirmCloseSession(hit.id, m_controller->model()->get(index).value(QStringLiteral("title")).toString());
        break;
    }
    case Target::SessionEditor: focus(Focus::SessionEditor); break;
    case Target::Terminal:
        focusTerminal();
        if (terminalReady()) { m_terminalCapture = true; forwardMouse(e); }
        break;
    case Target::TerminalButton: terminalButton(hit.index); break;
    default: break;
    }
    scheduleRender();
}

void TuiApp::contextMenu(const Hit &hit, const InputEvent &e) {
    switch (hit.target) {
    case Target::SessionRow:
    case Target::SessionTrash:
        focus(Focus::Sessions);
        openSessionMenu(hit.id, e.x, e.y, false);
        break;
    case Target::Nav:
        if (hit.index >= 2) openFolderMenu(hit.id, e.x, e.y, false);
        else openSidebarMenu(e.x, e.y, false);
        break;
    case Target::FoldersPane:
    case Target::SessionsPane:
    case Target::FolderAdd:
        openSidebarMenu(e.x, e.y, false);
        break;
    case Target::Terminal:
        focusTerminal();
        if (terminalReady()) { m_terminalCapture = true; forwardMouse(e); }
        break;
    default: break;
    }
}

void TuiApp::wheel(const Hit &hit, const InputEvent &e) {
    const int delta = e.action == MouseAction::WheelUp ? -3 : e.action == MouseAction::WheelDown ? 3 : 0;
    switch (hit.target) {
    case Target::SessionsPane:
    case Target::SessionRow:
    case Target::SessionTrash:
    case Target::SessionEditor:
        m_sessionScroll = qMax(0, m_sessionScroll + delta);
        scheduleRender();
        break;
    case Target::FoldersPane:
    case Target::Nav:
    case Target::FolderAdd:
    case Target::FolderMore:
    case Target::FolderEditor:
        m_folderScroll = qMax(0, m_folderScroll + delta);
        scheduleRender();
        break;
    case Target::Terminal: forwardMouse(e); break;
    default: break;
    }
}

void TuiApp::forwardMouse(const InputEvent &e) {
    if (!terminalReady() || m_termW <= 0 || m_termH <= 0) return;
    const int col = qBound(0, e.x - m_termX, m_termW - 1), row = qBound(0, e.y - m_termY, m_termH - 1);
    m_terminals->sendMouse(selectedId(), e, col, row);
}

bool TuiApp::terminalReady() const {
    const QString id = selectedId();
    return !id.isEmpty() && selected().value(QStringLiteral("terminalError")).toString().isEmpty() && m_terminals->hasOutput(id);
}

QStringList TuiApp::navIds() const {
    QStringList ids{QStringLiteral("all"), QStringLiteral("attention")};
    for (const auto &folder : m_controller->folders()) ids.append(folder.toMap().value(QStringLiteral("id")).toString());
    return ids;
}

QString TuiApp::folderName(const QString &id) const {
    for (const auto &folder : m_controller->folders()) {
        const auto map = folder.toMap();
        if (map.value(QStringLiteral("id")).toString() == id) return map.value(QStringLiteral("name")).toString();
    }
    return QStringLiteral("Sessions");
}

void TuiApp::focus(Focus focus) {
    m_focus = focus;
    syncTerminalFocus();
    scheduleRender();
}
void TuiApp::focusTerminal() {
    if (m_dialog) return;
    focus(Focus::Terminal);
}
void TuiApp::focusSearch() {
    setSessionsVisible(true);
    m_search.set(m_controller->search(), true);
    focus(Focus::Search);
}
void TuiApp::focusSessions() {
    setSessionsVisible(true);
    if (m_sessionsWidth == 0) return;
    m_revealSelected = true;
    focus(Focus::Sessions);
}
void TuiApp::syncTerminalFocus() {
    if (m_terminals) m_terminals->setFocused(m_focus == Focus::Terminal && m_ttyFocused && !m_menu && !m_dialog);
}
void TuiApp::hideTooltip() {
    m_tooltipTimer.stop();
    if (m_tooltipVisible) { m_tooltipVisible = false; scheduleRender(); }
}

void TuiApp::newSession() {
    const QString view = m_controller->view();
    const QString folderId = view != QStringLiteral("all") && view != QStringLiteral("attention") ? view : QString();
    m_controller->setSearch({});
    m_controller->createSession(folderId, {});
    focusTerminal();
}
void TuiApp::newFolder() { beginFolderCreate(); }
void TuiApp::renameSession() {
    const QString id = selectedId();
    if (id.isEmpty()) return;
    const QString title = selected().value(QStringLiteral("title")).toString();
    m_controller->setSearch({});
    m_controller->setView(QStringLiteral("all"));
    setSessionsVisible(true);
    beginSessionRename(id, title);
}
void TuiApp::nextAttention() {
    m_controller->selectNextAttention();
    m_revealSelected = true;
    focusTerminal();
}
void TuiApp::activateSession(const QString &id) {
    m_controller->selectSession(id);
    focusTerminal();
}
void TuiApp::chooseView(const QString &id) {
    m_controller->setSearch({});
    m_controller->setView(id);
    setSessionsVisible(true);
    m_folderCursor = qMax(0, int(navIds().indexOf(id)));
    if (m_foldersWidth > 0) focus(Focus::Folders);
}
void TuiApp::split(const QString &direction) {
    m_controller->splitActive(direction);
    focusTerminal();
}
void TuiApp::terminalButton(int index) {
    const QString id = selectedId();
    if (index == CreateButton) { newSession(); return; }
    if (id.isEmpty()) return;
    if (index == StartButton) m_controller->startSession(id, {});
    else m_controller->reconnectTerminal(id);
    focusTerminal();
}

void TuiApp::beginSessionRename(const QString &id, const QString &title) {
    m_sessionEdit = {};
    m_sessionEdit.id = id;
    m_sessionEdit.edit.set(title, true);
    focus(Focus::SessionEditor);
}
void TuiApp::submitSessionEdit() {
    if (m_sessionEdit.id.isEmpty() || m_sessionEdit.submitting) return;
    m_sessionEdit.submitting = true;
    m_sessionEdit.error.clear();
    m_controller->renameSession(m_sessionEdit.id, m_sessionEdit.edit.text);
    m_sessionEdit.submitting = false;
    if (m_sessionEdit.error.isEmpty()) cancelSessionEdit(true);
    else scheduleRender();
}
void TuiApp::cancelSessionEdit(bool restoreTerminal) {
    m_sessionEdit = {};
    if (!restoreTerminal && m_sessionsWidth > 0) focus(Focus::Sessions);
    else focusTerminal();
}
void TuiApp::beginFolderCreate() {
    setFoldersVisible(true);
    if (m_foldersWidth == 0) return;
    m_folderEdit = {};
    m_folderEdit.editing = true;
    m_folderEdit.creating = true;
    focus(Focus::FolderEditor);
}
void TuiApp::beginFolderRename(const QString &id, const QString &name) {
    setFoldersVisible(true);
    if (m_foldersWidth == 0) return;
    m_folderEdit = {};
    m_folderEdit.editing = true;
    m_folderEdit.id = id;
    m_folderEdit.edit.set(name, true);
    focus(Focus::FolderEditor);
}
void TuiApp::submitFolderEdit() {
    if (!m_folderEdit.editing || m_folderEdit.submitting) return;
    m_folderEdit.submitting = true;
    m_folderEdit.error.clear();
    if (m_folderEdit.creating) m_controller->createFolder(m_folderEdit.edit.text);
    else m_controller->renameFolder(m_folderEdit.id, m_folderEdit.edit.text);
    m_folderEdit.submitting = false;
    if (m_folderEdit.error.isEmpty()) cancelFolderEdit(true);
    else scheduleRender();
}
void TuiApp::cancelFolderEdit(bool restoreTerminal) {
    const QString target = m_folderEdit.id;
    m_folderEdit = {};
    if (m_foldersWidth == 0 || (restoreTerminal && !selectedId().isEmpty())) { focusTerminal(); return; }
    m_folderCursor = qMax(0, int(navIds().indexOf(target)));
    m_revealFolder = true;
    focus(Focus::Folders);
}
void TuiApp::cancelEdits() {
    if (!m_sessionEdit.id.isEmpty()) m_sessionEdit = {};
    if (m_folderEdit.editing) m_folderEdit = {};
    if (m_focus == Focus::SessionEditor) m_focus = Focus::Sessions;
    if (m_focus == Focus::FolderEditor) m_focus = Focus::Folders;
}
void TuiApp::cancelDrag() {
    if (!m_drag.pressed) return;
    m_drag = {};
    m_dropTarget.clear();
    scheduleRender();
}

void TuiApp::openMenu(Menu menu, bool keyboard) {
    hideTooltip();
    menu.restore = m_focus;
    if (keyboard) {
        for (int i = 0; i < int(menu.items.size()); ++i) if (menu.items[i].selectable()) { menu.highlighted = i; break; }
    }
    m_menu = std::move(menu);
    syncTerminalFocus();
    scheduleRender();
}
void TuiApp::closeMenu() {
    if (!m_menu) return;
    const Focus restore = m_menu->restore;
    m_menu.reset();
    focus(restore);
    keepFocusVisible();
}
void TuiApp::activateMenuItem(const MenuItem &item) {
    if (!item.selectable()) return;
    const auto action = item.action;
    closeMenu();
    if (action) action();
}

void TuiApp::openMoreMenu(bool keyboard) {
    const QString id = selectedId();
    const bool hasSelection = !id.isEmpty();
    const bool running = selected().value(QStringLiteral("status")).toString() == QStringLiteral("running");
    Menu menu;
    menu.anchor = Target::More;
    menu.alignRight = true;
    menu.x = m_frame.cols() - 1;
    menu.y = 1;
    auto item = [](const QString &icon, const QString &text, std::function<void()> action, const QString &hint = {}, bool enabled = true, bool destructive = false) {
        MenuItem result; result.icon = icon; result.text = text; result.action = std::move(action); result.hint = hint;
        result.enabled = enabled; result.destructive = destructive;
        return result;
    };
    menu.items = {
        item(glyphPlus, QStringLiteral("New tab"), [this] { newSession(); }, hint(Action::NewSession)),
        item(glyphFolder, QStringLiteral("New folder"), [this] { newFolder(); }, hint(Action::NewFolder)),
        MenuItem::line(),
        item(glyphPencil, QStringLiteral("Rename session"), [this] { renameSession(); }, hint(Action::Rename), hasSelection),
        item(glyphSplitRight, QStringLiteral("Split right"), [this] { split(QStringLiteral("right")); }, {}, running),
        item(glyphSplitDown, QStringLiteral("Split down"), [this] { split(QStringLiteral("down")); }, {}, running),
        MenuItem::line(),
        item(glyphPanelLeft, foldersVisible() ? QStringLiteral("Hide folders") : QStringLiteral("Show folders"),
             [this] { setFoldersVisible(!foldersVisible()); }, hint(Action::ToggleFolders)),
        item(glyphPanelRight, sessionsVisible() ? QStringLiteral("Hide sessions") : QStringLiteral("Show sessions"),
             [this] { setSessionsVisible(!sessionsVisible()); }, hint(Action::ToggleSessions)),
        MenuItem::line(),
        item(glyphClose, QStringLiteral("Close pane…"), [this] { confirmClosePane(); }, {}, hasSelection, true),
        item(glyphClose, QStringLiteral("Close session…"), [this, id] { confirmCloseSession(id, selected().value(QStringLiteral("title")).toString()); },
             hint(Action::CloseSession), hasSelection, true),
        MenuItem::line(),
        item(glyphQuit, QStringLiteral("Quit Cinmux"), [this] { m_app.quit(); }, hint(Action::Quit)),
    };
    openMenu(std::move(menu), keyboard);
}

void TuiApp::openSidebarMenu(int x, int y, bool keyboard) {
    Menu menu;
    menu.x = x;
    menu.y = y;
    MenuItem newTab; newTab.icon = glyphPlus; newTab.text = QStringLiteral("New tab"); newTab.hint = hint(Action::NewSession); newTab.action = [this] { newSession(); };
    MenuItem folder; folder.icon = glyphFolder; folder.text = QStringLiteral("New folder"); folder.hint = hint(Action::NewFolder); folder.action = [this] { newFolder(); };
    MenuItem all; all.icon = glyphTabs; all.text = QStringLiteral("Show all tabs");
    all.action = [this] { m_controller->setSearch({}); m_controller->setView(QStringLiteral("all")); setSessionsVisible(true); };
    menu.items = {newTab, folder, MenuItem::line(), all};
    openMenu(std::move(menu), keyboard);
}

void TuiApp::openFolderMenu(const QString &id, int x, int y, bool keyboard) {
    const QString name = folderName(id);
    Menu menu;
    menu.x = x;
    menu.y = y;
    menu.folderId = id;
    MenuItem newTab; newTab.icon = glyphPlus; newTab.text = QStringLiteral("New tab"); newTab.action = [this, id] { chooseView(id); newSession(); };
    MenuItem folder; folder.icon = glyphFolder; folder.text = QStringLiteral("New folder"); folder.hint = hint(Action::NewFolder); folder.action = [this] { newFolder(); };
    MenuItem rename; rename.icon = glyphPencil; rename.text = QStringLiteral("Rename folder"); rename.action = [this, id, name] { beginFolderRename(id, name); };
    MenuItem remove; remove.icon = glyphClose; remove.text = QStringLiteral("Delete folder…"); remove.destructive = true;
    remove.action = [this, id, name] { confirmDeleteFolder(id, name); };
    menu.items = {newTab, folder, MenuItem::line(), rename, MenuItem::line(), remove};
    openMenu(std::move(menu), keyboard);
}

void TuiApp::openSessionMenu(const QString &id, int x, int y, bool keyboard) {
    auto *model = m_controller->model();
    const QVariantMap row = model->get(int(model->ids().indexOf(id)));
    if (row.isEmpty()) return;
    const QString title = row.value(QStringLiteral("title")).toString();
    const QString folderId = row.value(QStringLiteral("folderId")).toString();
    const bool pinned = row.value(QStringLiteral("pinned")).toBool();
    const bool isSelected = id == selectedId();
    Menu menu;
    menu.x = x;
    menu.y = y;
    menu.sessionId = id;
    MenuItem newTab; newTab.icon = glyphPlus; newTab.text = QStringLiteral("New tab");
    newTab.action = [this, folderId] { m_controller->setView(folderId.isEmpty() ? QStringLiteral("all") : folderId); newSession(); };
    MenuItem rename; rename.icon = glyphPencil; rename.text = QStringLiteral("Rename"); rename.hint = isSelected ? hint(Action::Rename) : QString();
    rename.action = [this, id, title] { setSessionsVisible(true); beginSessionRename(id, title); };
    MenuItem pin; pin.icon = glyphPin; pin.text = pinned ? QStringLiteral("Unpin session") : QStringLiteral("Pin session");
    pin.action = [this, id, pinned] { m_controller->setPinned(id, !pinned); };
    MenuItem move; move.icon = glyphFolder; move.text = QStringLiteral("Move to folder");
    MenuItem unfiled; unfiled.icon = glyphFolder; unfiled.text = QStringLiteral("Unfiled"); unfiled.checked = folderId.isEmpty(); unfiled.enabled = !unfiled.checked;
    unfiled.action = [this, id] { m_controller->moveSession(id, {}); };
    move.submenu.push_back(unfiled);
    const auto folders = m_controller->folders();
    if (!folders.isEmpty()) move.submenu.push_back(MenuItem::line());
    for (const auto &value : folders) {
        const auto folder = value.toMap();
        const QString target = folder.value(QStringLiteral("id")).toString();
        MenuItem entry; entry.icon = glyphFolder; entry.text = folder.value(QStringLiteral("name")).toString();
        entry.checked = target == folderId; entry.enabled = !entry.checked;
        entry.action = [this, id, target] { m_controller->moveSession(id, target); };
        move.submenu.push_back(entry);
    }
    MenuItem close; close.icon = glyphClose; close.text = QStringLiteral("Close session…"); close.destructive = true;
    close.hint = isSelected ? hint(Action::CloseSession) : QString();
    close.action = [this, id, title] { confirmCloseSession(id, title); };
    menu.items = {newTab, MenuItem::line(), rename, pin, MenuItem::line(), move, MenuItem::line(), close};
    openMenu(std::move(menu), keyboard);
}

void TuiApp::openDialog(Dialog dialog) {
    closeMenu();
    cancelDrag();
    hideTooltip();
    m_resizing = 0;
    m_terminalCapture = false;
    dialog.restore = m_focus;
    m_dialog = std::move(dialog);
    syncTerminalFocus();
    scheduleRender();
}
void TuiApp::closeDialog() {
    if (!m_dialog) return;
    const Focus restore = m_dialog->restore;
    m_dialog.reset();
    focus(restore);
    keepFocusVisible();
}
// index -1 cancels; a button's action receives the dialog's input text.
void TuiApp::activateDialogButton(int index) {
    if (!m_dialog) return;
    std::function<void(const QString &)> action;
    if (index >= 0 && index < int(m_dialog->buttons.size())) action = m_dialog->buttons[index].action;
    const QString input = m_dialog->input.text;
    closeDialog();
    if (action) action(input);
}

void TuiApp::confirm(const QString &title, const QString &message, const QString &confirmText, std::function<void()> accept, const QString &paneTarget) {
    Dialog dialog;
    dialog.title = title;
    dialog.message = message;
    dialog.paneTarget = paneTarget;
    dialog.buttons = {{QStringLiteral("Cancel"), DialogButton::Normal, {}},
                      {confirmText, DialogButton::Destructive, [accept = std::move(accept)](const QString &) { accept(); }}};
    openDialog(std::move(dialog));
}
void TuiApp::confirmCloseSession(const QString &id, const QString &title) {
    if (id.isEmpty()) return;
    confirm(QStringLiteral("Close session “%1”?").arg(title),
            QStringLiteral("All its shells and jobs will end, and it will be removed from the list. This cannot be undone."),
            QStringLiteral("Close session"), [this, id] { m_controller->closeSession(id); focusTerminal(); });
}
void TuiApp::confirmClosePane() {
    const QString id = selectedId();
    if (id.isEmpty()) return;
    confirm(QStringLiteral("Close pane in “%1”?").arg(selected().value(QStringLiteral("title")).toString()),
            QStringLiteral("The active pane’s shell and jobs will end. If it is the session’s last pane, the session will also be removed. This cannot be undone."),
            QStringLiteral("Close pane"), [this, id] { if (selectedId() == id) m_controller->closeActivePane(); focusTerminal(); }, id);
}
void TuiApp::confirmDeleteFolder(const QString &id, const QString &name) {
    if (id.isEmpty()) return;
    confirm(QStringLiteral("Delete folder “%1”?").arg(name), QStringLiteral("Its sessions will become unfiled. Their shells and jobs will keep running."),
            QStringLiteral("Delete folder"), [this, id] { m_controller->deleteFolder(id); });
}
void TuiApp::showError(const QString &message) {
    Dialog dialog;
    dialog.kind = Dialog::Error;
    dialog.title = QStringLiteral("Unable to complete action");
    dialog.message = message;
    dialog.buttons = {{QStringLiteral("Dismiss"), DialogButton::Normal, {}}};
    if (m_dialog) { m_dialog->kind = dialog.kind; m_dialog->title = dialog.title; m_dialog->message = message; m_dialog->buttons = dialog.buttons; m_dialog->focus = 0; m_dialog->hasInput = false; scheduleRender(); return; }
    openDialog(std::move(dialog));
}
void TuiApp::chooseDirectory(const QString &sessionId, const QString &folderId, const QString &path) {
    Dialog dialog;
    dialog.kind = Dialog::Directory;
    dialog.title = QStringLiteral("Choose session working directory");
    dialog.message = QStringLiteral("Enter an existing directory. Tab completes directory names.");
    dialog.hasInput = true;
    dialog.input.set(existingDirectory(path));
    dialog.placeholder = QStringLiteral("/path/to/directory");
    dialog.focus = -1;
    dialog.buttons = {{QStringLiteral("Cancel"), DialogButton::Normal, {}},
                      {sessionId.isEmpty() ? QStringLiteral("Create session") : QStringLiteral("Start session"), DialogButton::Accent,
                       [this, sessionId, folderId](const QString &input) {
                           const QString directory = expandPath(input);
                           if (sessionId.isEmpty()) m_controller->createSession(folderId, directory);
                           else m_controller->startSession(sessionId, directory);
                           focusTerminal();
                       }}};
    openDialog(std::move(dialog));
}

void printHelp() {
    QTextStream(stdout) << "Usage: cinmux tui\n\n"
        "Opens the Cinmux workspace inside this terminal, for example over SSH.\n"
        "Sessions, folders and notifications are shared with the GUI, which may run\n"
        "at the same time. Quitting leaves every session running.\n\n"
        "Terminals without the kitty keyboard protocol use Ctrl+Alt instead of\n"
        "Ctrl+Shift for shortcuts (Ctrl+Alt+T opens a new tab).\n"
        "CINMUX_TUI_COLORS=24bit|256 overrides color detection.\n";
}
}

int runTui(QCoreApplication &app) {
    const QStringList args = app.arguments();
    if (args.size() > 2) {
        if (args[2] == QStringLiteral("--help") || args[2] == QStringLiteral("-h")) { printHelp(); return 0; }
        std::fprintf(stderr, "cinmux: unknown tui option: %s\n", qPrintable(args[2]));
        return 2;
    }
    ensureRuntimeDirectory();
    TuiApp tui(app);
    QString error;
    if (!tui.start(&error)) {
        tui.shutdown();
        std::fprintf(stderr, "cinmux: %s\n", qPrintable(error));
        return 1;
    }
    const int code = app.exec();
    tui.shutdown();
    return code;
}
