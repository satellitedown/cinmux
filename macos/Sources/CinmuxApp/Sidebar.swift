import CinmuxCore
import SwiftUI

struct Sidebar: View {
    @Bindable var model: AppModel
    let controller: SessionController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Spacer().frame(width: Chrome.trafficLightsWidth)
                BarButton(symbol: "sidebar.left", help: "Hide sidebar (⌃⌘S)") { model.sidebarVisible = false }
                Spacer()
            }
            .padding(.top, Chrome.barInset)
            .frame(height: Chrome.barHeight, alignment: .top)
            .titleBarArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    actions
                    Spacer().frame(height: 10)
                    if !controller.search.isEmpty {
                        flatList(heading: "Search results", empty: "No matching sessions")
                    } else if controller.view == "attention" {
                        flatList(heading: "Needs Attention", empty: "No sessions need attention")
                    } else {
                        tree
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
            .contextMenu { backgroundMenu }

            Divider().opacity(0.5)
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(SidebarBackground())
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        ActionRow(title: "New tab", symbol: "square.and.pencil", hint: "⌘T") { model.newTab() }
        if model.searchVisible || !controller.search.isEmpty {
            SearchField(model: model, controller: controller)
        } else {
            ActionRow(title: "Search", symbol: "magnifyingglass", hint: "⌘F") { model.showSearch() }
        }
        ActionRow(title: "Needs Attention", symbol: controller.attentionCount > 0 ? "bell.badge" : "bell",
                  selected: controller.view == "attention" && controller.search.isEmpty,
                  count: controller.attentionCount) { model.toggleAttention() }
    }

    @ViewBuilder private var backgroundMenu: some View {
        Button("New tab") { model.newTab() }
        Button("New folder") { model.beginNewFolder() }
        Divider()
        Button("Show all tabs") { model.showAllTabs() }
    }

    // MARK: Lists

    @ViewBuilder
    private func flatList(heading: String, empty: String) -> some View {
        SectionHeader(title: heading, count: controller.rows.count)
        if controller.rows.isEmpty {
            EmptyNote(text: empty)
        }
        ForEach(controller.rows) { row in
            SessionRowView(model: model, controller: controller, row: row, indent: 0)
        }
    }

    @ViewBuilder private var tree: some View {
        let pinned = controller.sessions.filter(\.pinned)
        if !pinned.isEmpty {
            SectionHeader(title: "Pinned", collapsed: collapsedBinding("pinned"))
            if !model.collapsedSections.contains("pinned") {
                ForEach(pinned) { row in SessionRowView(model: model, controller: controller, row: row, indent: 0) }
            }
            Spacer().frame(height: 10)
        }

        SectionHeader(title: "Folders", collapsed: collapsedBinding("folders")) {
            BarButton(symbol: "folder.badge.plus", help: "New folder (⇧⌘N)") { model.beginNewFolder() }
        }
        if !model.collapsedSections.contains("folders") {
            if model.editing == .newFolder {
                NameEditor(model: model, placeholder: "Folder name", accessibility: "New folder name")
            }
            ForEach(controller.folders) { folder in
                let children = controller.sessions.filter { $0.folderId == folder.id && !$0.pinned }
                if model.editing == .folder(folder.id) {
                    NameEditor(model: model, placeholder: "Folder name", accessibility: "Rename folder")
                } else {
                    // Pinned tabs show under Pinned, so the badge counts what is listed here.
                    FolderRowView(model: model, controller: controller, folder: folder, count: children.count)
                }
                if !model.collapsedFolders.contains(folder.id) {
                    ForEach(children) { row in
                        SessionRowView(model: model, controller: controller, row: row, indent: 18)
                    }
                }
            }
            if controller.folders.isEmpty && model.editing != .newFolder {
                EmptyNote(text: "Drag tabs here after creating a folder.")
            }
        }
        Spacer().frame(height: 10)

        let unfiled = controller.sessions.filter { $0.folderId.isEmpty && !$0.pinned }
        SectionHeader(title: "Tabs", collapsed: collapsedBinding("tabs"), dropFolder: "", controller: controller)
        if !model.collapsedSections.contains("tabs") {
            if controller.sessions.isEmpty { EmptyNote(text: "No sessions") }
            ForEach(unfiled) { row in SessionRowView(model: model, controller: controller, row: row, indent: 0) }
        }
    }

    private func collapsedBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { model.collapsedSections.contains(key) },
                set: { collapsed in if collapsed { model.collapsedSections.insert(key) } else { model.collapsedSections.remove(key) } })
    }
}

