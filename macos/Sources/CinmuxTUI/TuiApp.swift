import CinmuxCore
import Darwin
import Foundation

// Cell equivalents of the GUI's pixel metrics (1050px wide threshold, 150-460px
// folders, 210-540px sessions, 260px minimum terminal).
let wideColumns = 110
let minimumTerminal = 30
let minimumFolders = 16
let maximumFolders = 48
let minimumSessions = 24
let maximumSessions = 60
let defaultFolders = 24
let defaultSessions = 34
let escapeTimeout = 50
let pasteTimeout = 1000
let tooltipDelay = 700
let frameInterval = 16

let glyphPanelLeft = "◧"
let glyphPanelRight = "◨"
let glyphPlus = "+"
let glyphSplitRight = "◫"
let glyphSplitDown = "⊟"
let glyphBell = "⚑"
let glyphSearch = "⌕"
let glyphMore = "⋯"
let glyphClose = "✕"
let glyphTabs = "▣"
let glyphFolder = "▢"
let glyphPin = "✦"
let glyphPencil = "✎"
let glyphCheck = "✓"
let glyphIdle = "○"
let glyphWaiting = "?"
let glyphError = "●"
let glyphChevron = "›"
let glyphQuit = "←"
let glyphMarker = "▎"
let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

func style(_ fg: TuiColor, _ bg: TuiColor, _ attributes: TuiAttributes = []) -> TuiStyle { TuiStyle(fg: fg, bg: bg, attributes: attributes) }

func menuKey(_ e: InputEvent) -> Bool { e.key == .menu || (e.key == .function && e.function == 10 && e.modifiers == .shift) }
func plainKey(_ e: InputEvent, _ key: Key) -> Bool { e.key == key && e.modifiers.intersection([.ctrl, .alt]).isEmpty }
/// Two quick Escape presses arrive as one `ESC ESC` read, decoded as Alt+Escape.
func escape(_ e: InputEvent) -> Bool { e.key == .escape && !e.modifiers.contains(.ctrl) }
func character(_ e: InputEvent, _ c: Unicode.Scalar) -> Bool { e.key == .character && e.modifiers.isEmpty && e.codepoint == c.value }

enum Focus: Equatable { case terminal, search, folders, sessions, folderEditor, sessionEditor }

enum Action: Equatable {
    case none, newSession, newFolder, search, toggleFolders, toggleSessions, rename, closeSession, previous, next, attention, quit, focusSessions
}

enum Target: Equatable {
    case none, foldersToggle, sessionsToggle, newTab, splitRight, splitDown, attention, search, searchClear, more
    case foldersPane, nav, folderAdd, folderMore, folderEditor, foldersDivider
    case sessionsPane, sessionRow, sessionTrash, sessionEditor, sessionsDivider
    case terminal, terminalButton, menuSurface, menuItem, submenuItem, dialogSurface, dialogInput, dialogButton, backdrop
}

let createButton = 0
let startButton = 1
let reconnectButton = 2

struct Hit {
    var x = 0
    var y = 0
    var w = 0
    var h = 0
    var target = Target.none
    var id = ""
    var index = -1
    var tooltip = ""
    func contains(_ px: Int, _ py: Int) -> Bool { px >= x && py >= y && px < x + w && py < y + h }
    func same(_ other: Hit) -> Bool { target == other.target && id == other.id && index == other.index }
}

struct MenuItem {
    var icon = ""
    var text = ""
    var hint = ""
    var enabled = true
    var destructive = false
    var checked = false
    var separator = false
    var action: (@MainActor () -> Void)?
    var submenu: [MenuItem] = []
    static func line() -> MenuItem {
        var item = MenuItem()
        item.separator = true
        return item
    }
    var selectable: Bool { !separator && enabled }
}

struct Menu {
    var items: [MenuItem] = []
    var x = 0
    var y = 0
    /// x is the right edge (toolbar menu).
    var alignRight = false
    var highlighted = -1
    /// The item whose submenu is shown.
    var open = -1
    var subHighlighted = -1
    var inSubmenu = false
    var anchor = Target.none
    /// The row whose menu is open.
    var sessionId = ""
    var folderId = ""
    var restore = Focus.terminal
}

