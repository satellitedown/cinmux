import Darwin
import Foundation

// Cell drawing for `cinmux tui`: a cell grid composed each frame, and the tty
// that presents it with minimal, synchronized updates.

enum TuiColor: Equatable {
    case `default`
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

struct TuiAttributes: OptionSet, Equatable {
    let rawValue: UInt16
    static let bold = TuiAttributes(rawValue: 1 << 0)
    static let faint = TuiAttributes(rawValue: 1 << 1)
    static let italic = TuiAttributes(rawValue: 1 << 2)
    static let underline = TuiAttributes(rawValue: 1 << 3)
    static let doubleUnderline = TuiAttributes(rawValue: 1 << 4)
    static let curlyUnderline = TuiAttributes(rawValue: 1 << 5)
    static let blink = TuiAttributes(rawValue: 1 << 6)
    static let reverse = TuiAttributes(rawValue: 1 << 7)
    static let conceal = TuiAttributes(rawValue: 1 << 8)
    static let strike = TuiAttributes(rawValue: 1 << 9)
}

struct TuiStyle: Equatable {
    var fg: TuiColor = .default
    var bg: TuiColor = .default
    var attributes: TuiAttributes = []
}

struct TuiCell: Equatable {
    static let maxChars = 4
    /// Base character followed by combining marks; unused entries are 0.
    var chars = SIMD4<UInt32>(0x20, 0, 0, 0)
    /// 1 or 2 for a leading cell; 0 for the right half of a wide character.
    var width: UInt8 = 1
    var style = TuiStyle()
}

/// Text written without a width limit (the Linux build's INT_MAX).
let unlimitedWidth = Int(Int32.max)

struct Surface {
    struct Cursor: Equatable {
        var x = 0
        var y = 0
        var visible = false
        /// DECSCUSR value: 0 default, 1...6.
        var shape = 0
    }

    private(set) var cols = 0
    private(set) var rows = 0
    private var cells: [TuiCell] = []
    var cursor = Cursor()

    mutating func resize(cols: Int, rows: Int) {
        self.cols = max(0, cols)
        self.rows = max(0, rows)
        cells = Array(repeating: TuiCell(), count: self.cols * self.rows)
    }

    func contains(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < cols && y < rows }

    subscript(x: Int, y: Int) -> TuiCell {
        get { cells[y * cols + x] }
        set { cells[y * cols + x] = newValue }
    }

    /// Fills the clipped rectangle with spaces in `style`.
    mutating func fill(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ style: TuiStyle) {
        var blank = TuiCell()
        blank.style = style
        let bottom = min(rows, y + height), right = min(cols, x + width)
        var row = max(0, y)
        while row < bottom {
            var col = max(0, x)
            while col < right {
                put(col, row, blank)
                col += 1
            }
            row += 1
        }
    }

    /// Writes text at (x, y), clipped to [x, x + maxWidth) and to the surface.
    /// Combining marks join the previous cell; a wide character that does not
    /// fit is replaced by a space; C0/C1 controls and DEL are drawn as U+FFFD
    /// so untrusted titles can never emit escape sequences. Returns the number
    /// of columns written.
    @discardableResult
    mutating func text(_ x: Int, _ y: Int, _ text: String, _ style: TuiStyle, _ maxWidth: Int = unlimitedWidth) -> Int {
        let rowVisible = y >= 0 && y < rows
        let end = min(x + max(0, maxWidth), max(cols, x))
        var col = x
        var previous = -1
        var cell = TuiCell()
        cell.style = style
        let blank = cell
        for scalar in text.unicodeScalars {
            var c = scalar.value
            if isControl(c) { c = 0xfffd }
            let w = charWidth(c)
            if w == 0 {
                if previous < 0 { continue }
                var joined = self[previous, y]
                for slot in 1..<TuiCell.maxChars where joined.chars[slot] == 0 {
                    joined.chars[slot] = c
                    self[previous, y] = joined
                    break
                }
                continue
            }
            if col + w > end {
                if col < end && rowVisible && col >= 0 { put(col, y, blank) }
                if col < end { col += 1 }
                break
            }
            previous = -1
            if rowVisible && col >= 0 {
                cell.chars[0] = c
                cell.width = UInt8(w)
                put(col, y, cell)
                if contains(col, y) { previous = col }
            } else if rowVisible && col + w > 0 {
                // The right half of a wide character straddling column 0.
                put(0, y, blank)
            }
            col += w
        }
        return col - x
    }

