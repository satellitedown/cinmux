import QtQuick
import QtQuick.Controls
import Cinmux.Native 1.0

FocusScope {
    id: pane
    required property var appWindow
    readonly property var selected: controller.selected
    readonly property bool selectedReady: {
        const nativeViews = terminalCompositor.views
        for (let i = 0; i < nativeViews.length; ++i) {
            if (nativeViews[i].sessionId === controller.selectedId)
                return nativeViews[i].ready
        }
        return false
    }
    signal terminalReady(string sessionId)

    function focusTerminal() {
        if (controller.selectedId)
            terminalCompositor.focusTerminal(controller.selectedId)
    }

    Rectangle { anchors.fill: parent; color: Theme.bg }
    Item {
        id: content
        anchors.fill: parent
        clip: true
        Rectangle {
            anchors.fill: parent
            color: Theme.terminal
            visible: !!controller.selectedId && pane.selectedReady && !pane.selected.terminalError
        }

        // The compositor's retained views, never the filtered session list, own
        // these native items. Their buffers remain at client logical size.
        Repeater {
            model: terminalCompositor.views
            TerminalSurfaceItem {
                required property var modelData
                view: modelData
                compositor: terminalCompositor
                width: content.width
                height: content.height
                readonly property bool selectedView: modelData.sessionId === controller.selectedId
                visible: selectedView
                enabled: selectedView
                function configureSize() {
                    if (selectedView && content.width > 0 && content.height > 0)
                        terminalCompositor.configure(modelData.sessionId, Math.floor(content.width), Math.floor(content.height))
                }
                Component.onCompleted: {
                    configureSize()
                    if (selectedView && modelData.ready)
                        pane.terminalReady(modelData.sessionId)
                }
                onSelectedViewChanged: configureSize()
                onActiveFocusChanged: { if (activeFocus) terminalCompositor.focusTerminal(modelData.sessionId) }
                Connections {
                    target: content
                    function onWidthChanged() { configureSize() }
                    function onHeightChanged() { configureSize() }
                }
            }
        }
        ActionButton {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: 12
            visible: pane.selected.status === "stopped" && pane.selectedReady && !pane.selected.terminalError
            text: "Start session"
            onClicked: { controller.startSession(controller.selectedId, ""); pane.appWindow.focusTerminal() }
        }
        Column {
            anchors.centerIn: parent
            width: Math.max(0, Math.min(parent.width - 40, 440))
            spacing: 12
            visible: !controller.selectedId || !!pane.selected.terminalError || !pane.selectedReady
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: Theme.text
                font.family: Theme.fontFamily
                font.pixelSize: 17
                font.weight: Font.DemiBold
                visible: !!controller.selectedId
                text: pane.selected.terminalError ? "Terminal unavailable"
                      : pane.selected.status === "starting" ? "Starting session…"
                      : pane.selected.status === "stopped" ? "Session stopped" : "Connecting terminal…"
            }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
                color: Theme.textMuted
                font.family: Theme.fontFamily
                font.pixelSize: 13
                lineHeight: 1.45
                visible: !!controller.selectedId && (!!pane.selected.terminalError || pane.selected.status === "stopped")
                text: pane.selected.terminalError
                      ? pane.selected.terminalError + (pane.selected.status === "running" ? "\nThe session and its jobs are still running." : "")
                      : "Start a fresh shell in the saved working directory. Previous commands will not be replayed."
            }
            ActionButton {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: !controller.selectedId || pane.selected.status === "stopped" || !!pane.selected.terminalError
                text: !controller.selectedId ? "Create a terminal session"
                      : pane.selected.status === "stopped" ? "Start session" : "Reconnect terminal"
                onClicked: {
                    if (!controller.selectedId) {
                        pane.appWindow.newSession()
                    } else {
                        if (pane.selected.status === "stopped") controller.startSession(controller.selectedId, "")
                        else controller.reconnectTerminal(controller.selectedId)
                        pane.appWindow.focusTerminal()
                    }
                }
            }
        }
    }
    Connections {
        target: terminalCompositor
        function onViewReady(id) { pane.terminalReady(id) }
    }
}
