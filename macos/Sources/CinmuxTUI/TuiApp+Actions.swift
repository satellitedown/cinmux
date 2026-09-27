import CinmuxCore
import Foundation

// Actions, menus and dialogs, mirroring qml/Main.qml.
extension TuiApp {
    func terminalReady() -> Bool {
        let id = selectedId
        return !id.isEmpty && (selected?.terminalError ?? "").isEmpty && terminals.hasOutput(id)
    }

    func navIds() -> [String] { ["all", "attention"] + controller.folders.map(\.id) }

    func folderName(_ id: String) -> String { controller.folders.first(where: { $0.id == id })?.name ?? "Sessions" }

    func setFocus(_ value: Focus) {
        focus = value
        syncTerminalFocus()
        scheduleRender()
    }

    func focusTerminal() {
        if dialog != nil { return }
        setFocus(.terminal)
    }

    func focusSearch() {
        setSessionsVisible(true)
        search.set(controller.search, select: true)
        setFocus(.search)
    }

    func focusSessions() {
        setSessionsVisible(true)
        if sessionsWidth == 0 { return }
        revealSelected = true
        setFocus(.sessions)
    }

    func syncTerminalFocus() {
        terminals?.setFocused(focus == .terminal && ttyFocused && menu == nil && dialog == nil)
    }

    func hideTooltip() {
        tooltipTimer.stop()
        if tooltipVisible {
            tooltipVisible = false
            scheduleRender()
        }
    }

    func newSession() {
        let view = controller.view
        let folderId = view != "all" && view != "attention" ? view : ""
        controller.setSearch("")
        controller.createSession(folderId: folderId, cwd: "")
        focusTerminal()
    }

    func newFolder() { beginFolderCreate() }

    func renameSession() {
        let id = selectedId
        if id.isEmpty { return }
        let title = selected?.title ?? ""
        controller.setSearch("")
        controller.setView("all")
        setSessionsVisible(true)
        beginSessionRename(id, title)
    }

    func nextAttention() {
        controller.selectNextAttention()
        revealSelected = true
        focusTerminal()
    }

    func activateSession(_ id: String) {
        controller.selectSession(id)
        focusTerminal()
    }

    func chooseView(_ id: String) {
        controller.setSearch("")
        controller.setView(id)
        setSessionsVisible(true)
        folderCursor = navIds().firstIndex(of: id) ?? 0
        if foldersWidth > 0 { setFocus(.folders) }
    }

    func split(_ direction: SessionController.SplitDirection) {
        controller.splitActive(direction)
        focusTerminal()
    }

    func terminalButton(_ index: Int) {
        let id = selectedId
        if index == createButton {
            newSession()
            return
        }
        if id.isEmpty { return }
        if index == startButton { controller.startSession(id) }
        else { controller.reconnectTerminal(id) }
        focusTerminal()
    }

    // MARK: Inline editors

    func beginSessionRename(_ id: String, _ title: String) {
        sessionEdit = SessionEdit()
        sessionEdit.id = id
        sessionEdit.edit.set(title, select: true)
        setFocus(.sessionEditor)
    }

    func submitSessionEdit() {
        if sessionEdit.id.isEmpty || sessionEdit.submitting { return }
        sessionEdit.submitting = true
        sessionEdit.error = ""
        let id = sessionEdit.id, title = sessionEdit.edit.text
        controller.renameSession(id, title: title)
        sessionEdit.submitting = false
        if sessionEdit.error.isEmpty { cancelSessionEdit(restoreTerminal: true) }
        else { scheduleRender() }
    }

    func cancelSessionEdit(restoreTerminal: Bool) {
        sessionEdit = SessionEdit()
        if !restoreTerminal && sessionsWidth > 0 { setFocus(.sessions) }
        else { focusTerminal() }
    }

    func beginFolderCreate() {
        setFoldersVisible(true)
        if foldersWidth == 0 { return }
        folderEdit = FolderEdit()
        folderEdit.editing = true
        folderEdit.creating = true
        setFocus(.folderEditor)
    }

