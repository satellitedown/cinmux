#include "theme.h"
#include <QColor>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>
#include <toml++/toml.hpp>
#include <cmath>

namespace {
QColor mix(const QColor &a, const QColor &b, double amount) {
    return QColor(qRound(a.red() + (b.red() - a.red()) * amount),
                  qRound(a.green() + (b.green() - a.green()) * amount),
                  qRound(a.blue() + (b.blue() - a.blue()) * amount));
}
QColor onColor(const QColor &color) {
    auto linear = [](double channel) {
        const double s = channel / 255.;
        return s <= .03928 ? s / 12.92 : std::pow((s + .055) / 1.055, 2.4);
    };
    const double luminance = .2126 * linear(color.red()) + .7152 * linear(color.green()) + .0722 * linear(color.blue());
    return (luminance + .05) / .05 >= 1.05 / (luminance + .05) ? QColor(Qt::black) : QColor(Qt::white);
}
QColor alpha(Qt::GlobalColor color, double amount) {
    QColor result(color); result.setAlphaF(amount); return result;
}
}

ThemePalette Theme::defaultPalette() {
    return {"dark", {
        {"bg", QColor("#151719")}, {"bgSidebar", QColor("#111315")},
        {"bgRaised", QColor("#1d2023")}, {"bgHover", QColor("#23262a")},
        {"border", QColor("#2b3033")}, {"text", QColor("#e6e8e5")},
        {"textMuted", QColor("#9da5a0")}, {"accent", QColor("#a3be78")},
        {"accentDim", QColor("#6f7a4a")}, {"selected", QColor("#273023")},
        {"danger", QColor("#e5644e")}, {"warning", QColor("#d9a06b")},
        {"scrollbar", QColor("#3a4045")}, {"scrollbarHover", QColor("#4a5258")},
        {"onAccent", QColor("#1c1d20")}, {"shadowColor", alpha(Qt::black, .4)},
        {"overlay", alpha(Qt::black, .45)}, {"tagRemoveHover", alpha(Qt::black, .25)},
        {"selectionBg", QColor("#a3be78")}, {"selectionText", QColor("#1c1d20")}
    }};
}

std::optional<ThemePalette> Theme::parse(const QByteArray &text, bool lightMarker) {
    if (text.size() > 65536) return std::nullopt;
    toml::table table;
    try { table = toml::parse(std::string_view(text.constData(), size_t(text.size()))); }
    catch (const toml::parse_error &) { return std::nullopt; }
    auto pick = [&table](std::initializer_list<const char *> keys, QColor fallback = {}) {
        static const QRegularExpression valid("^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$");
        for (const auto *key : keys) {
            auto raw = table[key].value<std::string>();
            if (!raw) continue;
            auto value = QString::fromStdString(*raw);
            if (!valid.match(value).hasMatch()) continue;
            if (value.size() == 4) value = QString("#%1%1%2%2%3%3").arg(value[1]).arg(value[2]).arg(value[3]);
            return QColor(value);
        }
        return fallback;
    };
    const QColor bg = pick({"background", "bg", "color0"});
    const QColor fg = pick({"foreground", "fg", "color7"});
    if (!bg.isValid() || !fg.isValid()) return std::nullopt;
    QString mode;
    for (const auto *key : {"mode", "theme_type"}) {
        auto raw = table[key].value<std::string>();
        if (raw && (*raw == "light" || *raw == "dark")) { mode = QString::fromStdString(*raw); break; }
    }
    if (mode.isEmpty()) mode = lightMarker || bg.red() + bg.green() + bg.blue() > 382 ? "light" : "dark";
    const bool dark = mode == "dark";
    const QColor accent = pick({"accent", "blue", "color4"}, fg);
    const QColor selection = pick({"selection_background", "selection"}, accent);
    return ThemePalette{mode, {
        {"bg", bg}, {"bgSidebar", pick({"dark_background", "dark_bg"}, dark ? mix(bg, Qt::black, .18) : mix(bg, fg, .03))},
        {"bgRaised", pick({"lighter_background", "lighter_bg"}, mix(bg, fg, .05))},
        {"bgHover", mix(bg, fg, .1)}, {"border", mix(bg, fg, .18)},
        {"text", fg}, {"textMuted", mix(fg, bg, .3)}, {"accent", accent},
        {"accentDim", mix(bg, accent, .24)}, {"selected", mix(bg, accent, .16)},
        {"danger", pick({"red", "color1"}, QColor(dark ? "#e5644e" : "#b42318"))},
        {"warning", pick({"orange", "yellow", "color3"}, QColor(dark ? "#d9a06b" : "#986000"))},
        {"scrollbar", mix(bg, fg, .22)}, {"scrollbarHover", mix(bg, fg, .34)},
        {"onAccent", onColor(accent)}, {"shadowColor", alpha(Qt::black, dark ? .4 : .18)},
        {"overlay", alpha(Qt::black, dark ? .45 : .30)},
        {"tagRemoveHover", alpha(dark ? Qt::white : Qt::black, .1)},
        {"selectionBg", selection}, {"selectionText", pick({"selection_foreground"}, onColor(selection))}
    }};
}

Theme::Theme(const QString &directory, QObject *parent) : QObject(parent), m_directory(directory) {
    if (m_directory.isEmpty()) {
        m_directory = qEnvironmentVariable("CINMUX_THEME_DIR");
        if (!m_directory.isEmpty() && !QDir::isAbsolutePath(m_directory)) {
            qWarning("cinmux: CINMUX_THEME_DIR must be absolute; using default palette");
            return;
        }
        if (m_directory.isEmpty()) {
            QString state = qEnvironmentVariable("XDG_STATE_HOME", QDir::homePath() + "/.local/state");
            m_directory = state + "/omarchy/current/theme";
        }
    }
    connect(&m_timer, &QTimer::timeout, this, &Theme::refresh);
    refresh(); m_timer.start(1000);
}

void Theme::refresh() {
    QFile file(m_directory + "/colors.toml");
    if (!QFileInfo(file).isFile() || !file.open(QIODevice::ReadOnly) || file.size() > 65536) return;
    auto next = parse(file.read(65537), QFileInfo(m_directory + "/light.mode").isFile());
    if (next && *next != m_palette) { m_palette = std::move(*next); emit changed(); }
}
