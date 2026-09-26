#include "tui_screen.h"

#include <algorithm>
#include <cerrno>
#include <charconv>
#include <cmath>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iterator>
#include <poll.h>
#include <sys/ioctl.h>
#include <unicode/uchar.h>
#include <unistd.h>

namespace tui {
namespace {
constexpr char enterSequence[] = "\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h\x1b[?2004h\x1b[?1004h"
                                 "\x1b[>1u\x1b[>4;2m\x1b[?u\x1b[c\x1b[H\x1b[2J";
constexpr char leaveSequence[] = "\x1b[?2026l\x1b[<u\x1b[>4m\x1b[?1004l\x1b[?2004l\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l"
                                 "\x1b[0 q\x1b[0m\x1b[?25h\x1b[?1049l";

// Process-wide state for the signal and exit paths, which cannot reach the Terminal object.
volatile sig_atomic_t terminalActive = 0;
volatile sig_atomic_t signalWriteFd = -1;
struct termios savedTermios {};
bool exitHandlerRegistered = false;

bool isControl(char32_t c) { return c < 0x20 || (c >= 0x7f && c < 0xa0); }

char32_t nextCodePoint(QStringView text, qsizetype &index) {
    const char16_t unit = text[index++].unicode();
    if (QChar::isHighSurrogate(unit) && index < text.size() && QChar::isLowSurrogate(text[index].unicode()))
        return QChar::surrogateToUcs4(unit, text[index++].unicode());
    return QChar::isSurrogate(unit) ? U'\uFFFD' : char32_t(unit);
}

// Async-signal-safe: used by the fatal-signal and exit handlers as well as by Terminal.
void writeFully(int fd, const char *data, std::size_t size) {
    while (size > 0) {
        const ssize_t written = ::write(fd, data, size);
        if (written > 0) { data += written; size -= std::size_t(written); continue; }
        if (written < 0 && errno == EINTR) continue;
        if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            pollfd descriptor {fd, POLLOUT, 0};
            if (::poll(&descriptor, 1, -1) < 0 && errno != EINTR) return;
            continue;
        }
        return;
    }
}

void emergencyRestore() {
    if (!terminalActive) return;
    terminalActive = 0;
    writeFully(STDOUT_FILENO, leaveSequence, sizeof leaveSequence - 1);
    ::tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios);
}

void forwardSignal(int number) {
    const int savedErrno = errno;
    const unsigned char byte = static_cast<unsigned char>(number);
    if (signalWriteFd >= 0) (void)!::write(signalWriteFd, &byte, 1);
    errno = savedErrno;
}

void fatalSignal(int number) {
    emergencyRestore();
    struct sigaction action {};
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    ::sigaction(number, &action, nullptr);
    ::raise(number);
}

struct OwnedSignal {
    int number;
    void (*handler)(int);
    int flags;
};
const OwnedSignal ownedSignals[] = {
    {SIGWINCH, forwardSignal, SA_RESTART}, {SIGTERM, forwardSignal, SA_RESTART}, {SIGHUP, forwardSignal, SA_RESTART},
    {SIGINT, forwardSignal, SA_RESTART}, {SIGQUIT, forwardSignal, SA_RESTART},
    {SIGSEGV, fatalSignal, 0}, {SIGBUS, fatalSignal, 0}, {SIGFPE, fatalSignal, 0}, {SIGILL, fatalSignal, 0},
    {SIGABRT, fatalSignal, 0}, {SIGPIPE, SIG_IGN, 0}};
struct sigaction previousActions[std::size(ownedSignals)];

void installHandlers() {
    for (std::size_t i = 0; i < std::size(ownedSignals); ++i) {
        struct sigaction action {};
        sigemptyset(&action.sa_mask);
        action.sa_handler = ownedSignals[i].handler;
        action.sa_flags = ownedSignals[i].flags;
        ::sigaction(ownedSignals[i].number, &action, &previousActions[i]);
    }
}

void restoreHandlers() {
    for (std::size_t i = 0; i < std::size(ownedSignals); ++i) ::sigaction(ownedSignals[i].number, &previousActions[i], nullptr);
}

