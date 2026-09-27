import CinmuxCore
import Foundation

extension TuiApp {
    func shortcut(_ e: InputEvent) -> Action {
        let mods = e.modifiers
        if e.key == .character {
            // ASCII lowering suffices: only letters are bound.
            let c = e.codepoint >= 0x41 && e.codepoint <= 0x5a ? e.codepoint + 0x20 : e.codepoint
            let letter: Character = Unicode.Scalar(c).map { Character($0) } ?? " "
            if mods == .ctrl && letter == "r" { return .rename }
            if mods == [.ctrl, .shift] {
                switch letter {
                case "n": return .newSession
                case "f": return .search
                case "b": return .toggleFolders
                case "l": return .toggleSessions
                case "w": return .closeSession
                case "q": return .quit
                case "e": return .focusSessions
                default: break
                }
            }
            if mods == [.ctrl, .alt] {
                if letter == "n" { return .newFolder }
                if letter == "u" { return .attention }
                // Terminals without the kitty keyboard protocol cannot tell
                // Ctrl+Shift+letter from Ctrl+letter; Ctrl+Alt stands in.
                if !kittyKeyboard {
                    switch letter {
                    case "t": return .newSession
                    case "f": return .search
                    case "b": return .toggleFolders
                    case "l": return .toggleSessions
                    case "w": return .closeSession
                    case "q": return .quit
                    case "e": return .focusSessions
                    default: break
                    }
                }
            }
        } else if mods == [.ctrl, .alt] {
            if e.key == .pageUp { return .previous }
            if e.key == .pageDown { return .next }
        }
        return Action.none
    }

    func hint(_ action: Action) -> String {
        let legacy = keyboardKnown && !kittyKeyboard
        func shifted(_ gui: String, _ fallback: String) -> String { legacy ? "Ctrl+Alt+\(fallback)" : "Ctrl+Shift+\(gui)" }
        switch action {
        case .newSession: return shifted("N", "T")
        case .newFolder: return "Ctrl+Alt+N"
        case .search: return shifted("F", "F")
        case .toggleFolders: return shifted("B", "B")
        case .toggleSessions: return shifted("L", "L")
        case .rename: return "Ctrl+R"
        case .closeSession: return shifted("W", "W")
        case .previous: return "Ctrl+Alt+PageUp"
        case .next: return "Ctrl+Alt+PageDown"
        case .attention: return "Ctrl+Alt+U"
        case .quit: return shifted("Q", "Q")
        case .focusSessions: return shifted("E", "E")
        case .none: return ""
        }
    }

    func perform(_ action: Action) {
        switch action {
        case .newSession: newSession()
        case .newFolder: newFolder()
        case .search: focusSearch()
        case .toggleFolders: setFoldersVisible(!foldersVisible)
        case .toggleSessions: setSessionsVisible(!sessionsVisible)
        case .rename: renameSession()
        case .closeSession: confirmCloseSession(selectedId, selected?.title ?? "")
        case .previous:
            controller.navigate(-1)
            focusTerminal()
        case .next:
            controller.navigate(1)
            focusTerminal()
        case .attention: nextAttention()
        case .quit: quit()
        case .focusSessions: focusSessions()
        case .none: break
        }
    }

    func handleKey(_ e: InputEvent) {
        hideTooltip()
        let action = shortcut(e)
        if dialog != nil {
            if action == .quit { quit() } else { dialogKey(e) }
            return
        }
        if action != Action.none {
            closeMenu()
            cancelDrag()
            if action != .rename || !selectedId.isEmpty { cancelEdits() }
            perform(action)
            return
        }
        if menu != nil {
            menuKeyPress(e)
            return
        }
        if drag.active && escape(e) {
            cancelDrag()
            return
        }
        switch focus {
        case .terminal: terminalKey(e)
        case .search: searchKey(e)
        case .folders: foldersKey(e)
        case .sessions: sessionsKey(e)
        case .folderEditor: folderEditorKey(e)
        case .sessionEditor: sessionEditorKey(e)
        }
    }

