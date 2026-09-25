import QtQuick
import QtQuick.Effects

Rectangle {
    color: Theme.bgRaised
    radius: 12
    border.color: Theme.border
    layer.enabled: true
    layer.effect: MultiEffect {
        shadowEnabled: true
        shadowColor: Qt.rgba(0, 0, 0, Theme.dark ? 0.36 : 0.16)
        shadowVerticalOffset: 6
        shadowBlur: 0.65
        blurMax: 24
    }
}