bool detectTruecolor() {
    const QByteArray colors = qgetenv("CINMUX_TUI_COLORS").trimmed().toLower();
    if (colors == "24bit" || colors == "truecolor") return true;
    if (colors == "256") return false;
    const QByteArray colorterm = qgetenv("COLORTERM").trimmed().toLower();
    if (colorterm == "truecolor" || colorterm == "24bit") return true;
    const QByteArray term = qgetenv("TERM").toLower();
    for (const char *name : {"direct", "kitty", "ghostty", "foot", "alacritty", "wezterm", "contour", "rio", "iterm"})
        if (term.contains(name)) return true;
    return false;
}

void appendNumber(QByteArray &out, int value) {
    char buffer[12];
    const auto result = std::to_chars(buffer, buffer + sizeof buffer, value);
    out.append(buffer, result.ptr - buffer);
}

void appendUtf8(QByteArray &out, char32_t c) {
    if (isControl(c) || (c >= 0xd800 && c < 0xe000) || c > 0x10ffff) c = U'\uFFFD';
    if (c < 0x80) out.append(char(c));
    else if (c < 0x800) { out.append(char(0xc0 | (c >> 6))); out.append(char(0x80 | (c & 0x3f))); }
    else if (c < 0x10000) {
        out.append(char(0xe0 | (c >> 12))); out.append(char(0x80 | ((c >> 6) & 0x3f))); out.append(char(0x80 | (c & 0x3f)));
    } else {
        out.append(char(0xf0 | (c >> 18))); out.append(char(0x80 | ((c >> 12) & 0x3f)));
        out.append(char(0x80 | ((c >> 6) & 0x3f))); out.append(char(0x80 | (c & 0x3f)));
    }
}

int nearest256(int red, int green, int blue) {
    static constexpr int levels[] = {0, 95, 135, 175, 215, 255};
    const auto level = [](int value) {
        int best = 0;
        for (int i = 1; i < 6; ++i)
            if (std::abs(value - levels[i]) < std::abs(value - levels[best])) best = i;
        return best;
    };
    const auto distance = [&](int r, int g, int b) {
        return (red - r) * (red - r) + (green - g) * (green - g) + (blue - b) * (blue - b);
    };
    const int r = level(red), g = level(green), b = level(blue);
    // The squared distance to a gray is minimized by the gray nearest to the channel mean.
    const int step = std::clamp(int(std::lround(((red + green + blue) / 3.0 - 8.0) / 10.0)), 0, 23);
    const int gray = 8 + 10 * step;
    return distance(gray, gray, gray) < distance(levels[r], levels[g], levels[b]) ? 232 + step : 16 + 36 * r + 6 * g + b;
}

void appendColor(QByteArray &out, const Color &color, bool background, bool truecolor) {
    switch (color.kind) {
    case Color::Kind::Default: return;
    case Color::Kind::Indexed:
        out.append(';');
        if (color.index < 8) appendNumber(out, (background ? 40 : 30) + color.index);
        else if (color.index < 16) appendNumber(out, (background ? 100 : 90) + color.index - 8);
        else { out.append(background ? "48;5;" : "38;5;"); appendNumber(out, color.index); }
        return;
    case Color::Kind::Rgb:
        out.append(background ? ";48;" : ";38;");
        if (!truecolor) { out.append("5;"); appendNumber(out, nearest256(color.r, color.g, color.b)); return; }
        out.append("2;"); appendNumber(out, color.r);
        out.append(';'); appendNumber(out, color.g);
        out.append(';'); appendNumber(out, color.b);
        return;
    }
}

void appendStyle(QByteArray &out, const Style &style, bool truecolor) {
    out.append("\x1b[0");
    const uint16_t a = style.attributes;
    if (a & Bold) out.append(";1");
    if (a & Faint) out.append(";2");
    if (a & Italic) out.append(";3");
    if (a & CurlyUnderline) out.append(";4:3");
    else if (a & DoubleUnderline) out.append(";4:2");
    else if (a & Underline) out.append(";4");
    if (a & Blink) out.append(";5");
    if (a & Reverse) out.append(";7");
    if (a & Conceal) out.append(";8");
    if (a & Strike) out.append(";9");
    appendColor(out, style.fg, false, truecolor);
    appendColor(out, style.bg, true, truecolor);
    out.append('m');
}
}

