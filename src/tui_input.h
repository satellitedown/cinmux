#pragma once

#include <QByteArray>
#include <cstddef>
#include <cstdint>
#include <vector>

// Decodes the byte stream a terminal sends to `cinmux tui` in raw mode.
namespace tui {

enum Modifier : uint8_t { NoModifier = 0, Shift = 1, Alt = 2, Ctrl = 4 };

enum class Key : uint8_t {
    None,
    Character, // `codepoint` holds the Unicode scalar value
    Enter,
    Tab,
    Backspace,
    Escape,
    Up,
    Down,
    Left,
    Right,
    Insert,
    Delete,
    Home,
    End,
    PageUp,
    PageDown,
    Function, // `function` holds 1..35 (F1..F35)
    Menu,
};

enum class MouseAction : uint8_t { Press, Release, Move, WheelUp, WheelDown, WheelLeft, WheelRight };
enum class MouseButton : uint8_t { None, Left, Middle, Right };

struct InputEvent {
    enum class Type : uint8_t {
        Key,
        Mouse,
        Paste,
        FocusIn,
        FocusOut,
        KeyboardFlags,     // reply to the kitty keyboard query `CSI ? u`
        PrimaryAttributes, // reply to `CSI c`
    };
    Type type = Type::Key;
    // Key. Character events: typed text carries its shifted character and no
    // Shift modifier ('A', not Shift+'a'). Ctrl letters are lowercase ('r'
    // with Ctrl for 0x12). Disambiguated reports (kitty `CSI … u`, xterm
    // modifyOtherKeys `CSI 27;…~`) keep every reported modifier, e.g.
    // Ctrl+Shift+'n'. A lone ESC prefix adds Alt to the following key.
    Key key = Key::None;
    char32_t codepoint = 0;
    int function = 0;
    uint8_t modifiers = NoModifier;
    // Mouse (SGR 1006). Press/Release carry the button; Move carries the held
    // button (drag) or None (hover). Coordinates are zero-based cells.
    MouseAction action = MouseAction::Move;
    MouseButton button = MouseButton::None;
    int x = 0;
    int y = 0;
    // Paste: raw bytes between `CSI 200~` and `CSI 201~`.
    QByteArray text;
    // KeyboardFlags: reported flags.
    int flags = 0;
};

class InputParser {
public:
    // Consumes bytes and returns every completed event in order. An
    // incomplete escape sequence (or a lone trailing ESC) stays buffered.
    std::vector<InputEvent> feed(const char *data, std::size_t size);
    // True when bytes are buffered awaiting the rest of a sequence or of a
    // bracketed paste. Callers flush() after a short timeout (longer while
    // pasting()).
    bool pending() const;
    bool pasting() const { return m_pasting; }
    // Resolves buffered bytes after the timeout: a lone ESC becomes Escape,
    // `ESC x` becomes Alt+x, unfinished sequences are dropped, and an
    // unfinished bracketed paste is emitted as a Paste event.
    std::vector<InputEvent> flush();
private:
    std::vector<InputEvent> parse(bool final);
    QByteArray m_buffer;
    bool m_pasting = false;
    QByteArray m_paste;
};

} // namespace tui
