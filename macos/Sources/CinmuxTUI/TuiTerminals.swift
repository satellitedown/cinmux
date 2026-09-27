import CinmuxCore
import Darwin
import Foundation
import SwiftTerm

/// Starts a program on a new pseudo-terminal as the session leader with the
/// terminal as its controlling terminal (forkpty), inheriting nothing but the
/// pty as stdin/stdout/stderr.
enum PaneProcess {
    private static func cStrings(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let array = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() { array[index] = strdup(string) }
        array[strings.count] = nil
        return array
    }

    private static func free(_ array: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, _ count: Int) {
        for index in 0..<count { Darwin.free(array[index]) }
        array.deallocate()
    }

    private static func failure(_ step: String, _ code: Int32) -> CinmuxError {
        .message("Cannot open a pseudo-terminal (\(step)): \(String(cString: strerror(code)))")
    }

    /// Returns the child's PID and the non-blocking, close-on-exec primary side.
    static func spawn(program: String, arguments: [String], environment: [String: String], cols: Int, rows: Int) throws -> (pid: pid_t, master: Int32) {
        let argv = [program] + arguments
        let envp = environment.keys.sorted().map { $0 + "=" + environment[$0]! }
        // Everything the child touches is allocated before forking: it must not allocate.
        let cArgs = cStrings(argv)
        let cEnv = cStrings(envp)
        guard let cPath = strdup(program) else {
            free(cArgs, argv.count)
            free(cEnv, envp.count)
            throw failure("strdup", ENOMEM)
        }
        defer {
            free(cArgs, argv.count)
            free(cEnv, envp.count)
            Darwin.free(cPath)
        }
        // A failed exec reports errno through this close-on-exec pipe.
        var report: [Int32] = [-1, -1]
        guard pipe(&report) == 0 else { throw failure("pipe", errno) }
        _ = fcntl(report[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(report[1], F_SETFD, FD_CLOEXEC)
        let reportWrite = report[1]
        let highestFd = min(getdtablesize(), 65536)
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
        var unblocked: sigset_t = 0
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &size)
        if pid == 0 {
            // Like QProcess's ResetSignalHandlers: the TUI ignores SIGPIPE, and main-queue
            // work runs on dispatch threads that block signals; both would survive exec
            // and leave the client deaf to SIGWINCH and SIGTERM.
            var number: Int32 = 1
            while number < NSIG {
                _ = signal(number, SIG_DFL)
                number += 1
            }
            _ = sigprocmask(SIG_SETMASK, &unblocked, nil)
            var fd: Int32 = 3
            while fd < highestFd {
                if fd != reportWrite { _ = close(fd) }
                fd += 1
            }
            _ = execve(cPath, cArgs, cEnv)
            var code = errno
            _ = write(reportWrite, &code, MemoryLayout<Int32>.size)
            _exit(127)
        }
        _ = close(reportWrite)
        if pid < 0 {
            let code = errno
            _ = close(report[0])
            throw failure("forkpty", code)
        }
        var code: Int32 = 0
        var received = 0
        while true {
            received = withUnsafeMutableBytes(of: &code) { read(report[0], $0.baseAddress, $0.count) }
            if received < 0 && errno == EINTR { continue }
            break
        }
        _ = close(report[0])
        if received == MemoryLayout<Int32>.size {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            _ = close(master)
            throw CinmuxError.message("execve: \(String(cString: strerror(code)))")
        }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        let flags = fcntl(master, F_GETFL)
        if flags < 0 || fcntl(master, F_SETFL, flags | O_NONBLOCK) != 0 {
            let failed = failure("setup", errno)
            _ = kill(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            _ = close(master)
            throw failed
        }
        return (pid, master)
    }

    /// QProcess's exit code: the exit status, or the signal that ended the process.
    static func exitCode(_ status: Int32) -> Int32 {
        status & 0x7f == 0 ? (status >> 8) & 0xff : status & 0x7f
    }
}

/// One session's tmux client: its pty, process and SwiftTerm emulator.
/// Main-thread only.
final class PaneView: TerminalDelegate {
    let id: String
    let generation: UInt64
    let master: Int32
    let pid: pid_t
    var cols: Int
    var rows: Int
    private(set) var terminal: SwiftTerm.Terminal!
    /// Bytes for the tmux client in order: keyboard, mouse and terminal replies.
    var input: [UInt8] = []
    /// OSC 52 clipboard writes, as standard base64.
    var clipboards: [String] = []
    var cursorVisible = true
    /// DECSCUSR is reported only once the client chose a shape; otherwise the
    /// outer terminal keeps its configured cursor.
    var shapeSet = false
    var cursorStyle: CursorStyle = .blinkBlock
    /// libvterm's mouse state: held buttons (bit 0 left, 1 middle, 2 right) and last position.
    var mouseButtons = 0
    var mouseCol = 0
    var mouseRow = 0
    var ready = false
    var changed = false
    var rang = false

    var onOutput: (@MainActor (PaneView) -> Void)?
    var onExit: (@MainActor (PaneView, Int32) -> Void)?

    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var exitSource: DispatchSourceProcess?
    private var killTimer: DispatchSourceTimer?
    private var liveSources = 0
    private var closed = false
    private var exited = false

    init(id: String, generation: UInt64, master: Int32, pid: pid_t, cols: Int, rows: Int, focused: Bool) {
        self.id = id
        self.generation = generation
        self.master = master
        self.pid = pid
        self.cols = cols
        self.rows = rows
        terminal = SwiftTerm.Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows))
        // Debug builds of SwiftTerm log unknown sequences to stdout, which is the TUI's screen.
        terminal.silentLog = true
        // No report is sent yet: this only seeds the state a later DECSET 1004 reports.
        terminal.setTerminalFocus(focused)
    }