struct DialogButton {
    enum Role { case normal, accent, destructive }
    var label: String
    var role = Role.normal
    var action: (@MainActor (String) -> Void)?
}

struct Dialog {
    enum Kind { case confirm, error, directory }
    var kind = Kind.confirm
    var title = ""
    var message = ""
    var buttons: [DialogButton] = []
    /// Button index, or -1 for the input.
    var focus = 0
    var hasInput = false
    var input = LineEdit()
    var placeholder = ""
    /// A "Close pane" confirmation's session.
    var paneTarget = ""
    var restore = Focus.terminal
}

struct SessionEdit {
    var id = ""
    var edit = LineEdit()
    var error = ""
    var submitting = false
}

struct FolderEdit {
    var editing = false
    var creating = false
    var id = ""
    var edit = LineEdit()
    var error = ""
    var submitting = false
}

struct Drag {
    var pressed = false
    var active = false
    var sessionId = ""
    var caption = ""
    var x = 0
    var y = 0
}

/// `cinmux tui`: the Cinmux workspace inside the current terminal (for
/// example over SSH), sharing sessions, folders and notifications with the app.
@MainActor
final class TuiApp {
    let tty = Tty()
    let store = StateStore()
    let theme = TuiTheme()
    var settings: IniSettings?
    var terminals: TuiTerminals!
    var controller: SessionController!
    var frame = Surface()
    var parser = InputParser()
    var p = Palette()
    var inputSource: DispatchSourceRead?
    var readBuffer = [UInt8](repeating: 0, count: 65536)
    var escapeTimer: TuiTimer!
    var renderTimer: TuiTimer!
    var spinnerTimer: TuiTimer!
    var tooltipTimer: TuiTimer!
    /// Uptime of the last frame, in nanoseconds; nil before the first.
    var lastFrame: UInt64?
    var hits: [Hit] = []
    var quitting = false
    // Layout
    var wide = true, wideFolders = true, wideSessions = true, narrowFolders = false, narrowSessions = true
    var desiredFolders = defaultFolders, desiredSessions = defaultSessions
    var foldersWidth = 0, sessionsWidth = 0, termX = 0, termY = 1, termW = 0, termH = 0
    var folderScroll = 0, sessionScroll = 0
    var revealSelected = true, revealFolder = false
    /// Nav index -> screen row, from the last frame.
    var navRowY: [Int: Int] = [:]
    /// Session ID -> screen row, from the last frame.
    var sessionRowY: [String: Int] = [:]
    // State
    var focus = Focus.terminal
    var folderCursor = 0
    var search = LineEdit()
    var sessionEdit = SessionEdit()
    var folderEdit = FolderEdit()
    var menu: Menu?
    var dialog: Dialog?
    var drag = Drag()
    var dropTarget = ""
    /// 1 folders divider, 2 sessions divider.
    var resizing = 0
    var terminalCapture = false
    var hover = Hit()
    var mouseX = -1, mouseY = -1
    var tooltipVisible = false
    var tooltipText = ""
    var tooltipX = 0, tooltipY = 0
    var ttyFocused = true
    var kittyKeyboard = false, keyboardKnown = false
    var spinning = false
    var spinnerFrame = 0
    var lastSelected = ""
    /// The controller's search as last seen, to react only to its changes.
    var lastSearch = ""

    var foldersVisible: Bool { wide ? wideFolders : narrowFolders }
    var sessionsVisible: Bool { wide ? wideSessions : narrowSessions }
    var selectedId: String { controller.selectedId }
    var selected: SessionRow? { controller.selected }