    /// Stores a cell; a width-2 cell also claims its right neighbour, and
    /// overwriting either half of an existing wide character blanks the other.
    mutating func put(_ x: Int, _ y: Int, _ cell: TuiCell) {
        guard contains(x, y) else { return }
        if cell.width == 2 && x + 1 >= cols {
            blankOtherHalf(x, y)
            var blank = TuiCell()
            blank.style = cell.style
            self[x, y] = blank
            return
        }
        blankOtherHalf(x, y)
        if cell.width == 2 { blankOtherHalf(x + 1, y) }
        self[x, y] = cell
        guard cell.width == 2 else { return }
        var continuation = TuiCell()
        continuation.chars = SIMD4<UInt32>(0, 0, 0, 0)
        continuation.width = 0
        continuation.style = cell.style
        self[x + 1, y] = continuation
    }

    private mutating func blankOtherHalf(_ col: Int, _ y: Int) {
        let current = self[col, y]
        var other = -1
        if current.width == 2 && col + 1 < cols && self[col + 1, y].width == 0 { other = col + 1 }
        else if current.width == 0 && col > 0 && self[col - 1, y].width == 2 { other = col - 1 }
        if other < 0 { return }
        var blank = TuiCell()
        blank.style = self[other, y].style
        self[other, y] = blank
    }

    /// Applies `change` to the style of every cell of the clipped rectangle.
    mutating func restyle(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ change: (inout TuiStyle) -> Void) {
        var row = max(0, y)
        while row < min(rows, y + height) {
            var col = max(0, x)
            while col < min(cols, x + width) {
                change(&cells[row * cols + col].style)
                col += 1
            }
            row += 1
        }
    }
}

// MARK: - Controlling terminal

private let enterSequence = "\u{1b}[?1049h\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1006h\u{1b}[?2004h\u{1b}[?1004h"
    + "\u{1b}[>1u\u{1b}[>4;2m\u{1b}[?u\u{1b}[c\u{1b}[H\u{1b}[2J"
private let leaveSequence = "\u{1b}[?2026l\u{1b}[<u\u{1b}[>4m\u{1b}[?1004l\u{1b}[?2004l\u{1b}[?1006l\u{1b}[?1003l\u{1b}[?1002l\u{1b}[?1000l"
    + "\u{1b}[0 q\u{1b}[0m\u{1b}[?25h\u{1b}[?1049l"

// Process-wide state for the signal and exit paths, which cannot reach the Tty
// object. Initialized by Tty.open() before any handler can run.
private var emergencyActive: Int32 = 0
private var emergencySaved = termios()
private let emergencyLeave: UnsafeMutableBufferPointer<UInt8> = {
    let bytes = Array(leaveSequence.utf8)
    let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bytes.count)
    _ = buffer.initialize(from: bytes)
    return buffer
}()
private var exitHandlerRegistered = false

private func writeFully(_ fd: Int32, _ data: UnsafeRawPointer, _ count: Int) {
    var pointer = data
    var remaining = count
    while remaining > 0 {
        let written = Darwin.write(fd, pointer, remaining)
        if written > 0 {
            pointer += written
            remaining -= written
            continue
        }
        if written < 0 && errno == EINTR { continue }
        if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            if poll(&descriptor, 1, -1) < 0 && errno != EINTR { return }
            continue
        }
        return
    }
}

private func emergencyRestore() {
    if emergencyActive == 0 { return }
    emergencyActive = 0
    if let base = emergencyLeave.baseAddress { writeFully(STDOUT_FILENO, base, emergencyLeave.count) }
    _ = tcsetattr(STDIN_FILENO, TCSANOW, &emergencySaved)
}

/// Forwarded signals are observed by dispatch sources; this handler only
/// replaces the default action. Unlike SIG_IGN, it resets to the default in
/// exec'd children.
private func forwardedSignal(_ number: Int32) {}

private func fatalSignal(_ number: Int32) {
    emergencyRestore()
    _ = signal(number, SIG_DFL)
    _ = raise(number)
}

private enum SignalDisposition { case forward, fatal, ignore }

// SIGTRAP joins the Linux build's fatal set: Swift runtime traps raise it on arm64.
private let ownedSignals: [(Int32, SignalDisposition)] = [
    (SIGWINCH, .forward), (SIGTERM, .forward), (SIGHUP, .forward), (SIGINT, .forward), (SIGQUIT, .forward),
    (SIGSEGV, .fatal), (SIGBUS, .fatal), (SIGFPE, .fatal), (SIGILL, .fatal), (SIGABRT, .fatal), (SIGTRAP, .fatal),
    (SIGPIPE, .ignore),
]
private var previousActions: [sigaction] = Array(repeating: sigaction(), count: ownedSignals.count)

