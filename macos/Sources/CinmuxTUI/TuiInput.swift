// Decodes the byte stream a terminal sends to `cinmux tui` in raw mode.

struct KeyModifiers: OptionSet, Hashable {
    let rawValue: UInt8
    static let shift = KeyModifiers(rawValue: 1)
    static let alt = KeyModifiers(rawValue: 2)
    static let ctrl = KeyModifiers(rawValue: 4)
}

enum Key: Equatable {
    case none
    /// `codepoint` holds the Unicode scalar value.
    case character
    case enter, tab, backspace, escape, up, down, left, right, insert, delete, home, end, pageUp, pageDown
    /// `function` holds 1...35 (F1...F35).
    case function
    case menu
}

enum MouseAction: Equatable { case press, release, move, wheelUp, wheelDown, wheelLeft, wheelRight }
enum MouseButton: Equatable { case none, left, middle, right }

struct InputEvent: Equatable {
    enum Kind: Equatable {
        case key, mouse, paste, focusIn, focusOut
        /// Reply to the kitty keyboard query `CSI ? u`.
        case keyboardFlags
        /// Reply to `CSI c`.
        case primaryAttributes
    }
    var type: Kind = .key
    // Key. Character events: typed text carries its shifted character and no
    // Shift modifier ('A', not Shift+'a'). Ctrl letters are lowercase ('r'
    // with Ctrl for 0x12). Disambiguated reports (kitty `CSI … u`, xterm
    // modifyOtherKeys `CSI 27;…~`) keep every reported modifier, e.g.
    // Ctrl+Shift+'n'. A lone ESC prefix adds Alt to the following key.
    var key: Key = .none
    var codepoint: UInt32 = 0
    var function = 0
    var modifiers: KeyModifiers = []
    // Mouse (SGR 1006). Press/Release carry the button; Move carries the held
    // button (drag) or none (hover). Coordinates are zero-based cells.
    var action: MouseAction = .move
    var button: MouseButton = .none
    var x = 0
    var y = 0
    /// Paste: raw bytes between `CSI 200~` and `CSI 201~`.
    var text: [UInt8] = []
    /// KeyboardFlags: reported flags.
    var flags = 0
}

private let pasteEnd: [UInt8] = Array("\u{1b}[201~".utf8)
private let replacement: UInt32 = 0xfffd

private struct Sink {
    var events: [InputEvent] = []
    let final: Bool
    var pasteStarted = false
}

/// A window into the parser's buffer: `p[k]` is the k-th byte of the token.
private struct Bytes {
    let data: [UInt8]
    let start: Int
    let count: Int
    subscript(_ k: Int) -> UInt8 { data[start + k] }
    func dropFirst() -> Bytes { Bytes(data: data, start: start + 1, count: count - 1) }
}

private struct Csi {
    static let maxParams = 8
    var marker: UInt8 = 0
    var final: UInt8 = 0
    var intermediate = false
    var irregular = false
    var count = 0
    var value = [Int](repeating: 0, count: Csi.maxParams)
    var sub = [Int](repeating: 0, count: Csi.maxParams)
    func param(_ index: Int, _ fallback: Int = 0) -> Int { index < count && value[index] > 0 ? value[index] : fallback }
}

private func keyEvent(_ key: Key, _ modifiers: KeyModifiers = []) -> InputEvent {
    var event = InputEvent()
    event.key = key
    event.modifiers = modifiers
    return event
}

private func characterEvent(_ codepoint: UInt32, _ modifiers: KeyModifiers = []) -> InputEvent {
    var event = keyEvent(.character, modifiers)
    event.codepoint = codepoint
    return event
}

private func functionEvent(_ number: Int) -> InputEvent {
    var event = keyEvent(.function)
    event.function = number
    return event
}

private func typeEvent(_ type: InputEvent.Kind) -> InputEvent {
    var event = InputEvent()
    event.type = type
    return event
}

private func modifiersFrom(_ parameter: Int) -> KeyModifiers {
    if parameter < 2 { return [] }
    let bits = parameter - 1
    return KeyModifiers(rawValue: UInt8((bits & 7) | (bits & 32 != 0 ? 2 : 0)))
}