int charWidth(char32_t c) {
    if (isControl(c)) return 1;
    if (c == 0x200b || (c >= 0x1160 && c <= 0x11ff)) return 0;
    const int8_t category = u_charType(UChar32(c));
    if (category == U_NON_SPACING_MARK || category == U_ENCLOSING_MARK || category == U_FORMAT_CHAR) return 0;
    const int eastAsianWidth = u_getIntPropertyValue(UChar32(c), UCHAR_EAST_ASIAN_WIDTH);
    if (eastAsianWidth == U_EA_WIDE || eastAsianWidth == U_EA_FULLWIDTH || u_hasBinaryProperty(UChar32(c), UCHAR_EMOJI_PRESENTATION))
        return 2;
    return 1;
}

int textWidth(const QString &text) {
    int width = 0;
    for (qsizetype i = 0; i < text.size();) width += charWidth(nextCodePoint(text, i));
    return width;
}

QString elide(const QString &text, int width) {
    if (width <= 0) return {};
    if (textWidth(text) <= width) return text;
    int used = 0;
    qsizetype end = 0;
    for (qsizetype i = 0; i < text.size();) {
        const int w = charWidth(nextCodePoint(text, i));
        if (used + w > width - 1) break;
        used += w;
        end = i;
    }
    return text.left(end) + QChar(0x2026);
}

QStringList wrap(const QString &text, int width) {
    if (width <= 0) return {text};
    QStringList lines;
    for (const QString &paragraph : text.split(u'\n')) {
        QString line;
        int lineWidth = 0;
        const auto breakLine = [&] {
            lines << line;
            line.clear();
            lineWidth = 0;
        };
        for (qsizetype i = 0; i < paragraph.size();) {
            qsizetype wordStart = i;
            while (wordStart < paragraph.size() && paragraph[wordStart] == u' ') ++wordStart;
            const int gap = int(wordStart - i);
            qsizetype wordEnd = wordStart;
            int wordWidth = 0;
            while (wordEnd < paragraph.size() && paragraph[wordEnd] != u' ') wordWidth += charWidth(nextCodePoint(paragraph, wordEnd));
            i = wordEnd;
            if (wordStart == wordEnd) break;
            if (lineWidth + gap + wordWidth <= width) {
                line.resize(line.size() + gap, u' ');
                line.append(QStringView(paragraph).sliced(wordStart, wordEnd - wordStart));
                lineWidth += gap + wordWidth;
            } else if (wordWidth <= width) {
                if (!line.isEmpty()) breakLine();
                line.append(QStringView(paragraph).sliced(wordStart, wordEnd - wordStart));
                lineWidth = wordWidth;
            } else {
                // A word wider than any line continues the current one and is split wherever it overflows.
                for (qsizetype j = wordStart; j < wordEnd;) {
                    const qsizetype start = j;
                    const int w = charWidth(nextCodePoint(paragraph, j));
                    if (start == wordStart) {
                        if (lineWidth + gap + w <= width) {
                            line.resize(line.size() + gap, u' ');
                            lineWidth += gap;
                        } else if (!line.isEmpty()) {
                            breakLine();
                        }
                    } else if (w > 0 && lineWidth + w > width) {
                        breakLine();
                    }
                    line.append(QStringView(paragraph).sliced(start, j - start));
                    lineWidth += w;
                }
            }
        }
        lines << line;
    }
    return lines;
}

void Surface::resize(int cols, int rows) {
    m_cols = qMax(0, cols);
    m_rows = qMax(0, rows);
    m_cells.assign(std::size_t(m_cols) * std::size_t(m_rows), Cell {});
}

void Surface::fill(int x, int y, int width, int height, const Style &style) {
    Cell blank;
    blank.style = style;
    for (int row = qMax(0, y); row < qMin<qint64>(m_rows, qint64(y) + height); ++row)
        for (int col = qMax(0, x); col < qMin<qint64>(m_cols, qint64(x) + width); ++col) put(col, row, blank);
}

