import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Dialog {
    id: dialog
    property string message: ""
    property string confirmText: "Confirm"
    property bool destructive: true
    modal: true
    focus: true
    width: Math.min(440, parent ? parent.width - 40 : 440)
    anchors.centerIn: parent
    padding: 24
    topPadding: 10
    bottomPadding: 24
    font.family: Theme.fontFamily
    font.pixelSize: 13
    closePolicy: Popup.CloseOnEscape
    background: PopupSurface {}
    Overlay.modal: Rectangle { color: Theme.overlay }
    header: Label {
        text: dialog.title
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
        Accessible.name: dialog.title
        color: Theme.text
        font.family: Theme.fontFamily
        font.pixelSize: 17
        font.weight: Font.DemiBold
        lineHeight: 1.25
        leftPadding: 24
        rightPadding: 24
        topPadding: 24
    }
    contentItem: ColumnLayout {
        spacing: 24
        Label {
            Layout.fillWidth: true
            text: dialog.message
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: Theme.textMuted
            font.family: Theme.fontFamily
            font.pixelSize: 13
            lineHeight: 1.45
        }
        RowLayout {
            Layout.alignment: Qt.AlignRight
            spacing: 8
            ActionButton {
                id: cancel
                text: "Cancel"
                onClicked: dialog.reject()
                Keys.onReturnPressed: dialog.reject()
                Keys.onEnterPressed: dialog.reject()
            }
            ActionButton {
                text: dialog.confirmText
                destructive: dialog.destructive
                accent: !dialog.destructive
                font.weight: Font.DemiBold
                onClicked: dialog.accept()
                Keys.onReturnPressed: dialog.accept()
                Keys.onEnterPressed: dialog.accept()
            }
        }
    }
    onOpened: cancel.forceActiveFocus(Qt.TabFocusReason)
}
