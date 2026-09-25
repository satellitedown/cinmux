import QtQuick
import QtQuick.Controls

ApplicationWindow {
    id: root
    width: 600; height: 300
    minimumWidth: 440; minimumHeight: 230
    visible: true
    title: "Cinmux — Unable to open"
    color: Theme.bg
    Label {
        id: heading
        anchors.top: parent.top; anchors.left: parent.left; anchors.margins: 24
        text: "Could not open Cinmux"
        color: Theme.text
        font.pixelSize: 16; font.weight: Font.DemiBold
    }
    ScrollView {
        anchors.top: heading.bottom; anchors.bottom: closeButton.top
        anchors.left: parent.left; anchors.right: parent.right
        anchors.margins: 24
        clip: true
        TextArea {
            text: startupError
            textFormat: TextEdit.PlainText
            readOnly: true; selectByMouse: true
            wrapMode: TextEdit.Wrap
            color: Theme.textMuted
            selectionColor: Theme.selectionBg
            selectedTextColor: Theme.selectionText
            font.pixelSize: 13
            background: null
            Accessible.name: "Startup error details"
        }
    }
    ActionButton {
        id: closeButton
        anchors.bottom: parent.bottom; anchors.right: parent.right; anchors.margins: 24
        text: "Close"
        onClicked: Qt.quit()
        Component.onCompleted: forceActiveFocus()
    }
}