private func controlEvent(_ byte: UInt8) -> InputEvent {
    switch byte {
    case 0x00: return characterEvent(0x20, .ctrl)
    case 0x09: return keyEvent(.tab)
    case 0x0d: return keyEvent(.enter)
    case 0x1b: return keyEvent(.escape)
    case 0x7f: return keyEvent(.backspace)
    default: break
    }
    if byte <= 0x1a { return characterEvent(0x61 + UInt32(byte) - 1, .ctrl) }
    let punctuation: [UInt32] = [0x5c, 0x5d, 0x5e, 0x5f] // \ ] ^ _
    return characterEvent(punctuation[Int(byte) - 0x1c], .ctrl)
}

private func letterKey(_ final: UInt8) -> InputEvent? {
    switch final {
    case UInt8(ascii: "A"): return keyEvent(.up)
    case UInt8(ascii: "B"): return keyEvent(.down)
    case UInt8(ascii: "C"): return keyEvent(.right)
    case UInt8(ascii: "D"): return keyEvent(.left)
    case UInt8(ascii: "H"): return keyEvent(.home)
    case UInt8(ascii: "F"): return keyEvent(.end)
    case UInt8(ascii: "P"), UInt8(ascii: "Q"), UInt8(ascii: "R"), UInt8(ascii: "S"):
        return functionEvent(Int(final) - Int(UInt8(ascii: "P")) + 1)
    default: return nil
    }
}

private func tildeKey(_ number: Int) -> InputEvent? {
    switch number {
    case 1, 7: return keyEvent(.home)
    case 2: return keyEvent(.insert)
    case 3: return keyEvent(.delete)
    case 4, 8: return keyEvent(.end)
    case 5: return keyEvent(.pageUp)
    case 6: return keyEvent(.pageDown)
    case 29: return keyEvent(.menu)
    default: break
    }
    if number >= 11 && number <= 15 { return functionEvent(number - 10) }
    if number >= 17 && number <= 21 { return functionEvent(number - 11) }
    if number == 23 || number == 24 { return functionEvent(number - 12) }
    return nil
}

/// Kitty encodes keys without a Unicode value as private-use codepoints.
private func kittyKey(_ codepoint: Int) -> InputEvent? {
    if codepoint >= 57399 && codepoint <= 57408 { return characterEvent(0x30 + UInt32(codepoint - 57399)) }
    if codepoint >= 57376 && codepoint <= 57398 { return functionEvent(codepoint - 57376 + 13) }
    switch codepoint {
    case 57363: return keyEvent(.menu)
    case 57409: return characterEvent(UInt32(UInt8(ascii: ".")))
    case 57410: return characterEvent(UInt32(UInt8(ascii: "/")))
    case 57411: return characterEvent(UInt32(UInt8(ascii: "*")))
    case 57412: return characterEvent(UInt32(UInt8(ascii: "-")))
    case 57413: return characterEvent(UInt32(UInt8(ascii: "+")))
    case 57414: return keyEvent(.enter)
    case 57415: return characterEvent(UInt32(UInt8(ascii: "=")))
    case 57416: return characterEvent(UInt32(UInt8(ascii: ",")))
    case 57417: return keyEvent(.left)
    case 57418: return keyEvent(.right)
    case 57419: return keyEvent(.up)
    case 57420: return keyEvent(.down)
    case 57421: return keyEvent(.pageUp)
    case 57422: return keyEvent(.pageDown)
    case 57423: return keyEvent(.home)
    case 57424: return keyEvent(.end)
    case 57425: return keyEvent(.insert)
    case 57426: return keyEvent(.delete)
    default: return nil
    }
}

/// Disambiguated reports carry the unshifted key, so Shift alone on a
/// printable key is ordinary typed text.
private func codepointKey(_ codepoint: Int, _ modifiers: KeyModifiers) -> InputEvent? {
    if codepoint <= 0 || codepoint > 0x10ffff || (codepoint >= 0x80 && codepoint < 0xa0) || (codepoint >= 0xd800 && codepoint < 0xe000) {
        return nil
    }
    var event: InputEvent?
    if codepoint < 0x20 || codepoint == 0x7f { event = controlEvent(UInt8(codepoint)) }
    else if codepoint >= 0xe000 && codepoint <= 0xf8ff { event = kittyKey(codepoint) }
    else { event = characterEvent(UInt32(codepoint)) }
    guard var result = event else { return nil }
    if result.key == .character && result.modifiers.isEmpty && modifiers == .shift {
        if result.codepoint >= 0x61 && result.codepoint <= 0x7a { result.codepoint -= 0x20 }
        return result
    }
    result.modifiers.formUnion(modifiers)
    return result
}