    func start() {
        let reader = DispatchSource.makeReadSource(fileDescriptor: master, queue: .main)
        reader.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onOutput?(self)
            }
        }
        // Strong: the view must outlive its sources to close the descriptor after them.
        reader.setCancelHandler { self.sourceCancelled() }
        liveSources += 1
        reader.resume()
        self.reader = reader
        // The handler keeps the view alive until the client is reaped.
        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exitSource.setEventHandler { MainActor.assumeIsolated { self.reap() } }
        exitSource.activate()
        self.exitSource = exitSource
    }

    /// Feeds pending pty output to the emulator; true when bytes arrived.
    func drain() -> Bool {
        var received = false
        var buffer = [UInt8](repeating: 0, count: 16384)
        // Bounded so a flooding client cannot starve the event loop; the source fires again.
        var reads = 0
        while reads < 64 {
            let size = buffer.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
            if size > 0 {
                terminal.feed(buffer: buffer[0..<size])
                received = true
                reads += 1
                continue
            }
            if size < 0 && errno == EINTR { continue }
            if size == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) {
                reader?.cancel()
                reader = nil
            }
            break
        }
        if received { changed = true }
        return received
    }

    /// Writes queued input; the rest waits for the pty to accept more.
    func flushInput() {
        var written = 0
        while written < input.count {
            let size = input.withUnsafeBytes { write(master, $0.baseAddress! + written, $0.count - written) }
            if size > 0 {
                written += size
                continue
            }
            if size < 0 && errno == EINTR { continue }
            // The client is gone: its input is moot.
            if size < 0 && errno != EAGAIN && errno != EWOULDBLOCK { written = input.count }
            break
        }
        input.removeFirst(written)
        if input.isEmpty || closed {
            writer?.cancel()
            writer = nil
        } else if writer == nil {
            let writer = DispatchSource.makeWriteSource(fileDescriptor: master, queue: .main)
            writer.setEventHandler { [weak self] in self?.flushInput() }
            writer.setCancelHandler { self.sourceCancelled() }
            liveSources += 1
            writer.resume()
            self.writer = writer
        }
    }

    /// The bottom-most non-blank line of the screen, trimmed.
    func lastLine() -> String {
        var row = rows - 1
        while row >= 0 {
            defer { row -= 1 }
            guard let line = terminal.getLine(row: row) else { continue }
            var text = ""
            for col in 0..<min(cols, line.count) {
                let cell = line[col]
                if cell.width == 0 { continue }
                let character = terminal.getCharacter(for: cell)
                text.append(character.unicodeScalars.first?.value == 0 ? " " : character)
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// Hangs up and terminates the client; the view stays alive until it is reaped.
    func close() {
        guard !closed else { return }
        closed = true
        onOutput = nil
        onExit = nil
        reader?.cancel()
        reader = nil
        writer?.cancel()
        writer = nil
        if liveSources == 0 { _ = Darwin.close(master) }
        guard !exited else { return }
        _ = kill(pid, SIGTERM)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1)
        timer.setEventHandler { [weak self] in
            guard let self, !self.exited else { return }
            _ = kill(self.pid, SIGKILL)
        }
        timer.resume()
        killTimer = timer
    }

    private func sourceCancelled() {
        liveSources -= 1
        // The descriptor may only be closed once no source watches it.
        if liveSources == 0 && closed { _ = Darwin.close(master) }
    }

    @MainActor private func reap() {
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, WNOHANG) } while result < 0 && errno == EINTR
        if result == 0 { return }
        exited = true
        exitSource?.cancel()
        exitSource = nil
        killTimer?.cancel()
        killTimer = nil
        onExit?(self, result < 0 ? 0 : PaneProcess.exitCode(status))
    }

    // MARK: TerminalDelegate

    func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) { input.append(contentsOf: data) }
    func bell(source: SwiftTerm.Terminal) { rang = true }
    func showCursor(source: SwiftTerm.Terminal) { cursorVisible = true; changed = true }
    func hideCursor(source: SwiftTerm.Terminal) { cursorVisible = false; changed = true }
    func mouseModeChanged(source: SwiftTerm.Terminal) { changed = true }
    func cursorStyleChanged(source: SwiftTerm.Terminal, newStyle: CursorStyle) {
        cursorStyle = newStyle
        shapeSet = true
        changed = true
    }
    func clipboardCopy(source: SwiftTerm.Terminal, content: Data) { clipboards.append(content.base64EncodedString()) }
}

