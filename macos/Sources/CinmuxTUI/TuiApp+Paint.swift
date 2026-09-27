import CinmuxCore
import Foundation

private struct FolderRow {
    enum Kind { case nav, blank, heading, editor, error }
    var kind: Kind
    var nav = -1
    var id = ""
    var name = ""
    var error = ""
    var count = 0
}

func menuWidth(_ items: [MenuItem]) -> Int {
    var inner = 18
    for item in items where !item.separator {
        inner = max(inner, 4 + textWidth(item.text) + (item.hint.isEmpty ? 0 : 3 + textWidth(item.hint)) + (item.submenu.isEmpty ? 0 : 2) + 1)
    }
    return inner + 2
}

extension TuiApp {
    func paintHeaderButton(_ x: Int, _ target: Target, _ glyph: String, enabled: Bool, toggled: Bool, tooltip: String) {
        let hovered = enabled && hover.target == target
        let open = menu.map { $0.anchor == target } ?? false
        let bg = toggled || open ? p.selected : hovered ? p.hover : p.chrome
        let fg = !enabled ? p.muted : toggled ? p.accent : hovered || open ? p.text : p.muted
        let st = style(fg, bg, enabled ? [] : .faint)
        frame.fill(x, 0, 3, 1, st)
        frame.text(x + 1, 0, glyph, st, 1)
        addHit(Hit(x: x, y: 0, w: 3, h: 1, target: target, tooltip: tooltip))
    }

    func paintHeader() {
        let width = frame.cols
        frame.fill(0, 0, width, 1, style(p.text, p.chrome))
        let running = selected?.status == .running
        let attention = controller.attentionCount
        var left = 1
        paintHeaderButton(left, .foldersToggle, glyphPanelLeft, enabled: true, toggled: false,
                          tooltip: (foldersVisible ? "Hide folders" : "Show folders") + " (\(hint(.toggleFolders)))")
        left += 3
        paintHeaderButton(left, .sessionsToggle, glyphPanelRight, enabled: true, toggled: false,
                          tooltip: (sessionsVisible ? "Hide sessions" : "Show sessions") + " (\(hint(.toggleSessions)))")
        left += 3
        paintHeaderButton(left, .newTab, glyphPlus, enabled: true, toggled: false, tooltip: "New tab (\(hint(.newSession)))")
        left += 3
        var right = width - 1
        if right - 3 < left { return }
        right -= 3
        paintHeaderButton(right, .more, glyphMore, enabled: true, toggled: false, tooltip: "More")
        let available = right - left - 1
        var searchWidth = max(12, min(width / 5, 28))
        if available < searchWidth + 1 + 9 { searchWidth = available - 1 - 9 }
        if searchWidth >= 8 {
            right -= searchWidth + 1
            paintSearch(right, searchWidth)
        }
        if right - 9 <= left { return }
        right -= 3
        paintHeaderButton(right, .attention, glyphBell, enabled: attention > 0, toggled: attention > 0,
                          tooltip: "Next attention (\(hint(.attention)))")
        right -= 3
        paintHeaderButton(right, .splitDown, glyphSplitDown, enabled: running, toggled: false, tooltip: "Split down")
        right -= 3
        paintHeaderButton(right, .splitRight, glyphSplitRight, enabled: running, toggled: false, tooltip: "Split right")
    }

    func paintEdit(_ edit: LineEdit, _ x: Int, _ y: Int, _ width: Int, _ base: TuiStyle, _ placeholder: String, focused: Bool) {
        if width <= 0 { return }
        frame.fill(x, y, width, 1, base)
        if edit.isEmpty {
            if !placeholder.isEmpty { frame.text(x, y, elide(placeholder, width), style(p.muted, base.bg), width) }
            if focused { frame.cursor = Surface.Cursor(x: x, y: y, visible: true, shape: 5) }
            return
        }
        // Scroll horizontally so the cursor keeps a visible cell.
        var start = 0
        while start < edit.cursor && textWidth(edit.slice(start, edit.cursor)) > width - 1 { start = edit.next(start) }
        let textStyle = edit.selected ? style(p.selectionText, p.selectionBg, base.attributes) : base
        frame.text(x, y, edit.slice(start, edit.scalars.count), textStyle, width)
        if focused { frame.cursor = Surface.Cursor(x: x + textWidth(edit.slice(start, edit.cursor)), y: y, visible: true, shape: 5) }
    }