    init() {
        escapeTimer = TuiTimer { [unowned self] in self.handle(self.parser.flush()) }
        renderTimer = TuiTimer { [unowned self] in self.render() }
        spinnerTimer = TuiTimer(repeating: true) { [unowned self] in
            self.spinnerFrame = (self.spinnerFrame + 1) % spinner.count
            self.scheduleRender()
        }
        tooltipTimer = TuiTimer { [unowned self] in
            if self.hover.tooltip.isEmpty || self.menu != nil || self.dialog != nil || self.drag.active { return }
            self.tooltipVisible = true
            self.tooltipText = self.hover.tooltip
            self.tooltipX = self.mouseX
            self.tooltipY = self.mouseY
            self.scheduleRender()
        }
    }

    /// Returns an error message when the TUI cannot start.
    func start() -> String? {
        do { try store.open() } catch { return error.cinmuxMessage }
        if let error = tty.open() { return error }
        let settings = IniSettings(path: store.stateDirectory + "/ui.ini")
        self.settings = settings
        wideFolders = settings.bool("tui/foldersVisible", true)
        wideSessions = settings.bool("tui/sessionsVisible", true)
        narrowSessions = wideSessions
        desiredFolders = min(max(settings.int("tui/foldersWidth", defaultFolders), minimumFolders), maximumFolders)
        desiredSessions = min(max(settings.int("tui/sessionsWidth", defaultSessions), minimumSessions), maximumSessions)
        // A first TUI visit continues where the app left off.
        let view = settings.value("tui/view") ?? settings.value("selection/view") ?? "all"
        let session = settings.value("tui/session") ?? settings.value("selection/session") ?? ""

        p = Palette(theme.palette)
        terminals = TuiTerminals(store: store)
        let helper = Paths.executable().map { ($0 as NSString).deletingLastPathComponent }
        controller = SessionController(store: store, renderer: terminals, helperDirectory: helper)
        controller.onChange = { [unowned self] in self.controllerChanged() }
        controller.onFailure = { [unowned self] id, message in
            if self.folderEdit.submitting && id.isEmpty {
                self.folderEdit.error = message
                return
            }
            if self.sessionEdit.submitting && id == self.sessionEdit.id {
                self.sessionEdit.error = message
                return
            }
            self.showError(message)
        }
        controller.onDirectoryRequired = { [unowned self] sessionId, folderId, path in
            guard self.dialog != nil, self.dialog?.kind == .error else { return }
            self.dialog?.buttons = [
                DialogButton(label: "Cancel", role: .normal, action: nil),
                DialogButton(label: "Choose directory", role: .accent, action: { [unowned self] _ in
                    self.chooseDirectory(sessionId: sessionId, folderId: folderId, path: path)
                }),
            ]
            self.dialog?.focus = 0
            self.scheduleRender()
        }
        theme.onChange = { [unowned self] in
            self.p = Palette(self.theme.palette)
            self.tty.invalidate()
            self.scheduleRender()
        }
        terminals.onUpdated = { [unowned self] id in if id == self.selectedId { self.scheduleRender() } }
        terminals.onBell = { [unowned self] id in if id == self.selectedId { self.tty.write([0x07]) } }
        terminals.onClipboard = { [unowned self] base64 in
            self.tty.write(Array("\u{1b}]52;c;".utf8) + Array(base64.utf8) + [0x07])
        }

        let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        input.setEventHandler { [unowned self] in MainActor.assumeIsolated { self.onInput() } }
        input.resume()
        inputSource = input
        tty.onSignal = { [unowned self] number in self.onSignal(number) }

        lastSearch = controller.search
        controller.setView(view)
        if !session.isEmpty { controller.selectSession(session) }
        search.set(controller.search)
        lastSearch = controller.search
        lastSelected = selectedId
        terminals.setSelected(lastSelected)
        layoutPanes()
        syncTerminalFocus()
        render()
        return nil
    }

