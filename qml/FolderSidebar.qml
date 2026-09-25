import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

FocusScope {
    id: root
    required property var appWindow
    property bool editing: false
    property bool creating: false
    property string editingId: ""
    property string draft: ""
    property string errorMessage: ""
    property bool submitting: false
    property var activeEditor: null

    function focusEditor() {
        if (editing && activeEditor) {
            terminalCompositor.clearFocus()
            activeEditor.forceActiveFocus()
            activeEditor.selectAll()
            const point = activeEditor.mapToItem(sections, 0, 0)
            if (point.y < scroll.contentY) scroll.contentY = point.y
            else if (point.y + activeEditor.height > scroll.contentY + scroll.height)
                scroll.contentY = point.y + activeEditor.height - scroll.height
        }
    }
    function beginCreate() {
        creating = true
        editingId = ""
        draft = ""
        errorMessage = ""
        editing = true
        Qt.callLater(focusEditor)
    }
    function beginRename(id, name) {
        creating = false
        editingId = id
        draft = name
        errorMessage = ""
        editing = true
        Qt.callLater(focusEditor)
    }
    function cancelEdit(restoreTerminal = false) {
        const targetId = editingId
        // Clear the editor's focus before its Loader hides it; a FocusScope
        // otherwise remembers the hidden TextField as its focused child.
        if (activeEditor) activeEditor.focus = false
        editing = false
        errorMessage = ""
        if (!visible || !enabled || (restoreTerminal && controller.selectedId)) {
            appWindow.focusTerminal()
            return
        }
        for (let i = 0; i < folderRepeater.count; ++i) {
            const row = folderRepeater.itemAt(i)
            if (row && row.modelData.id === targetId) {
                row.focusNavigation()
                return
            }
        }
        allSessions.forceActiveFocus()
    }
    function submitEdit() {
        if (submitting || !editing) return
        errorMessage = ""
        submitting = true
        if (creating) controller.createFolder(draft)
        else controller.renameFolder(editingId, draft)
        submitting = false
        if (!errorMessage) cancelEdit(true)
        else Qt.callLater(focusEditor)
    }
    function handleOperationError(id, message) {
        if (!submitting || id !== "") return false
        errorMessage = message
        return true
    }
    function chooseView(id) {
        terminalCompositor.clearFocus()
        forceActiveFocus()
        controller.search = ""
        controller.view = id
        appWindow.showSessions()
    }
    function acceptSession(drop, folderId) {
        if (!drop.source || !drop.source.sessionId) return
        const id = drop.source.sessionId
        drop.accept(Qt.MoveAction)
        // Finish the drag before a filtered model reset can remove its row.
        Qt.callLater(function() { controller.moveSession(id, folderId) })
    }
    function showMenu(id, name, x, y) {
        terminalCompositor.clearFocus()
        forceActiveFocus()
        folderMenu.folderId = id
        folderMenu.folderName = name
        folderMenu.popup(x, y)
    }

    Rectangle { anchors.fill: parent; color: Theme.chrome }
    Rectangle { anchors.right: parent.right; height: parent.height; width: 1; color: Theme.border }
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: mouse => appWindow.showSidebarMenu(root, mouse.x, mouse.y)
    }
    Keys.onPressed: function(event) {
        if (!root.editing && (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && event.modifiers & Qt.ShiftModifier))) {
            appWindow.showSidebarMenu(root, 12, 36)
            event.accepted = true
        }
    }

    component NavigationButton: Button {
        id: navigation
        required property string caption
        required property string viewId
        required property int itemCount
        property string iconName: "folder"
        property bool dropTarget: false
        width: parent.width
        height: 28
        implicitHeight: 28
        leftPadding: 7
        rightPadding: 7
        topPadding: 4
        bottomPadding: 4
        font.family: Theme.fontFamily
        onActiveFocusChanged: if (activeFocus) terminalCompositor.clearFocus()
        hoverEnabled: true
        text: caption
        Accessible.name: caption + ", " + itemCount + " sessions"
        onClicked: root.chooseView(viewId)
        background: Rectangle {
            radius: 6
            color: navigation.dropTarget || (controller.view === navigation.viewId && !controller.search)
                   ? Theme.selected : navigation.hovered ? Theme.bgHover : "transparent"
            border.width: navigation.activeFocus || navigation.dropTarget ? 1 : 0
            border.color: Theme.accent
            Behavior on color { ColorAnimation { duration: 110 } }
        }
        contentItem: RowLayout {
            spacing: 7
            Button {
                enabled: false
                padding: 0
                Layout.preferredWidth: 16
                Layout.preferredHeight: 16
                background: null
                icon.source: "qrc:/cinmux/icons/" + navigation.iconName + ".svg"
                icon.color: Theme.textMuted
                icon.width: 16
                icon.height: 16
                display: AbstractButton.IconOnly
                Accessible.ignored: true
            }
            Text {
                Layout.fillWidth: true
                text: navigation.caption
                textFormat: Text.PlainText
                color: Theme.text
                elide: Text.ElideRight
                font.pixelSize: 13
                font.family: Theme.fontFamily
                font.weight: controller.view === navigation.viewId && !controller.search ? Font.DemiBold : Font.Normal
            }
            Text { visible: navigation.itemCount > 0; text: navigation.itemCount; color: Theme.textMuted; font.family: Theme.fontFamily; font.pixelSize: 12; textFormat: Text.PlainText }
        }
        AppToolTip {
            id: navigationTip
            visible: navigation.hovered
            delay: 700
            text: navigation.caption
        }
    }

    Component {
        id: nameEditor
        Column {
            width: parent.width
            spacing: 4
            topPadding: 2
            bottomPadding: 2
            TextField {
                id: nameField
                x: 3
                width: parent.width - 6
                height: 28
                text: root.draft
                placeholderText: "Folder name"
                color: Theme.text
                selectionColor: Theme.selectionBg
                selectedTextColor: Theme.selectionText
                placeholderTextColor: Theme.textMuted
                font.pixelSize: 13
                font.family: Theme.fontFamily
                leftPadding: 8
                rightPadding: 8
                selectByMouse: true
                Accessible.name: root.creating ? "New folder name" : "Rename folder"
                background: Rectangle { color: Theme.bg; radius: 6; border.color: root.errorMessage ? Theme.danger : Theme.accent }
                onTextEdited: { root.draft = text; root.errorMessage = "" }
                onAccepted: root.submitEdit()
                Keys.onEscapePressed: function(event) { root.cancelEdit(); event.accepted = true }
                onActiveFocusChanged: if (activeFocus) terminalCompositor.clearFocus()
                Component.onCompleted: { root.activeEditor = nameField; Qt.callLater(root.focusEditor) }
                Component.onDestruction: if (root.activeEditor === nameField) root.activeEditor = null
            }
            Text {
                x: 8
                width: parent.width - 16
                visible: root.errorMessage !== ""
                text: root.errorMessage
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: Theme.danger
                font.pixelSize: 12
                font.family: Theme.fontFamily
                Accessible.role: Accessible.StaticText
            }
        }
    }

    Flickable {
        id: scroll
        anchors.fill: parent
        anchors.rightMargin: 1
        contentWidth: width
        contentHeight: sections.y + sections.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { }
        Column {
            id: sections
            x: 8
            y: 4
            width: scroll.width - 16
            spacing: 1
            bottomPadding: 5
            NavigationButton {
                id: allSessions
                caption: "Tabs"
                viewId: "all"
                itemCount: controller.totalCount
                iconName: "terminal"
                dropTarget: allDrop.containsDrag
                DropArea {
                    id: allDrop
                    anchors.fill: parent
                    keys: ["cinmux-session"]
                    onDropped: function(drop) { root.acceptSession(drop, "") }
                }
            }
            NavigationButton { caption: "Needs Attention"; viewId: "attention"; itemCount: controller.attentionCount; iconName: "bell" }
            Item { width: 1; height: 6 }
            RowLayout {
                width: parent.width
                height: 24
                spacing: 6
                Text {
                    Layout.leftMargin: 7
                    Layout.fillWidth: true
                    text: "Folders"
                    textFormat: Text.PlainText
                    color: Theme.textMuted
                    font.family: Theme.fontFamily
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                }
                IconButton {
                    Layout.rightMargin: 2
                    width: 24; height: 24
                    implicitWidth: 24; implicitHeight: 24
                    icon.width: 15; icon.height: 15
                    iconName: "plus"
                    label: "New folder"
                    onClicked: root.beginCreate()
                }
            }
            Loader { width: parent.width; active: root.editing && root.creating; visible: active; sourceComponent: nameEditor }
            Repeater {
                id: folderRepeater
                model: controller.folders
                delegate: Column {
                    id: folderRow
                    required property var modelData
                    width: sections.width
                    property bool renaming: root.editing && !root.creating && root.editingId === modelData.id
                    function focusNavigation() { folderNavigation.forceActiveFocus() }
                    Loader { width: parent.width; active: folderRow.renaming; visible: active; sourceComponent: nameEditor }
                    Item {
                        id: folderItem
                        width: parent.width
                        height: visible ? 28 : 0
                        visible: !folderRow.renaming
                        HoverHandler { id: folderHover }
                        Rectangle {
                            anchors.fill: parent
                            radius: 6
                            color: folderDrop.containsDrag || (controller.view === folderRow.modelData.id && !controller.search)
                                   ? Theme.selected : folderHover.hovered ? Theme.bgHover : "transparent"
                            border.width: folderDrop.containsDrag || folderNavigation.activeFocus ? 1 : 0
                            border.color: Theme.accent
                            Behavior on color { ColorAnimation { duration: 110 } }
                        }
                        RowLayout {
                            anchors.fill: parent
                            spacing: 4
                            NavigationButton {
                                id: folderNavigation
                                Layout.fillWidth: true
                                caption: folderRow.modelData.name
                                viewId: folderRow.modelData.id
                                itemCount: folderRow.modelData.count
                                background: null
                                Keys.onPressed: function(event) {
                                    if (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && event.modifiers & Qt.ShiftModifier)) {
                                        const point = mapToItem(root, 0, height)
                                        root.showMenu(folderRow.modelData.id, folderRow.modelData.name, point.x, point.y)
                                        event.accepted = true
                                    }
                                }
                            }
                            IconButton {
                                id: folderMore
                                Layout.rightMargin: 2
                                width: 22; height: 24
                                implicitWidth: 22; implicitHeight: 24
                                icon.width: 14; icon.height: 14
                                iconName: "ellipsis"
                                label: "Folder actions for " + folderRow.modelData.name
                                opacity: folderHover.hovered || folderNavigation.activeFocus || activeFocus || (folderMenu.visible && folderMenu.folderId === folderRow.modelData.id) ? 1 : 0
                                onClicked: {
                                    const point = mapToItem(root, width, height)
                                    root.showMenu(folderRow.modelData.id, folderRow.modelData.name, point.x, point.y)
                                }
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.RightButton
                            onClicked: function(mouse) {
                                const point = mapToItem(root, mouse.x, mouse.y)
                                root.showMenu(folderRow.modelData.id, folderRow.modelData.name, point.x, point.y)
                            }
                        }
                        DropArea {
                            id: folderDrop
                            anchors.fill: parent
                            keys: ["cinmux-session"]
                            onDropped: function(drop) { root.acceptSession(drop, folderRow.modelData.id) }
                        }
                    }
                }
            }
        }
    }
    AppMenu {
        id: folderMenu
        implicitWidth: 224
        property string folderId: ""
        property string folderName: ""
        onAboutToShow: appWindow.popupOpened()
        onClosed: appWindow.popupClosed()
        AppMenuItem {
            text: "New tab"
            iconName: "plus"
            onTriggered: {
                root.chooseView(folderMenu.folderId)
                appWindow.newSession()
            }
        }
        AppMenuItem { text: "New folder"; iconName: "folder-plus"; hint: "Ctrl+Alt+N"; onTriggered: appWindow.newFolder() }
        AppMenuSeparator { }
        AppMenuItem { text: "Rename folder"; iconName: "pencil"; onTriggered: root.beginRename(folderMenu.folderId, folderMenu.folderName) }
        AppMenuSeparator { }
        AppMenuItem { text: "Delete folder…"; iconName: "trash-2"; destructive: true; onTriggered: appWindow.confirmDeleteFolder(folderMenu.folderId, folderMenu.folderName) }
    }
}
