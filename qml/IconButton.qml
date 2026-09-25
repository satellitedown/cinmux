import QtQuick
import QtQuick.Controls

Button {
    id: control
    property string iconName: ""
    property string label: ""
    property bool toggled: false
    property bool destructive: false
    width: 34
    height: 34
    implicitWidth: 34
    implicitHeight: 34
    // Compact callers resize the button; keep their requested icon size centered.
    padding: Math.max(0, (Math.min(width, height) - Math.max(icon.width, icon.height)) / 2)
    font.family: Theme.fontFamily
    hoverEnabled: true
    focusPolicy: Qt.TabFocus
    display: AbstractButton.IconOnly
    icon.source: iconName ? "qrc:/cinmux/icons/" + iconName + ".svg" : ""
    icon.width: 18
    icon.height: 18
    icon.color: destructive && (hovered || down || visualFocus) ? Theme.danger
                : toggled || hovered || down || visualFocus ? Theme.text : Theme.textMuted
    opacity: enabled ? 1 : 0.35
    Accessible.name: label
    Accessible.description: label
    background: Rectangle {
        radius: 6
        color: control.destructive && control.enabled && (control.hovered || control.down)
               ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, control.down ? 0.16 : 0.09)
               : control.down || control.toggled ? Theme.selected
               : control.hovered && control.enabled ? Theme.bgHover : "transparent"
        border.width: control.enabled && control.visualFocus ? 1 : 0
        border.color: Theme.accent
        Behavior on color {
            ColorAnimation { duration: 110; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.2, 0.7, 0.3, 1, 1, 1] }
        }
    }
    AppToolTip {
        visible: control.enabled && control.hovered && control.label.length > 0
        text: control.label
    }
}