int Surface::text(int x, int y, const QString &text, const Style &style, int maxWidth) {
    const bool rowVisible = y >= 0 && y < m_rows;
    const qint64 end = qMin<qint64>(qint64(x) + qMax(0, maxWidth), qMax<qint64>(m_cols, x));
    qint64 col = x;
    int previous = -1;
    Cell cell;
    cell.style = style;
    Cell blank = cell;
    for (qsizetype i = 0; i < text.size();) {
        char32_t c = nextCodePoint(text, i);
        if (isControl(c)) c = U'\uFFFD';
        const int w = charWidth(c);
        if (w == 0) {
            if (previous < 0) continue;
            char32_t *chars = at(previous, y).chars;
            char32_t *slot = std::find(chars + 1, chars + Cell::maxChars, char32_t(0));
            if (slot != chars + Cell::maxChars) *slot = c;
            continue;
        }
        if (col + w > end) {
            if (col < end && rowVisible && col >= 0) put(int(col), y, blank);
            if (col < end) ++col;
            break;
        }
        previous = -1;
        if (rowVisible && col >= 0) {
            cell.chars[0] = c;
            cell.width = uint8_t(w);
            put(int(col), y, cell);
            previous = int(col);
        } else if (rowVisible && col + w > 0) {
            // The right half of a wide character straddling column 0.
            put(0, y, blank);
        }
        col += w;
    }
    return int(col - x);
}

void Surface::put(int x, int y, const Cell &cell) {
    if (!contains(x, y)) return;
    const auto blankOtherHalf = [this, y](int col) {
        const Cell &current = at(col, y);
        int other = -1;
        if (current.width == 2 && col + 1 < m_cols && at(col + 1, y).width == 0) other = col + 1;
        else if (current.width == 0 && col > 0 && at(col - 1, y).width == 2) other = col - 1;
        if (other < 0) return;
        Cell blank;
        blank.style = at(other, y).style;
        at(other, y) = blank;
    };
    if (cell.width == 2 && x + 1 >= m_cols) {
        blankOtherHalf(x);
        Cell blank;
        blank.style = cell.style;
        at(x, y) = blank;
        return;
    }
    blankOtherHalf(x);
    if (cell.width == 2) blankOtherHalf(x + 1);
    at(x, y) = cell;
    if (cell.width != 2) return;
    Cell continuation;
    continuation.chars[0] = 0;
    continuation.width = 0;
    continuation.style = cell.style;
    at(x + 1, y) = continuation;
}

Terminal::~Terminal() { restore(); }

bool Terminal::open(QString *error) {
    const auto fail = [error](const QString &message) {
        if (error) *error = message;
        return false;
    };
    if (m_open) return true;
    if (!::isatty(STDIN_FILENO) || !::isatty(STDOUT_FILENO)) return fail(QStringLiteral("cinmux tui requires an interactive terminal"));
    if (::tcgetattr(STDIN_FILENO, &m_saved) != 0)
        return fail(QStringLiteral("Cannot read terminal attributes: %1").arg(QString::fromLocal8Bit(std::strerror(errno))));
    if (::pipe2(m_signalPipe, O_CLOEXEC | O_NONBLOCK) != 0)
        return fail(QStringLiteral("Cannot create signal pipe: %1").arg(QString::fromLocal8Bit(std::strerror(errno))));
    struct termios raw = m_saved;
    ::cfmakeraw(&raw);
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;
    savedTermios = m_saved;
    signalWriteFd = m_signalPipe[1];
    if (!exitHandlerRegistered) exitHandlerRegistered = std::atexit(emergencyRestore) == 0;
    installHandlers();
    if (::tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) != 0) {
        const int savedErrno = errno;
        restoreHandlers();
        signalWriteFd = -1;
        ::close(m_signalPipe[0]);
        ::close(m_signalPipe[1]);
        m_signalPipe[0] = m_signalPipe[1] = -1;
        return fail(QStringLiteral("Cannot enter raw mode: %1").arg(QString::fromLocal8Bit(std::strerror(savedErrno))));
    }
    terminalActive = 1;
    m_open = true;
    writeAll(enterSequence, sizeof enterSequence - 1);
    m_cols = m_rows = 0;
    updateSize();
    m_invalid = true;
    m_cursorKnown = false;
    m_truecolor = detectTruecolor();
    return true;
}

void Terminal::restore() {
    if (!m_open) return;
    m_open = false;
    writeAll(leaveSequence, sizeof leaveSequence - 1);
    ::tcsetattr(STDIN_FILENO, TCSANOW, &m_saved);
    terminalActive = 0;
    restoreHandlers();
    signalWriteFd = -1;
    ::close(m_signalPipe[0]);
    ::close(m_signalPipe[1]);
    m_signalPipe[0] = m_signalPipe[1] = -1;
}

