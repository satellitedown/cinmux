import Darwin
import Foundation

struct RGB: Equatable {
    var r: Int
    var g: Int
    var b: Int

    /// Qt's qRound for the non-negative channel values mixed here.
    static func rounded(_ value: Double) -> Int { Int((value + 0.5).rounded(.down)) }
}

func mix(_ a: RGB, _ b: RGB, _ amount: Double) -> RGB {
    RGB(r: RGB.rounded(Double(a.r) + Double(b.r - a.r) * amount),
        g: RGB.rounded(Double(a.g) + Double(b.g - a.g) * amount),
        b: RGB.rounded(Double(a.b) + Double(b.b - a.b) * amount))
}

/// The colors `cinmux tui` takes from the shared theme (src/theme.cpp).
struct ThemePalette: Equatable {
    var mode: String
    var bg: RGB
    var bgRaised: RGB
    var accent: RGB
    var danger: RGB
    var warning: RGB
    var onAccent: RGB
    var selectionBg: RGB
    var selectionText: RGB

    static let `default` = ThemePalette(
        mode: "dark", bg: RGB(r: 0x15, g: 0x17, b: 0x19), bgRaised: RGB(r: 0x1d, g: 0x20, b: 0x23),
        accent: RGB(r: 0xa3, g: 0xbe, b: 0x78), danger: RGB(r: 0xe5, g: 0x64, b: 0x4e), warning: RGB(r: 0xd9, g: 0xa0, b: 0x6b),
        onAccent: RGB(r: 0x1c, g: 0x1d, b: 0x20), selectionBg: RGB(r: 0xa3, g: 0xbe, b: 0x78), selectionText: RGB(r: 0x1c, g: 0x1d, b: 0x20))

    /// Black or white, whichever contrasts more with `color` (WCAG luminance).
    static func onColor(_ color: RGB) -> RGB {
        func linear(_ channel: Int) -> Double {
            let s = Double(channel) / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
        return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05) ? RGB(r: 0, g: 0, b: 0) : RGB(r: 255, g: 255, b: 255)
    }

    static func hex(_ text: String) -> RGB? {
        var digits = Array(text.utf8)
        guard digits.first == UInt8(ascii: "#"), digits.count == 4 || digits.count == 7 else { return nil }
        digits.removeFirst()
        guard digits.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) }) else { return nil }
        if digits.count == 3 { digits = digits.flatMap { [$0, $0] } }
        guard let value = Int(String(decoding: digits, as: UTF8.self), radix: 16) else { return nil }
        return RGB(r: (value >> 16) & 0xff, g: (value >> 8) & 0xff, b: value & 0xff)
    }

    /// Reads an Omarchy colors.toml; nil when it lacks a background and foreground.
    static func parse(_ data: Data, lightMarker: Bool) -> ThemePalette? {
        if data.count > 65536 { return nil }
        guard let table = TomlStrings.parse(data) else { return nil }
        func pick(_ keys: [String]) -> RGB? {
            for key in keys { if let raw = table[key], let color = hex(raw) { return color } }
            return nil
        }
        guard let bg = pick(["background", "bg", "color0"]), let fg = pick(["foreground", "fg", "color7"]) else { return nil }
        var mode = ""
        for key in ["mode", "theme_type"] {
            if let raw = table[key], raw == "light" || raw == "dark" {
                mode = raw
                break
            }
        }
        if mode.isEmpty { mode = lightMarker || bg.r + bg.g + bg.b > 382 ? "light" : "dark" }
        let dark = mode == "dark"
        let accent = pick(["accent", "blue", "color4"]) ?? fg
        let selection = pick(["selection_background", "selection"]) ?? accent
        return ThemePalette(
            mode: mode, bg: bg, bgRaised: pick(["lighter_background", "lighter_bg"]) ?? mix(bg, fg, 0.05), accent: accent,
            danger: pick(["red", "color1"]) ?? (dark ? RGB(r: 0xe5, g: 0x64, b: 0x4e) : RGB(r: 0xb4, g: 0x23, b: 0x18)),
            warning: pick(["orange", "yellow", "color3"]) ?? (dark ? RGB(r: 0xd9, g: 0xa0, b: 0x6b) : RGB(r: 0x98, g: 0x60, b: 0x00)),
            onAccent: onColor(accent), selectionBg: selection, selectionText: pick(["selection_foreground"]) ?? onColor(selection))
    }
}