    func beginFolderRename(_ id: String, _ name: String) {
        setFoldersVisible(true)
        if foldersWidth == 0 { return }
        folderEdit = FolderEdit()
        folderEdit.editing = true
        folderEdit.id = id
        folderEdit.edit.set(name, select: true)
        setFocus(.folderEditor)
    }

    func submitFolderEdit() {
        if !folderEdit.editing || folderEdit.submitting { return }
        folderEdit.submitting = true
        folderEdit.error = ""
        let name = folderEdit.edit.text
        if folderEdit.creating { controller.createFolder(name) }
        else { controller.renameFolder(folderEdit.id, name: name) }
        folderEdit.submitting = false
        if folderEdit.error.isEmpty { cancelFolderEdit(restoreTerminal: true) }
        else { scheduleRender() }
    }

    func cancelFolderEdit(restoreTerminal: Bool) {
        let target = folderEdit.id
        folderEdit = FolderEdit()
        if foldersWidth == 0 || (restoreTerminal && !selectedId.isEmpty) {
            focusTerminal()
            return
        }
        folderCursor = navIds().firstIndex(of: target) ?? 0
        revealFolder = true
        setFocus(.folders)
    }

    func cancelEdits() {
        if !sessionEdit.id.isEmpty { sessionEdit = SessionEdit() }
        if folderEdit.editing { folderEdit = FolderEdit() }
        if focus == .sessionEditor { focus = .sessions }
        if focus == .folderEditor { focus = .folders }
    }

    func cancelDrag() {
        if !drag.pressed { return }
        drag = Drag()
        dropTarget = ""
        scheduleRender()
    }

    // MARK: Menus

    func openMenu(_ opened: Menu, keyboard: Bool) {
        hideTooltip()
        var opened = opened
        opened.restore = focus
        if keyboard { opened.highlighted = opened.items.firstIndex(where: \.selectable) ?? opened.highlighted }
        menu = opened
        syncTerminalFocus()
        scheduleRender()
    }

    func closeMenu() {
        guard let current = menu else { return }
        menu = nil
        setFocus(current.restore)
        keepFocusVisible()
    }

    func activateMenuItem(_ item: MenuItem) {
        if !item.selectable { return }
        let action = item.action
        closeMenu()
        action?()
    }

    private func item(_ icon: String, _ text: String, hint: String = "", enabled: Bool = true, destructive: Bool = false,
                      _ action: @escaping @MainActor () -> Void) -> MenuItem {
        var result = MenuItem()
        result.icon = icon
        result.text = text
        result.hint = hint
        result.enabled = enabled
        result.destructive = destructive
        result.action = action
        return result
    }

    func openMoreMenu(keyboard: Bool) {
        let id = selectedId
        let hasSelection = !id.isEmpty
        let running = selected?.status == .running
        var opened = Menu()
        opened.anchor = .more
        opened.alignRight = true
        opened.x = frame.cols - 1
        opened.y = 1
        var items: [MenuItem] = []
        items.append(item(glyphPlus, "New tab", hint: hint(.newSession)) { [unowned self] in self.newSession() })
        items.append(item(glyphFolder, "New folder", hint: hint(.newFolder)) { [unowned self] in self.newFolder() })
        items.append(MenuItem.line())
        items.append(item(glyphPencil, "Rename session", hint: hint(.rename), enabled: hasSelection) { [unowned self] in self.renameSession() })
        items.append(item(glyphSplitRight, "Split right", enabled: running) { [unowned self] in self.split(.right) })
        items.append(item(glyphSplitDown, "Split down", enabled: running) { [unowned self] in self.split(.down) })
        items.append(MenuItem.line())
        items.append(item(glyphPanelLeft, foldersVisible ? "Hide folders" : "Show folders", hint: hint(.toggleFolders)) { [unowned self] in
            self.setFoldersVisible(!self.foldersVisible)
        })
        items.append(item(glyphPanelRight, sessionsVisible ? "Hide sessions" : "Show sessions", hint: hint(.toggleSessions)) { [unowned self] in
            self.setSessionsVisible(!self.sessionsVisible)
        })
        items.append(MenuItem.line())
        items.append(item(glyphClose, "Close pane…", enabled: hasSelection, destructive: true) { [unowned self] in self.confirmClosePane() })
        items.append(item(glyphClose, "Close session…", hint: hint(.closeSession), enabled: hasSelection, destructive: true) { [unowned self] in
            self.confirmCloseSession(id, self.selected?.title ?? "")
        })
        items.append(MenuItem.line())
        items.append(item(glyphQuit, "Quit Cinmux", hint: hint(.quit)) { [unowned self] in self.quit() })
        opened.items = items
        openMenu(opened, keyboard: keyboard)
    }

