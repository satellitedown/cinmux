import QtQuick
import QtQuick.Controls

Menu {
    id: control
    implicitWidth: 280
    padding: 6
    margins: 12
    overlap: -4
    focus: true
    popupType: Popup.Item
    font.family: Theme.fontFamily
    font.pixelSize: 13
    delegate: AppMenuItem { }
    background: PopupSurface { }
    enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 90 } }
    exit: Transition { NumberAnimation { property: "opacity"; from: 1; to: 0; duration: 70 } }
}
