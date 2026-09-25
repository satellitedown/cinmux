import QtQml.Models
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

FocusScope {
    id: root
    required property var appWindow
    property string editingId: ""
    property string draft: ""
    property string errorMessage: ""
    property bool submitting: false
    property var activeEditor: null
    property bool dragging: false
    readonly property string heading: {
        if (controller.search) return "Search results"
        if (controller.view === "all") return ""
        if (controller.view === "attention") return "Needs Attention"
        for (const folder of controller.folders)
            if (folder.id === controller.view) return folder.name
        return "Sessions"
    }

    function selectedIndex() {
        for (let i = 0; i < controller.model.count; ++i)
            if (controller.model.get(i).sessionId === controller.selectedId) return i
        return -1
    }
    function focusSelected() {
        terminalCompositor.clearFocus()
        const index = selectedIndex()
        if (index >= 0) sessions.positionViewAtIndex(index, ListView.Contain)
        sessions.forceActiveFocus()
    }
    function focusEditor() {
        if (editingId && activeEditor) {
            terminalCompositor.clearFocus()
            activeEditor.forceActiveFocus()
            activeEditor.selectAll()
        }
    }
    function beginRename(id, title) {
        editingId = id
        draft = title
        errorMessage = ""
        for (let i = 0; i < controller.model.count; ++i)
            if (controller.model.get(i).sessionId === id) {
                sessions.positionViewAtIndex(i, ListView.Contain)
                break
            }
        Qt.callLater(focusEditor)
    }
    function cancelEdit(restoreTerminal = false) {
        // Remove the focused child before the Loader hides the editor.
        if (activeEditor) activeEditor.focus = false
        editingId = ""
        errorMessage = ""
        if (!restoreTerminal && visible && enabled) focusSelected()
        else appWindow.focusTerminal()
    }
    function submitEdit() {
        if (submitting || !editingId) return
        submitting = true
        errorMessage = ""
        controller.renameSession(editingId, draft)
        submitting = false
        if (!errorMessage) cancelEdit(true)
        else Qt.callLater(focusEditor)
    }
    function handleOperationError(id, message) {
        if (!submitting || id !== editingId) return false
        errorMessage = message
        return true
    }
    function activateSession(id) {
        controller.selectSession(id)
        appWindow.focusTerminal()
    }
    function navigateList(delta) {
        if (!controller.model.count) return
        const index = selectedIndex()
        const next = Math.max(0, Math.min(controller.model.count - 1, index + delta))
        controller.selectSession(controller.model.get(next).sessionId)
        focusSelected()
    }
    function showMenu(id, title, pinned, folderId, x, y) {
        terminalCompositor.clearFocus()
        sessions.forceActiveFocus()
        sessionMenu.sessionId = id
        sessionMenu.sessionTitle = title
        sessionMenu.pinned = pinned
        sessionMenu.folderId = folderId
        sessionMenu.popup(x, y)
    }
    function prepareDrag(id, title, x, y) {
        dragProxy.sessionId = id
        dragProxy.caption = title
        dragProxy.x = x - 12
        dragProxy.y = y - 12
    }
    function finishDrag(cancelled) {
        if (dragging) {
            if (cancelled) dragProxy.Drag.cancel()
            else dragProxy.Drag.drop()
        }
        dragging = false
    }
    onVisibleChanged: if (!visible) finishDrag(true)

    Rectangle { anchors.fill: parent; color: Theme.chrome }
    Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.border }
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: mouse => appWindow.showSidebarMenu(root, mouse.x, mouse.y)
    }
    RowLayout {
        id: header
        x: 14
        y: 0
        width: root.width - 28
        visible: root.heading.length > 0
        height: visible ? 28 : 0
        spacing: 6
        Text {
            Layout.fillWidth: true
            text: root.heading
            textFormat: Text.PlainText
            color: Theme.textMuted
            font.family: Theme.fontFamily
            font.pixelSize: 12
            font.weight: Font.DemiBold
            elide: Text.ElideRight
            HoverHandler { id: headingHover }
            AppToolTip {
                id: headingTip
                visible: headingHover.hovered
                delay: 700
                text: root.heading
            }
        }
        Text { text: controller.model.count; textFormat: Text.PlainText; color: Theme.textMuted; font.family: Theme.fontFamily; font.pixelSize: 12 }
    }
    Text {
        x: 10
        y: header.y + header.height + 12
        width: root.width - 20
        visible: controller.model.count === 0
        text: controller.search ? "No matching sessions" : controller.view === "attention" ? "No sessions need attention" : "No sessions"
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: Theme.textMuted
        font.pixelSize: 13
        font.family: Theme.fontFamily
    }
    ListView {
        id: sessions
        anchors.top: header.bottom
        anchors.topMargin: header.visible ? 0 : 4
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 4
        anchors.left: parent.left
        anchors.leftMargin: 6
        anchors.right: parent.right
        anchors.rightMargin: 6
        clip: true
        model: controller.model
        boundsBehavior: Flickable.StopAtBounds
        activeFocusOnTab: true
        onActiveFocusChanged: if (activeFocus) terminalCompositor.clearFocus()
        keyNavigationEnabled: false
        Accessible.role: Accessible.List
        Accessible.name: "Sessions"
        ScrollBar.vertical: ScrollBar { }
        Keys.onUpPressed: function(event) { if (!root.editingId) { root.navigateList(-1); event.accepted = true } }
        Keys.onDownPressed: function(event) { if (!root.editingId) { root.navigateList(1); event.accepted = true } }
        Keys.onReturnPressed: function(event) { if (!root.editingId) { appWindow.focusTerminal(); event.accepted = true } }
        Keys.onEnterPressed: function(event) { if (!root.editingId) { appWindow.focusTerminal(); event.accepted = true } }
        Keys.onPressed: function(event) {
            if (!root.editingId && (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && event.modifiers & Qt.ShiftModifier))) {
                const row = itemAtIndex(root.selectedIndex())
                if (row) row.showContextMenu()
                else appWindow.showSidebarMenu(root, 12, header.height + 8)
                event.accepted = true
            }
        }
        delegate: Item {
            id: sessionRow
            required property int index
            required property string sessionId
            required property string title
            required property string folderId
            required property bool pinned
            required property string cwd
            required property string branch
            required property string status
            required property string activity
            required property string activityDetail
            required property int unreadCount
            required property string noticeTitle
            required property string noticeBody
            required property string terminalError
            readonly property bool renaming: root.editingId === sessionId
            readonly property string statusLabel: status === "starting" ? "Starting" : status === "running" ? "Running" : "Stopped"
            readonly property string activityLabel: status !== "running" ? statusLabel
                : activity === "working" ? "Working" : activity === "waiting" ? "Needs input"
                : activity === "done" ? "Done" : "Idle"
            readonly property bool working: status === "starting" || (status === "running" && activity === "working")
            readonly property color activityColor: status !== "running" ? Theme.textMuted
                : activity === "waiting" ? Theme.warning
                : activity === "working" || activity === "done" ? Theme.accent : Theme.textMuted
            readonly property string details: title + "\n" + cwd + (branch ? "\n" + branch : "") + "\n" + statusLabel
                + (status === "running" ? "\n" + activityLabel + (activityDetail ? ": " + activityDetail : "") : "")
                + (pinned ? "\nPinned" : "")
                + (unreadCount > 0 ? "\n" + unreadCount + " unread notifications" : "")
                + (noticeTitle ? "\n" + noticeTitle + (noticeBody ? "\n" + noticeBody : "") : "")
                + (terminalError ? "\n" + terminalError : "")
            width: sessions.width
            height: card.height + 2
            function showContextMenu() {
                const point = card.mapToItem(root, 0, card.height)
                root.showMenu(sessionId, title, pinned, folderId, point.x, point.y)
            }
            HoverHandler { id: rowHover }
            Rectangle {
                id: card
                y: 1
                width: parent.width
                height: contents.implicitHeight + 2
                radius: 6
                color: sessionRow.sessionId === controller.selectedId ? Theme.selected : rowHover.hovered || (sessionMenu.visible && sessionMenu.sessionId === sessionRow.sessionId) ? Theme.bgHover : "transparent"
                border.width: !sessionRow.renaming && (rowButton.activeFocus || closeSessionButton.activeFocus || (sessions.activeFocus && sessionRow.sessionId === controller.selectedId)) ? 1 : 0
                border.color: Theme.accent
                Behavior on color { ColorAnimation { duration: 110 } }
                Button {
                    id: rowButton
                    enabled: !sessionRow.renaming
                    anchors.fill: parent
                    padding: 0
                    background: null
                    contentItem: Item { }
                    text: sessionRow.title
                    Accessible.name: sessionRow.title + ", " + sessionRow.statusLabel + ", " + sessionRow.activityLabel + (sessionRow.unreadCount > 0 ? ", " + sessionRow.unreadCount + " unread notifications" : "")
                    Accessible.description: sessionRow.details
                    Keys.onPressed: function(event) {
                        if (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && event.modifiers & Qt.ShiftModifier)) {
                            sessionRow.showContextMenu()
                            event.accepted = true
                        }
                    }
                    onClicked: root.activateSession(sessionRow.sessionId)
                    onActiveFocusChanged: if (activeFocus) terminalCompositor.clearFocus()
                    MouseArea {
                        id: pointer
                        anchors.fill: parent
                        enabled: !sessionRow.renaming
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        drag.target: pressedButtons & Qt.LeftButton ? dragProxy : null
                        drag.smoothed: false
                        property bool dragged: false
                        onPressed: function(mouse) {
                            dragged = false
                            terminalCompositor.clearFocus()
                            sessions.forceActiveFocus()
                            if (mouse.button === Qt.LeftButton) {
                                const point = mapToItem(appWindow.contentItem, mouse.x, mouse.y)
                                root.prepareDrag(sessionRow.sessionId, sessionRow.title, point.x, point.y)
                            }
                        }
                        onPositionChanged: {
                            if (drag.active) { dragged = true; root.dragging = true }
                        }
                        onReleased: if (dragged) root.finishDrag(false)
                        onCanceled: root.finishDrag(true)
                        onClicked: function(mouse) {
                            if (dragged) return
                            if (mouse.button === Qt.LeftButton) root.activateSession(sessionRow.sessionId)
                            else {
                                const point = mapToItem(root, mouse.x, mouse.y)
                                root.showMenu(sessionRow.sessionId, sessionRow.title, sessionRow.pinned, sessionRow.folderId, point.x, point.y)
                            }
                        }
                    }
                }
                Column {
                    id: contents
                    x: 7
                    y: 1
                    width: parent.width - 38
                    spacing: 3
                    RowLayout {
                        width: parent.width
                        height: 26
                        spacing: 6
                        Button {
                            visible: sessionRow.pinned
                            enabled: false
                            padding: 0
                            Layout.preferredWidth: 12
                            Layout.preferredHeight: 16
                            background: null
                            icon.source: "qrc:/cinmux/icons/pin.svg"
                            icon.color: Theme.textMuted
                            icon.width: 12; icon.height: 12
                            display: AbstractButton.IconOnly
                            Accessible.name: "Pinned"
                        }
                        Text {
                            visible: !sessionRow.renaming
                            Layout.fillWidth: true
                            text: sessionRow.title
                            textFormat: Text.PlainText
                            color: Theme.text
                            font.pixelSize: 13
                            font.family: Theme.fontFamily
                            font.weight: sessionRow.sessionId === controller.selectedId ? Font.DemiBold : Font.Normal
                            elide: Text.ElideRight
                        }
                        Loader {
                            Layout.fillWidth: true
                            Layout.minimumWidth: 0
                            Layout.preferredHeight: 26
                            active: sessionRow.renaming
                            visible: active
                            sourceComponent: TextInput {
                                id: titleField
                                text: root.draft
                                color: root.errorMessage ? Theme.danger : Theme.text
                                selectionColor: Theme.selectionBg
                                selectedTextColor: Theme.selectionText
                                font.pixelSize: 13
                                font.family: Theme.fontFamily
                                font.weight: sessionRow.sessionId === controller.selectedId ? Font.DemiBold : Font.Normal
                                verticalAlignment: TextInput.AlignVCenter
                                selectByMouse: true
                                clip: true
                                Accessible.name: "Session title"
                                Accessible.description: root.errorMessage
                                onTextEdited: { root.draft = text; root.errorMessage = "" }
                                onAccepted: root.submitEdit()
                                Keys.onEscapePressed: function(event) { root.cancelEdit(); event.accepted = true }
                                onActiveFocusChanged: if (activeFocus) terminalCompositor.clearFocus()
                                Component.onCompleted: { root.activeEditor = titleField; Qt.callLater(root.focusEditor) }
                                Component.onDestruction: if (root.activeEditor === titleField) root.activeEditor = null
                                AppToolTip {
                                    visible: titleField.activeFocus && root.errorMessage !== ""
                                    delay: 0
                                    text: root.errorMessage
                                }
                            }
                        }
                        Text {
                            visible: sessionRow.unreadCount > 0
                            text: sessionRow.unreadCount
                            textFormat: Text.PlainText
                            color: Theme.accent
                            font.pixelSize: 12
                            font.family: Theme.fontFamily
                            font.weight: Font.DemiBold
                        }
                        Rectangle {
                            visible: !!sessionRow.terminalError
                            Layout.preferredWidth: 5
                            Layout.preferredHeight: 5
                            radius: 3
                            color: Theme.danger
                            Accessible.ignored: true
                        }
                        RowLayout {
                            spacing: 4
                            Button {
                                id: activitySymbol
                                enabled: false
                                padding: 0
                                Layout.preferredWidth: 13
                                Layout.preferredHeight: 13
                                background: null
                                icon.source: "qrc:/cinmux/icons/" + (sessionRow.working ? "loader-circle"
                                    : sessionRow.status !== "running" ? "circle"
                                    : sessionRow.activity === "waiting" ? "circle-question-mark"
                                    : sessionRow.activity === "done" ? "check" : "circle") + ".svg"
                                icon.color: sessionRow.activityColor
                                icon.width: 13; icon.height: 13
                                display: AbstractButton.IconOnly
                                Accessible.ignored: true
                                RotationAnimation on rotation {
                                    from: 0
                                    to: 360
                                    duration: 1100
                                    loops: Animation.Infinite
                                    running: sessionRow.working && sessionRow.visible && sessions.visible && appWindow.visible
                                    onStopped: activitySymbol.rotation = 0
                                }
                            }
                            Text {
                                text: sessionRow.activityLabel
                                textFormat: Text.PlainText
                                color: sessionRow.activityColor
                                font.pixelSize: 11
                                font.family: Theme.fontFamily
                                Accessible.ignored: true
                            }
                        }
                    }
                }
                IconButton {
                    id: closeSessionButton
                    anchors.right: parent.right
                    anchors.rightMargin: 2
                    anchors.top: parent.top
                    anchors.topMargin: 2
                    width: 24; height: 24
                    icon.width: 14; icon.height: 14
                    iconName: "trash-2"
                    label: "Close session " + sessionRow.title
                    destructive: true
                    enabled: !sessionRow.renaming
                    opacity: enabled && (rowHover.hovered || rowButton.activeFocus || activeFocus || (sessions.activeFocus && sessionRow.sessionId === controller.selectedId)) ? 1 : 0
                    onClicked: appWindow.confirmCloseSession(sessionRow.sessionId, sessionRow.title)
                    Keys.onPressed: function(event) {
                        if (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && event.modifiers & Qt.ShiftModifier)) {
                            sessionRow.showContextMenu()
                            event.accepted = true
                        }
                    }
                }
                AppToolTip {
                    visible: rowHover.hovered && !closeSessionButton.hovered && !pointer.pressed && !root.dragging && !sessionMenu.visible && !sessionRow.renaming
                    delay: 700
                    text: sessionRow.details
                }
            }
        }
    }

    // This source outlives delegates, whose metadata/filter rows can reset.
    Item {
        id: dragProxy
        parent: appWindow.contentItem
        property string sessionId: ""
        property string caption: ""
        z: 1000
        width: 180
        height: 32
        visible: root.dragging
        Drag.active: root.dragging
        Drag.source: dragProxy
        Drag.keys: ["cinmux-session"]
        Drag.supportedActions: Qt.MoveAction
        Drag.hotSpot.x: 12
        Drag.hotSpot.y: 12
        Rectangle {
            anchors.fill: parent
            radius: 9
            color: Theme.bgRaised
            border.color: Theme.border
            opacity: 0.94
            Text {
                anchors.fill: parent
                anchors.margins: 8
                text: dragProxy.caption
                textFormat: Text.PlainText
                color: Theme.text
                font.pixelSize: 13
                font.family: Theme.fontFamily
                elide: Text.ElideRight
            }
        }
    }
    AppMenu {
        id: sessionMenu
        property string sessionId: ""
        property string sessionTitle: ""
        property string folderId: ""
        property bool pinned: false
        onAboutToShow: appWindow.popupOpened()
        onClosed: appWindow.popupClosed()
        AppMenuItem {
            text: "New tab"
            iconName: "plus"
            onTriggered: {
                controller.view = sessionMenu.folderId || "all"
                appWindow.newSession()
            }
        }
        AppMenuSeparator { }
        AppMenuItem {
            text: "Rename"
            iconName: "pencil"
            hint: sessionMenu.sessionId === controller.selectedId ? "Ctrl+R" : ""
            onTriggered: root.beginRename(sessionMenu.sessionId, sessionMenu.sessionTitle)
        }
        AppMenuItem {
            text: sessionMenu.pinned ? "Unpin session" : "Pin session"
            iconName: "pin"
            onTriggered: controller.setPinned(sessionMenu.sessionId, !sessionMenu.pinned)
        }
        AppMenuSeparator {}
        AppMenu {
            id: moveMenu
            title: "Move to folder"
            icon.source: "qrc:/cinmux/icons/folder.svg"
            implicitWidth: 248
            onAboutToShow: appWindow.popupOpened()
            onClosed: appWindow.popupClosed()
            AppMenuItem {
                text: "Unfiled"
                iconName: "folder"
                checked: sessionMenu.folderId === ""
                enabled: !checked
                onTriggered: controller.moveSession(sessionMenu.sessionId, "")
            }
            AppMenuSeparator { visible: controller.folders.length > 0; height: visible ? implicitHeight : 0 }
            Instantiator {
                model: controller.folders
                delegate: AppMenuItem {
                    required property var modelData
                    text: modelData.name
                    iconName: "folder"
                    checked: sessionMenu.folderId === modelData.id
                    enabled: !checked
                    onTriggered: controller.moveSession(sessionMenu.sessionId, modelData.id)
                }
                onObjectAdded: function(index, object) { moveMenu.insertItem(index + 2, object) }
                onObjectRemoved: function(index, object) { moveMenu.removeItem(object) }
            }
        }
        AppMenuSeparator { }
        AppMenuItem {
            text: "Close session…"
            iconName: "trash-2"
            hint: sessionMenu.sessionId === controller.selectedId ? "Ctrl+Shift+W" : ""
            destructive: true
            onTriggered: appWindow.confirmCloseSession(sessionMenu.sessionId, sessionMenu.sessionTitle)
        }
    }
}
