import AppKit
import CinmuxCore
import Observation
import SwiftUI

/// Interface state around the session controller: selection restore, inline
/// editors, confirmations and errors. Mirrors the Linux GUI's Main.qml.
@MainActor
@Observable
final class AppModel {
    enum Editing: Equatable {
        case session(String)
        case newFolder
        case folder(String)
    }

    enum Confirmation: Identifiable {
        case closeSession(id: String, title: String)
        case closePane(id: String, title: String)
        case deleteFolder(id: String, name: String)

        var id: String {
            switch self {
            case .closeSession(let id, _): return "session-" + id
            case .closePane(let id, _): return "pane-" + id
            case .deleteFolder(let id, _): return "folder-" + id
            }
        }

        var title: String {
            switch self {
            case .closeSession(_, let title): return "Close session “\(title)”?"
            case .closePane(_, let title): return "Close pane in “\(title)”?"
            case .deleteFolder(_, let name): return "Delete folder “\(name)”?"
            }
        }

        var message: String {
            switch self {
            case .closeSession: return "All its shells and jobs will end, and it will be removed from the list. This cannot be undone."
            case .closePane: return "The active pane’s shell and jobs will end. If it is the session’s last pane, the session will also be removed. This cannot be undone."
            case .deleteFolder: return "Its sessions will become unfiled. Their shells and jobs will keep running."
            }
        }

        var confirmText: String {
            switch self {
            case .closeSession: return "Close session"
            case .closePane: return "Close pane"
            case .deleteFolder: return "Delete folder"
            }
        }
    }

    struct Recovery: Equatable {
        var sessionId: String
        var folderId: String
        var path: String
    }

