import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

MenuItem {
    id: control
    property string iconName: ""
    property string hint: ""
    property bool destructive: false
    readonly property color foreground: destructive ? Theme.danger : Theme.text
    implicitHeight: 32
    implicitWidth: contentItem.implicitWidth + leftPadding + rightPadding
    leftPadding: 9
    rightPadding: 9
    topPadding: 0
    bottomPadding: 0
    font.family: Theme.fontFamily
    font.pixelSize: 13
    font.weight: Font.Normal
    hoverEnabled: true
    icon.source: iconName ? "qrc:/cinmux/icons/" + iconName + ".svg" : ""
    icon.width: 16
    icon.height: 16
    opacity: enabled ? 1 : 0.42
    Accessible.description: hint
    indicator: null
    arrow: null
    contentItem: RowLayout {
        spacing: 10
        IconButton {
            Layout.preferredWidth: 16
            Layout.preferredHeight: 16
            enabled: false
            opacity: 1
            icon.source: control.checked ? "qrc:/cinmux/icons/check.svg"
                         : control.subMenu ? control.subMenu.icon.source : control.icon.source
            icon.width: 16
            icon.height: 16
            icon.color: control.destructive ? control.foreground : Theme.textMuted
            background: null
            Accessible.ignored: true
        }
        Text {
            Layout.fillWidth: true
            text: control.text
            textFormat: Text.PlainText
            font: control.font
            color: control.foreground
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
        }
        Text {
            visible: control.hint.length > 0
            Layout.leftMargin: 12
            text: control.hint
            textFormat: Text.PlainText
            font.family: Theme.fontFamily
            font.pixelSize: 11
            color: Theme.textMuted
        }
        IconButton {
            visible: !!control.subMenu
            Layout.preferredWidth: 12
            Layout.preferredHeight: 12
            enabled: false
            opacity: 1
            iconName: "chevron-right"
            icon.width: 12
            icon.height: 12
            icon.color: Theme.textMuted
            background: null
            Accessible.ignored: true
        }
    }
    background: Rectangle {
        radius: 6
        color: control.highlighted || control.down
               ? control.destructive ? Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.10) : Theme.bgHover
               : "transparent"
        border.width: control.visualFocus ? 1 : 0
        border.color: Theme.border
    }
}