private func installHandlers() {
    for index in ownedSignals.indices {
        // sigaction() zero-fills sa_mask: no signal is blocked while a handler runs.
        var action = sigaction()
        switch ownedSignals[index].1 {
        case .forward:
            action.__sigaction_u.__sa_handler = forwardedSignal
            action.sa_flags = SA_RESTART
        case .fatal:
            action.__sigaction_u.__sa_handler = fatalSignal
            action.sa_flags = 0
        case .ignore:
            action.__sigaction_u.__sa_handler = SIG_IGN
            action.sa_flags = 0
        }
        var previous = sigaction()
        _ = sigaction(ownedSignals[index].0, &action, &previous)
        previousActions[index] = previous
    }
}

private func restoreHandlers() {
    for index in ownedSignals.indices {
        var previous = previousActions[index]
        _ = sigaction(ownedSignals[index].0, &previous, nil)
    }
}

private func detectTruecolor() -> Bool {
    let environment = ProcessInfo.processInfo.environment
    let colors = (environment["CINMUX_TUI_COLORS"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if colors == "24bit" || colors == "truecolor" { return true }
    if colors == "256" { return false }
    let colorterm = (environment["COLORTERM"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if colorterm == "truecolor" || colorterm == "24bit" { return true }
    let term = (environment["TERM"] ?? "").lowercased()
    for name in ["direct", "kitty", "ghostty", "foot", "alacritty", "wezterm", "contour", "rio", "iterm"] where term.contains(name) {
        return true
    }
    return false
}

private func appendNumber(_ out: inout [UInt8], _ value: Int) { out.append(contentsOf: String(value).utf8) }

private func appendUtf8(_ out: inout [UInt8], _ value: UInt32) {
    var c = value
    if isControl(c) || (c >= 0xd800 && c < 0xe000) || c > 0x10ffff { c = 0xfffd }
    if c < 0x80 {
        out.append(UInt8(c))
    } else if c < 0x800 {
        out.append(UInt8(0xc0 | (c >> 6)))
        out.append(UInt8(0x80 | (c & 0x3f)))
    } else if c < 0x10000 {
        out.append(UInt8(0xe0 | (c >> 12)))
        out.append(UInt8(0x80 | ((c >> 6) & 0x3f)))
        out.append(UInt8(0x80 | (c & 0x3f)))
    } else {
        out.append(UInt8(0xf0 | (c >> 18)))
        out.append(UInt8(0x80 | ((c >> 12) & 0x3f)))
        out.append(UInt8(0x80 | ((c >> 6) & 0x3f)))
        out.append(UInt8(0x80 | (c & 0x3f)))
    }
}

func nearest256(_ red: Int, _ green: Int, _ blue: Int) -> Int {
    let levels = [0, 95, 135, 175, 215, 255]
    func level(_ value: Int) -> Int {
        var best = 0
        for i in 1..<6 where abs(value - levels[i]) < abs(value - levels[best]) { best = i }
        return best
    }
    func distance(_ r: Int, _ g: Int, _ b: Int) -> Int {
        (red - r) * (red - r) + (green - g) * (green - g) + (blue - b) * (blue - b)
    }
    let r = level(red), g = level(green), b = level(blue)
    // The squared distance to a gray is minimized by the gray nearest to the channel mean.
    let step = min(max(Int(((Double(red + green + blue) / 3.0 - 8.0) / 10.0).rounded()), 0), 23)
    let gray = 8 + 10 * step
    return distance(gray, gray, gray) < distance(levels[r], levels[g], levels[b]) ? 232 + step : 16 + 36 * r + 6 * g + b
}

private func appendColor(_ out: inout [UInt8], _ color: TuiColor, background: Bool, truecolor: Bool) {
    switch color {
    case .default:
        return
    case .indexed(let index):
        out.append(UInt8(ascii: ";"))
        if index < 8 { appendNumber(&out, (background ? 40 : 30) + Int(index)) }
        else if index < 16 { appendNumber(&out, (background ? 100 : 90) + Int(index) - 8) }
        else {
            out.append(contentsOf: (background ? "48;5;" : "38;5;").utf8)
            appendNumber(&out, Int(index))
        }
    case .rgb(let r, let g, let b):
        out.append(contentsOf: (background ? ";48;" : ";38;").utf8)
        if !truecolor {
            out.append(contentsOf: "5;".utf8)
            appendNumber(&out, nearest256(Int(r), Int(g), Int(b)))
            return
        }
        out.append(contentsOf: "2;".utf8)
        appendNumber(&out, Int(r))
        out.append(UInt8(ascii: ";"))
        appendNumber(&out, Int(g))
        out.append(UInt8(ascii: ";"))
        appendNumber(&out, Int(b))
    }
}

func appendStyle(_ out: inout [UInt8], _ style: TuiStyle, truecolor: Bool) {
    out.append(contentsOf: "\u{1b}[0".utf8)
    let a = style.attributes
    if a.contains(.bold) { out.append(contentsOf: ";1".utf8) }
    if a.contains(.faint) { out.append(contentsOf: ";2".utf8) }
    if a.contains(.italic) { out.append(contentsOf: ";3".utf8) }
    if a.contains(.curlyUnderline) { out.append(contentsOf: ";4:3".utf8) }
    else if a.contains(.doubleUnderline) { out.append(contentsOf: ";4:2".utf8) }
    else if a.contains(.underline) { out.append(contentsOf: ";4".utf8) }
    if a.contains(.blink) { out.append(contentsOf: ";5".utf8) }
    if a.contains(.reverse) { out.append(contentsOf: ";7".utf8) }
    if a.contains(.conceal) { out.append(contentsOf: ";8".utf8) }
    if a.contains(.strike) { out.append(contentsOf: ";9".utf8) }
    appendColor(&out, style.fg, background: false, truecolor: truecolor)
    appendColor(&out, style.bg, background: true, truecolor: truecolor)
    out.append(UInt8(ascii: "m"))
}

/// Owns the controlling terminal on stdin/stdout while the TUI runs.
@MainActor
final class Tty {
    private(set) var cols = 0
    private(set) var rows = 0
    /// 24-bit color output: CINMUX_TUI_COLORS=24bit|256 overrides; otherwise
    /// COLORTERM truecolor/24bit, or a TERM known to support direct color.
    private(set) var truecolor = false
    /// Called on the main queue for SIGWINCH, SIGTERM, SIGHUP, SIGINT and SIGQUIT.
    var onSignal: (@MainActor (Int32) -> Void)?

    private var isOpen = false
    private var saved = termios()
    private var previous = Surface()
    private var invalid = true
    private var cursor = Surface.Cursor()
    private var cursorKnown = false
    private var signalSources: [DispatchSourceSignal] = []

    /// Enters raw mode and the alternate screen; enables SGR any-event mouse
    /// reporting, bracketed paste, focus events, kitty keyboard flag 1
    /// (disambiguate) and xterm modifyOtherKeys 2; then queries `CSI ? u`
    /// followed by `CSI c`. Handles SIGWINCH/SIGTERM/SIGHUP/SIGINT/SIGQUIT
    /// through `onSignal`, ignores SIGPIPE, and restores the terminal on exit
    /// and on fatal signals. Fails unless stdin and stdout are terminals.
    /// Returns an error message on failure.
    func open() -> String? {
        if isOpen { return nil }
        if isatty(STDIN_FILENO) == 0 || isatty(STDOUT_FILENO) == 0 { return "cinmux tui requires an interactive terminal" }
        if tcgetattr(STDIN_FILENO, &saved) != 0 { return "Cannot read terminal attributes: \(String(cString: strerror(errno)))" }
        var raw = saved
        cfmakeraw(&raw)
        withUnsafeMutableBytes(of: &raw.c_cc) { bytes in
            bytes[Int(VMIN)] = 1
            bytes[Int(VTIME)] = 0
        }
        emergencySaved = saved
        _ = emergencyLeave.count
        if !exitHandlerRegistered { exitHandlerRegistered = atexit { emergencyRestore() } == 0 }
        installHandlers()
        if tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) != 0 {
            let savedErrno = errno
            restoreHandlers()
            return "Cannot enter raw mode: \(String(cString: strerror(savedErrno)))"
        }
        emergencyActive = 1
        isOpen = true
        for (number, disposition) in ownedSignals where disposition == .forward {
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.onSignal?(number) }
            }
            source.resume()
            signalSources.append(source)
        }
        write(Array(enterSequence.utf8))
        cols = 0
        rows = 0
        _ = updateSize()
        invalid = true
        cursorKnown = false
        truecolor = detectTruecolor()
        return nil
    }

    /// Leaves every mode enabled by open() and restores termios. Idempotent.
    func restore() {
        guard isOpen else { return }
        isOpen = false
        write(Array(leaveSequence.utf8))
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &saved)
        emergencyActive = 0
        for source in signalSources { source.cancel() }
        signalSources.removeAll()
        restoreHandlers()
    }

    /// Re-reads the window size; true when it changed.
    func updateSize() -> Bool {
        var size = winsize()
        let known = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0
        let newCols = known && size.ws_col > 0 ? Int(size.ws_col) : 80
        let newRows = known && size.ws_row > 0 ? Int(size.ws_row) : 24
        if newCols == cols && newRows == rows { return false }
        cols = newCols
        rows = newRows
        invalid = true
        return true
    }

    func invalidate() { invalid = true }

    /// Writes raw bytes (OSC 52, BEL) to the terminal.
    func write(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress { writeFully(STDOUT_FILENO, base, buffer.count) }
        }
    }

    /// Emits the difference from the previously presented frame (everything
    /// after invalidate() or a size change) inside a synchronized update, then
    /// positions/shapes/shows the cursor per `frame.cursor`. RGB colors are
    /// mapped to the xterm 256-color palette unless truecolor.
    func present(_ frame: Surface) {
        guard isOpen else { return }
        var out: [UInt8] = []
        out.reserveCapacity(frame.cols * frame.rows * 4 + 64)
        out.append(contentsOf: "\u{1b}[?2026h\u{1b}[?25l".utf8)
        let full = invalid || frame.cols != previous.cols || frame.rows != previous.rows
        var cursorX = -1
        var cursorY = -1
        if full {
            out.append(contentsOf: "\u{1b}[0m\u{1b}[H\u{1b}[2J".utf8)
            cursorX = 0
            cursorY = 0
        }
        var pen = TuiStyle()
        let width = min(frame.cols, cols)
        let height = min(frame.rows, rows)
        for y in 0..<max(0, height) {
            var x = 0
            while x < width {
                let cell = frame[x, y]
                let changed = full || cell != previous[x, y]
                var wide = false
                if cell.width == 2 && x + 1 < width && frame[x + 1, y].width == 0 {
                    wide = true
                    if !changed && frame[x + 1, y] == previous[x + 1, y] {
                        x += 2
                        continue
                    }
                } else if cell.width == 0 {
                    if x > 0 && frame[x - 1, y].width == 2 {
                        x += 1
                        continue
                    }
                    // Rewriting the left neighbour may have erased this orphan half on the terminal.
                    if !changed && (x == 0 || frame[x - 1, y] == previous[x - 1, y]) {
                        x += 1
                        continue
                    }
                } else if !changed {
                    x += 1
                    continue
                }
                if x != cursorX || y != cursorY {
                    out.append(contentsOf: "\u{1b}[".utf8)
                    appendNumber(&out, y + 1)
                    out.append(UInt8(ascii: ";"))
                    appendNumber(&out, x + 1)
                    out.append(UInt8(ascii: "H"))
                }
                if cell.style != pen {
                    appendStyle(&out, cell.style, truecolor: truecolor)
                    pen = cell.style
                }
                if cell.width == 1 && cell.chars[0] != 0 {
                    for i in 0..<TuiCell.maxChars where cell.chars[i] != 0 { appendUtf8(&out, cell.chars[i]) }
                    cursorX = x + 1
                } else if wide {
                    for i in 0..<TuiCell.maxChars where cell.chars[i] != 0 { appendUtf8(&out, cell.chars[i]) }
                    // Terminals disagree about the width of some wide characters; re-anchor the next write.
                    cursorX = -1
                    x += 1
                } else {
                    out.append(0x20)
                    cursorX = x + 1
                }
                cursorY = y
                x += 1
            }
        }
        out.append(contentsOf: "\u{1b}[0m".utf8)
        if frame.cursor.visible {
            out.append(contentsOf: "\u{1b}[".utf8)
            appendNumber(&out, max(0, frame.cursor.y) + 1)
            out.append(UInt8(ascii: ";"))
            appendNumber(&out, max(0, frame.cursor.x) + 1)
            out.append(UInt8(ascii: "H"))
            if !cursorKnown || cursor.shape != frame.cursor.shape {
                out.append(contentsOf: "\u{1b}[".utf8)
                appendNumber(&out, frame.cursor.shape)
                out.append(contentsOf: " q".utf8)
                cursor = frame.cursor
                cursorKnown = true
            }
            out.append(contentsOf: "\u{1b}[?25h".utf8)
        }
        out.append(contentsOf: "\u{1b}[?2026l".utf8)
        write(out)
        previous = frame
        invalid = false
    }
}
