#pragma once

#include <QByteArray>
#include <QColor>
#include <QString>
#include <QStringList>
#include <climits>
#include <cstdint>
#include <termios.h>
#include <vector>

// Cell drawing for `cinmux tui`: a cell grid composed each frame, and the tty
// that presents it with minimal, synchronized updates.
namespace tui {

struct Color {
    enum class Kind : uint8_t { Default, Indexed, Rgb };
    Kind kind = Kind::Default;
    uint8_t index = 0;
    uint8_t r = 0;
    uint8_t g = 0;
    uint8_t b = 0;
    static Color rgb(uint8_t red, uint8_t green, uint8_t blue) {
        Color c; c.kind = Kind::Rgb; c.r = red; c.g = green; c.b = blue; return c;
    }
    static Color rgb(const QColor &color) { return rgb(uint8_t(color.red()), uint8_t(color.green()), uint8_t(color.blue())); }
    static Color indexed(int value) { Color c; c.kind = Kind::Indexed; c.index = uint8_t(value); return c; }
    bool operator==(const Color &) const = default;
};

enum Attribute : uint16_t {
    Bold = 1 << 0,
    Faint = 1 << 1,
    Italic = 1 << 2,
    Underline = 1 << 3,
    DoubleUnderline = 1 << 4,
    CurlyUnderline = 1 << 5,
    Blink = 1 << 6,
    Reverse = 1 << 7,
    Conceal = 1 << 8,
    Strike = 1 << 9,
};

struct Style {
    Color fg;
    Color bg;
    uint16_t attributes = 0;
    bool operator==(const Style &) const = default;
};

struct Cell {
    static constexpr int maxChars = 4;
    // Base character followed by combining marks; unused entries are 0.
    char32_t chars[maxChars] = {U' ', 0, 0, 0};
    // 1 or 2 for a leading cell; 0 for the right half of a wide character.
    uint8_t width = 1;
    Style style;
    bool operator==(const Cell &) const = default;
};

// Display width in cells using ICU properties: 0 for combining marks,
// format and zero-width characters; 2 for East Asian Wide/Fullwidth and
// default-emoji-presentation characters; otherwise 1.
int charWidth(char32_t c);
int textWidth(const QString &text);
// Fits `text` within `width` cells, ending with "…" when truncated.
QString elide(const QString &text, int width);
// Splits plain text into lines of at most `width` cells, breaking at spaces
// when possible and at explicit newlines.
QStringList wrap(const QString &text, int width);

class Surface {
public:
    void resize(int cols, int rows);
    int cols() const { return m_cols; }
    int rows() const { return m_rows; }
    bool contains(int x, int y) const { return x >= 0 && y >= 0 && x < m_cols && y < m_rows; }
    const Cell &at(int x, int y) const { return m_cells[std::size_t(y) * std::size_t(m_cols) + std::size_t(x)]; }
    Cell &at(int x, int y) { return m_cells[std::size_t(y) * std::size_t(m_cols) + std::size_t(x)]; }
    // Fills the clipped rectangle with spaces in `style`.
    void fill(int x, int y, int width, int height, const Style &style);
    // Writes text at (x, y), clipped to [x, x + maxWidth) and to the surface.
    // Combining marks join the previous cell; a wide character that does not
    // fit is replaced by a space; C0/C1 controls and DEL are drawn as U+FFFD
    // so untrusted titles can never emit escape sequences. Returns the number
    // of columns written.
    int text(int x, int y, const QString &text, const Style &style, int maxWidth = INT_MAX);
    // Stores a cell; a width-2 cell also claims its right neighbour, and
    // overwriting either half of an existing wide character blanks the other.
    void put(int x, int y, const Cell &cell);
    // Applies `f(Style &)` to every cell of the clipped rectangle.
    template<typename F>
    void restyle(int x, int y, int width, int height, F f) {
        for (int row = qMax(0, y); row < qMin(m_rows, y + height); ++row)
            for (int col = qMax(0, x); col < qMin(m_cols, x + width); ++col) f(at(col, row).style);
    }
    struct Cursor {
        int x = 0;
        int y = 0;
        bool visible = false;
        int shape = 0; // DECSCUSR value: 0 default, 1..6
    };
    Cursor cursor;
private:
    int m_cols = 0;
    int m_rows = 0;
    std::vector<Cell> m_cells;
};

// Owns the controlling terminal on stdin/stdout while the TUI runs.
class Terminal {
public:
    Terminal() = default;
    ~Terminal();
    Terminal(const Terminal &) = delete;
    Terminal &operator=(const Terminal &) = delete;
    // Enters raw mode and the alternate screen; enables SGR any-event mouse
    // reporting, bracketed paste, focus events, kitty keyboard flag 1
    // (disambiguate) and xterm modifyOtherKeys 2; then queries `CSI ? u`
    // followed by `CSI c`. Installs SIGWINCH/SIGTERM/SIGHUP/SIGINT/SIGQUIT
    // handlers that write to a self-pipe, ignores SIGPIPE, and restores the
    // terminal on exit and on fatal signals. Fails unless stdin and stdout
    // are terminals.
    bool open(QString *error);
    // Leaves every mode enabled by open() and restores termios. Idempotent.
    void restore();
    int cols() const { return m_cols; }
    int rows() const { return m_rows; }
    // Re-reads the window size; true when it changed.
    bool updateSize();
    // stdin, left blocking (its open file description is shared with the
    // login shell): read it once per readiness notification.
    int inputFd() const;
    // Readable when a handled signal arrived.
    int signalFd() const { return m_signalPipe[0]; }
    // Drains the self-pipe, returning signal numbers in arrival order.
    std::vector<int> takeSignals();
    // 24-bit color output: CINMUX_TUI_COLORS=24bit|256 overrides; otherwise
    // COLORTERM truecolor/24bit, or a TERM known to support direct color.
    bool truecolor() const { return m_truecolor; }
    // Emits the difference from the previously presented frame (everything
    // after invalidate() or a size change) inside a synchronized update,
    // then positions/shapes/shows the cursor per `frame.cursor`. RGB colors
    // are mapped to the xterm 256-color palette unless truecolor().
    void present(const Surface &frame);
    void invalidate();
    // Writes raw bytes (OSC 52, BEL) to the terminal.
    void write(const QByteArray &bytes);
private:
    void writeAll(const char *data, std::size_t size);
    bool m_open = false;
    bool m_truecolor = false;
    int m_cols = 0;
    int m_rows = 0;
    int m_signalPipe[2] = {-1, -1};
    struct termios m_saved {};
    Surface m_previous;
    bool m_invalid = true;
    Surface::Cursor m_cursor;
    bool m_cursorKnown = false;
    QByteArray m_output;
};

} // namespace tui
