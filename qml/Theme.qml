pragma Singleton
import QtQuick

QtObject {
    readonly property string mode: themeService.mode
    readonly property string fontFamily: "Noto Sans"
    readonly property bool dark: mode === "dark"
    function surface(source, darkBase, lightBase) {
        return Qt.tint(dark ? darkBase : lightBase, Qt.rgba(source.r, source.g, source.b, 0.035))
    }
    readonly property color bg: themeService.colors.bg
    readonly property color bgSidebar: bg
    readonly property color chrome: Qt.rgba(bgSidebar.r, bgSidebar.g, bgSidebar.b, dark ? 0.80 : 0.86)
    readonly property color bgRaised: surface(themeService.colors.bgRaised, "#2b2b2e", "#ffffff")
    readonly property color bgHover: Qt.rgba(text.r, text.g, text.b, dark ? 0.055 : 0.045)
    readonly property color border: Qt.rgba(text.r, text.g, text.b, dark ? 0.10 : 0.11)
    // Foot draws the published theme background; its unused cell remainder must match it.
    readonly property color terminal: themeService.colors.bg
    readonly property color text: dark ? "#ededee" : "#252528"
    readonly property color textMuted: dark ? "#aaaab0" : "#66666e"
    readonly property color accent: themeService.colors.accent
    readonly property color accentDim: Qt.rgba(accent.r, accent.g, accent.b, 0.12)
    readonly property color selected: Qt.rgba(text.r, text.g, text.b, dark ? 0.10 : 0.075)
    readonly property color danger: themeService.colors.danger
    readonly property color warning: themeService.colors.warning
    readonly property color scrollbar: themeService.colors.scrollbar
    readonly property color scrollbarHover: themeService.colors.scrollbarHover
    readonly property color onAccent: themeService.colors.onAccent
    readonly property color shadowColor: themeService.colors.shadowColor
    readonly property color overlay: themeService.colors.overlay
    readonly property color tagRemoveHover: themeService.colors.tagRemoveHover
    readonly property color selectionBg: themeService.colors.selectionBg
    readonly property color selectionText: themeService.colors.selectionText
}