    func paintSearch(_ x: Int, _ width: Int) {
        let focused = focus == .search
        let bg = p.hover
        frame.fill(x, 0, width, 1, style(p.text, bg))
        frame.text(x + 1, 0, glyphSearch, style(focused ? p.accent : p.muted, bg), 1)
        let clear = !search.isEmpty
        addHit(Hit(x: x, y: 0, w: width, h: 1, target: .search))
        paintEdit(search, x + 3, 0, width - 4 - (clear ? 2 : 0), style(p.text, bg), "Search sessions", focused: focused)
        if clear {
            let hovered = hover.target == .searchClear
            frame.text(x + width - 2, 0, glyphClose, style(hovered ? p.text : p.muted, bg), 1)
            addHit(Hit(x: x + width - 3, y: 0, w: 3, h: 1, target: .searchClear, tooltip: "Clear search"))
        }
    }

    func paintDivider(_ x: Int, _ target: Target, active: Bool) {
        let hovered = hover.target == target
        let st = style(active ? p.accent : hovered ? p.muted : p.border, p.chrome)
        var y = 1
        while y < frame.rows {
            frame.text(x, y, "│", st, 1)
            y += 1
        }
        addHit(Hit(x: x, y: 1, w: 1, h: frame.rows - 1, target: target))
    }

    func paintEditError(_ message: String, _ x: Int, _ y: Int, _ width: Int) {
        let lines = wrap(message, max(4, width - 2))
        var i = 0
        while i < lines.count && y + i < frame.rows {
            frame.fill(x, y + i, width, 1, style(p.danger, p.raised))
            frame.text(x + 1, y + i, lines[i], style(p.danger, p.raised), width - 2)
            i += 1
        }
    }

    func paintFolders() {
        let width = foldersWidth
        if width <= 0 { return }
        let height = frame.rows - 1, inner = width - 1
        frame.fill(0, 1, inner, height, style(p.text, p.chrome))
        addHit(Hit(x: 0, y: 1, w: inner, h: height, target: .foldersPane))
        paintDivider(width - 1, .foldersDivider, active: resizing == 1)

        var rows: [FolderRow] = []
        rows.append(FolderRow(kind: .nav, nav: 0, id: "all", name: "Tabs", count: controller.totalCount))
        rows.append(FolderRow(kind: .nav, nav: 1, id: "attention", name: "Needs Attention", count: controller.attentionCount))
        rows.append(FolderRow(kind: .blank))
        rows.append(FolderRow(kind: .heading))
        let editError = folderEdit.error
        func editor() {
            rows.append(FolderRow(kind: .editor))
            for line in wrap(editError, max(4, inner - 4)) where !editError.isEmpty { rows.append(FolderRow(kind: .error, error: line)) }
        }
        if folderEdit.editing && folderEdit.creating { editor() }
        for (i, folder) in controller.folders.enumerated() {
            if folderEdit.editing && !folderEdit.creating && folderEdit.id == folder.id { editor() }
            else { rows.append(FolderRow(kind: .nav, nav: 2 + i, id: folder.id, name: folder.name, count: folder.count)) }
        }
        var focusRow = -1
        for (i, row) in rows.enumerated() {
            if (focus == .folderEditor && row.kind == .editor) || (focus == .folders && row.kind == .nav && row.nav == folderCursor) { focusRow = i }
        }
        if revealFolder || focus == .folderEditor {
            if focusRow >= 0 && focusRow < folderScroll { folderScroll = focusRow }
            else if focusRow >= folderScroll + height { folderScroll = focusRow - height + 1 }
            revealFolder = false
        }
        folderScroll = max(0, min(folderScroll, max(0, rows.count - height)))

        let view = controller.view
        let searching = !controller.search.isEmpty
        var i = folderScroll
        while i < rows.count && i - folderScroll < height {
            let row = rows[i]
            let y = 1 + i - folderScroll
            i += 1
            switch row.kind {
            case .blank:
                break
            case .heading:
                frame.text(1, y, "Folders", style(p.muted, p.chrome, .bold), inner - 4)
                let hovered = hover.target == .folderAdd
                frame.fill(inner - 3, y, 3, 1, style(p.text, hovered ? p.hover : p.chrome))
                frame.text(inner - 2, y, glyphPlus, style(hovered ? p.text : p.muted, hovered ? p.hover : p.chrome), 1)
                addHit(Hit(x: inner - 3, y: y, w: 3, h: 1, target: .folderAdd, tooltip: "New folder"))
            case .editor:
                let failed = !folderEdit.error.isEmpty
                frame.text(0, y, glyphMarker, style(failed ? p.danger : p.accent, p.chrome), 1)
                paintEdit(folderEdit.edit, 1, y, inner - 2, style(p.text, p.terminal), "Folder name", focused: focus == .folderEditor)
                addHit(Hit(x: 0, y: y, w: inner, h: 1, target: .folderEditor))
            case .error:
                frame.text(2, y, row.error, style(p.danger, p.chrome), inner - 3)
            case .nav:
                navRowY[row.nav] = y
                let isFolder = row.nav >= 2
                let active = view == row.id && !searching
                let hovered = (hover.target == .nav || hover.target == .folderMore) && hover.id == row.id
                let drop = drag.active && dropTarget == row.id
                let keyboard = focus == .folders && folderCursor == row.nav
                let menuOpen = menu.map { $0.folderId == row.id } ?? false
                let bg = drop || active ? p.selected : hovered || menuOpen ? p.hover : p.chrome
                frame.fill(0, y, inner, 1, style(p.text, bg))
                if keyboard || drop { frame.text(0, y, glyphMarker, style(p.accent, bg), 1) }
                frame.text(1, y, row.nav == 0 ? glyphTabs : row.nav == 1 ? glyphBell : glyphFolder, style(p.muted, bg), 1)
                var end = inner - 1
                if isFolder {
                    if hovered || keyboard || menuOpen {
                        let overMore = hover.target == .folderMore && hover.id == row.id
                        frame.text(end - 1, y, glyphMore, style(overMore ? p.text : p.muted, bg), 1)
                    }
                    end -= 2
                }
                if row.count > 0 {
                    let count = String(row.count)
                    end -= count.count
                    frame.text(end, y, count, style(p.muted, bg), count.count)
                    end -= 1
                }
                let caption = elide(row.name, end - 3)
                frame.text(3, y, caption, style(p.text, bg, active ? .bold : []), end - 3)
                addHit(Hit(x: 0, y: y, w: inner, h: 1, target: .nav, id: row.id, index: row.nav, tooltip: caption == row.name ? "" : row.name))
                if isFolder {
                    addHit(Hit(x: inner - 3, y: y, w: 3, h: 1, target: .folderMore, id: row.id, index: row.nav, tooltip: "Folder actions for \(row.name)"))
                }
            }
        }
    }