    func openSidebarMenu(_ x: Int, _ y: Int, keyboard: Bool) {
        var opened = Menu()
        opened.x = x
        opened.y = y
        let newTab = item(glyphPlus, "New tab", hint: hint(.newSession)) { [unowned self] in self.newSession() }
        let folder = item(glyphFolder, "New folder", hint: hint(.newFolder)) { [unowned self] in self.newFolder() }
        let all = item(glyphTabs, "Show all tabs") { [unowned self] in
            self.controller.setSearch("")
            self.controller.setView("all")
            self.setSessionsVisible(true)
        }
        opened.items = [newTab, folder, MenuItem.line(), all]
        openMenu(opened, keyboard: keyboard)
    }

    func openFolderMenu(_ id: String, _ x: Int, _ y: Int, keyboard: Bool) {
        let name = folderName(id)
        var opened = Menu()
        opened.x = x
        opened.y = y
        opened.folderId = id
        let newTab = item(glyphPlus, "New tab") { [unowned self] in
            self.chooseView(id)
            self.newSession()
        }
        let folder = item(glyphFolder, "New folder", hint: hint(.newFolder)) { [unowned self] in self.newFolder() }
        let rename = item(glyphPencil, "Rename folder") { [unowned self] in self.beginFolderRename(id, name) }
        let remove = item(glyphClose, "Delete folder…", destructive: true) { [unowned self] in self.confirmDeleteFolder(id, name) }
        opened.items = [newTab, folder, MenuItem.line(), rename, MenuItem.line(), remove]
        openMenu(opened, keyboard: keyboard)
    }

    func openSessionMenu(_ id: String, _ x: Int, _ y: Int, keyboard: Bool) {
        guard let row = controller.rows.first(where: { $0.id == id }) else { return }
        let title = row.title
        let folderId = row.folderId
        let pinned = row.pinned
        let isSelected = id == selectedId
        var opened = Menu()
        opened.x = x
        opened.y = y
        opened.sessionId = id
        let newTab = item(glyphPlus, "New tab") { [unowned self] in
            self.controller.setView(folderId.isEmpty ? "all" : folderId)
            self.newSession()
        }
        let rename = item(glyphPencil, "Rename", hint: isSelected ? hint(.rename) : "") { [unowned self] in
            self.setSessionsVisible(true)
            self.beginSessionRename(id, title)
        }
        let pin = item(glyphPin, pinned ? "Unpin session" : "Pin session") { [unowned self] in self.controller.setPinned(id, !pinned) }
        var move = item(glyphFolder, "Move to folder") {}
        move.action = nil
        var unfiled = item(glyphFolder, "Unfiled") { [unowned self] in self.controller.moveSession(id, folderId: "") }
        unfiled.checked = folderId.isEmpty
        unfiled.enabled = !unfiled.checked
        move.submenu.append(unfiled)
        let folders = controller.folders
        if !folders.isEmpty { move.submenu.append(MenuItem.line()) }
        for folder in folders {
            let target = folder.id
            var entry = item(glyphFolder, folder.name) { [unowned self] in self.controller.moveSession(id, folderId: target) }
            entry.checked = target == folderId
            entry.enabled = !entry.checked
            move.submenu.append(entry)
        }
        let close = item(glyphClose, "Close session…", hint: isSelected ? hint(.closeSession) : "", destructive: true) { [unowned self] in
            self.confirmCloseSession(id, title)
        }
        opened.items = [newTab, MenuItem.line(), rename, pin, MenuItem.line(), move, MenuItem.line(), close]
        openMenu(opened, keyboard: keyboard)
    }