/// `cinmux tui` renderer: one pseudo-terminal per displayed session running
/// `tmux -u -S <socket> attach-session -E -t =cinmux-<id>`, emulated with
/// SwiftTerm. Views are retained until detached, like the app's views.
@MainActor
final class TuiTerminals: TerminalRenderer {
    struct Cursor {
        var x = 0
        var y = 0
        var visible = false
        /// DECSCUSR value: 0 default, 1...6.
        var shape = 0
    }

    weak var delegate: TerminalRendererDelegate?
    /// Screen content, cursor or mouse mode changed.
    var onUpdated: (@MainActor (String) -> Void)?
    var onBell: (@MainActor (String) -> Void)?
    /// An OSC 52 clipboard write from a tmux client, as standard base64.
    var onClipboard: (@MainActor (String) -> Void)?

    private let store: StateStore
    private let environment: [String: String]
    private let tmuxProgram: String?
    private var views: [String: PaneView] = [:]
    private var selected = ""
    private var focused = false
    private var cols = 80
    private var rows = 24
    private var generation: UInt64 = 0

    init(store: StateStore) {
        self.store = store
        // The private server's configuration grants RGB, clipboard and extended keys to this TERM.
        environment = Tmux.clientEnvironment(HostEnvironment.current())
        tmuxProgram = HostEnvironment.findExecutable("tmux")
    }

    func attach(_ id: String, force: Bool) {
        if views[id] != nil {
            if !force { return }
            detach(id)
        }
        guard let tmuxProgram else {
            delegate?.rendererLost(id, message: "tmux is not installed or is not on PATH")
            return
        }
        var environment = self.environment
        environment["CINMUX_STATE_DIR"] = store.stateDirectory
        environment["CINMUX_SESSION_ID"] = id
        environment["CINMUX_TMUX_SOCKET"] = store.tmuxSocket
        let spawned: (pid: pid_t, master: Int32)
        do {
            spawned = try PaneProcess.spawn(program: tmuxProgram, arguments: Tmux.attachArguments(socket: store.tmuxSocket, id: id),
                                            environment: environment, cols: cols, rows: rows)
        } catch {
            delegate?.rendererLost(id, message: error.cinmuxMessage)
            return
        }
        generation += 1
        let view = PaneView(id: id, generation: generation, master: spawned.master, pid: spawned.pid, cols: cols, rows: rows,
                            focused: focused && id == selected)
        view.onOutput = { [weak self] view in self?.readOutput(view) }
        view.onExit = { [weak self] view, code in self?.finished(view, code: code) }
        views[id] = view
        view.start()
    }

    func detach(_ id: String) {
        views.removeValue(forKey: id)?.close()
    }

    func isAttached(_ id: String) -> Bool { views[id] != nil }

    private func finished(_ view: PaneView, code: Int32) {
        guard let current = views[view.id], current.generation == view.generation else { return }
        _ = current.drain()
        var message = current.lastLine()
        // tmux reports ordinary exits in brackets, e.g. "[exited]" or "[detached …]"; errors are plain text.
        if message.isEmpty || message.hasPrefix("[") {
            message = "Terminal client exited (code \(code)). The tmux session is unaffected; reconnect to view it."
        }
        let id = current.id
        views.removeValue(forKey: id)?.close()
        delegate?.rendererLost(id, message: message)
    }

