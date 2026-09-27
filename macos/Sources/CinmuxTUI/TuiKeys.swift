// The bytes a pane's tmux client receives for keys and pastes: a port of the
// libvterm keyboard encoder the Linux build uses (7-bit C1, no LNM). SwiftTerm
// 1.20 only has a view-bound, internal key encoder.

enum PaneEncoding {
    private static let shift: UInt8 = 1
    private static let alt: UInt8 = 2
    private static let ctrl: UInt8 = 4

    private static func utf8(_ value: UInt32) -> [UInt8] {
        guard let scalar = Unicode.Scalar(value) else { return Array("\u{fffd}".utf8) }
        return Array(String(scalar).utf8)
    }

    private static func csi(_ body: String) -> [UInt8] { [0x1b, UInt8(ascii: "[")] + Array(body.utf8) }

    /// libvterm's vterm_keyboard_unichar.
    static func character(_ c: UInt32, _ modifiers: KeyModifiers) -> [UInt8] {
        var mod = modifiers.rawValue & 7
        // The shift modifier is never important for Unicode characters apart from Space.
        if c != 0x20 { mod &= ~shift }
        if mod == 0 { return utf8(c) }
        let needsCsiU: Bool
        switch c {
        // Special Ctrl- letters that can't be represented elsewise.
        case 0x69, 0x6a, 0x6d, 0x5b: needsCsiU = true   // i j m [
        // Ctrl-\ ] ^ _ don't need CSI u.
        case 0x5c, 0x5d, 0x5e, 0x5f: needsCsiU = false
        // Shift-space needs CSI u.
        case 0x20: needsCsiU = mod & shift != 0
        // All other characters need CSI u except for letters a-z.
        default: needsCsiU = c < 0x61 || c > 0x7a
        }
        // Alt can just prefix with ESC; anything else requires CSI u.
        if needsCsiU && mod & ~alt != 0 { return csi("\(c);\(Int(mod) + 1)u") }
        var value = c
        if mod & ctrl != 0 { value &= 0x1f }
        // libvterm prints the value with %c, truncating non-ASCII Alt+text; encode it as UTF-8 instead.
        return (mod & alt != 0 ? [0x1b] : []) + utf8(value)
    }

    private enum Code {
        case literal(UInt8)
        case tab
        case enter
        case ss3(UInt8)
        case csiNumber(Int)
        case cursor(UInt8)
    }

    /// libvterm's vterm_keyboard_key. Returns no bytes for keys libvterm does
    /// not encode (Menu, F13 and above).
    static func key(_ event: InputEvent, applicationCursor: Bool) -> [UInt8] {
        if event.key == .character { return character(event.codepoint, event.modifiers) }
        let mod = event.modifiers.rawValue & 7
        let code: Code
        switch event.key {
        case .enter: code = .enter
        case .tab: code = .tab
        case .backspace: code = .literal(0x7f)
        case .escape: code = .literal(0x1b)
        case .up: code = .cursor(UInt8(ascii: "A"))
        case .down: code = .cursor(UInt8(ascii: "B"))
        case .left: code = .cursor(UInt8(ascii: "D"))
        case .right: code = .cursor(UInt8(ascii: "C"))
        case .insert: code = .csiNumber(2)
        case .delete: code = .csiNumber(3)
        case .home: code = .cursor(UInt8(ascii: "H"))
        case .end: code = .cursor(UInt8(ascii: "F"))
        case .pageUp: code = .csiNumber(5)
        case .pageDown: code = .csiNumber(6)
        case .function:
            let numbers = [15, 17, 18, 19, 20, 21, 23, 24]
            switch event.function {
            case 1...4: code = .ss3(UInt8(ascii: "P") + UInt8(event.function - 1))
            case 5...12: code = .csiNumber(numbers[event.function - 5])
            default: return []
            }
        case .character, .none, .menu:
            return []
        }
        func literal(_ byte: UInt8) -> [UInt8] {
            if mod & (shift | ctrl) != 0 { return csi("\(byte);\(Int(mod) + 1)u") }
            return mod & alt != 0 ? [0x1b, byte] : [byte]
        }
        func csiFinal(_ final: UInt8) -> [UInt8] {
            mod == 0 ? [0x1b, UInt8(ascii: "["), final] : csi("1;\(Int(mod) + 1)") + [final]
        }
        func ss3(_ final: UInt8) -> [UInt8] { mod == 0 ? [0x1b, UInt8(ascii: "O"), final] : csiFinal(final) }
        switch code {
        case .tab:
            // Shift-Tab is CSI Z but plain Tab is 0x09.
            if mod == shift { return csi("Z") }
            if mod & shift != 0 { return csi("1;\(Int(mod) + 1)Z") }
            return literal(0x09)
        case .enter:
            return literal(0x0d)
        case .literal(let byte):
            return literal(byte)
        case .ss3(let final):
            return ss3(final)
        case .csiNumber(let number):
            return mod == 0 ? csi("\(number)~") : csi("\(number);\(Int(mod) + 1)~")
        case .cursor(let final):
            return applicationCursor ? ss3(final) : csiFinal(final)
        }
    }

    /// A paste as the pane receives it: newlines become carriage returns and
    /// a pasted end-of-paste marker cannot end the bracket early.
    static func paste(_ text: [UInt8], bracketed: Bool) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.count)
        var i = 0
        while i < text.count {
            if text[i] == 0x0d && i + 1 < text.count && text[i + 1] == 0x0a {
                bytes.append(0x0d)
                i += 2
            } else {
                bytes.append(text[i] == 0x0a ? 0x0d : text[i])
                i += 1
            }
        }
        // Removal can join fragments into a new terminator, so repeat until none remains.
        let terminator = Array("\u{1b}[201~".utf8)
        while let range = firstRange(of: terminator, in: bytes) { bytes.removeSubrange(range) }
        guard bracketed else { return bytes }
        return Array("\u{1b}[200~".utf8) + bytes + terminator
    }

    private static func firstRange(of needle: [UInt8], in haystack: [UInt8]) -> Range<Int>? {
        guard needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) where haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return start..<(start + needle.count)
        }
        return nil
    }
}