    // MARK: Dialogs

    func openDialog(_ opened: Dialog) {
        closeMenu()
        cancelDrag()
        hideTooltip()
        resizing = 0
        terminalCapture = false
        var opened = opened
        opened.restore = focus
        dialog = opened
        syncTerminalFocus()
        scheduleRender()
    }

    func closeDialog() {
        guard let current = dialog else { return }
        dialog = nil
        setFocus(current.restore)
        keepFocusVisible()
    }

    /// Index -1 cancels; a button's action receives the dialog's input text.
    func activateDialogButton(_ index: Int) {
        guard let current = dialog else { return }
        var action: (@MainActor (String) -> Void)?
        if index >= 0 && index < current.buttons.count { action = current.buttons[index].action }
        let input = current.input.text
        closeDialog()
        action?(input)
    }

    func confirm(_ title: String, _ message: String, _ confirmText: String, paneTarget: String = "", _ accept: @escaping @MainActor () -> Void) {
        var opened = Dialog()
        opened.title = title
        opened.message = message
        opened.paneTarget = paneTarget
        opened.buttons = [
            DialogButton(label: "Cancel", role: .normal, action: nil),
            DialogButton(label: confirmText, role: .destructive, action: { _ in accept() }),
        ]
        openDialog(opened)
    }

    func confirmCloseSession(_ id: String, _ title: String) {
        if id.isEmpty { return }
        confirm("Close session “\(title)”?",
                "All its shells and jobs will end, and it will be removed from the list. This cannot be undone.",
                "Close session") { [unowned self] in
            self.controller.closeSession(id)
            self.focusTerminal()
        }
    }

    func confirmClosePane() {
        let id = selectedId
        if id.isEmpty { return }
        confirm("Close pane in “\(selected?.title ?? "")”?",
                "The active pane’s shell and jobs will end. If it is the session’s last pane, the session will also be removed. This cannot be undone.",
                "Close pane", paneTarget: id) { [unowned self] in
            if self.selectedId == id { self.controller.closeActivePane() }
            self.focusTerminal()
        }
    }

    func confirmDeleteFolder(_ id: String, _ name: String) {
        if id.isEmpty { return }
        confirm("Delete folder “\(name)”?", "Its sessions will become unfiled. Their shells and jobs will keep running.",
                "Delete folder") { [unowned self] in self.controller.deleteFolder(id) }
    }

    func showError(_ message: String) {
        var opened = Dialog()
        opened.kind = .error
        opened.title = "Unable to complete action"
        opened.message = message
        opened.buttons = [DialogButton(label: "Dismiss", role: .normal, action: nil)]
        if dialog != nil {
            dialog?.kind = opened.kind
            dialog?.title = opened.title
            dialog?.message = message
            dialog?.buttons = opened.buttons
            dialog?.focus = 0
            dialog?.hasInput = false
            scheduleRender()
            return
        }
        openDialog(opened)
    }

    func chooseDirectory(sessionId: String, folderId: String, path: String) {
        var opened = Dialog()
        opened.kind = .directory
        opened.title = "Choose session working directory"
        opened.message = "Enter an existing directory. Tab completes directory names."
        opened.hasInput = true
        opened.input.set(existingDirectory(path))
        opened.placeholder = "/path/to/directory"
        opened.focus = -1
        opened.buttons = [
            DialogButton(label: "Cancel", role: .normal, action: nil),
            DialogButton(label: sessionId.isEmpty ? "Create session" : "Start session", role: .accent, action: { [unowned self] input in
                let directory = expandPath(input)
                if sessionId.isEmpty { self.controller.createSession(folderId: folderId, cwd: directory) }
                else { self.controller.startSession(sessionId, cwd: directory) }
                self.focusTerminal()
            }),
        ]
        openDialog(opened)
    }
}
