import QtQuick
import QtQuick.Controls

Button {
    id: control
    property bool destructive: false
    property bool accent: false
    property string label: text
    implicitHeight: 34
    implicitWidth: Math.max(72, contentItem.implicitWidth + leftPadding + rightPadding)
    leftPadding: 14
    rightPadding: 14
    topPadding: 8
    bottomPadding: 8
    font.family: Theme.fontFamily
    font.pixelSize: 13
    font.weight: Font.Medium
    hoverEnabled: true
    focusPolicy: Qt.TabFocus
    opacity: enabled ? 1 : 0.35
    Accessible.name: label
    contentItem: Text {
        text: control.text
        textFormat: Text.PlainText
        font: control.font
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        color: control.destructive ? Theme.danger : control.accent ? Theme.onAccent : Theme.text
        elide: Text.ElideRight
    }
    background: Rectangle {
        radius: 6
        color: control.destructive
               ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b,
                         control.enabled && control.down ? 0.16 : control.enabled && control.hovered ? 0.11 : 0.06)
               : control.accent ? Theme.accent : Theme.bgRaised
        border.width: 1
        border.color: control.enabled && control.visualFocus ? Theme.accent
                      : control.destructive ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.22)
                      : control.accent ? "transparent" : Theme.border
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: control.accent ? Theme.onAccent : Theme.text
            opacity: !control.destructive && control.enabled
                     ? control.down ? 0.12 : control.hovered ? 0.06 : 0 : 0
            Behavior on opacity { NumberAnimation { duration: 110 } }
        }
        Rectangle {
            anchors.fill: parent
            anchors.margins: -3
            radius: parent.radius + 3
            color: "transparent"
            border.width: 1
            border.color: Theme.accent
            visible: control.accent && !control.destructive && control.enabled && control.visualFocus
        }
        Behavior on color {
            ColorAnimation { duration: 110; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.2, 0.7, 0.3, 1, 1, 1] }
        }
    }
}
