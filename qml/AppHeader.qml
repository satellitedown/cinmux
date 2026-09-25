import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: header
    required property var appWindow
    readonly property bool searchHasFocus: search.activeFocus
    height: 28
    color: Theme.chrome

    function focusSearch() {
        appWindow.showSessions()
        search.forceActiveFocus()
        search.selectAll()
    }
    function focusFoldersToggle() { foldersToggle.forceActiveFocus() }
    function focusSessionsToggle() { sessionsToggle.forceActiveFocus() }

    component ToolbarButton: IconButton {
        width: 22
        height: 22
        icon.width: 14
        icon.height: 14
    }


    Row {
        anchors.left: parent.left
        anchors.leftMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        spacing: 3
        ToolbarButton {
            id: foldersToggle
            iconName: "panel-left"
            label: (header.appWindow.foldersVisible ? "Hide folders" : "Show folders") + " (Ctrl+Shift+B)"
            onClicked: header.appWindow.toggleFolders()
        }
        ToolbarButton {
            id: sessionsToggle
            iconName: "panel-right"
            label: (header.appWindow.sessionsVisible ? "Hide sessions" : "Show sessions") + " (Ctrl+Shift+L)"
            onClicked: header.appWindow.toggleSessions()
        }
        ToolbarButton { iconName: "plus"; label: "New tab (Ctrl+Shift+N)"; onClicked: header.appWindow.newSession() }
    }
    Row {
        anchors.right: parent.right
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        spacing: 3
        ToolbarButton {
            iconName: "columns-2"
            label: "Split right"
            enabled: controller.selected.status === "running"
            onClicked: { controller.splitActive("right"); header.appWindow.focusTerminal() }
        }
        ToolbarButton {
            iconName: "rows-2"
            label: "Split down"
            enabled: controller.selected.status === "running"
            onClicked: { controller.splitActive("down"); header.appWindow.focusTerminal() }
        }
        ToolbarButton {
            iconName: "bell"
            label: "Next attention (Ctrl+Alt+U)"
            enabled: controller.attentionCount > 0
            toggled: controller.attentionCount > 0
            onClicked: header.appWindow.nextAttention()
        }
        Item {
            width: 184
            height: 22
            TextField {
                id: search
                anchors.fill: parent
                anchors.leftMargin: 4
                anchors.rightMargin: 4
                leftPadding: 32
                rightPadding: clearSearch.visible ? 30 : 8
                topPadding: 0
                bottomPadding: 0
                placeholderText: "Search sessions"
                Accessible.name: "Search sessions"
                Accessible.description: "Search session titles, working directories and branches (Ctrl+Shift+F)"
                color: Theme.text
                placeholderTextColor: Theme.textMuted
                font.family: Theme.fontFamily
                font.pixelSize: 12
                selectionColor: Theme.selectionBg
                selectedTextColor: Theme.selectionText
                text: controller.search
                onTextEdited: controller.search = text
                onActiveFocusChanged: { if (activeFocus) terminalCompositor.clearFocus() }
                onAccepted: header.appWindow.focusTerminal()
                Keys.onEscapePressed: {
                    controller.search = ""
                    header.appWindow.focusTerminal()
                }
                background: Rectangle {
                    color: Theme.bgHover
                    border.width: search.activeFocus ? 1 : 0
                    border.color: Theme.accent
                    radius: 6
                }
                IconButton {
                    x: 8
                    anchors.verticalCenter: parent.verticalCenter
                    width: 18
                    height: 18
                    padding: 0
                    iconName: "search"
                    enabled: false
                    opacity: 1
                    Accessible.ignored: true
                    background: Item {}
                }
                IconButton {
                    id: clearSearch
                    anchors.right: parent.right
                    anchors.rightMargin: 3
                    anchors.verticalCenter: parent.verticalCenter
                    width: 20
                    height: 20
                    padding: 3
                    icon.width: 14
                    icon.height: 14
                    iconName: "x"
                    label: "Clear search"
                    visible: search.text.length > 0
                    onClicked: { controller.search = ""; search.forceActiveFocus() }
                }
            }
        }
        ToolbarButton {
            id: moreButton
            iconName: "ellipsis"
            label: "More"
            toggled: moreMenu.visible
            onClicked: moreMenu.open()
            AppMenu {
                id: moreMenu
                x: moreButton.width - width
                y: moreButton.height + 6
                width: 312
                onAboutToShow: header.appWindow.popupOpened()
                onClosed: header.appWindow.popupClosed()
                AppMenuItem { text: "New tab"; iconName: "plus"; hint: "Ctrl+Shift+N"; onTriggered: header.appWindow.newSession() }
                AppMenuItem { text: "New folder"; iconName: "folder-plus"; hint: "Ctrl+Alt+N"; onTriggered: header.appWindow.newFolder() }
                AppMenuSeparator {}
                AppMenuItem { text: "Rename session"; iconName: "pencil"; hint: "Ctrl+R"; enabled: !!controller.selectedId; onTriggered: header.appWindow.renameSession() }
                AppMenuItem { text: "Split right"; iconName: "columns-2"; enabled: controller.selected.status === "running"; onTriggered: { controller.splitActive("right"); header.appWindow.focusTerminal() } }
                AppMenuItem { text: "Split down"; iconName: "rows-2"; enabled: controller.selected.status === "running"; onTriggered: { controller.splitActive("down"); header.appWindow.focusTerminal() } }
                AppMenuSeparator {}
                AppMenuItem {
                    text: header.appWindow.foldersVisible ? "Hide folders" : "Show folders"
                    iconName: "panel-left"
                    hint: "Ctrl+Shift+B"
                    onTriggered: header.appWindow.toggleFolders()
                }
                AppMenuItem {
                    text: header.appWindow.sessionsVisible ? "Hide sessions" : "Show sessions"
                    iconName: "panel-right"
                    hint: "Ctrl+Shift+L"
                    onTriggered: header.appWindow.toggleSessions()
                }
                AppMenuSeparator {}
                AppMenuItem { text: "Close pane…"; iconName: "x"; destructive: true; enabled: !!controller.selectedId; onTriggered: header.appWindow.confirmClosePane() }
                AppMenuItem {
                    text: "Close session…"
                    iconName: "trash-2"
                    destructive: true
                    hint: "Ctrl+Shift+W"
                    enabled: !!controller.selectedId
                    onTriggered: header.appWindow.confirmCloseSession(controller.selectedId, controller.selected.title)
                }
                AppMenuSeparator {}
                AppMenuItem { text: "Quit Cinmux"; iconName: "log-out"; hint: "Ctrl+Shift+Q"; onTriggered: Qt.quit() }
            }
        }
    }
    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
}