    private func readOutput(_ view: PaneView) {
        let received = view.drain()
        view.flushInput()
        let id = view.id
        let generation = view.generation
        let becameReady = received && !view.ready
        if received { view.ready = true }
        let rang = view.rang
        view.rang = false
        let changed = view.changed
        view.changed = false
        let clipboards = view.clipboards
        view.clipboards = []
        // Handlers may detach or replace the view.
        let alive = { [weak self] () -> Bool in self?.views[id]?.generation == generation }
        if becameReady { delegate?.rendererReady(id) }
        if rang && alive() { onBell?(id) }
        for base64 in clipboards { onClipboard?(base64) }
        if changed && alive() { onUpdated?(id) }
    }

    /// Applies the current size to the view; true when it changed.
    private func resize(_ view: PaneView) -> Bool {
        if view.cols == cols && view.rows == rows { return false }
        view.cols = cols
        view.rows = rows
        view.terminal.resize(cols: cols, rows: rows)
        view.changed = false
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(view.master, TIOCSWINSZ, &size)
        return true
    }

    /// Terminal area size in cells. The selected view is resized at once;
    /// other views are resized when they become selected. New views start at
    /// this size.
    func setSize(cols: Int, rows: Int) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        guard let current = views[selected], resize(current) else { return }
        onUpdated?(selected)
    }

    func setSelected(_ id: String) {
        if id == selected { return }
        if let previous = views[selected], focused {
            previous.terminal.setTerminalFocus(false)
            previous.flushInput()
        }
        selected = id
        guard let current = views[id] else { return }
        if focused {
            current.terminal.setTerminalFocus(true)
            current.flushInput()
        }
        if resize(current) { onUpdated?(id) }
    }

    /// Keyboard focus of the selected view, for focus reporting.
    func setFocused(_ value: Bool) {
        if value == focused { return }
        focused = value
        guard let current = views[selected] else { return }
        current.terminal.setTerminalFocus(value)
        current.flushInput()
    }

    /// True once the view has received output from its tmux client.
    func hasOutput(_ id: String) -> Bool { views[id]?.ready ?? false }

    /// Copies the view's screen to `surface` at (x, y), clipped to
    /// width x height. False when there is no view.
    func paint(_ id: String, _ surface: inout Surface, _ x: Int, _ y: Int, _ width: Int, _ height: Int) -> Bool {
        guard let view = views[id], let terminal = view.terminal else { return false }
        let cols = min(min(width, view.cols), surface.cols - x)
        let rows = min(min(height, view.rows), surface.rows - y)
        guard cols > 0 && rows > 0 else { return true }
        for row in 0..<rows {
            guard let line = terminal.getLine(row: row) else { continue }
            for col in 0..<min(cols, line.count) {
                let source = line[col]
                // The right half of a wide character.
                if source.width == 0 { continue }
                var cell = TuiCell()
                let scalars = terminal.getCharacter(for: source).unicodeScalars
                if let first = scalars.first, first.value != 0, !(source.width == 2 && col + 1 >= cols) {
                    var index = 0
                    for scalar in scalars where index < TuiCell.maxChars {
                        cell.chars[index] = scalar.value
                        index += 1
                    }
                    cell.width = source.width >= 2 ? 2 : 1
                }
                let attribute = source.attribute
                cell.style.fg = Self.color(attribute.fg)
                cell.style.bg = Self.color(attribute.bg)
                var attributes: TuiAttributes = []
                let style = attribute.style
                if style.contains(.bold) { attributes.insert(.bold) }
                if style.contains(.dim) { attributes.insert(.faint) }
                if style.contains(.italic) { attributes.insert(.italic) }
                if style.contains(.blink) { attributes.insert(.blink) }
                if style.contains(.inverse) { attributes.insert(.reverse) }
                if style.contains(.invisible) { attributes.insert(.conceal) }
                if style.contains(.crossedOut) { attributes.insert(.strike) }
                if style.contains(.underline) {
                    switch attribute.underlineStyle {
                    case .double: attributes.insert(.doubleUnderline)
                    case .curly: attributes.insert(.curlyUnderline)
                    default: attributes.insert(.underline)
                    }
                }
                cell.style.attributes = attributes
                surface.put(x + col, y + row, cell)
            }
        }
        return true
    }

    private static func color(_ value: Attribute.Color) -> TuiColor {
        switch value {
        case .ansi256(let code): return .indexed(code)
        case .trueColor(let red, let green, let blue): return .rgb(red, green, blue)
        case .defaultColor, .defaultInvertedColor: return .default
        }
    }

    /// Cursor relative to the view's top-left cell.
    func cursor(_ id: String) -> Cursor {
        guard let view = views[id], let terminal = view.terminal else { return Cursor() }
        let location = terminal.getCursorLocation()
        // SwiftTerm parks the cursor one past the last column while a wrap is pending.
        var result = Cursor(x: min(location.x, max(0, terminal.cols - 1)), y: location.y, visible: view.cursorVisible, shape: 0)
        if view.shapeSet {
            let style = view.cursorStyle
            if style == .steadyBlock { result.shape = 2 }
            else if style == .blinkUnderline { result.shape = 3 }
            else if style == .steadyUnderline { result.shape = 4 }
            else if style == .blinkBar { result.shape = 5 }
            else if style == .steadyBar { result.shape = 6 }
            else { result.shape = 1 }
        }
        return result
    }

    /// True when the tmux client enabled mouse reporting.
    func wantsMouse(_ id: String) -> Bool { (views[id]?.terminal.mouseMode ?? .off) != .off }

    /// Input for the view; each reports rendererInteracted.
    func sendKey(_ id: String, _ event: InputEvent) {
        guard let view = views[id], event.type == .key else { return }
        if event.key == .none || event.key == .menu { return }
        view.input.append(contentsOf: PaneEncoding.key(event, applicationCursor: view.terminal.applicationCursor))
        view.flushInput()
        delegate?.rendererInteracted(id)
    }

    func sendPaste(_ id: String, _ text: [UInt8]) {
        guard let view = views[id] else { return }
        view.input.append(contentsOf: PaneEncoding.paste(text, bracketed: view.terminal.bracketedPasteMode))
        view.flushInput()
        delegate?.rendererInteracted(id)
    }

    /// Coordinates are relative to the view's top-left cell. Press, Release
    /// and wheel actions report rendererInteracted. Follows libvterm's mouse
    /// state machine; SwiftTerm encodes the report in the client's protocol.
    func sendMouse(_ id: String, _ event: InputEvent, col: Int, row: Int) {
        guard let view = views[id], event.type == .mouse, let terminal = view.terminal else { return }
        let mode = terminal.mouseMode
        let x10 = mode == .x10
        let modifiers = x10 ? 0 : Int(event.modifiers.rawValue & 7) << 2
        func output(_ code: Int, pressed: Bool) {
            if mode == .off || (x10 && (!pressed || code & 0x20 != 0)) { return }
            // SwiftTerm encodes a release as button 3 (X10) or an SGR "m" report.
            terminal.sendEvent(buttonFlags: (pressed ? code : 3) | modifiers, x: view.mouseCol, y: view.mouseRow)
        }
        // Reports carry the last moved-to position, so every event moves first.
        if col != view.mouseCol || row != view.mouseRow {
            view.mouseCol = col
            view.mouseRow = row
            let drag = mode == .buttonEventTracking || mode == .anyEvent
            if (drag && view.mouseButtons != 0) || mode == .anyEvent {
                let buttons = view.mouseButtons
                let button = buttons & 1 != 0 ? 1 : buttons & 2 != 0 ? 2 : buttons & 4 != 0 ? 3 : 4
                output(button - 1 + 0x20, pressed: true)
            }
        }
        var button = 0
        var pressed = true
        switch event.action {
        case .press, .release:
            pressed = event.action == .press
            switch event.button {
            case .left: button = 1
            case .middle: button = 2
            case .right: button = 3
            case .none: button = 0
            }
        case .move: break
        case .wheelUp: button = 4
        case .wheelDown: button = 5
        case .wheelLeft: button = 6
        case .wheelRight: button = 7
        }
        if button != 0 {
            let old = view.mouseButtons
            if button <= 3 {
                if pressed { view.mouseButtons |= 1 << (button - 1) } else { view.mouseButtons &= ~(1 << (button - 1)) }
            }
            if !(view.mouseButtons == old && button < 4) {
                if button < 4 { output(button - 1, pressed: pressed) }
                else if pressed { output(button - 4 + 0x40, pressed: true) }
            }
        }
        view.flushInput()
        if button != 0 { delegate?.rendererInteracted(id) }
    }
}