private func mouseEvent(_ code: Int, _ x: Int, _ y: Int, release: Bool) -> InputEvent? {
    if code < 0 || code & 128 != 0 { return nil }
    let buttons: [MouseButton] = [.left, .middle, .right, .none]
    let wheels: [MouseAction] = [.wheelUp, .wheelDown, .wheelLeft, .wheelRight]
    var event = InputEvent()
    event.type = .mouse
    var modifiers: KeyModifiers = []
    if code & 4 != 0 { modifiers.insert(.shift) }
    if code & 8 != 0 { modifiers.insert(.alt) }
    if code & 16 != 0 { modifiers.insert(.ctrl) }
    event.modifiers = modifiers
    event.x = max(x, 0)
    event.y = max(y, 0)
    let base = code & 3
    if code & 64 != 0 {
        if release { return nil }
        event.action = wheels[base]
        return event
    }
    event.button = buttons[base]
    if code & 32 != 0 { event.action = .move }
    else { event.action = release || base == 3 ? .release : .press }
    return event
}

private func dispatchCsi(_ csi: Csi, _ sink: inout Sink) {
    if csi.marker == UInt8(ascii: "<") {
        if (csi.final == UInt8(ascii: "M") || csi.final == UInt8(ascii: "m")) && csi.count >= 3,
           let event = mouseEvent(csi.value[0], csi.value[1] - 1, csi.value[2] - 1, release: csi.final == UInt8(ascii: "m")) {
            sink.events.append(event)
        }
        return
    }
    if csi.marker == UInt8(ascii: "?") {
        if csi.final == UInt8(ascii: "u") {
            var event = typeEvent(.keyboardFlags)
            event.flags = csi.param(0)
            sink.events.append(event)
        } else if csi.final == UInt8(ascii: "c") {
            sink.events.append(typeEvent(.primaryAttributes))
        }
        return
    }
    // Kitty marks key releases with event type 3 after the modifiers.
    if csi.marker != 0 || csi.sub[1] == 3 { return }
    let modifiers = modifiersFrom(csi.param(1))
    var event: InputEvent?
    switch csi.final {
    case UInt8(ascii: "u"):
        event = codepointKey(csi.param(0), modifiers)
    case UInt8(ascii: "~"):
        if csi.param(0) == 200 { sink.pasteStarted = true }
        else if csi.param(0) == 27 && csi.count >= 3 { event = codepointKey(csi.param(2), modifiers) }
        else if var key = tildeKey(csi.param(0)) {
            key.modifiers = modifiers
            event = key
        }
    case UInt8(ascii: "Z"):
        event = keyEvent(.tab, modifiers.union(.shift))
    case UInt8(ascii: "I"):
        event = typeEvent(.focusIn)
    case UInt8(ascii: "O"):
        event = typeEvent(.focusOut)
    default:
        // Cursor position reports share F3's final; key reports only use a first parameter of 1.
        if csi.count <= 2 && csi.param(0, 1) == 1, var key = letterKey(csi.final) {
            key.modifiers = modifiers
            event = key
        }
    }
    if let event { sink.events.append(event) }
}

/// `ESC [`, `ESC O` and string introducers not followed by a sequence are Alt+key.
private func altIntroducer(_ p: Bytes, _ sink: inout Sink) -> Int {
    sink.events.append(characterEvent(UInt32(p[1]), .alt))
    return 2
}