/// The top-level string values of a TOML document, which is all a theme's
/// colors.toml needs. Keys inside tables are not top-level and are skipped;
/// nil for a line that is neither a table header, a comment nor `key = value`.
enum TomlStrings {
    static func parse(_ data: Data) -> [String: String]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        var inTable = false
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = Array(rawLine.unicodeScalars)
            var i = 0
            func skipSpace() { while i < line.count && (line[i] == " " || line[i] == "\t" || line[i] == "\r") { i += 1 } }
            skipSpace()
            if i == line.count || line[i] == "#" { continue }
            if line[i] == "[" {
                inTable = true
                continue
            }
            // Key: bare, or quoted.
            var key = ""
            if line[i] == "\"" || line[i] == "'" {
                guard let parsed = quoted(line, i) else { return nil }
                key = parsed.value
                i = parsed.end
            } else {
                let start = i
                while i < line.count, isBareKey(line[i]) { i += 1 }
                if i == start { return nil }
                key = String(scalars: line[start..<i])
            }
            skipSpace()
            // Dotted keys name nested tables, never top-level strings.
            if i < line.count && line[i] == "." { continue }
            guard i < line.count, line[i] == "=" else { return nil }
            i += 1
            skipSpace()
            guard i < line.count else { return nil }
            if line[i] == "\"" || line[i] == "'" {
                guard let parsed = quoted(line, i) else { return nil }
                if !inTable { values[key] = parsed.value }
            }
            // Other value types (numbers, booleans, arrays, inline tables) are not colors.
        }
        return values
    }

    private static func isBareKey(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_" || c == "-"
    }

    /// A basic ("…" with escapes) or literal ('…') string starting at `start`.
    private static func quoted(_ line: [Unicode.Scalar], _ start: Int) -> (value: String, end: Int)? {
        let quote = line[start]
        var i = start + 1
        var value = String.UnicodeScalarView()
        while i < line.count {
            let c = line[i]
            if c == quote { return (value: String(value), end: i + 1) }
            if quote == "\"" && c == "\\" {
                i += 1
                guard i < line.count else { return nil }
                switch line[i] {
                case "n": value.append("\n")
                case "t": value.append("\t")
                case "r": value.append("\r")
                case "\"": value.append("\"")
                case "\\": value.append("\\")
                default: value.append(line[i])
                }
            } else {
                value.append(c)
            }
            i += 1
        }
        return nil
    }
}

/// Follows the Omarchy theme (or CINMUX_THEME_DIR), re-reading it every second.
@MainActor
final class TuiTheme {
    private(set) var palette = ThemePalette.default
    var onChange: (@MainActor () -> Void)?
    private var directory = ""
    private var timer: DispatchSourceTimer?

    init() {
        directory = ProcessInfo.processInfo.environment["CINMUX_THEME_DIR"] ?? ""
        if !directory.isEmpty && !directory.hasPrefix("/") {
            FileHandle.standardError.write(Data("cinmux: CINMUX_THEME_DIR must be absolute; using default palette\n".utf8))
            return
        }
        if directory.isEmpty {
            var state = ProcessInfo.processInfo.environment["XDG_STATE_HOME"] ?? ""
            if state.isEmpty { state = NSHomeDirectory() + "/.local/state" }
            directory = state + "/omarchy/current/theme"
        }
        refresh()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        timer.resume()
        self.timer = timer
    }

