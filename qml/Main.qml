import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs as NativeDialogs

ApplicationWindow {
    id: root
    width: initialUi["window/width"]
    height: initialUi["window/height"]
    minimumWidth: 760
    minimumHeight: 540
    visible: true
    title: "Cinmux"
    color: "transparent"
    background: null
    font.family: Theme.fontFamily
    font.pixelSize: 13

    palette.window: Theme.bg
    palette.windowText: Theme.text
    palette.base: Theme.bg
    palette.alternateBase: Theme.bgSidebar
    palette.text: Theme.text
    palette.button: Theme.bgRaised
    palette.buttonText: Theme.text
    palette.highlight: Theme.selectionBg
    palette.highlightedText: Theme.selectionText
    palette.toolTipBase: Theme.bgRaised
    palette.toolTipText: Theme.text
    palette.light: Theme.bgHover
    palette.midlight: Theme.bgRaised
    palette.mid: Theme.border
    palette.dark: Theme.border
    palette.shadow: Theme.shadowColor
    palette.link: Theme.accent

    property bool wideFolders: initialUi["panes/foldersVisible"]
    property bool wideSessions: initialUi["panes/sessionsVisible"]
    property real desiredFoldersWidth: Math.max(150, Math.min(460, initialUi["panes/foldersWidth"]))
    property real desiredSessionsWidth: Math.max(210, Math.min(540, initialUi["panes/sessionsWidth"]))
    readonly property bool wide: width >= 1050
    property bool narrowFolders: false
    property bool narrowSessions: wideSessions
    readonly property bool foldersVisible: wide ? wideFolders : narrowFolders
    readonly property bool sessionsVisible: wide ? wideSessions : narrowSessions
    readonly property real effectiveFoldersWidth: foldersVisible
        ? Math.min(desiredFoldersWidth, width - 260 - (sessionsVisible ? 210 : 0)) : 0
    readonly property real effectiveSessionsWidth: sessionsVisible
        ? Math.min(desiredSessionsWidth, width - 260 - effectiveFoldersWidth) : 0
    property bool resizing: false
    property bool paneMotion: false
    property bool initialized: false
    property int popupCount: 0
    property bool terminalFocusAfterPopup: false
    property string pendingTerminalId: ""
    property var pendingFocusItem: null
    readonly property string selectedSessionId: controller.selectedId

    function focusInside(item) {
        for (let current = activeFocusItem; current; current = current.parent) {
            if (current === item) return true
        }
        return false
    }
    function animatePanes() {
        if (!initialized) return
        paneMotion = initialized && !resizing
        paneMotionTimer.restart()
    }
    function setFoldersVisible(value) {
        const hadFoldersFocus = focusInside(folderSidebar)
        const hadSessionsFocus = focusInside(sessionList)
        animatePanes()
        if (wide) wideFolders = value
        else {
            narrowFolders = value
            if (value) narrowSessions = false
        }
        if (!foldersVisible && hadFoldersFocus) header.focusFoldersToggle()
        if (!sessionsVisible && hadSessionsFocus) header.focusSessionsToggle()
    }
    function setSessionsVisible(value) {
        const hadFoldersFocus = focusInside(folderSidebar)
        const hadSessionsFocus = focusInside(sessionList)
        animatePanes()
        if (wide) wideSessions = value
        else {
            narrowSessions = value
            if (value) narrowFolders = false
        }
        if (!foldersVisible && hadFoldersFocus) header.focusFoldersToggle()
        if (!sessionsVisible && hadSessionsFocus) header.focusSessionsToggle()
    }
    function toggleFolders() { setFoldersVisible(!foldersVisible) }
    function toggleSessions() { setSessionsVisible(!sessionsVisible) }
    function showFolders() { setFoldersVisible(true) }
    function showSessions() { setSessionsVisible(true) }
    function resizePane(folder, value) {
        if (folder) desiredFoldersWidth = Math.max(150, Math.min(460, width - 260 - effectiveSessionsWidth, value))
        else desiredSessionsWidth = Math.max(210, Math.min(540, width - 260 - effectiveFoldersWidth, value))
    }
    function focusTerminal() {
        if (!controller.selectedId || confirmDialog.visible || errorDialog.visible || directoryDialog.visible) return
        if (popupCount > 0) {
            terminalFocusAfterPopup = true
            return
        }
        pendingTerminalId = controller.selectedId
        pendingFocusItem = activeFocusItem
        terminal.focusTerminal()
        if (terminal.selectedReady) pendingTerminalId = ""
    }
    function terminalMapped(id) {
        if (id !== controller.selectedId || id !== pendingTerminalId || popupCount > 0) return
        if (activeFocusItem === pendingFocusItem || focusInside(terminal)) focusTerminal()
    }
    function popupOpened() {
        ++popupCount
        pendingTerminalId = ""
        terminalCompositor.clearFocus()
    }
    function popupClosed() {
        popupCount = Math.max(0, popupCount - 1)
        Qt.callLater(function() {
            if (root.popupCount > 0 || directoryDialog.visible) return
            const requested = root.terminalFocusAfterPopup
            root.terminalFocusAfterPopup = false
            // A closing popup can restore its old focus after creating an editor.
            if (!requested && folderSidebar.visible && folderSidebar.editing) {
                folderSidebar.focusEditor()
                return
            }
            if (!requested && sessionList.visible && sessionList.editingId) {
                sessionList.focusEditor()
                return
            }
            // Inline editing, search, and list keyboard navigation retain their
            // focus when a menu closes; a late Foot map must not take it away.
            if (!requested && (header.searchHasFocus
                || (root.activeFocusItem && root.activeFocusItem.cursorPosition !== undefined)
                || root.focusInside(folderSidebar) || root.focusInside(sessionList))) return
            root.focusTerminal()
        })
    }
    function newSession() {
        const folderId = controller.view !== "all" && controller.view !== "attention" ? controller.view : ""
        controller.search = ""
        controller.createSession(folderId, "")
        focusTerminal()
    }
    function newFolder() {
        showFolders()
        folderSidebar.beginCreate()
    }
    function showSidebarMenu(item, x, y) {
        const point = item.mapToItem(root.contentItem, x, y)
        sidebarMenu.popup(point.x, point.y)
    }
    function renameSession() {
        if (!controller.selectedId) return
        const id = controller.selectedId
        const title = controller.selected.title
        controller.search = ""
        controller.view = "all"
        showSessions()
        sessionList.beginRename(id, title)
    }
    function nextAttention() {
        controller.selectNextAttention()
        sessionList.focusSelected()
        focusTerminal()
    }
    function confirmCloseSession(id, title) {
        if (!id) return
        confirmDialog.action = "session"
        confirmDialog.targetId = id
        confirmDialog.title = "Close session “" + title + "”?"
        confirmDialog.message = "All its shells and jobs will end, and it will be removed from the list. This cannot be undone."
        confirmDialog.confirmText = "Close session"
        confirmDialog.open()
    }
    function confirmClosePane() {
        if (!controller.selectedId) return
        confirmDialog.action = "pane"
        confirmDialog.targetId = controller.selectedId
        confirmDialog.title = "Close pane in “" + controller.selected.title + "”?"
        confirmDialog.message = "The active pane’s shell and jobs will end. If it is the session’s last pane, the session will also be removed. This cannot be undone."
        confirmDialog.confirmText = "Close pane"
        confirmDialog.open()
    }
    function confirmDeleteFolder(id, name) {
        if (!id) return
        confirmDialog.action = "folder"
        confirmDialog.targetId = id
        confirmDialog.title = "Delete folder “" + name + "”?"
        confirmDialog.message = "Its sessions will become unfiled. Their shells and jobs will keep running."
        confirmDialog.confirmText = "Delete folder"
        confirmDialog.open()
    }
    function showError(message) {
        errorDialog.recovery = null
        errorDialog.message = message
        errorDialog.open()
    }
    function chooseDirectory() {
        if (!errorDialog.recovery) return
        directoryDialog.sessionId = errorDialog.recovery.sessionId
        directoryDialog.folderId = errorDialog.recovery.folderId
        directoryDialog.open()
        errorDialog.close()
    }
    function localDirectory(url) {
        const value = url.toString()
        if (!value.startsWith("file://")) throw new Error("Choose a local directory.")
        let path = value.slice(7)
        if (path.startsWith("localhost/")) path = path.slice(9)
        if (!path.startsWith("/")) throw new Error("Choose a local directory.")
        return decodeURIComponent(path)
    }

    onWideChanged: {
        animatePanes()
        if (!wide) {
            narrowFolders = false
            narrowSessions = wideSessions
        }
    }
    onFoldersVisibleChanged: {
        if (!foldersVisible && focusInside(folderSidebar)) header.focusFoldersToggle()
    }
    onSessionsVisibleChanged: {
        if (!sessionsVisible && focusInside(sessionList)) header.focusSessionsToggle()
    }
    onSelectedSessionIdChanged: {
        terminalCompositor.selectedId = selectedSessionId
        if (pendingTerminalId !== selectedSessionId) pendingTerminalId = ""
        if (initialized && confirmDialog.visible && confirmDialog.action === "pane" && confirmDialog.targetId !== selectedSessionId)
            confirmDialog.reject()
    }
    onActiveFocusItemChanged: {
        if (active && pendingTerminalId && activeFocusItem !== pendingFocusItem && !focusInside(terminal)) pendingTerminalId = ""
    }
    Component.onCompleted: {
        initialized = true
        terminalCompositor.selectedId = controller.selectedId
        if (initialUi["window/maximized"]) showMaximized()
        if (terminalCompositor.error) showError(terminalCompositor.error)
        else Qt.callLater(root.focusTerminal)
    }
    Timer { id: paneMotionTimer; interval: 160; onTriggered: root.paneMotion = false }

    AppHeader { id: header; anchors.top: parent.top; width: parent.width; appWindow: root }
    Item {
        id: workspace
        anchors.top: header.bottom
        anchors.bottom: parent.bottom
        width: parent.width
        Item {
            id: foldersFrame
            width: root.effectiveFoldersWidth
            height: parent.height
            clip: true
            visible: width > 0
            enabled: root.foldersVisible
            Behavior on width {
                enabled: root.paneMotion && !root.resizing
                NumberAnimation { duration: 140; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.22, 0.61, 0.36, 1, 1, 1] }
            }
            FolderSidebar { id: folderSidebar; anchors.fill: parent; appWindow: root }
            Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.border }
        }
        Item {
            id: sessionsFrame
            x: foldersFrame.width
            width: root.effectiveSessionsWidth
            height: parent.height
            clip: true
            visible: width > 0
            enabled: root.sessionsVisible
            Behavior on width {
                enabled: root.paneMotion && !root.resizing
                NumberAnimation { duration: 140; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.22, 0.61, 0.36, 1, 1, 1] }
            }
            SessionList { id: sessionList; anchors.fill: parent; appWindow: root }
            Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.border }
        }
        TerminalPane {
            id: terminal
            focus: true
            appWindow: root
            x: foldersFrame.width + sessionsFrame.width
            width: parent.width - x
            height: parent.height
            onTerminalReady: id => root.terminalMapped(id)
        }
        PaneDivider { folder: true; appWindow: root; terminalItem: terminal; x: foldersFrame.width - 1; visible: root.foldersVisible }
        PaneDivider { folder: false; appWindow: root; terminalItem: terminal; x: foldersFrame.width + sessionsFrame.width - 1; visible: root.sessionsVisible }
    }
    component PaneDivider: Rectangle {
        id: divider
        required property bool folder
        required property var appWindow
        required property Item terminalItem
        width: 8
        height: parent.height
        z: 2
        activeFocusOnTab: true
        color: drag.pressed || activeFocus ? Theme.accentDim : drag.containsMouse ? Theme.border : "transparent"
        Accessible.role: Accessible.Separator
        Accessible.name: folder ? "Resize folders pane" : "Resize sessions pane"
        Accessible.description: "Drag, or use Left and Right to resize"
        Keys.onLeftPressed: appWindow.resizePane(folder, (folder ? appWindow.effectiveFoldersWidth : appWindow.effectiveSessionsWidth) - 10)
        Keys.onRightPressed: appWindow.resizePane(folder, (folder ? appWindow.effectiveFoldersWidth : appWindow.effectiveSessionsWidth) + 10)
        Behavior on color { ColorAnimation { duration: 110 } }
        MouseArea {
            id: drag
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.SplitHCursor
            property real originX: 0
            property real originWidth: 0
            property bool restoreTerminal: false
            onPressed: mouse => {
                originX = mapToItem(divider.parent, mouse.x, mouse.y).x
                originWidth = divider.folder ? divider.appWindow.effectiveFoldersWidth : divider.appWindow.effectiveSessionsWidth
                restoreTerminal = divider.appWindow.focusInside(divider.terminalItem)
                divider.appWindow.paneMotion = false
                divider.appWindow.resizing = true
                divider.forceActiveFocus()
                terminalCompositor.clearFocus()
            }
            onPositionChanged: mouse => {
                if (pressed) divider.appWindow.resizePane(divider.folder, originWidth + mapToItem(divider.parent, mouse.x, mouse.y).x - originX)
            }
            onReleased: {
                divider.appWindow.resizing = false
                if (restoreTerminal) divider.appWindow.focusTerminal()
            }
            onCanceled: divider.appWindow.resizing = false
        }
    }

    AppMenu {
        id: sidebarMenu
        parent: root.contentItem
        onAboutToShow: root.popupOpened()
        onClosed: root.popupClosed()
        AppMenuItem { text: "New tab"; iconName: "plus"; hint: "Ctrl+Shift+N"; onTriggered: root.newSession() }
        AppMenuItem { text: "New folder"; iconName: "folder-plus"; hint: "Ctrl+Alt+N"; onTriggered: root.newFolder() }
        AppMenuSeparator { }
        AppMenuItem {
            text: "Show all tabs"
            iconName: "terminal"
            onTriggered: {
                controller.search = ""
                controller.view = "all"
                root.showSessions()
            }
        }
    }

    ConfirmDialog {
        id: confirmDialog
        property string action: ""
        property string targetId: ""
        parent: Overlay.overlay
        onAboutToShow: root.popupOpened()
        onClosed: root.popupClosed()
        onAccepted: {
            if (action === "session" || action === "pane") root.terminalFocusAfterPopup = true
            if (action === "session") controller.closeSession(targetId)
            else if (action === "folder") controller.deleteFolder(targetId)
            else if (action === "pane" && controller.selectedId === targetId) controller.closeActivePane()
        }
    }
    Dialog {
        id: errorDialog
        parent: Overlay.overlay
        property string message: ""
        property var recovery: null
        anchors.centerIn: parent
        width: Math.min(root.width - 40, 520)
        modal: true
        focus: true
        padding: 24
        topPadding: 16
        closePolicy: Popup.CloseOnEscape
        background: PopupSurface { radius: 14 }
        Overlay.modal: Rectangle { color: Theme.overlay }
        header: Label {
            text: "Unable to complete action"
            textFormat: Text.PlainText
            color: Theme.text
            font.pixelSize: 17
            font.weight: Font.DemiBold
            leftPadding: 24
            rightPadding: 24
            topPadding: 24
        }
        contentItem: ColumnLayout {
            spacing: 18
            ScrollView {
                id: errorScroll
                Layout.fillWidth: true
                implicitHeight: Math.min(root.height - 240, errorText.implicitHeight)
                contentWidth: availableWidth
                clip: true
                Label {
                    id: errorText
                    width: errorScroll.availableWidth
                    text: errorDialog.message
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    color: Theme.textMuted
                    lineHeight: 1.45
                }
            }
            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: 6
                ActionButton { id: dismissError; text: errorDialog.recovery ? "Cancel" : "Dismiss"; onClicked: errorDialog.close() }
                ActionButton { visible: !!errorDialog.recovery; text: "Choose directory"; onClicked: root.chooseDirectory() }
            }
        }
        onAboutToShow: root.popupOpened()
        onOpened: dismissError.forceActiveFocus()
        onClosed: root.popupClosed()
    }
    NativeDialogs.FolderDialog {
        id: directoryDialog
        property string sessionId: ""
        property string folderId: ""
        title: "Choose session working directory"
        onVisibleChanged: {
            if (visible) root.popupOpened()
            else root.popupClosed()
        }
        onAccepted: {
            let path
            try { path = root.localDirectory(selectedFolder) }
            catch (error) { root.showError(error.message); return }
            if (sessionId) controller.startSession(sessionId, path)
            else controller.createSession(folderId, path)
            Qt.callLater(root.focusTerminal)
        }
    }
    Connections {
        target: controller
        function onOperationFailed(id, message) {
            if (folderSidebar.handleOperationError(id, message)) return
            if (sessionList.handleOperationError(id, message)) return
            root.showError(message)
        }
        function onDirectoryRequired(sessionId, folderId, path) {
            errorDialog.recovery = { sessionId: sessionId, folderId: folderId, path: path }
        }
    }
    Connections {
        target: terminalCompositor
        function onErrorChanged() { if (terminalCompositor.error) root.showError(terminalCompositor.error) }
        function onShortcutTriggered(action) {
            if (confirmDialog.visible || errorDialog.visible || directoryDialog.visible) {
                if (action === "quit") Qt.quit()
                return
            }
            switch (action) {
            case "newSession": root.newSession(); break
            case "newFolder": root.newFolder(); break
            case "search": header.focusSearch(); break
            case "toggleFolders": root.toggleFolders(); break
            case "toggleSessions": root.toggleSessions(); break
            case "rename": root.renameSession(); break
            case "closeSession": root.confirmCloseSession(controller.selectedId, controller.selected.title); break
            case "previous": controller.navigate(-1); root.focusTerminal(); break
            case "next": controller.navigate(1); root.focusTerminal(); break
            case "attention": root.nextAttention(); break
            case "quit": Qt.quit(); break
            }
        }
    }
}