    /// Saves preferences, stops every client (sessions keep running) and restores the terminal.
    func shutdown() {
        if let settings, let controller {
            settings.set("tui/foldersVisible", wideFolders ? "true" : "false")
            settings.set("tui/sessionsVisible", wideSessions ? "true" : "false")
            settings.set("tui/foldersWidth", String(desiredFolders))
            settings.set("tui/sessionsWidth", String(desiredSessions))
            settings.set("tui/view", controller.view)
            settings.set("tui/session", controller.selectedId)
        }
        let saved = settings?.sync() ?? true
        inputSource?.cancel()
        inputSource = nil
        tty.onSignal = nil
        escapeTimer.stop()
        renderTimer.stop()
        spinnerTimer.stop()
        tooltipTimer.stop()
        controller?.shutdown()
        tty.restore()
        if !saved { FileHandle.standardError.write(Data("cinmux: could not save TUI preferences\n".utf8)) }
    }

    /// Leaves the event loop after the current event, like QCoreApplication::quit.
    func quit() {
        guard !quitting else { return }
        quitting = true
        onMain { [unowned self] in
            self.shutdown()
            exit(0)
        }
    }

    // MARK: Controller notifications

    /// Mirrors the Linux build's reactions to searchChanged and selectionChanged,
    /// then schedules a frame for any published change.
    private func controllerChanged() {
        if controller.search != lastSearch {
            lastSearch = controller.search
            if search.text != controller.search { search.set(controller.search) }
        }
        let id = selectedId
        terminals.setSelected(id)
        if id != lastSelected {
            lastSelected = id
            revealSelected = true
            if let dialog, !dialog.paneTarget.isEmpty && dialog.paneTarget != id { closeDialog() }
        }
        syncTerminalFocus()
        scheduleRender()
    }

    // MARK: Terminal I/O

    private func onInput() {
        if quitting { return }
        let count = readBuffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
        if count == 0 || (count < 0 && errno != EINTR && errno != EAGAIN) {
            inputSource?.cancel()
            inputSource = nil
            quit()
            return
        }
        if count > 0 { handle(parser.feed(readBuffer[0..<count])) }
        if parser.pending { escapeTimer.start(parser.pasting ? pasteTimeout : escapeTimeout) }
        else { escapeTimer.stop() }
    }

    private func onSignal(_ number: Int32) {
        if number == SIGWINCH {
            if tty.updateSize() {
                hideTooltip()
                scheduleRender()
            }
        } else {
            quit()
        }
    }

    func handle(_ events: [InputEvent]) {
        for e in events {
            switch e.type {
            case .key: handleKey(e)
            case .mouse: handleMouse(e)
            case .paste: handlePaste(e.text)
            case .focusIn:
                ttyFocused = true
                syncTerminalFocus()
            case .focusOut:
                ttyFocused = false
                syncTerminalFocus()
            case .keyboardFlags: kittyKeyboard = true
            case .primaryAttributes: keyboardKnown = true
            }
        }
        if !events.isEmpty { scheduleRender() }
    }

    func scheduleRender() {
        if renderTimer.isActive { return }
        let elapsed = lastFrame.map { Int((DispatchTime.now().uptimeNanoseconds - $0) / 1_000_000) } ?? frameInterval
        renderTimer.start(max(0, frameInterval - elapsed))
    }

    // MARK: Layout

    func layoutPanes() {
        let width = tty.cols
        let isWide = width >= wideColumns
        if isWide != wide && !isWide {
            narrowFolders = false
            narrowSessions = wideSessions
        }
        wide = isWide
        let folders = foldersVisible, sessions = sessionsVisible
        foldersWidth = folders ? max(0, min(desiredFolders, width - minimumTerminal - (sessions ? minimumSessions : 0))) : 0
        if foldersWidth < 8 { foldersWidth = 0 }
        sessionsWidth = sessions ? max(0, min(desiredSessions, width - minimumTerminal - foldersWidth)) : 0
        if sessionsWidth < 10 { sessionsWidth = 0 }
        termX = foldersWidth + sessionsWidth
        termY = 1
        termW = max(0, width - termX)
        termH = max(0, tty.rows - 1)
        terminals.setSize(cols: max(1, termW), rows: max(1, termH))
        keepFocusVisible()
    }