bool Terminal::updateSize() {
    struct winsize size {};
    const bool known = ::ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0;
    const int cols = known && size.ws_col > 0 ? size.ws_col : 80;
    const int rows = known && size.ws_row > 0 ? size.ws_row : 24;
    if (cols == m_cols && rows == m_rows) return false;
    m_cols = cols;
    m_rows = rows;
    m_invalid = true;
    return true;
}

int Terminal::inputFd() const { return STDIN_FILENO; }

std::vector<int> Terminal::takeSignals() {
    std::vector<int> numbers;
    if (m_signalPipe[0] < 0) return numbers;
    unsigned char buffer[64];
    for (;;) {
        const ssize_t count = ::read(m_signalPipe[0], buffer, sizeof buffer);
        if (count > 0) numbers.insert(numbers.end(), buffer, buffer + count);
        else if (!(count < 0 && errno == EINTR)) break;
    }
    return numbers;
}

void Terminal::present(const Surface &frame) {
    if (!m_open) return;
    QByteArray &out = m_output;
    out.resize(0);
    out.append("\x1b[?2026h\x1b[?25l");
    const bool full = m_invalid || frame.cols() != m_previous.cols() || frame.rows() != m_previous.rows();
    int cursorX = -1;
    int cursorY = -1;
    if (full) {
        out.append("\x1b[0m\x1b[H\x1b[2J");
        cursorX = cursorY = 0;
    }
    Style pen;
    const int cols = qMin(frame.cols(), m_cols);
    const int rows = qMin(frame.rows(), m_rows);
    for (int y = 0; y < rows; ++y) {
        for (int x = 0; x < cols; ++x) {
            const Cell &cell = frame.at(x, y);
            const bool changed = full || cell != m_previous.at(x, y);
            bool wide = false;
            if (cell.width == 2 && x + 1 < cols && frame.at(x + 1, y).width == 0) {
                wide = true;
                if (!changed && frame.at(x + 1, y) == m_previous.at(x + 1, y)) { ++x; continue; }
            } else if (cell.width == 0) {
                if (x > 0 && frame.at(x - 1, y).width == 2) continue;
                // Rewriting the left neighbour may have erased this orphan half on the terminal.
                if (!changed && (x == 0 || frame.at(x - 1, y) == m_previous.at(x - 1, y))) continue;
            } else if (!changed) {
                continue;
            }
            if (x != cursorX || y != cursorY) {
                out.append("\x1b[");
                appendNumber(out, y + 1);
                out.append(';');
                appendNumber(out, x + 1);
                out.append('H');
            }
            if (cell.style != pen) {
                appendStyle(out, cell.style, m_truecolor);
                pen = cell.style;
            }
            if (cell.width == 1 && cell.chars[0] != 0) {
                for (const char32_t c : cell.chars)
                    if (c) appendUtf8(out, c);
                cursorX = x + 1;
            } else if (wide) {
                for (const char32_t c : cell.chars)
                    if (c) appendUtf8(out, c);
                // Terminals disagree about the width of some wide characters; re-anchor the next write.
                cursorX = -1;
                ++x;
            } else {
                out.append(' ');
                cursorX = x + 1;
            }
            cursorY = y;
        }
    }
    out.append("\x1b[0m");
    if (frame.cursor.visible) {
        out.append("\x1b[");
        appendNumber(out, qMax(0, frame.cursor.y) + 1);
        out.append(';');
        appendNumber(out, qMax(0, frame.cursor.x) + 1);
        out.append('H');
        if (!m_cursorKnown || m_cursor.shape != frame.cursor.shape) {
            out.append("\x1b[");
            appendNumber(out, frame.cursor.shape);
            out.append(" q");
            m_cursor = frame.cursor;
            m_cursorKnown = true;
        }
        out.append("\x1b[?25h");
    }
    out.append("\x1b[?2026l");
    writeAll(out.constData(), std::size_t(out.size()));
    m_previous = frame;
    m_invalid = false;
}

void Terminal::invalidate() { m_invalid = true; }

void Terminal::write(const QByteArray &bytes) { writeAll(bytes.constData(), std::size_t(bytes.size())); }

void Terminal::writeAll(const char *data, std::size_t size) { writeFully(STDOUT_FILENO, data, size); }

}