    private static func isFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    func refresh() {
        let path = directory + "/colors.toml"
        guard Self.isFile(path), let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65537), data.count <= 65536 else { return }
        if let next = ThemePalette.parse(data, lightMarker: Self.isFile(directory + "/light.mode")), next != palette {
            palette = next
            onChange?()
        }
    }
}

/// Mirrors qml/Theme.qml: fixed text colors per mode, translucent overlays
/// flattened onto the theme background.
struct Palette {
    var overlay = 0.45
    var chrome = TuiColor.default, terminal = TuiColor.default, raised = TuiColor.default, raisedHover = TuiColor.default
    var raisedBorder = TuiColor.default, hover = TuiColor.default, border = TuiColor.default, text = TuiColor.default
    var muted = TuiColor.default, accent = TuiColor.default, accentDim = TuiColor.default, selected = TuiColor.default
    var danger = TuiColor.default, dangerDim = TuiColor.default, warning = TuiColor.default, onAccent = TuiColor.default
    var onDanger = TuiColor.default, selectionBg = TuiColor.default, selectionText = TuiColor.default

    static func rgb(_ color: RGB) -> TuiColor { .rgb(UInt8(clamping: color.r), UInt8(clamping: color.g), UInt8(clamping: color.b)) }

    /// Black or white text for a colored background (the TUI's own rule, not the theme's).
    static func onColor(_ color: RGB) -> RGB {
        color.r * 299 + color.g * 587 + color.b * 114 > 150000 ? RGB(r: 0, g: 0, b: 0) : RGB(r: 255, g: 255, b: 255)
    }

    init() {}

    init(_ theme: ThemePalette) {
        let dark = theme.mode != "light"
        let bg = theme.bg
        let text = dark ? RGB(r: 0xed, g: 0xed, b: 0xee) : RGB(r: 0x25, g: 0x25, b: 0x28)
        let muted = dark ? RGB(r: 0xaa, g: 0xaa, b: 0xb0) : RGB(r: 0x66, g: 0x66, b: 0x6e)
        let raised = mix(dark ? RGB(r: 0x2b, g: 0x2b, b: 0x2e) : RGB(r: 255, g: 255, b: 255), theme.bgRaised, 0.035)
        overlay = dark ? 0.45 : 0.30
        chrome = Self.rgb(bg)
        terminal = Self.rgb(bg)
        self.raised = Self.rgb(raised)
        raisedHover = Self.rgb(mix(raised, text, dark ? 0.08 : 0.06))
        raisedBorder = Self.rgb(mix(raised, text, dark ? 0.16 : 0.18))
        hover = Self.rgb(mix(bg, text, dark ? 0.055 : 0.045))
        border = Self.rgb(mix(bg, text, dark ? 0.10 : 0.11))
        self.text = Self.rgb(text)
        self.muted = Self.rgb(muted)
        accent = Self.rgb(theme.accent)
        accentDim = Self.rgb(mix(bg, theme.accent, 0.12))
        selected = Self.rgb(mix(bg, text, dark ? 0.10 : 0.075))
        danger = Self.rgb(theme.danger)
        dangerDim = Self.rgb(mix(raised, theme.danger, 0.10))
        warning = Self.rgb(theme.warning)
        onAccent = Self.rgb(theme.onAccent)
        onDanger = Self.rgb(Self.onColor(theme.danger))
        selectionBg = Self.rgb(theme.selectionBg)
        selectionText = Self.rgb(theme.selectionText)
    }
}

func toward(_ color: TuiColor, _ target: TuiColor, _ amount: Double) -> TuiColor {
    guard case let .rgb(r, g, b) = color, case let .rgb(tr, tg, tb) = target else { return color }
    return Palette.rgb(mix(RGB(r: Int(r), g: Int(g), b: Int(b)), RGB(r: Int(tr), g: Int(tg), b: Int(tb)), amount))
}

func darken(_ color: TuiColor, _ amount: Double) -> TuiColor { toward(color, .rgb(0, 0, 0), amount) }