// MARK: Rows

private struct ActionRow: View {
    let title: String
    let symbol: String
    var hint = ""
    var selected = false
    var count = 0
    let action: () -> Void
    @State var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                } else if hovered && !hint.isEmpty {
                    Text(hint).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RowBackground(selected: selected, hovered: hovered))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct SectionHeader<Trailing: View>: View {
    let title: String
    var count: Int?
    var collapsed: Binding<Bool>?
    /// A drop target: sessions dropped here move to this folder ("" is unfiled).
    var dropFolder: String?
    var controller: SessionController?
    @ViewBuilder var trailing: () -> Trailing
    @State var hovered = false
    @State var targeted = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                collapsed?.wrappedValue.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    if let collapsed, hovered || collapsed.wrappedValue {
                        Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(collapsed == nil)
            Spacer()
            if let count { Text("\(count)").font(.system(size: 12)).foregroundStyle(.secondary) }
            trailing()
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(height: 28)
        .background(RowBackground(targeted: targeted))
        .onHover { hovered = $0 }
        .modifier(SessionDrop(folderId: dropFolder, controller: controller, targeted: $targeted))
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil, collapsed: Binding<Bool>? = nil, dropFolder: String? = nil, controller: SessionController? = nil) {
        self.init(title: title, count: count, collapsed: collapsed, dropFolder: dropFolder, controller: controller, trailing: { EmptyView() })
    }
}

/// Accepts dragged session IDs and moves them into a folder.
private struct SessionDrop: ViewModifier {
    let folderId: String?
    let controller: SessionController?
    @Binding var targeted: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if let folderId, let controller {
            content.dropDestination(for: String.self) { items, _ in
                let ids = items.filter { id in controller.sessions.contains { $0.id == id } }
                // Finish the drop before the move re-renders (and may remove) the dragged row.
                onMain { for id in ids { controller.moveSession(id, folderId: folderId) } }
                return !ids.isEmpty
            } isTargeted: { targeted = $0 }
        } else {
            content
        }
    }
}

private struct EmptyNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

private struct FolderRowView: View {
    let model: AppModel
    let controller: SessionController
    let folder: FolderSummary
    let count: Int
    @State var hovered = false
    @State var targeted = false

