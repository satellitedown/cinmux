#include "tui_input.h"

#include <QByteArrayView>
#include <algorithm>
#include <optional>
#include <utility>

namespace tui {
namespace {
constexpr QByteArrayView PasteEnd("\x1b[201~");
constexpr char32_t Replacement = 0xfffd;

struct Sink {
    std::vector<InputEvent> &events;
    bool final;
    bool pasteStarted = false;
};

struct Csi {
    static constexpr int MaxParams = 8;
    unsigned char marker = 0;
    unsigned char final = 0;
    bool intermediate = false;
    bool irregular = false;
    int count = 0;
    int value[MaxParams] = {};
    int sub[MaxParams] = {};
    int param(int index, int fallback = 0) const { return index < count && value[index] > 0 ? value[index] : fallback; }
};

InputEvent keyEvent(Key key, uint8_t modifiers = NoModifier) {
    InputEvent event;
    event.key = key;
    event.modifiers = modifiers;
    return event;
}
InputEvent characterEvent(char32_t codepoint, uint8_t modifiers = NoModifier) {
    InputEvent event = keyEvent(Key::Character, modifiers);
    event.codepoint = codepoint;
    return event;
}
InputEvent functionEvent(int number) {
    InputEvent event = keyEvent(Key::Function);
    event.function = number;
    return event;
}
InputEvent typeEvent(InputEvent::Type type) {
    InputEvent event;
    event.type = type;
    return event;
}

uint8_t modifiersFrom(int parameter) {
    if (parameter < 2) return NoModifier;
    const int bits = parameter - 1;
    return uint8_t((bits & (Shift | Alt | Ctrl)) | (bits & 32 ? Alt : 0));
}

InputEvent controlEvent(unsigned char byte) {
    switch (byte) {
    case 0x00: return characterEvent(' ', Ctrl);
    case 0x09: return keyEvent(Key::Tab);
    case 0x0d: return keyEvent(Key::Enter);
    case 0x1b: return keyEvent(Key::Escape);
    case 0x7f: return keyEvent(Key::Backspace);
    }
    if (byte <= 0x1a) return characterEvent(U'a' + byte - 1, Ctrl);
    return characterEvent(char32_t("\\]^_"[byte - 0x1c]), Ctrl);
}

std::optional<InputEvent> letterKey(unsigned char final) {
    switch (final) {
    case 'A': return keyEvent(Key::Up);
    case 'B': return keyEvent(Key::Down);
    case 'C': return keyEvent(Key::Right);
    case 'D': return keyEvent(Key::Left);
    case 'H': return keyEvent(Key::Home);
    case 'F': return keyEvent(Key::End);
    case 'P': case 'Q': case 'R': case 'S': return functionEvent(final - 'P' + 1);
    }
    return std::nullopt;
}

std::optional<InputEvent> tildeKey(int number) {
    switch (number) {
    case 1: case 7: return keyEvent(Key::Home);
    case 2: return keyEvent(Key::Insert);
    case 3: return keyEvent(Key::Delete);
    case 4: case 8: return keyEvent(Key::End);
    case 5: return keyEvent(Key::PageUp);
    case 6: return keyEvent(Key::PageDown);
    case 29: return keyEvent(Key::Menu);
    }
    if (number >= 11 && number <= 15) return functionEvent(number - 10);
    if (number >= 17 && number <= 21) return functionEvent(number - 11);
    if (number == 23 || number == 24) return functionEvent(number - 12);
    return std::nullopt;
}

// Kitty encodes keys without a Unicode value as private-use codepoints.
std::optional<InputEvent> kittyKey(int codepoint) {
    if (codepoint >= 57399 && codepoint <= 57408) return characterEvent(U'0' + char32_t(codepoint - 57399));
    if (codepoint >= 57376 && codepoint <= 57398) return functionEvent(codepoint - 57376 + 13);
    switch (codepoint) {
    case 57363: return keyEvent(Key::Menu);
    case 57409: return characterEvent('.');
    case 57410: return characterEvent('/');
    case 57411: return characterEvent('*');
    case 57412: return characterEvent('-');
    case 57413: return characterEvent('+');
    case 57414: return keyEvent(Key::Enter);
    case 57415: return characterEvent('=');
    case 57416: return characterEvent(',');
    case 57417: return keyEvent(Key::Left);
    case 57418: return keyEvent(Key::Right);
    case 57419: return keyEvent(Key::Up);
    case 57420: return keyEvent(Key::Down);
    case 57421: return keyEvent(Key::PageUp);
    case 57422: return keyEvent(Key::PageDown);
    case 57423: return keyEvent(Key::Home);
    case 57424: return keyEvent(Key::End);
    case 57425: return keyEvent(Key::Insert);
    case 57426: return keyEvent(Key::Delete);
    }
    return std::nullopt;
}

// Disambiguated reports carry the unshifted key, so Shift alone on a printable
// key is ordinary typed text.
std::optional<InputEvent> codepointKey(int codepoint, uint8_t modifiers) {
    if (codepoint <= 0 || codepoint > 0x10ffff || (codepoint >= 0x80 && codepoint < 0xa0) || (codepoint >= 0xd800 && codepoint < 0xe000))
        return std::nullopt;
    std::optional<InputEvent> event;
    if (codepoint < 0x20 || codepoint == 0x7f) event = controlEvent(uint8_t(codepoint));
    else if (codepoint >= 0xe000 && codepoint <= 0xf8ff) event = kittyKey(codepoint);
    else event = characterEvent(char32_t(codepoint));
    if (!event) return std::nullopt;
    if (event->key == Key::Character && event->modifiers == NoModifier && modifiers == Shift) {
        if (event->codepoint >= 'a' && event->codepoint <= 'z') event->codepoint -= 'a' - 'A';
        return event;
    }
    event->modifiers |= modifiers;
    return event;
}

std::optional<InputEvent> mouseEvent(int code, int x, int y, bool release) {
    if (code < 0 || (code & 128)) return std::nullopt;
    static constexpr MouseButton Buttons[] = {MouseButton::Left, MouseButton::Middle, MouseButton::Right, MouseButton::None};
    static constexpr MouseAction Wheels[] = {MouseAction::WheelUp, MouseAction::WheelDown, MouseAction::WheelLeft, MouseAction::WheelRight};
    InputEvent event;
    event.type = InputEvent::Type::Mouse;
    event.modifiers = uint8_t((code & 4 ? Shift : 0) | (code & 8 ? Alt : 0) | (code & 16 ? Ctrl : 0));
    event.x = std::max(x, 0);
    event.y = std::max(y, 0);
    const int base = code & 3;
    if (code & 64) {
        if (release) return std::nullopt;
        event.action = Wheels[base];
        return event;
    }
    event.button = Buttons[base];
    if (code & 32) event.action = MouseAction::Move;
    else event.action = release || base == 3 ? MouseAction::Release : MouseAction::Press;
    return event;
}

void dispatchCsi(const Csi &csi, Sink &sink) {
    if (csi.marker == '<') {
        if ((csi.final == 'M' || csi.final == 'm') && csi.count >= 3)
            if (const auto event = mouseEvent(csi.value[0], csi.value[1] - 1, csi.value[2] - 1, csi.final == 'm')) sink.events.push_back(*event);
        return;
    }
    if (csi.marker == '?') {
        if (csi.final == 'u') {
            InputEvent event = typeEvent(InputEvent::Type::KeyboardFlags);
            event.flags = csi.param(0);
            sink.events.push_back(event);
        } else if (csi.final == 'c') sink.events.push_back(typeEvent(InputEvent::Type::PrimaryAttributes));
        return;
    }
    // Kitty marks key releases with event type 3 after the modifiers.
    if (csi.marker || csi.sub[1] == 3) return;
    const uint8_t modifiers = modifiersFrom(csi.param(1));
    std::optional<InputEvent> event;
    switch (csi.final) {
    case 'u': event = codepointKey(csi.param(0), modifiers); break;
    case '~':
        if (csi.param(0) == 200) sink.pasteStarted = true;
        else if (csi.param(0) == 27 && csi.count >= 3) event = codepointKey(csi.param(2), modifiers);
        else if ((event = tildeKey(csi.param(0)))) event->modifiers = modifiers;
        break;
    case 'Z': event = keyEvent(Key::Tab, uint8_t(Shift | modifiers)); break;
    case 'I': event = typeEvent(InputEvent::Type::FocusIn); break;
    case 'O': event = typeEvent(InputEvent::Type::FocusOut); break;
    default:
        // Cursor position reports share F3's final; key reports only use a first parameter of 1.
        if (csi.count <= 2 && csi.param(0, 1) == 1 && (event = letterKey(csi.final))) event->modifiers = modifiers;
    }
    if (event) sink.events.push_back(*event);
}

std::size_t parseToken(const unsigned char *p, std::size_t n, Sink &sink, bool altPrefix);

// `ESC [`, `ESC O` and string introducers not followed by a sequence are Alt+key.
std::size_t altIntroducer(const unsigned char *p, Sink &sink) {
    sink.events.push_back(characterEvent(p[1], Alt));
    return 2;
}

std::size_t parseCsi(const unsigned char *p, std::size_t n, Sink &sink) {
    if (n == 2) return sink.final ? altIntroducer(p, sink) : 0;
    if (p[2] == 'M') {
        if (n < 6) return sink.final ? n : 0;
        if (const auto event = mouseEvent(p[3] - 32, p[4] - 33, p[5] - 33, false)) sink.events.push_back(*event);
        return 6;
    }
    Csi csi;
    int index = 0, subIndex = 0;
    bool parameters = false;
    std::size_t j = 2;
    for (; j < n; ++j) {
        const unsigned char c = p[j];
        if (c >= 0x30 && c <= 0x3f && !csi.intermediate) {
            if (c <= '9') {
                if (index < Csi::MaxParams && subIndex < 2) {
                    int &slot = subIndex ? csi.sub[index] : csi.value[index];
                    if (slot < 10000000) slot = slot * 10 + (c - '0');
                }
                parameters = true;
            } else if (c == ':') {
                ++subIndex;
                parameters = true;
            } else if (c == ';') {
                ++index;
                subIndex = 0;
                parameters = true;
            } else if (j == 2) csi.marker = c;
            else csi.irregular = true;
        } else if (c >= 0x20 && c <= 0x2f) csi.intermediate = true;
        else if (c >= 0x40 && c <= 0x7e) break;
        else return j == 2 ? altIntroducer(p, sink) : j;
    }
    if (j == n) return sink.final ? n : 0;
    csi.final = p[j];
    csi.count = parameters ? std::min(index + 1, Csi::MaxParams) : 0;
    if (!csi.intermediate && !csi.irregular) dispatchCsi(csi, sink);
    return j + 1;
}

std::size_t parseSs3(const unsigned char *p, std::size_t n, Sink &sink) {
    int modifier = 0;
    std::size_t j = 2;
    for (; j < n; ++j) {
        if (p[j] >= '0' && p[j] <= '9') modifier = std::min(modifier * 10 + (p[j] - '0'), 1000);
        else if (p[j] == ';') modifier = 0;
        else break;
    }
    if (j == n) {
        if (!sink.final) return 0;
        return j == 2 ? altIntroducer(p, sink) : n;
    }
    if (p[j] < 0x40 || p[j] > 0x7e) return j == 2 ? altIntroducer(p, sink) : j;
    auto event = p[j] == 'M' ? keyEvent(Key::Enter) : letterKey(p[j]);
    if (event) {
        event->modifiers = modifiersFrom(modifier);
        sink.events.push_back(*event);
    }
    return j + 1;
}

std::size_t parseString(const unsigned char *p, std::size_t n, Sink &sink) {
    if (n == 2) return sink.final ? altIntroducer(p, sink) : 0;
    for (std::size_t j = 2; j < n; ++j) {
        const unsigned char c = p[j];
        if (c == 0x07) return j + 1;
        if (c == 0x1b) {
            if (j + 1 < n && p[j + 1] == '\\') return j + 2;
            if (j + 1 == n && !sink.final) return 0;
        } else if (c >= 0x20) continue;
        return j == 2 ? altIntroducer(p, sink) : j;
    }
    return sink.final ? n : 0;
}

std::size_t parseEscape(const unsigned char *p, std::size_t n, Sink &sink, bool altPrefix) {
    if (n == 1) {
        if (!sink.final) return 0;
        sink.events.push_back(keyEvent(Key::Escape));
        return 1;
    }
    switch (p[1]) {
    case '[': return parseCsi(p, n, sink);
    case 'O': return parseSs3(p, n, sink);
    case ']': case 'P': case '_': case '^': case 'X': return parseString(p, n, sink);
    }
    if (!altPrefix) {
        sink.events.push_back(keyEvent(Key::Escape));
        return 1;
    }
    const std::size_t first = sink.events.size();
    const std::size_t used = parseToken(p + 1, n - 1, sink, false);
    if (!used) return 0;
    for (std::size_t k = first; k < sink.events.size(); ++k)
        if (sink.events[k].type == InputEvent::Type::Key) sink.events[k].modifiers |= Alt;
    return used + 1;
}

std::size_t parseUtf8(const unsigned char *p, std::size_t n, Sink &sink) {
    const unsigned char lead = p[0];
    std::size_t length = 0;
    unsigned char low = 0x80, high = 0xbf;
    if (lead >= 0xc2 && lead <= 0xdf) length = 2;
    else if (lead >= 0xe0 && lead <= 0xef) {
        length = 3;
        if (lead == 0xe0) low = 0xa0;
        else if (lead == 0xed) high = 0x9f;
    } else if (lead >= 0xf0 && lead <= 0xf4) {
        length = 4;
        if (lead == 0xf0) low = 0x90;
        else if (lead == 0xf4) high = 0x8f;
    } else {
        sink.events.push_back(characterEvent(Replacement));
        return 1;
    }
    char32_t codepoint = lead & (0x7f >> length);
    for (std::size_t k = 1; k < length; ++k) {
        if (k == n && !sink.final) return 0;
        // A truncated or invalid sequence becomes one replacement character; the offending byte is parsed again.
        if (k == n || p[k] < low || p[k] > high) {
            sink.events.push_back(characterEvent(Replacement));
            return k;
        }
        codepoint = codepoint << 6 | (p[k] & 0x3f);
        low = 0x80;
        high = 0xbf;
    }
    // UTF-8 encoded C1 controls are not text.
    if (codepoint >= 0xa0) sink.events.push_back(characterEvent(codepoint));
    return length;
}

// Returns the bytes consumed from p, or 0 when the token needs more input (never when finalizing).
std::size_t parseToken(const unsigned char *p, std::size_t n, Sink &sink, bool altPrefix) {
    const unsigned char byte = p[0];
    if (byte == 0x1b) return parseEscape(p, n, sink, altPrefix);
    if (byte < 0x20 || byte == 0x7f) sink.events.push_back(controlEvent(byte));
    else if (byte < 0x80) sink.events.push_back(characterEvent(byte));
    else return parseUtf8(p, n, sink);
    return 1;
}
}

std::vector<InputEvent> InputParser::feed(const char *data, std::size_t size) {
    m_buffer.append(data, qsizetype(size));
    return parse(false);
}

bool InputParser::pending() const { return m_pasting || !m_buffer.isEmpty(); }

std::vector<InputEvent> InputParser::flush() { return parse(true); }

std::vector<InputEvent> InputParser::parse(bool final) {
    std::vector<InputEvent> events;
    Sink sink{events, final};
    const auto finishPaste = [&] {
        InputEvent event = typeEvent(InputEvent::Type::Paste);
        event.text = std::exchange(m_paste, {});
        events.push_back(std::move(event));
        m_pasting = false;
    };
    const auto *data = reinterpret_cast<const unsigned char *>(m_buffer.constData());
    const std::size_t size = std::size_t(m_buffer.size());
    std::size_t at = 0;
    while (at < size) {
        if (m_pasting) {
            const QByteArrayView rest(data + at, qsizetype(size - at));
            const qsizetype end = rest.indexOf(PasteEnd);
            if (end >= 0) {
                m_paste.append(rest.first(end));
                finishPaste();
                at += std::size_t(end + PasteEnd.size());
                continue;
            }
            // Keep a trailing prefix of the terminator: the rest may arrive in the next feed.
            qsizetype keep = final ? 0 : std::min(rest.size(), PasteEnd.size() - 1);
            while (keep && !rest.endsWith(PasteEnd.first(keep))) --keep;
            m_paste.append(rest.first(rest.size() - keep));
            at = size - std::size_t(keep);
            break;
        }
        const std::size_t used = parseToken(data + at, size - at, sink, true);
        if (!used) break;
        at += used;
        if (sink.pasteStarted) {
            sink.pasteStarted = false;
            m_pasting = true;
        }
    }
    if (final && m_pasting) finishPaste();
    m_buffer.remove(0, qsizetype(at));
    return events;
}

} // namespace tui
