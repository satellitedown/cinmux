import CinmuxCore
import Darwin
import Foundation

/// A single-line text field: emacs-style editing on Unicode scalars.
struct LineEdit {
    enum Result { case ignored, moved, changed }

    private(set) var scalars: [Unicode.Scalar] = []
    var cursor = 0
    /// The whole text is selected; typing replaces it.
    var selected = false

    var text: String { String(scalars: scalars) }
    var isEmpty: Bool { scalars.isEmpty }

    mutating func set(_ value: String, select: Bool = false) {
        scalars = Array(value.unicodeScalars)
        cursor = scalars.count
        selected = select && !scalars.isEmpty
    }

    mutating func insert(_ value: String) {
        var inserted: [Unicode.Scalar] = []
        for scalar in value.unicodeScalars {
            if scalar == "\r" { continue }
            inserted.append(scalar == "\t" || scalar == "\n" ? " " : scalar)
        }
        if selected {
            scalars.removeAll()
            cursor = 0
            selected = false
        }
        scalars.insert(contentsOf: inserted, at: cursor)
        cursor += inserted.count
    }

    /// The text between two scalar offsets.
    func slice(_ from: Int, _ to: Int) -> String { String(scalars: scalars[max(0, from)..<min(scalars.count, max(from, to))]) }

    func previous(_ i: Int) -> Int { max(0, i - 1) }
    func next(_ i: Int) -> Int { min(scalars.count, i + 1) }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.isWhitespace }

    func wordStart(_ from: Int) -> Int {
        var i = from
        while i > 0 && Self.isSpace(scalars[i - 1]) { i -= 1 }
        while i > 0 && !Self.isSpace(scalars[i - 1]) { i -= 1 }
        return i
    }

    func wordEnd(_ from: Int) -> Int {
        var i = from
        while i < scalars.count && Self.isSpace(scalars[i]) { i += 1 }
        while i < scalars.count && !Self.isSpace(scalars[i]) { i += 1 }
        return i
    }

    private mutating func move(_ to: Int) -> Result {
        cursor = to
        selected = false
        return .moved
    }

    private mutating func erase(_ from: Int, _ to: Int) -> Result {
        if selected {
            scalars.removeAll()
            cursor = 0
            selected = false
            return .changed
        }
        if from >= to { return .moved }
        scalars.removeSubrange(from..<to)
        cursor = from
        return .changed
    }

    mutating func handle(_ e: InputEvent) -> Result {
        let mods = e.modifiers.intersection([.ctrl, .alt])
        let size = scalars.count
        switch e.key {
        case .character:
            if mods.isEmpty {
                if let scalar = Unicode.Scalar(e.codepoint) { insert(String(scalar)) }
                return .changed
            }
            if mods == .ctrl {
                switch e.codepoint {
                case 0x61: return move(0)                          // a
                case 0x65: return move(size)                       // e
                case 0x62: return move(previous(cursor))           // b
                case 0x66: return move(next(cursor))               // f
                case 0x75: return erase(0, cursor)                 // u
                case 0x6b: return erase(cursor, size)              // k
                case 0x77: return erase(wordStart(cursor), cursor) // w
                case 0x68: return erase(previous(cursor), cursor)  // h
                case 0x64: return erase(cursor, next(cursor))      // d
                default: return .ignored
                }
            }
            if mods == .alt {
                switch e.codepoint {
                case 0x62: return move(wordStart(cursor))          // b
                case 0x66: return move(wordEnd(cursor))            // f
                case 0x64: return erase(cursor, wordEnd(cursor))   // d
                default: return .ignored
                }
            }
            return .ignored
        case .backspace: return mods.isEmpty ? erase(previous(cursor), cursor) : erase(wordStart(cursor), cursor)
        case .delete: return mods.isEmpty ? erase(cursor, next(cursor)) : erase(cursor, wordEnd(cursor))
        case .left: return move(mods.isEmpty ? previous(cursor) : wordStart(cursor))
        case .right: return move(mods.isEmpty ? next(cursor) : wordEnd(cursor))
        case .home: return move(0)
        case .end: return move(size)
        default: return .ignored
        }
    }
}

/// A main-queue timer with QTimer's single-shot/repeating semantics.
@MainActor
final class TuiTimer {
    private let repeating: Bool
    private let handler: @MainActor () -> Void
    private var source: DispatchSourceTimer?

    init(repeating: Bool = false, _ handler: @escaping @MainActor () -> Void) {
        self.repeating = repeating
        self.handler = handler
    }

    var isActive: Bool { source != nil }

    func start(_ milliseconds: Int) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = DispatchTimeInterval.milliseconds(max(0, milliseconds))
        timer.schedule(deadline: .now() + interval, repeating: repeating ? interval : .never, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.fire() } }
        timer.resume()
        source = timer
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func fire() {
        guard source != nil else { return }
        if !repeating { stop() }
        handler()
    }
}

// MARK: - Directory input

/// `~` expansion and path cleanup for a typed directory.
func expandPath(_ input: String) -> String {
    var path = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if path == "~" { return NSHomeDirectory() }
    if path.hasPrefix("~/") { path = NSHomeDirectory() + String(path.dropFirst()) }
    return path.hasPrefix("/") ? Paths.clean(path) : path
}

private func isDirectory(_ path: String) -> Bool {
    var info = stat()
    return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
}

/// The nearest existing directory at or above `path`, with a trailing slash.
func existingDirectory(_ path: String) -> String {
    var current = path.hasPrefix("/") ? Paths.clean(path) : NSHomeDirectory()
    while !isDirectory(current) && current != "/" { current = (current as NSString).deletingLastPathComponent }
    return current == "/" ? current : current + "/"
}

/// Shell-style completion of the last path component to a directory.
func completeDirectory(_ edit: inout LineEdit) -> Bool {
    let text = edit.scalars
    guard let slash = text.lastIndex(of: "/") else { return false }
    let parent = String(scalars: text[...slash])
    let prefix = Array(text[(slash + 1)...])
    let directory = expandPath(parent)
    let hidden = prefix.first == "."
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    var matches: [[Unicode.Scalar]] = []
    for name in names {
        let scalars = Array(name.unicodeScalars)
        if scalars.first == "." && !hidden { continue }
        guard scalars.starts(with: prefix), isDirectory((directory as NSString).appendingPathComponent(name)) else { continue }
        matches.append(scalars)
    }
    guard var common = matches.first else { return false }
    for name in matches {
        var length = 0
        while length < common.count && length < name.count && common[length] == name[length] { length += 1 }
        common.removeSubrange(length...)
    }
    if matches.count == 1 { common.append("/") }
    if common.count <= prefix.count && matches.count > 1 { return false }
    edit.set(parent + String(scalars: common))
    return true
}
