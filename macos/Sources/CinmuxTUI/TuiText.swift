import Foundation

// Display widths for `cinmux tui`, matching the Linux build's ICU rules:
// 0 for combining marks, format and zero-width characters; 2 for East Asian
// Wide/Fullwidth and default-emoji-presentation characters; otherwise 1.

/// C0/C1 controls and DEL.
func isControl(_ c: UInt32) -> Bool { c < 0x20 || (c >= 0x7f && c < 0xa0) }

/// East Asian Width W and F ranges (Unicode 16; unassigned CJK code points
/// default to W as in EastAsianWidth.txt). Swift's Unicode properties do not
/// expose East_Asian_Width.
private let eastAsianWide: [(UInt32, UInt32)] = [
    (0x1100, 0x115F), (0x231A, 0x231B), (0x2329, 0x232A), (0x23E9, 0x23EC), (0x23F0, 0x23F0), (0x23F3, 0x23F3),
    (0x25FD, 0x25FE), (0x2614, 0x2615), (0x2630, 0x2637), (0x2648, 0x2653), (0x267F, 0x267F), (0x268A, 0x268F),
    (0x2693, 0x2693), (0x26A1, 0x26A1), (0x26AA, 0x26AB), (0x26BD, 0x26BE), (0x26C4, 0x26C5), (0x26CE, 0x26CE),
    (0x26D4, 0x26D4), (0x26EA, 0x26EA), (0x26F2, 0x26F3), (0x26F5, 0x26F5), (0x26FA, 0x26FA), (0x26FD, 0x26FD),
    (0x2705, 0x2705), (0x270A, 0x270B), (0x2728, 0x2728), (0x274C, 0x274C), (0x274E, 0x274E), (0x2753, 0x2755),
    (0x2757, 0x2757), (0x2795, 0x2797), (0x27B0, 0x27B0), (0x27BF, 0x27BF), (0x2B1B, 0x2B1C), (0x2B50, 0x2B50),
    (0x2B55, 0x2B55), (0x2E80, 0x2E99), (0x2E9B, 0x2EF3), (0x2F00, 0x2FD5), (0x2FF0, 0x303E), (0x3041, 0x3096),
    (0x3099, 0x30FF), (0x3105, 0x312F), (0x3131, 0x318E), (0x3190, 0x31E5), (0x31EF, 0x321E), (0x3220, 0x3247),
    (0x3250, 0xA48C), (0xA490, 0xA4C6), (0xA960, 0xA97C), (0xAC00, 0xD7A3), (0xF900, 0xFAFF), (0xFE10, 0xFE19),
    (0xFE30, 0xFE52), (0xFE54, 0xFE66), (0xFE68, 0xFE6B), (0xFF01, 0xFF60), (0xFFE0, 0xFFE6), (0x16FE0, 0x16FE4),
    (0x16FF0, 0x16FF1), (0x17000, 0x187F7), (0x18800, 0x18CD5), (0x18CFF, 0x18D08), (0x1AFF0, 0x1AFF3),
    (0x1AFF5, 0x1AFFB), (0x1AFFD, 0x1AFFE), (0x1B000, 0x1B122), (0x1B132, 0x1B132), (0x1B150, 0x1B152),
    (0x1B155, 0x1B155), (0x1B164, 0x1B167), (0x1B170, 0x1B2FB), (0x1D300, 0x1D356), (0x1D360, 0x1D376),
    (0x1F004, 0x1F004), (0x1F0CF, 0x1F0CF), (0x1F18E, 0x1F18E), (0x1F191, 0x1F19A), (0x1F200, 0x1F202),
    (0x1F210, 0x1F23B), (0x1F240, 0x1F248), (0x1F250, 0x1F251), (0x1F260, 0x1F265), (0x1F300, 0x1F320),
    (0x1F32D, 0x1F335), (0x1F337, 0x1F37C), (0x1F37E, 0x1F393), (0x1F3A0, 0x1F3CA), (0x1F3CF, 0x1F3D3),
    (0x1F3E0, 0x1F3F0), (0x1F3F4, 0x1F3F4), (0x1F3F8, 0x1F43E), (0x1F440, 0x1F440), (0x1F442, 0x1F4FC),
    (0x1F4FF, 0x1F53D), (0x1F54B, 0x1F54E), (0x1F550, 0x1F567), (0x1F57A, 0x1F57A), (0x1F595, 0x1F596),
    (0x1F5A4, 0x1F5A4), (0x1F5FB, 0x1F64F), (0x1F680, 0x1F6C5), (0x1F6CC, 0x1F6CC), (0x1F6D0, 0x1F6D2),
    (0x1F6D5, 0x1F6D7), (0x1F6DC, 0x1F6DF), (0x1F6EB, 0x1F6EC), (0x1F6F4, 0x1F6FC), (0x1F7E0, 0x1F7EB),
    (0x1F7F0, 0x1F7F0), (0x1F90C, 0x1F93A), (0x1F93C, 0x1F945), (0x1F947, 0x1F9FF), (0x1FA70, 0x1FA7C),
    (0x1FA80, 0x1FA89), (0x1FA8F, 0x1FAC6), (0x1FACE, 0x1FADC), (0x1FADF, 0x1FAE9), (0x1FAF0, 0x1FAF8),
    (0x20000, 0x2FFFD), (0x30000, 0x3FFFD),
]