    private func tabKey(_ e: InputEvent) -> Bool { e.key == .tab && e.modifiers.intersection([.ctrl, .alt]).isEmpty }

    func terminalKey(_ e: InputEvent) {
        let id = selectedId
        if id.isEmpty {
            if plainKey(e, .enter) { newSession() }
            return
        }
        let status = selected?.status
        let error = selected?.terminalError ?? ""
        // Dead panes and failed views take no input; Enter triggers their button.
        if plainKey(e, .enter) && status == .stopped {
            controller.startSession(id)
            return
        }
        if plainKey(e, .enter) && !error.isEmpty {
            controller.reconnectTerminal(id)
            return
        }
        if error.isEmpty && terminals.hasOutput(id) { terminals.sendKey(id, e) }
    }

    func searchKey(_ e: InputEvent) {
        if plainKey(e, .enter) {
            focusTerminal()
            return
        }
        if escape(e) {
            controller.setSearch("")
            focusTerminal()
            return
        }
        if plainKey(e, .down) {
            focusSessions()
            return
        }
        if tabKey(e) {
            cycleFocus(e.modifiers.contains(.shift) ? -1 : 1)
            return
        }
        if menuKey(e) {
            openMoreMenu(keyboard: true)
            return
        }
        if search.handle(e) == .changed { controller.setSearch(search.text) }
    }

    func foldersKey(_ e: InputEvent) {
        let ids = navIds()
        folderCursor = max(0, min(folderCursor, ids.count - 1))
        let y = navRowY[folderCursor] ?? 1
        if plainKey(e, .up) {
            folderCursor = max(0, folderCursor - 1)
            revealFolder = true
        } else if plainKey(e, .down) {
            folderCursor = min(ids.count - 1, folderCursor + 1)
            revealFolder = true
        } else if plainKey(e, .home) {
            folderCursor = 0
            revealFolder = true
        } else if plainKey(e, .end) {
            folderCursor = ids.count - 1
            revealFolder = true
        } else if plainKey(e, .enter) || character(e, " ") {
            chooseView(ids[folderCursor])
        } else if escape(e) {
            focusTerminal()
        } else if tabKey(e) {
            cycleFocus(e.modifiers.contains(.shift) ? -1 : 1)
        } else if menuKey(e) {
            if folderCursor >= 2 { openFolderMenu(ids[folderCursor], 2, y + 1, keyboard: true) }
            else { openSidebarMenu(2, y + 1, keyboard: true) }
        }
    }

    func sessionsKey(_ e: InputEvent) {
        let ids = controller.rows.map(\.id)
        let id = selectedId
        func select(_ index: Int) {
            if ids.isEmpty { return }
            controller.selectSession(ids[max(0, min(index, ids.count - 1))])
            revealSelected = true
        }
        let index = ids.firstIndex(of: id) ?? -1
        let page = max(1, frame.rows - 3)
        if plainKey(e, .up) { select(index < 0 ? 0 : index - 1) }
        else if plainKey(e, .down) { select(index < 0 ? 0 : index + 1) }
        else if plainKey(e, .home) { select(0) }
        else if plainKey(e, .end) { select(ids.count - 1) }
        else if plainKey(e, .pageUp) { select(index - page) }
        else if plainKey(e, .pageDown) { select(index + page) }
        else if plainKey(e, .enter) || escape(e) { focusTerminal() }
        else if plainKey(e, .delete) { confirmCloseSession(id, selected?.title ?? "") }
        else if tabKey(e) { cycleFocus(e.modifiers.contains(.shift) ? -1 : 1) }
        else if menuKey(e) {
            if !id.isEmpty, let y = sessionRowY[id] { openSessionMenu(id, foldersWidth + 2, y + 1, keyboard: true) }
            else { openSidebarMenu(foldersWidth + 2, 2, keyboard: true) }
        }
    }

    func folderEditorKey(_ e: InputEvent) {
        if plainKey(e, .enter) { submitFolderEdit() }
        else if escape(e) { cancelFolderEdit(restoreTerminal: false) }
        else if folderEdit.edit.handle(e) == .changed { folderEdit.error = "" }
    }

