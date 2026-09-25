import QtQuick
import QtQuick.Controls

ToolTip {
    id: control
    property real maximumWidth: 360
    width: Math.min(implicitWidth, maximumWidth,
                    Overlay.overlay ? Math.max(1, Overlay.overlay.width - 24) : maximumWidth)
    margins: 12
    delay: 600
    leftPadding: 10
    rightPadding: 10
    topPadding: 7
    bottomPadding: 7
    font.family: Theme.fontFamily
    font.pixelSize: 12
    contentItem: Text {
        text: control.text
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: Theme.text
        font: control.font
        lineHeight: 1.25
    }
    background: PopupSurface { radius: 8 }
}