    func paintSessions() {
        let x0 = foldersWidth, width = sessionsWidth
        if width <= 0 { return }
        let inner = width - 1, bottom = frame.rows
        frame.fill(x0, 1, inner, bottom - 1, style(p.text, p.chrome))
        addHit(Hit(x: x0, y: 1, w: inner, h: bottom - 1, target: .sessionsPane))
        paintDivider(x0 + width - 1, .sessionsDivider, active: resizing == 2)

        let view = controller.view
        let searching = !controller.search.isEmpty
        var heading = ""
        if searching { heading = "Search results" }
        else if view == "attention" { heading = "Needs Attention" }
        else if view != "all" { heading = folderName(view) }
        let rows = controller.rows
        let count = rows.count
        var top = 1
        if !heading.isEmpty {
            let number = String(count)
            frame.text(x0 + 2, 1, elide(heading, inner - 5 - number.count), style(p.muted, p.chrome, .bold))
            frame.text(x0 + inner - 1 - number.count, 1, number, style(p.muted, p.chrome))
            top = 2
        }
        if count == 0 {
            let message = searching ? "No matching sessions" : view == "attention" ? "No sessions need attention" : "No sessions"
            var y = top + 1
            for line in wrap(message, max(4, inner - 2)) {
                frame.text(x0 + 1, y, line, style(p.muted, p.chrome), inner - 2)
                y += 1
            }
            return
        }
        let visible = max(1, bottom - top)
        let ids = rows.map(\.id)
        var reveal = -1
        if !sessionEdit.id.isEmpty { reveal = ids.firstIndex(of: sessionEdit.id) ?? -1 }
        else if revealSelected { reveal = ids.firstIndex(of: selectedId) ?? -1 }
        if reveal >= 0 {
            if reveal < sessionScroll { sessionScroll = reveal }
            else if reveal >= sessionScroll + visible { sessionScroll = reveal - visible + 1 }
        }
        revealSelected = false
        sessionScroll = max(0, min(sessionScroll, max(0, count - visible)))
        var i = sessionScroll
        while i < count && i - sessionScroll < visible {
            paintSessionRow(rows[i], top + i - sessionScroll, x0, inner)
            i += 1
        }
        // The app shows a rename failure as a tooltip under the title field.
        if !sessionEdit.error.isEmpty, let y = sessionRowY[sessionEdit.id] {
            paintEditError(sessionEdit.error, x0 + 1, y + 1, inner - 2)
        }
    }