    func sessionEditorKey(_ e: InputEvent) {
        if plainKey(e, .enter) { submitSessionEdit() }
        else if escape(e) { cancelSessionEdit(restoreTerminal: false) }
        else if sessionEdit.edit.handle(e) == .changed { sessionEdit.error = "" }
    }

    func menuKeyPress(_ e: InputEvent) {
        guard var menu else { return }
        let sub = menu.inSubmenu && menu.open >= 0
        let items = sub ? menu.items[menu.open].submenu : menu.items
        var current = sub ? menu.subHighlighted : menu.highlighted
        func step(_ delta: Int) {
            let count = items.count
            for i in stride(from: 1, through: count, by: 1) {
                let candidate = ((current < 0 ? (delta > 0 ? -1 : 0) : current) + delta * i + count * 2) % count
                if items[candidate].selectable {
                    current = candidate
                    return
                }
            }
        }
        func first() -> Int { items.firstIndex(where: \.selectable) ?? -1 }
        func store() {
            if sub { menu.subHighlighted = current } else { menu.highlighted = current }
            self.menu = menu
        }
        if plainKey(e, .up) {
            step(-1)
            store()
        } else if plainKey(e, .down) {
            step(1)
            store()
        } else if plainKey(e, .home) {
            current = first()
            store()
        } else if plainKey(e, .end) {
            current = -1
            step(-1)
            store()
        } else if escape(e) || (plainKey(e, .left) && sub) {
            if sub && !e.modifiers.contains(.alt) {
                menu.inSubmenu = false
                menu.open = -1
                menu.subHighlighted = -1
                self.menu = menu
            } else {
                closeMenu()
            }
        } else if (plainKey(e, .right) || plainKey(e, .enter) || character(e, " ")) && current >= 0 && current < items.count {
            if !sub && !items[current].submenu.isEmpty {
                menu.open = current
                menu.inSubmenu = true
                menu.subHighlighted = menu.items[current].submenu.firstIndex(where: \.selectable) ?? -1
                self.menu = menu
            } else if !plainKey(e, .right) {
                activateMenuItem(items[current])
            }
        }
    }

    func dialogKey(_ e: InputEvent) {
        guard var dialog else { return }
        let count = dialog.buttons.count
        func move(_ delta: Int) {
            let first = dialog.hasInput ? -1 : 0
            let span = count - first
            dialog.focus = first + ((dialog.focus - first + delta) % span + span) % span
            self.dialog = dialog
        }
        let tab = tabKey(e)
        if escape(e) {
            activateDialogButton(-1)
            return
        }
        if dialog.focus == -1 {
            if plainKey(e, .enter) {
                activateDialogButton(count - 1)
                return
            }
            if tab && !e.modifiers.contains(.shift) {
                if completeDirectory(&dialog.input) { self.dialog = dialog } else { move(1) }
                return
            }
            if tab {
                move(-1)
                return
            }
            _ = dialog.input.handle(e)
            self.dialog = dialog
            return
        }
        if tab { move(e.modifiers.contains(.shift) ? -1 : 1) }
        else if plainKey(e, .right) { move(1) }
        else if plainKey(e, .left) { move(-1) }
        else if plainKey(e, .enter) || character(e, " ") { activateDialogButton(dialog.focus) }
    }

    func cycleFocus(_ direction: Int) {
        var order: [Focus] = [.search]
        if foldersWidth > 0 { order.append(.folders) }
        if sessionsWidth > 0 { order.append(.sessions) }
        order.append(.terminal)
        let index = order.firstIndex(of: focus) ?? 0
        let next = (index + direction + order.count) % order.count
        switch order[next] {
        case .search: focusSearch()
        case .sessions: focusSessions()
        case .folders:
            folderCursor = navIds().firstIndex(of: controller.view) ?? 0
            revealFolder = true
            setFocus(.folders)
        default: focusTerminal()
        }
    }