    func setFoldersVisible(_ visible: Bool) {
        if wide { wideFolders = visible }
        else {
            narrowFolders = visible
            if visible { narrowSessions = false }
        }
        layoutPanes()
        scheduleRender()
    }

    func setSessionsVisible(_ visible: Bool) {
        if wide { wideSessions = visible }
        else {
            narrowSessions = visible
            if visible { narrowFolders = false }
        }
        layoutPanes()
        scheduleRender()
    }

    func resizePane(folders: Bool, _ value: Int) {
        let width = tty.cols
        if folders {
            desiredFolders = min(max(value, minimumFolders), max(minimumFolders, min(maximumFolders, width - minimumTerminal - sessionsWidth)))
        } else {
            desiredSessions = min(max(value, minimumSessions), max(minimumSessions, min(maximumSessions, width - minimumTerminal - foldersWidth)))
        }
        layoutPanes()
        scheduleRender()
    }

    /// A hidden pane cannot keep keyboard focus (the app moves it to the toolbar).
    func keepFocusVisible() {
        if foldersWidth == 0 && (focus == .folders || focus == .folderEditor) {
            if folderEdit.editing { folderEdit = FolderEdit() }
            focus = .terminal
            syncTerminalFocus()
        }
        if sessionsWidth == 0 && (focus == .sessions || focus == .sessionEditor) {
            sessionEdit = SessionEdit()
            focus = .terminal
            syncTerminalFocus()
        }
    }

    func hitAt(_ x: Int, _ y: Int) -> Hit {
        for hit in hits.reversed() where hit.contains(x, y) { return hit }
        return Hit()
    }

    func addHit(_ hit: Hit) { hits.append(hit) }

    func render() {
        renderTimer.stop()
        lastFrame = DispatchTime.now().uptimeNanoseconds
        let width = tty.cols, height = tty.rows
        if frame.cols != width || frame.rows != height { frame.resize(cols: width, rows: height) }
        frame.fill(0, 0, width, height, style(p.text, p.chrome))
        frame.cursor = Surface.Cursor()
        hits.removeAll(keepingCapacity: true)
        navRowY.removeAll()
        sessionRowY.removeAll()
        spinning = false
        layoutPanes()
        paintHeader()
        paintFolders()
        paintSessions()
        paintTerminal()
        if drag.active { paintDrag() }
        if menu != nil { paintMenu() }
        if dialog != nil { paintDialog() }
        else if tooltipVisible && menu == nil { paintTooltip() }
        tty.present(frame)
        if spinning && !spinnerTimer.isActive { spinnerTimer.start(100) }
        else if !spinning { spinnerTimer.stop() }
    }
}

private func printTuiHelp() {
    print("""
    Usage: cinmux tui

    Opens the Cinmux workspace inside this terminal, for example over SSH.
    Sessions, folders and notifications are shared with the GUI, which may run
    at the same time. Quitting leaves every session running.

    Terminals without the kitty keyboard protocol use Ctrl+Alt instead of
    Ctrl+Shift for shortcuts (Ctrl+Alt+T opens a new tab).
    CINMUX_TUI_COLORS=24bit|256 overrides color detection.
    """)
}

/// Runs `cinmux tui` (`arguments` is the full command line, `arguments[1] == "tui"`).
/// Returns the exit status for help and startup failures; otherwise the
/// process exits when the user quits, leaving every session running.
@MainActor
public func runTui(_ arguments: [String]) -> Int32 {
    if arguments.count > 2 {
        if arguments[2] == "--help" || arguments[2] == "-h" {
            printTuiHelp()
            return 0
        }
        FileHandle.standardError.write(Data("cinmux: unknown tui option: \(arguments[2])\n".utf8))
        return 2
    }
    let app = TuiApp()
    if let error = app.start() {
        app.shutdown()
        FileHandle.standardError.write(Data("cinmux: \(error)\n".utf8))
        return 1
    }
    // Retained for the process lifetime: quitting exits from the main queue.
    runningApp = app
    dispatchMain()
}

@MainActor private var runningApp: TuiApp?