    func paintSessionRow(_ row: SessionRow, _ y: Int, _ x0: Int, _ inner: Int) {
        let id = row.id
        let title = row.title
        let status = row.status
        let activity = row.activity
        let unread = row.unreadCount
        sessionRowY[id] = y

        let isSelected = id == selectedId
        let renaming = sessionEdit.id == id
        let hovered = (hover.target == .sessionRow || hover.target == .sessionTrash) && hover.id == id
        let menuOpen = menu.map { $0.sessionId == id } ?? false
        let keyboard = focus == .sessions && isSelected
        let bg = isSelected ? p.selected : hovered || menuOpen ? p.hover : p.chrome
        frame.fill(x0, y, inner, 1, style(p.text, bg))
        if keyboard || renaming {
            frame.text(x0, y, glyphMarker, style(renaming && !sessionEdit.error.isEmpty ? p.danger : p.accent, bg), 1)
        }

        // qml/SessionList.qml labels and colors.
        let running = status == .running
        let statusLabel = status == .starting ? "Starting" : running ? "Running" : "Stopped"
        let activityLabel = !running ? statusLabel
            : activity == .working ? "Working"
            : activity == .waiting ? "Needs input"
            : activity == .done ? "Done" : "Idle"
        let working = status == .starting || (running && activity == .working)
        let activityColor = !running ? p.muted : activity == .waiting ? p.warning
            : activity == .working || activity == .done ? p.accent : p.muted
        let activityGlyph = working ? spinner[spinnerFrame] : !running ? glyphIdle
            : activity == .waiting ? glyphWaiting : activity == .done ? glyphCheck : glyphIdle
        if working { spinning = true }

        var x = x0 + 1
        var end = x0 + inner - 1
        let trash = !renaming && (hovered || keyboard)
        let trashX = end - 1
        if trash {
            let over = hover.target == .sessionTrash && hover.id == id
            frame.text(trashX, y, glyphClose, style(over ? p.danger : p.muted, bg), 1)
        }
        end -= 2
        if inner >= 30 {
            let labelWidth = textWidth(activityLabel)
            end -= labelWidth
            frame.text(end, y, activityLabel, style(activityColor, bg), labelWidth)
            end -= 1
        }
        end -= 1
        frame.text(end, y, activityGlyph, style(activityColor, bg), 1)
        end -= 1
        if !row.terminalError.isEmpty {
            end -= 1
            frame.text(end, y, glyphError, style(p.danger, bg), 1)
            end -= 1
        }
        if unread > 0 {
            let number = String(unread)
            end -= number.count
            frame.text(end, y, number, style(p.accent, bg, .bold), number.count)
            end -= 1
        }
        if row.pinned {
            frame.text(x, y, glyphPin, style(p.muted, bg), 1)
            x += 2
        }
        let weight: TuiAttributes = isSelected ? .bold : []
        if renaming {
            paintEdit(sessionEdit.edit, x, y, max(1, end - x), style(sessionEdit.error.isEmpty ? p.text : p.danger, bg, weight), "",
                      focused: focus == .sessionEditor)
            addHit(Hit(x: x0, y: y, w: inner, h: 1, target: .sessionEditor, id: id))
            return
        }
        frame.text(x, y, elide(title, end - x), style(p.text, bg, weight), end - x)
        var details = title + "\n" + row.cwd + (row.branch.isEmpty ? "" : "\n" + row.branch) + "\n" + statusLabel
        if running { details += "\n" + activityLabel + (row.activityDetail.isEmpty ? "" : ": " + row.activityDetail) }
        if row.pinned { details += "\nPinned" }
        if unread > 0 { details += "\n\(unread) unread notifications" }
        if !row.noticeTitle.isEmpty { details += "\n" + row.noticeTitle + (row.noticeBody.isEmpty ? "" : "\n" + row.noticeBody) }
        if !row.terminalError.isEmpty { details += "\n" + row.terminalError }
        addHit(Hit(x: x0, y: y, w: inner, h: 1, target: .sessionRow, id: id, tooltip: details))
        if trash { addHit(Hit(x: trashX - 1, y: y, w: 3, h: 1, target: .sessionTrash, id: id, tooltip: "Close session \(title)")) }
    }