    func handlePaste(_ text: [UInt8]) {
        hideTooltip()
        let value = String(decoding: text, as: UTF8.self)
        if dialog != nil {
            if dialog?.focus == -1 { dialog?.input.insert(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return
        }
        if menu != nil { return }
        switch focus {
        case .search:
            search.insert(value)
            controller.setSearch(search.text)
        case .folderEditor:
            folderEdit.edit.insert(value)
            folderEdit.error = ""
        case .sessionEditor:
            sessionEdit.edit.insert(value)
            sessionEdit.error = ""
        case .terminal:
            if terminalReady() { terminals.sendPaste(selectedId, text) }
        case .folders, .sessions:
            break
        }
    }

    func handleMouse(_ e: InputEvent) {
        mouseX = e.x
        mouseY = e.y
        let hit = hitAt(e.x, e.y)
        let isPress = e.action == .press, isRelease = e.action == .release
        let isWheel = e.action == .wheelUp || e.action == .wheelDown || e.action == .wheelLeft || e.action == .wheelRight
        if isPress || isRelease || isWheel { hideTooltip() }
        // An active gesture owns the pointer until its button is released.
        if resizing != 0 {
            if e.action == .move { resizePane(folders: resizing == 1, resizing == 1 ? e.x + 1 : e.x - foldersWidth + 1) }
            else if isRelease { resizing = 0 }
            scheduleRender()
            return
        }
        if terminalCapture {
            forwardMouse(e)
            if isRelease { terminalCapture = false }
            return
        }
        if drag.pressed && (e.action == .move || isRelease) {
            if e.action == .move {
                if !drag.active && (e.x != drag.x || e.y != drag.y) { drag.active = true }
                if drag.active {
                    dropTarget = hit.target == .nav && hit.index != 1 ? hit.id : ""
                    scheduleRender()
                }
                return
            }
            let finished = drag
            let target = dropTarget
            drag = Drag()
            dropTarget = ""
            if !finished.active { activateSession(finished.sessionId) }
            else if !target.isEmpty { controller.moveSession(finished.sessionId, folderId: target == "all" ? "" : target) }
            scheduleRender()
            return
        }
        if e.action == .move {
            hoverOver(hit, e)
            return
        }
        if let current = dialog {
            if isPress && e.button == .left {
                if hit.target == .dialogButton { activateDialogButton(hit.index) }
                else if hit.target == .dialogInput && current.hasInput { dialog?.focus = -1 }
            }
            return
        }
        if let current = menu {
            if !isPress { return }
            if hit.target == .menuItem && hit.index < current.items.count {
                let item = current.items[hit.index]
                if !item.submenu.isEmpty {
                    menu?.open = current.open == hit.index ? -1 : hit.index
                    menu?.inSubmenu = false
                } else {
                    activateMenuItem(item)
                }
            } else if hit.target == .submenuItem && current.open >= 0 {
                let sub = current.items[current.open].submenu
                if hit.index < sub.count { activateMenuItem(sub[hit.index]) }
            } else if hit.target != .menuSurface {
                closeMenu()
            }
            return
        }
        if isWheel {
            wheel(hit, e)
            return
        }
        if isPress { press(hit, e) }
        else if isRelease && hit.target == .terminal { forwardMouse(e) }
    }

    func hoverOver(_ hit: Hit, _ e: InputEvent) {
        if let current = menu {
            if hit.target == .menuItem {
                menu?.highlighted = hit.index
                menu?.inSubmenu = false
                if hit.index < current.items.count && !current.items[hit.index].submenu.isEmpty {
                    menu?.open = hit.index
                    menu?.subHighlighted = -1
                } else {
                    menu?.open = -1
                }
            } else if hit.target == .submenuItem {
                menu?.subHighlighted = hit.index
                menu?.inSubmenu = true
            }
        }
        if !hit.same(hover) {
            hover = hit
            tooltipVisible = false
            tooltipTimer.stop()
            if !hit.tooltip.isEmpty && menu == nil && dialog == nil { tooltipTimer.start(tooltipDelay) }
            scheduleRender()
        } else if menu != nil {
            scheduleRender()
        }
        // Motion reports are sent only when the tmux client requested them.
        if hit.target == .terminal && menu == nil && dialog == nil { forwardMouse(e) }
    }

    private func title(of id: String) -> String { controller.rows.first(where: { $0.id == id })?.title ?? "" }

    func press(_ hit: Hit, _ e: InputEvent) {
        if !sessionEdit.id.isEmpty && hit.target != .sessionEditor { cancelSessionEdit(restoreTerminal: false) }
        if folderEdit.editing && hit.target != .folderEditor { cancelFolderEdit(restoreTerminal: false) }
        if e.button == .right {
            contextMenu(hit, e)
            return
        }
        if e.button == .middle {
            if hit.target == .terminal {
                focusTerminal()
                forwardMouse(e)
            }
            return
        }
        if e.button != .left { return }
        let running = selected?.status == .running
        switch hit.target {
        case .foldersToggle: setFoldersVisible(!foldersVisible)
        case .sessionsToggle: setSessionsVisible(!sessionsVisible)
        case .newTab: newSession()
        case .splitRight: if running { split(.right) }
        case .splitDown: if running { split(.down) }
        case .attention: if controller.attentionCount > 0 { nextAttention() }
        case .more: openMoreMenu(keyboard: false)
        case .search:
            search.selected = false
            search.cursor = search.scalars.count
            setFocus(.search)
        case .searchClear:
            controller.setSearch("")
            search.set("")
            setFocus(.search)
        case .nav: chooseView(hit.id)
        case .folderAdd: beginFolderCreate()
        case .folderMore: openFolderMenu(hit.id, hit.x, hit.y + 1, keyboard: false)
        case .folderEditor: setFocus(.folderEditor)
        case .foldersDivider: resizing = 1
        case .sessionsDivider: resizing = 2
        case .sessionRow:
            // The app selects on click; a press may instead start dragging the row to a folder.
            drag = Drag(pressed: true, active: false, sessionId: hit.id, caption: title(of: hit.id), x: e.x, y: e.y)
            setFocus(.sessions)
        case .sessionTrash:
            confirmCloseSession(hit.id, title(of: hit.id))
        case .sessionEditor: setFocus(.sessionEditor)
        case .terminal:
            focusTerminal()
            if terminalReady() {
                terminalCapture = true
                forwardMouse(e)
            }
        case .terminalButton: terminalButton(hit.index)
        default: break
        }
        scheduleRender()
    }

    func contextMenu(_ hit: Hit, _ e: InputEvent) {
        switch hit.target {
        case .sessionRow, .sessionTrash:
            setFocus(.sessions)
            openSessionMenu(hit.id, e.x, e.y, keyboard: false)
        case .nav:
            if hit.index >= 2 { openFolderMenu(hit.id, e.x, e.y, keyboard: false) }
            else { openSidebarMenu(e.x, e.y, keyboard: false) }
        case .foldersPane, .sessionsPane, .folderAdd:
            openSidebarMenu(e.x, e.y, keyboard: false)
        case .terminal:
            focusTerminal()
            if terminalReady() {
                terminalCapture = true
                forwardMouse(e)
            }
        default: break
        }
    }

    func wheel(_ hit: Hit, _ e: InputEvent) {
        let delta = e.action == .wheelUp ? -3 : e.action == .wheelDown ? 3 : 0
        switch hit.target {
        case .sessionsPane, .sessionRow, .sessionTrash, .sessionEditor:
            sessionScroll = max(0, sessionScroll + delta)
            scheduleRender()
        case .foldersPane, .nav, .folderAdd, .folderMore, .folderEditor:
            folderScroll = max(0, folderScroll + delta)
            scheduleRender()
        case .terminal:
            forwardMouse(e)
        default: break
        }
    }

    func forwardMouse(_ e: InputEvent) {
        if !terminalReady() || termW <= 0 || termH <= 0 { return }
        let col = max(0, min(e.x - termX, termW - 1)), row = max(0, min(e.y - termY, termH - 1))
        terminals.sendMouse(selectedId, e, col: col, row: row)
    }
}