private func parseCsi(_ p: Bytes, _ sink: inout Sink) -> Int {
    let n = p.count
    if n == 2 { return sink.final ? altIntroducer(p, &sink) : 0 }
    if p[2] == UInt8(ascii: "M") {
        if n < 6 { return sink.final ? n : 0 }
        if let event = mouseEvent(Int(p[3]) - 32, Int(p[4]) - 33, Int(p[5]) - 33, release: false) { sink.events.append(event) }
        return 6
    }
    var csi = Csi()
    var index = 0
    var subIndex = 0
    var parameters = false
    var j = 2
    while j < n {
        let c = p[j]
        if c >= 0x30 && c <= 0x3f && !csi.intermediate {
            if c <= 0x39 {
                if index < Csi.maxParams && subIndex < 2 {
                    let digit = Int(c - 0x30)
                    if subIndex != 0 {
                        if csi.sub[index] < 10_000_000 { csi.sub[index] = csi.sub[index] * 10 + digit }
                    } else if csi.value[index] < 10_000_000 {
                        csi.value[index] = csi.value[index] * 10 + digit
                    }
                }
                parameters = true
            } else if c == UInt8(ascii: ":") {
                subIndex += 1
                parameters = true
            } else if c == UInt8(ascii: ";") {
                index += 1
                subIndex = 0
                parameters = true
            } else if j == 2 {
                csi.marker = c
            } else {
                csi.irregular = true
            }
        } else if c >= 0x20 && c <= 0x2f {
            csi.intermediate = true
        } else if c >= 0x40 && c <= 0x7e {
            break
        } else {
            return j == 2 ? altIntroducer(p, &sink) : j
        }
        j += 1
    }
    if j == n { return sink.final ? n : 0 }
    csi.final = p[j]
    csi.count = parameters ? min(index + 1, Csi.maxParams) : 0
    if !csi.intermediate && !csi.irregular { dispatchCsi(csi, &sink) }
    return j + 1
}

private func parseSs3(_ p: Bytes, _ sink: inout Sink) -> Int {
    let n = p.count
    var modifier = 0
    var j = 2
    while j < n {
        if p[j] >= 0x30 && p[j] <= 0x39 { modifier = min(modifier * 10 + Int(p[j] - 0x30), 1000) }
        else if p[j] == UInt8(ascii: ";") { modifier = 0 }
        else { break }
        j += 1
    }
    if j == n {
        if !sink.final { return 0 }
        return j == 2 ? altIntroducer(p, &sink) : n
    }
    if p[j] < 0x40 || p[j] > 0x7e { return j == 2 ? altIntroducer(p, &sink) : j }
    let candidate: InputEvent? = p[j] == UInt8(ascii: "M") ? keyEvent(.enter) : letterKey(p[j])
    if var event = candidate {
        event.modifiers = modifiersFrom(modifier)
        sink.events.append(event)
    }
    return j + 1
}

private func parseString(_ p: Bytes, _ sink: inout Sink) -> Int {
    let n = p.count
    if n == 2 { return sink.final ? altIntroducer(p, &sink) : 0 }
    var j = 2
    while j < n {
        let c = p[j]
        if c == 0x07 { return j + 1 }
        if c == 0x1b {
            if j + 1 < n && p[j + 1] == UInt8(ascii: "\\") { return j + 2 }
            if j + 1 == n && !sink.final { return 0 }
        } else if c >= 0x20 {
            j += 1
            continue
        }
        return j == 2 ? altIntroducer(p, &sink) : j
    }
    return sink.final ? n : 0
}

private func parseEscape(_ p: Bytes, _ sink: inout Sink, altPrefix: Bool) -> Int {
    let n = p.count
    if n == 1 {
        if !sink.final { return 0 }
        sink.events.append(keyEvent(.escape))
        return 1
    }
    switch p[1] {
    case UInt8(ascii: "["): return parseCsi(p, &sink)
    case UInt8(ascii: "O"): return parseSs3(p, &sink)
    case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "_"), UInt8(ascii: "^"), UInt8(ascii: "X"): return parseString(p, &sink)
    default: break
    }
    if !altPrefix {
        sink.events.append(keyEvent(.escape))
        return 1
    }
    let first = sink.events.count
    let used = parseToken(p.dropFirst(), &sink, altPrefix: false)
    if used == 0 { return 0 }
    for k in first..<sink.events.count where sink.events[k].type == .key { sink.events[k].modifiers.insert(.alt) }
    return used + 1
}