    func paintButton(_ x: Int, _ y: Int, _ label: String, _ role: DialogButton.Role, focused: Bool, hovered: Bool) {
        var fg = p.text, bg = p.raisedHover
        var attributes: TuiAttributes = []
        if role == .destructive {
            fg = p.danger
            bg = p.dangerDim
        } else if role == .accent {
            fg = p.onAccent
            bg = p.accent
        }
        if hovered { bg = toward(bg, p.text, 0.08) }
        if focused {
            attributes.insert(.bold)
            if role == .destructive {
                fg = p.onDanger
                bg = p.danger
            } else if role == .accent {
                attributes.insert(.underline)
            } else {
                fg = p.onAccent
                bg = p.accent
            }
        }
        let width = textWidth(label) + 4
        frame.fill(x, y, width, 1, style(fg, bg, attributes))
        frame.text(x + 2, y, label, style(fg, bg, attributes), width - 4)
    }

    func paintTerminal() {
        let x0 = termX, y0 = termY, width = termW, height = termH
        if width <= 0 || height <= 0 { return }
        let base = style(p.text, p.terminal)
        addHit(Hit(x: x0, y: y0, w: width, h: height, target: .terminal))
        let id = selectedId
        let focused = focus == .terminal && menu == nil && dialog == nil
        func centeredButton(_ label: String, _ index: Int, _ y: Int) {
            let buttonWidth = textWidth(label) + 4
            let x = x0 + max(0, (width - buttonWidth) / 2)
            paintButton(x, y, label, .normal, focused: focused, hovered: hover.target == .terminalButton && hover.index == index)
            addHit(Hit(x: x, y: y, w: buttonWidth, h: 1, target: .terminalButton, index: index))
        }
        if id.isEmpty {
            frame.fill(x0, y0, width, height, base)
            centeredButton("Create a terminal session", createButton, y0 + height / 2)
            return
        }
        let session = selected
        let status = session?.status
        let error = session?.terminalError ?? ""
        if error.isEmpty && terminals.hasOutput(id) {
            frame.fill(x0, y0, width, height, TuiStyle())
            _ = terminals.paint(id, &frame, x0, y0, width, height)
            if status == .stopped {
                let label = "Start session"
                let buttonWidth = textWidth(label) + 4
                let x = x0 + max(0, width - 2 - buttonWidth)
                paintButton(x, y0 + 1, label, .normal, focused: focused, hovered: hover.target == .terminalButton && hover.index == startButton)
                addHit(Hit(x: x, y: y0 + 1, w: buttonWidth, h: 1, target: .terminalButton, index: startButton))
            } else if focused {
                let cursor = terminals.cursor(id)
                if cursor.visible && cursor.x < width && cursor.y < height {
                    frame.cursor = Surface.Cursor(x: x0 + cursor.x, y: y0 + cursor.y, visible: true, shape: cursor.shape)
                }
            }
            return
        }
        frame.fill(x0, y0, width, height, base)
        let title = !error.isEmpty ? "Terminal unavailable"
            : status == .starting ? "Starting session…"
            : status == .stopped ? "Session stopped" : "Connecting terminal…"
        let message = !error.isEmpty
            ? error + (status == .running ? "\nThe session and its jobs are still running." : "")
            : status == .stopped ? "Start a fresh shell in the saved working directory. Previous commands will not be replayed." : ""
        let columnWidth = max(4, min(width - 4, 56))
        let titleLines = wrap(title, columnWidth)
        let lines = message.isEmpty ? [] : wrap(message, columnWidth)
        let button = status == .stopped || !error.isEmpty
        let total = titleLines.count + (lines.isEmpty ? 0 : 1 + lines.count) + (button ? 2 : 0)
        var y = y0 + max(0, (height - total) / 2)
        for line in titleLines {
            frame.text(x0 + max(0, (width - textWidth(line)) / 2), y, line, style(p.text, p.terminal, .bold), width)
            y += 1
        }
        if !lines.isEmpty {
            y += 1
            for line in lines {
                frame.text(x0 + max(0, (width - textWidth(line)) / 2), y, line, style(p.muted, p.terminal), width)
                y += 1
            }
        }
        if button {
            y += 1
            if status == .stopped { centeredButton("Start session", startButton, y) }
            else { centeredButton("Reconnect terminal", reconnectButton, y) }
        }
    }