    struct Failure: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var recovery: Recovery?
    }

    let controller: SessionController?
    let terminals: TerminalViews?
    let startupError: String?

    var editing: Editing?
    var draft = ""
    var editError = ""
    var confirmation: Confirmation?
    var failure: Failure?
    var searchVisible = false
    /// Bumped to move keyboard focus: into the terminal, or into the search field.
    var terminalFocusToken = 0
    var searchFocusToken = 0
    var sidebarVisible: Bool {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: Keys.sidebarVisible) }
    }
    var sidebarWidth: Double {
        didSet { UserDefaults.standard.set(sidebarWidth, forKey: Keys.sidebarWidth) }
    }
    var collapsedFolders: Set<String> {
        didSet { UserDefaults.standard.set(Array(collapsedFolders), forKey: Keys.collapsedFolders) }
    }
    var collapsedSections: Set<String> {
        didSet { UserDefaults.standard.set(Array(collapsedSections), forKey: Keys.collapsedSections) }
    }

    @ObservationIgnored private var submitting = false
    @ObservationIgnored private let notifier = Notifier()

    enum Keys {
        static let sidebarVisible = "sidebarVisible"
        static let sidebarWidth = "sidebarWidth"
        static let collapsedFolders = "collapsedFolders"
        static let collapsedSections = "collapsedSections"
    }

    init() {
        let defaults = UserDefaults.standard
        sidebarVisible = defaults.object(forKey: Keys.sidebarVisible) as? Bool ?? true
        sidebarWidth = max(200, min(420, defaults.object(forKey: Keys.sidebarWidth) as? Double ?? 264))
        collapsedFolders = Set(defaults.stringArray(forKey: Keys.collapsedFolders) ?? [])
        collapsedSections = Set(defaults.stringArray(forKey: Keys.collapsedSections) ?? [])
        let store = StateStore()
        do {
            try store.open()
        } catch {
            controller = nil
            terminals = nil
            startupError = error.cinmuxMessage
            return
        }
        startupError = nil
        let terminals = TerminalViews(socket: store.tmuxSocket)
        self.terminals = terminals
        let helper = Paths.executable().map { executable -> String in
            // Contents/MacOS/Cinmux → Contents/Helpers holds the `cinmux` CLI.
            URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers").path
        }
        let controller = SessionController(store: store, renderer: terminals,
                                           helperDirectory: helper.flatMap { FileManager.default.fileExists(atPath: $0 + "/cinmux") ? $0 : nil })
        self.controller = controller
        controller.onFailure = { [weak self] id, message in self?.operationFailed(id, message) }
        controller.onDirectoryRequired = { [weak self] sessionId, folderId, path in
            self?.failure?.recovery = Recovery(sessionId: sessionId, folderId: folderId, path: path)
        }
        controller.onChange = { [weak self] in self?.stateChanged() }
        // The Linux GUI's [selection] in <state>/ui.ini, which `cinmux tui` also falls back to.
        let settings = IniSettings(path: store.stateDirectory + "/ui.ini")
        controller.setView(settings.value("selection/view") ?? "all")
        if let selected = settings.value("selection/session"), !selected.isEmpty {
            controller.selectSession(selected)
        }
        notifier.onOpen = { [weak self] id in self?.revealFromNotification(id) }
        notifier.prime(controller.sessions)
    }

    /// Persists the selection; sessions keep running in tmux.
    func shutdown() {
        guard let controller else { return }
        // Re-read first: `cinmux tui` keeps its own [tui] group in the same file.
        let settings = IniSettings(path: controller.store.stateDirectory + "/ui.ini")
        settings.set("selection/view", controller.view)
        settings.set("selection/session", controller.selectedId)
        settings.sync()
        controller.shutdown()
        terminals?.detachAll()
    }

    private func stateChanged() {
        guard let controller else { return }
        notifier.observe(controller.sessions, selectedId: controller.selectedId)
        NSApp?.dockTile.badgeLabel = controller.attentionCount > 0 ? String(controller.attentionCount) : nil
    }

    private func operationFailed(_ id: String, _ message: String) {
        if submitting, let editing {
            switch editing {
            case .session(let editingId) where editingId == id: editError = message; return
            case .newFolder where id.isEmpty, .folder where id.isEmpty: editError = message; return
            default: break
            }
        }
        failure = Failure(message: message, recovery: nil)
    }

    // MARK: Actions

    func focusTerminal() {
        guard controller?.selectedId.isEmpty == false, confirmation == nil, failure == nil else { return }
        terminalFocusToken += 1
    }

    /// The folder a new tab joins: the chosen folder, else the selected tab's.
    private var newTabFolder: String {
        guard let controller else { return "" }
        if controller.view != "all" && controller.view != "attention" { return controller.view }
        if controller.view == "all" && controller.search.isEmpty { return controller.selected?.folderId ?? "" }
        return ""
    }

    func newTab(in folderId: String? = nil) {
        guard let controller else { return }
        let folder = folderId ?? newTabFolder
        controller.setSearch("")
        searchVisible = false
        controller.createSession(folderId: folder, cwd: "")
        if !folder.isEmpty { collapsedFolders.remove(folder) }
        focusTerminal()
    }

    func select(_ id: String) {
        guard let controller else { return }
        // Choosing a tab from the tree leaves folder focus; filtered lists stay filtered.
        if controller.search.isEmpty && controller.view != "attention" { controller.setView("all") }
        controller.selectSession(id)
        focusTerminal()
    }

    func chooseFolder(_ id: String) {
        guard let controller else { return }
        controller.setSearch("")
        if controller.view == id {
            controller.setView("all")
        } else {
            controller.setView(id)
            collapsedFolders.remove(id)
        }
    }

    func toggleAttention() {
        guard let controller else { return }
        controller.setSearch("")
        searchVisible = false
        controller.setView(controller.view == "attention" ? "all" : "attention")
    }

    func showAllTabs() {
        controller?.setSearch("")
        controller?.setView("all")
        searchVisible = false
        sidebarVisible = true
    }

    func showSearch() {
        sidebarVisible = true
        searchVisible = true
        searchFocusToken += 1
    }

    func endSearch() {
        controller?.setSearch("")
        searchVisible = false
        focusTerminal()
    }

    func nextAttention() {
        controller?.selectNextAttention()
        searchVisible = false
        focusTerminal()
    }

    func navigate(_ delta: Int) {
        controller?.navigate(delta)
        focusTerminal()
    }

    func split(_ direction: SessionController.SplitDirection) {
        controller?.splitActive(direction)
        focusTerminal()
    }

    func startSelected() {
        guard let controller, !controller.selectedId.isEmpty else { return }
        controller.startSession(controller.selectedId)
        focusTerminal()
    }

    func reconnectSelected() {
        guard let controller, !controller.selectedId.isEmpty else { return }
        controller.reconnectTerminal(controller.selectedId)
        focusTerminal()
    }

    // MARK: Editing

    func beginRename(_ id: String? = nil) {
        guard let controller else { return }
        let target = id ?? controller.selectedId
        guard let row = controller.sessions.first(where: { $0.id == target }) else { return }
        if controller.search.isEmpty == false || controller.view == "attention" || !controller.rows.contains(where: { $0.id == target }) {
            controller.setSearch("")
            controller.setView("all")
            searchVisible = false
        }
        if !row.folderId.isEmpty { collapsedFolders.remove(row.folderId) }
        sidebarVisible = true
        draft = row.title
        editError = ""
        editing = .session(target)
    }

    func beginNewFolder() {
        sidebarVisible = true
        collapsedSections.remove("folders")
        draft = ""
        editError = ""
        editing = .newFolder
    }

    func beginRenameFolder(_ id: String, name: String) {
        draft = name
        editError = ""
        editing = .folder(id)
    }

    func submitEdit() {
        guard let controller, let editing, !submitting else { return }
        editError = ""
        submitting = true
        switch editing {
        case .session(let id): controller.renameSession(id, title: draft)
        case .newFolder: controller.createFolder(draft)
        case .folder(let id): controller.renameFolder(id, name: draft)
        }
        submitting = false
        if editError.isEmpty { cancelEdit() }
    }

    func cancelEdit() {
        editing = nil
        editError = ""
        focusTerminal()
    }

    // MARK: Confirmations

    func confirmCloseSession(_ id: String? = nil) {
        guard let controller else { return }
        let target = id ?? controller.selectedId
        guard let row = controller.sessions.first(where: { $0.id == target }) else { return }
        confirmation = .closeSession(id: row.id, title: row.title)
    }

    func confirmClosePane() {
        guard let selected = controller?.selected else { return }
        confirmation = .closePane(id: selected.id, title: selected.title)
    }

    func confirmDeleteFolder(_ id: String, name: String) {
        confirmation = .deleteFolder(id: id, name: name)
    }

    func accept(_ confirmation: Confirmation) {
        guard let controller else { return }
        self.confirmation = nil
        switch confirmation {
        case .closeSession(let id, _): controller.closeSession(id)
        case .closePane(let id, _): if controller.selectedId == id { controller.closeActivePane() }
        case .deleteFolder(let id, _): controller.deleteFolder(id)
        }
        focusTerminal()
    }

    /// Asks for a working directory after "Working directory is missing or inaccessible".
    func chooseDirectory(for recovery: Recovery) {
        failure = nil
        let panel = NSOpenPanel()
        panel.title = "Choose session working directory"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.isFileURL, url.path.hasPrefix("/") else {
            failure = Failure(message: "Choose a local directory.")
            return
        }
        if recovery.sessionId.isEmpty { controller?.createSession(folderId: recovery.folderId, cwd: url.path) }
        else { controller?.startSession(recovery.sessionId, cwd: url.path) }
        focusTerminal()
    }

    private func revealFromNotification(_ id: String) {
        NSApp.activate()
        for window in NSApp.windows where window.canBecomeMain { window.makeKeyAndOrderFront(nil) }
        guard let controller, controller.sessions.contains(where: { $0.id == id }) else { return }
        controller.setSearch("")
        controller.setView("all")
        controller.selectSession(id)
        focusTerminal()
    }
}