    private var expanded: Bool { !model.collapsedFolders.contains(folder.id) }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggle) {
                Image(systemName: hovered ? (expanded ? "chevron.down" : "chevron.right") : (expanded ? "folder" : "folder.fill"))
                    .font(.system(size: hovered ? 10 : 13, weight: hovered ? .semibold : .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Collapse" : "Expand")
            .accessibilityLabel(expanded ? "Collapse \(folder.name)" : "Expand \(folder.name)")
            Button { model.chooseFolder(folder.id) } label: {
                HStack(spacing: 4) {
                    Text(folder.name)
                        .font(.system(size: 13, weight: controller.view == folder.id ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if !hovered && count > 0 {
                        Text("\(count)").font(.system(size: 12)).foregroundStyle(.secondary).padding(.trailing, 6)
                    }
                }
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(folder.name), \(count) sessions")
            if hovered {
                BarButton(symbol: "square.and.pencil", help: "New tab in \(folder.name)") { model.newTab(in: folder.id) }
                Menu {
                    menu
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 22, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Folder actions for \(folder.name)")
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 2)
        .frame(height: 30)
        .background(RowBackground(selected: controller.view == folder.id, targeted: targeted, hovered: hovered))
        .onHover { hovered = $0 }
        .contextMenu { menu }
        .modifier(SessionDrop(folderId: folder.id, controller: controller, targeted: $targeted))
    }

    private func toggle() {
        if expanded { model.collapsedFolders.insert(folder.id) } else { model.collapsedFolders.remove(folder.id) }
    }

    @ViewBuilder private var menu: some View {
        Button("New tab") { model.newTab(in: folder.id) }
        Button("New folder") { model.beginNewFolder() }
        Divider()
        Button("Rename folder") { model.beginRenameFolder(folder.id, name: folder.name) }
        Divider()
        Button("Delete folder…", role: .destructive) { model.confirmDeleteFolder(folder.id, name: folder.name) }
    }
}

struct SessionRowView: View {
    let model: AppModel
    let controller: SessionController
    let row: SessionRow
    let indent: CGFloat
    @State var hovered = false

    private var selected: Bool { row.id == controller.selectedId }
    private var renaming: Bool { model.editing == .session(row.id) }

    var body: some View {
        if renaming {
            NameEditor(model: model, placeholder: "Session title", accessibility: "Session title", indent: indent)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 7) {
            if row.pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.tertiary).rotationEffect(.degrees(45))
            }
            Text(row.title)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(row.status == .stopped ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if hovered {
                Button { model.confirmCloseSession(row.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Close session \(row.title)")
            } else {
                if row.unreadCount > 0 {
                    Text("\(row.unreadCount)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
                }
                if !row.terminalError.isEmpty {
                    Circle().fill(Color.red).frame(width: 5, height: 5)
                }
                if row.status == .stopped {
                    Text("Stopped").font(.system(size: 11)).foregroundStyle(.tertiary)
                } else {
                    ActivityGlyph(row: row)
                }
            }
        }
        .padding(.leading, 8 + indent)
        .padding(.trailing, 8)
        .frame(height: 30)
        .background(RowBackground(selected: selected, hovered: hovered))
        .contentShape(Rectangle())
        .onTapGesture { model.select(row.id) }
        .onHover { hovered = $0 }
        .help(row.details)
        .draggable(row.id) {
            Text(row.title)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        }
        .contextMenu { SessionMenu(model: model, controller: controller, row: row) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.title + ", " + row.statusLabel + ", " + row.activityLabel + (row.unreadCount > 0 ? ", \(row.unreadCount) unread notifications" : ""))
        .accessibilityHint(row.details)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The session context menu (Linux SessionList sessionMenu).
struct SessionMenu: View {
    let model: AppModel
    let controller: SessionController
    let row: SessionRow

    var body: some View {
        Button("New tab") { model.newTab(in: row.folderId) }
        Divider()
        Button("Rename") { model.beginRename(row.id) }
        Button(row.pinned ? "Unpin session" : "Pin session") { controller.setPinned(row.id, !row.pinned) }
        Divider()
        Menu("Move to folder") {
            Button("Unfiled") { controller.moveSession(row.id, folderId: "") }.disabled(row.folderId.isEmpty)
            if !controller.folders.isEmpty { Divider() }
            ForEach(controller.folders) { folder in
                Button(folder.name) { controller.moveSession(row.id, folderId: folder.id) }.disabled(row.folderId == folder.id)
            }
        }
        Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: row.cwd) }
        Divider()
        Button("Close session…", role: .destructive) { model.confirmCloseSession(row.id) }
    }
}

/// Inline name editor for sessions and folders, with the failure shown beneath.
private struct NameEditor: View {
    @Bindable var model: AppModel
    let placeholder: String
    let accessibility: String
    var indent: CGFloat = 0
    @FocusState var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField(placeholder, text: $model.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(model.editError.isEmpty ? Color.accentColor : Color.red, lineWidth: 1))
                .focused($focused)
                .onSubmit { model.submitEdit() }
                .onExitCommand { model.cancelEdit() }
                .onChange(of: model.draft) { model.editError = "" }
                .onChange(of: focused) { _, now in if !now && model.editing != nil && model.editError.isEmpty { model.cancelEdit() } }
                .accessibilityLabel(accessibility)
            if !model.editError.isEmpty {
                Text(model.editError).font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 8)
            }
        }
        .padding(.leading, indent)
        .padding(.vertical, 1)
        .focusOnAppear($focused)
    }
}

private struct SearchField: View {
    @Bindable var model: AppModel
    let controller: SessionController
    @FocusState var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
            TextField("Search sessions", text: Binding(get: { controller.search }, set: { controller.setSearch($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit { model.focusTerminal() }
                .onExitCommand { model.endSearch() }
                .accessibilityHint("Search session titles, working directories and branches")
            if !controller.search.isEmpty {
                Button { controller.setSearch(""); focused = true } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.accentColor.opacity(focused ? 0.8 : 0), lineWidth: 1))
        .focusOnAppear($focused)
        .onChange(of: model.searchFocusToken) {
            NSApp.keyWindow?.makeFirstResponder(nil)
            focused = true
        }
        .onChange(of: focused) { _, now in if !now && controller.search.isEmpty { model.searchVisible = false } }
    }
}