    func paintBox(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ bg: TuiColor, _ border: TuiColor) {
        let fill = style(p.text, bg), line = style(border, bg)
        frame.fill(x, y, width, height, fill)
        var col = x + 1
        while col < x + width - 1 {
            frame.text(col, y, "─", line, 1)
            frame.text(col, y + height - 1, "─", line, 1)
            col += 1
        }
        var row = y + 1
        while row < y + height - 1 {
            frame.text(x, row, "│", line, 1)
            frame.text(x + width - 1, row, "│", line, 1)
            row += 1
        }
        frame.text(x, y, "╭", line, 1)
        frame.text(x + width - 1, y, "╮", line, 1)
        frame.text(x, y + height - 1, "╰", line, 1)
        frame.text(x + width - 1, y + height - 1, "╯", line, 1)
    }

    /// Draws a menu with its top-left corner near (x, y), kept on screen.
    func paintMenuBox(_ items: [MenuItem], _ left: Int, _ top: Int, highlighted: Int, open: Int, target: Target) {
        let width = min(menuWidth(items), frame.cols), height = min(items.count + 2, frame.rows)
        let x = max(0, min(left, max(0, frame.cols - width)))
        let y = max(0, min(top, max(0, frame.rows - height)))
        paintBox(x, y, width, height, p.raised, p.raisedBorder)
        addHit(Hit(x: x, y: y, w: width, h: height, target: .menuSurface))
        var i = 0
        while i < items.count && i < height - 2 {
            let item = items[i]
            let row = y + 1 + i
            defer { i += 1 }
            if item.separator {
                let line = style(p.raisedBorder, p.raised)
                frame.text(x, row, "├", line, 1)
                var col = x + 1
                while col < x + width - 1 {
                    frame.text(col, row, "─", line, 1)
                    col += 1
                }
                frame.text(x + width - 1, row, "┤", line, 1)
                continue
            }
            let lit = item.enabled && (i == highlighted || i == open)
            let bg = lit ? (item.destructive ? p.dangerDim : p.raisedHover) : p.raised
            let attributes: TuiAttributes = item.enabled ? [] : .faint
            let fg = !item.enabled ? p.muted : item.destructive ? p.danger : p.text
            frame.fill(x + 1, row, width - 2, 1, style(fg, bg, attributes))
            frame.text(x + 2, row, item.checked ? glyphCheck : item.icon, style(item.destructive ? p.danger : p.muted, bg, attributes), 1)
            var end = x + width - 2
            if !item.submenu.isEmpty {
                frame.text(end - 1, row, glyphChevron, style(p.muted, bg, attributes), 1)
                end -= 2
            }
            if !item.hint.isEmpty {
                let hintWidth = textWidth(item.hint)
                frame.text(end - hintWidth, row, item.hint, style(p.muted, bg, attributes), hintWidth)
                end -= hintWidth + 2
            }
            frame.text(x + 4, row, elide(item.text, end - x - 4), style(fg, bg, attributes), end - x - 4)
            if item.enabled { addHit(Hit(x: x + 1, y: row, w: width - 2, h: 1, target: target, index: i)) }
        }
    }

    func paintMenu() {
        guard let menu else { return }
        let x = menu.alignRight ? menu.x - menuWidth(menu.items) : menu.x
        paintMenuBox(menu.items, x, menu.y, highlighted: menu.inSubmenu ? -1 : menu.highlighted, open: menu.open, target: .menuItem)
        if menu.open < 0 || menu.open >= menu.items.count { return }
        // The parent box may have been shifted on screen; recover its row from the hit map.
        var parent = Hit()
        for hit in hits where hit.target == .menuItem && hit.index == menu.open { parent = hit }
        let sub = menu.items[menu.open].submenu
        let subWidth = menuWidth(sub)
        var subX = parent.x + parent.w
        if subX + subWidth > frame.cols { subX = max(0, parent.x - 1 - subWidth) }
        paintMenuBox(sub, subX, parent.y - 1, highlighted: menu.subHighlighted, open: -1, target: .submenuItem)
    }