private func parseUtf8(_ p: Bytes, _ sink: inout Sink) -> Int {
    let n = p.count
    let lead = p[0]
    var length = 0
    var low: UInt8 = 0x80
    var high: UInt8 = 0xbf
    if lead >= 0xc2 && lead <= 0xdf {
        length = 2
    } else if lead >= 0xe0 && lead <= 0xef {
        length = 3
        if lead == 0xe0 { low = 0xa0 } else if lead == 0xed { high = 0x9f }
    } else if lead >= 0xf0 && lead <= 0xf4 {
        length = 4
        if lead == 0xf0 { low = 0x90 } else if lead == 0xf4 { high = 0x8f }
    } else {
        sink.events.append(characterEvent(replacement))
        return 1
    }
    var codepoint = UInt32(lead) & (0x7f >> UInt32(length))
    for k in 1..<length {
        if k == n && !sink.final { return 0 }
        // A truncated or invalid sequence becomes one replacement character; the offending byte is parsed again.
        if k == n || p[k] < low || p[k] > high {
            sink.events.append(characterEvent(replacement))
            return k
        }
        codepoint = codepoint << 6 | (UInt32(p[k]) & 0x3f)
        low = 0x80
        high = 0xbf
    }
    // UTF-8 encoded C1 controls are not text.
    if codepoint >= 0xa0 { sink.events.append(characterEvent(codepoint)) }
    return length
}

/// Returns the bytes consumed from p, or 0 when the token needs more input (never when finalizing).
private func parseToken(_ p: Bytes, _ sink: inout Sink, altPrefix: Bool) -> Int {
    let byte = p[0]
    if byte == 0x1b { return parseEscape(p, &sink, altPrefix: altPrefix) }
    if byte < 0x20 || byte == 0x7f { sink.events.append(controlEvent(byte)) }
    else if byte < 0x80 { sink.events.append(characterEvent(UInt32(byte))) }
    else { return parseUtf8(p, &sink) }
    return 1
}

struct InputParser {
    private var buffer: [UInt8] = []
    private(set) var pasting = false
    private var paste: [UInt8] = []

    /// True when bytes are buffered awaiting the rest of a sequence or of a
    /// bracketed paste. Callers flush() after a short timeout (longer while
    /// pasting).
    var pending: Bool { pasting || !buffer.isEmpty }

    /// Consumes bytes and returns every completed event in order. An
    /// incomplete escape sequence (or a lone trailing ESC) stays buffered.
    mutating func feed<S: Sequence>(_ bytes: S) -> [InputEvent] where S.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        return parse(final: false)
    }

    /// Resolves buffered bytes after the timeout: a lone ESC becomes Escape,
    /// `ESC x` becomes Alt+x, unfinished sequences are dropped, and an
    /// unfinished bracketed paste is emitted as a Paste event.
    mutating func flush() -> [InputEvent] { parse(final: true) }

    private mutating func finishPaste(_ sink: inout Sink) {
        var event = typeEvent(.paste)
        event.text = paste
        paste = []
        sink.events.append(event)
        pasting = false
    }

    private mutating func parse(final: Bool) -> [InputEvent] {
        var sink = Sink(final: final)
        let data = buffer
        let size = data.count
        var at = 0
        while at < size {
            if pasting {
                if let end = find(pasteEnd, in: data, from: at) {
                    paste.append(contentsOf: data[at..<end])
                    finishPaste(&sink)
                    at = end + pasteEnd.count
                    continue
                }
                // Keep a trailing prefix of the terminator: the rest may arrive in the next feed.
                var keep = final ? 0 : min(size - at, pasteEnd.count - 1)
                while keep > 0 && !data[(size - keep)..<size].elementsEqual(pasteEnd[0..<keep]) { keep -= 1 }
                paste.append(contentsOf: data[at..<(size - keep)])
                at = size - keep
                break
            }
            let used = parseToken(Bytes(data: data, start: at, count: size - at), &sink, altPrefix: true)
            if used == 0 { break }
            at += used
            if sink.pasteStarted {
                sink.pasteStarted = false
                pasting = true
            }
        }
        if final && pasting { finishPaste(&sink) }
        buffer.removeFirst(at)
        return sink.events
    }

    private func find(_ needle: [UInt8], in data: [UInt8], from start: Int) -> Int? {
        guard needle.count <= data.count - start else { return nil }
        var i = start
        while i + needle.count <= data.count {
            if data[i] == needle[0] && data[i..<(i + needle.count)].elementsEqual(needle) { return i }
            i += 1
        }
        return nil
    }
}