private func isEastAsianWide(_ c: UInt32) -> Bool {
    var low = 0
    var high = eastAsianWide.count - 1
    while low <= high {
        let middle = (low + high) / 2
        let range = eastAsianWide[middle]
        if c < range.0 { high = middle - 1 } else if c > range.1 { low = middle + 1 } else { return true }
    }
    return false
}

func charWidth(_ c: UInt32) -> Int {
    if isControl(c) { return 1 }
    if c == 0x200b || (c >= 0x1160 && c <= 0x11ff) { return 0 }
    guard let scalar = Unicode.Scalar(c) else { return 1 }
    switch scalar.properties.generalCategory {
    case .nonspacingMark, .enclosingMark, .format: return 0
    default: break
    }
    if isEastAsianWide(c) || scalar.properties.isEmojiPresentation { return 2 }
    return 1
}

func textWidth(_ text: String) -> Int { textWidth(text.unicodeScalars) }

func textWidth<S: Sequence>(_ scalars: S) -> Int where S.Element == Unicode.Scalar {
    var width = 0
    for scalar in scalars { width += charWidth(scalar.value) }
    return width
}

extension String {
    init<S: Sequence>(scalars: S) where S.Element == Unicode.Scalar {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        self.init(view)
    }
}

/// Fits `text` within `width` cells, ending with "…" when truncated.
func elide(_ text: String, _ width: Int) -> String {
    if width <= 0 { return "" }
    if textWidth(text) <= width { return text }
    var used = 0
    var kept = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        let w = charWidth(scalar.value)
        if used + w > width - 1 { break }
        used += w
        kept.append(scalar)
    }
    return String(kept) + "\u{2026}"
}

/// Splits plain text into lines of at most `width` cells, breaking at spaces
/// when possible and at explicit newlines.
func wrap(_ text: String, _ width: Int) -> [String] {
    if width <= 0 { return [text] }
    var lines: [String] = []
    for paragraphView in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
        let paragraph = Array(paragraphView)
        var line: [Unicode.Scalar] = []
        var lineWidth = 0
        func breakLine() {
            lines.append(String(scalars: line))
            line.removeAll()
            lineWidth = 0
        }
        var i = 0
        while i < paragraph.count {
            var wordStart = i
            while wordStart < paragraph.count && paragraph[wordStart] == " " { wordStart += 1 }
            let gap = wordStart - i
            var wordEnd = wordStart
            var wordWidth = 0
            while wordEnd < paragraph.count && paragraph[wordEnd] != " " {
                wordWidth += charWidth(paragraph[wordEnd].value)
                wordEnd += 1
            }
            i = wordEnd
            if wordStart == wordEnd { break }
            if lineWidth + gap + wordWidth <= width {
                line.append(contentsOf: repeatElement(" ", count: gap))
                line.append(contentsOf: paragraph[wordStart..<wordEnd])
                lineWidth += gap + wordWidth
            } else if wordWidth <= width {
                if !line.isEmpty { breakLine() }
                line.append(contentsOf: paragraph[wordStart..<wordEnd])
                lineWidth = wordWidth
            } else {
                // A word wider than any line continues the current one and is split wherever it overflows.
                for j in wordStart..<wordEnd {
                    let w = charWidth(paragraph[j].value)
                    if j == wordStart {
                        if lineWidth + gap + w <= width {
                            line.append(contentsOf: repeatElement(" ", count: gap))
                            lineWidth += gap
                        } else if !line.isEmpty {
                            breakLine()
                        }
                    } else if w > 0 && lineWidth + w > width {
                        breakLine()
                    }
                    line.append(paragraph[j])
                    lineWidth += w
                }
            }
        }
        lines.append(String(scalars: line))
    }
    return lines
}