    func paintDialog() {
        guard let dialog else { return }
        let screenWidth = frame.cols, screenHeight = frame.rows
        let amount = p.overlay
        frame.restyle(0, 0, screenWidth, screenHeight) { s in
            s.fg = darken(s.fg, amount)
            s.bg = darken(s.bg, amount)
            if case .rgb = s.fg {} else { s.attributes.insert(.faint) }
        }
        frame.cursor = Surface.Cursor()
        addHit(Hit(x: 0, y: 0, w: screenWidth, h: screenHeight, target: .backdrop))
        let width = max(20, min(screenWidth - 2, dialog.hasInput ? 66 : 58))
        let inner = width - 6
        var title = wrap(dialog.title, inner)
        if title.count > 3 {
            title = Array(title[0..<3])
            title[2] = elide(title[2] + "…", inner)
        }
        var buttonsWidth = 0
        for button in dialog.buttons { buttonsWidth += textWidth(button.label) + 4 + 2 }
        buttonsWidth -= 2
        let fixed = 2 + title.count + 1 + (dialog.hasInput ? 2 : 0) + 1 + 2
        var message = wrap(dialog.message, inner)
        let room = max(0, screenHeight - fixed - 1)
        if message.count > room {
            message = Array(message[0..<room])
            if room > 0 { message[room - 1] = elide(message[room - 1] + "…", inner) }
        }
        let height = fixed + (message.isEmpty ? 0 : message.count + 1)
        let x = max(0, (screenWidth - width) / 2), y = max(0, (screenHeight - height) / 2)
        paintBox(x, y, width, height, p.raised, p.raisedBorder)
        addHit(Hit(x: x, y: y, w: width, h: height, target: .dialogSurface))
        var row = y + 2
        for line in title {
            frame.text(x + 3, row, line, style(p.text, p.raised, .bold), inner)
            row += 1
        }
        row += 1
        for line in message {
            frame.text(x + 3, row, line, style(p.muted, p.raised), inner)
            row += 1
        }
        if !message.isEmpty { row += 1 }
        if dialog.hasInput {
            paintEdit(dialog.input, x + 3, row, inner, style(p.text, p.terminal), dialog.placeholder, focused: dialog.focus == -1)
            if dialog.focus == -1 { frame.text(x + 2, row, glyphMarker, style(p.accent, p.raised), 1) }
            addHit(Hit(x: x + 3, y: row, w: inner, h: 1, target: .dialogInput))
            row += 2
        }
        var buttonX = x + width - 3 - buttonsWidth
        for (i, button) in dialog.buttons.enumerated() {
            let buttonWidth = textWidth(button.label) + 4
            paintButton(buttonX, row, button.label, button.role, focused: dialog.focus == i, hovered: hover.target == .dialogButton && hover.index == i)
            addHit(Hit(x: buttonX, y: row, w: buttonWidth, h: 1, target: .dialogButton, index: i))
            buttonX += buttonWidth + 2
        }
    }

    func paintTooltip() {
        var lines: [String] = []
        for paragraph in tooltipText.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            lines += wrap(String(scalars: paragraph), 48)
        }
        var width = 0
        for line in lines { width = max(width, textWidth(line)) }
        width += 4
        let height = lines.count + 2
        var x = tooltipX + 1, y = tooltipY + 1
        if x + width > frame.cols { x = max(0, frame.cols - width) }
        if y + height > frame.rows { y = max(0, tooltipY - height) }
        paintBox(x, y, width, height, p.raised, p.raisedBorder)
        for (i, line) in lines.enumerated() { frame.text(x + 2, y + 1 + i, line, style(p.text, p.raised), width - 4) }
    }

    func paintDrag() {
        let caption = elide(drag.caption, 24)
        let width = textWidth(caption) + 4
        let x = max(0, min(mouseX + 1, max(0, frame.cols - width)))
        let y = max(0, min(mouseY, max(0, frame.rows - 1)))
        frame.fill(x, y, width, 1, style(p.text, p.raisedHover))
        frame.text(x + 2, y, caption, style(p.text, p.raisedHover, .bold), width - 4)
    }
}
