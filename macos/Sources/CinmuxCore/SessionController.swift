import Darwin
import Foundation
import Observation

public enum SessionStatus: String, Sendable {
    case stopped, starting, running
}

/// One session as the interfaces show it.
public struct SessionRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// Empty when the session is not in a folder.
    public var folderId: String
    public var pinned: Bool
    public var cwd: String
    /// The git branch, `detached:<rev>`, or empty outside a repository.
    public var branch: String
    public var status: SessionStatus
    public var unreadCount: Int
    public var noticeTitle: String
    public var noticeBody: String
    public var noticeSequence: Int64
    public var noticeAt: Int64
    public var terminalError: String
    public var activity: Activity
    public var activityDetail: String
    public var activityAt: Int64
    public var createdAt: Int64

    public var needsAttention: Bool { unreadCount > 0 || activity == .waiting }
}

public struct FolderSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var count: Int
}

/// Owns the sessions of one state profile: mirrors the database, reconciles
/// with the private tmux server and drives a renderer. Main-thread only.
@MainActor
@Observable
public final class SessionController: TerminalRendererDelegate {
    /// Every session, pinned first, then newest first.
    public private(set) var sessions: [SessionRow] = []
    /// `sessions` filtered by the search text or, without one, by `view`.
    public private(set) var rows: [SessionRow] = []
    public private(set) var folders: [FolderSummary] = []
    /// Empty when nothing is selected.
    public private(set) var selectedId = ""
    public private(set) var search = ""
    /// "all", "attention" or a folder ID.
    public private(set) var view = "all"
    public private(set) var attentionCount = 0

    public var totalCount: Int { sessions.count }
    public var selected: SessionRow? { selectedId.isEmpty ? nil : sessions.first { $0.id == selectedId } }

    /// (session ID or empty, message): an operation failed.
    @ObservationIgnored public var onFailure: ((String, String) -> Void)?
    /// (session ID or empty, folder ID or empty, path): the directory is unusable; ask for another.
    @ObservationIgnored public var onDirectoryRequired: ((String, String, String) -> Void)?
    /// Any published state changed.
    @ObservationIgnored public var onChange: (() -> Void)?

    public let store: StateStore
    @ObservationIgnored private weak var renderer: TerminalRenderer?

    private final class Session {
        var record: SessionRecord
        var status: SessionStatus = .stopped
        var branch = ""
        var terminalError = ""
        var panes: [TmuxPane] = []
        var reconciled = false
        var closing = false
        init(record: SessionRecord) { self.record = record }
    }

    private struct GitEntry { var branch = ""; var checkedAt: Int64 = 0; var pending = false }
    private typealias Done = @MainActor () -> Void
    private typealias Operation = @MainActor (@escaping Done) -> Void
    private typealias Completion = @MainActor (CommandResult) -> Void

    @ObservationIgnored private var entries: [String: Session] = [:]
    @ObservationIgnored private var folderRecords: [FolderRecord] = []
    @ObservationIgnored private var operations: [String: [Operation]] = [:]
    @ObservationIgnored private var busy: Set<String> = []
    @ObservationIgnored private var git: [String: GitEntry] = [:]
    @ObservationIgnored private let hostEnvironment: [String: String]
    @ObservationIgnored private let tmuxProgram: String?
    @ObservationIgnored private let gitProgram: String?
    @ObservationIgnored private var tmuxConfig: String?
    @ObservationIgnored private var dataVersion: Int64 = -1
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var lastPublished: PublishedState?
    @ObservationIgnored private var shuttingDown = false
    @ObservationIgnored private var metadataTimer: DispatchSourceTimer?
    @ObservationIgnored private var databaseTimer: DispatchSourceTimer?
    /// Where `cinmux` lives: prepended to sessions' PATH so agents can report.
    @ObservationIgnored private let helperDirectory: String?

    /// `store` must already be open.
    public init(store: StateStore, renderer: TerminalRenderer?, helperDirectory: String? = nil) {
        self.store = store
        self.renderer = renderer
        self.helperDirectory = helperDirectory
        var host = HostEnvironment.current()
        // An unattached tmux client's own PATH replaces `-e PATH=…` for panes it
        // spawns (new-session, respawn-pane, split-window), so the helper must be
        // on the PATH of every tmux invocation for shells and agents to find `cinmux`.
        if let helperDirectory { host["PATH"] = helperDirectory + ":" + (host["PATH"] ?? "") }
        hostEnvironment = host
        tmuxProgram = HostEnvironment.findExecutable("tmux", environment: hostEnvironment)
        gitProgram = HostEnvironment.findExecutable("git", environment: hostEnvironment)
        tmuxConfig = Self.materializeConfig(stateDirectory: store.stateDirectory)
        renderer?.delegate = self
        // Sample before reading: a concurrent CLI commit must remain visible to the next poll.
        do {
            let initial = try store.dataVersion()
            if readState() { dataVersion = initial }
        } catch {
            let message = error.cinmuxMessage
            onMain { [weak self] in self?.fail("", message) }
        }
        metadataTimer = Self.timer(interval: 1.0) { [weak self] in self?.refresh() }
        databaseTimer = Self.timer(interval: 0.25) { [weak self] in self?.pollDatabase() }
        onMain { [weak self] in
            guard let self else { return }
            if self.tmuxProgram == nil { self.fail("", "tmux is not installed. Install it with: brew install tmux") }
            else if self.tmuxConfig == nil { self.fail("", "Cannot write the Cinmux tmux configuration") }
            else { self.refresh() }
        }
    }

    /// Stops polling and every renderer client. Sessions keep running in tmux.
    public func shutdown() {
        shuttingDown = true
        metadataTimer?.cancel()
        databaseTimer?.cancel()
        for id in entries.keys { renderer?.detach(id) }
    }

    private static func timer(interval: TimeInterval, _ handler: @escaping @MainActor () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(20))
        timer.setEventHandler { MainActor.assumeIsolated { handler() } }
        timer.resume()
        return timer
    }

    private static func materializeConfig(stateDirectory: String) -> String? {
        guard let source = Paths.resource("cinmux.tmux.conf"), let bytes = FileManager.default.contents(atPath: source) else { return nil }
        let destination = stateDirectory + "/cinmux.tmux.conf"
        do {
            try bytes.write(to: URL(fileURLWithPath: destination), options: .atomic)
            chmod(destination, 0o600)
            return destination
        } catch {
            return nil
        }
    }

    private func pollDatabase() {
        guard !shuttingDown else { return }
        do {
            let version = try store.dataVersion()
            if version != dataVersion && readState() { dataVersion = version }
        } catch {
            fail("", error.cinmuxMessage)
        }
    }

    // MARK: Commands

    private func command(_ program: String, _ arguments: [String], environment: [String: String], _ callback: @escaping Completion) {
        guard !shuttingDown else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Command.run(program, arguments, environment: environment)
            onMain { [weak self] in
                guard let self, !self.shuttingDown else { return }
                callback(result)
                if result.timedOut { onMain { [weak self] in self?.refresh() } }
            }
        }
    }

    private func tmux(_ arguments: [String], _ callback: @escaping Completion) {
        guard let tmuxProgram, let tmuxConfig else {
            callback(CommandResult(ok: false, timedOut: false, output: Data(), error: Data("tmux or the Cinmux tmux configuration is unavailable".utf8)))
            return
        }
        // Bootstrap tmux with the host locale: its global environment is inherited by shells.
        command(tmuxProgram, ["-S", store.tmuxSocket, "-f", tmuxConfig] + arguments.map(Tmux.escape), environment: hostEnvironment, callback)
    }

    private func enqueue(_ id: String, _ operation: @escaping Operation) {
        guard entries[id] != nil else { fail(id, "Unknown session"); return }
        operations[id, default: []].append(operation)
        if !busy.contains(id) { nextOperation(id) }
    }

    private func nextOperation(_ id: String) {
        guard !shuttingDown else { return }
        guard var queue = operations[id], !queue.isEmpty, entries[id] != nil else {
            operations[id] = nil
            busy.remove(id)
            return
        }
        busy.insert(id)
        let operation = queue.removeFirst()
        operations[id] = queue
        var completed = false
        operation { [weak self] in
            guard let self, !completed, !self.shuttingDown else { return }
            completed = true
            onMain { [weak self] in self?.nextOperation(id) }
        }
    }

    private func fail(_ id: String, _ message: String) { onFailure?(id, message) }

    /// Runs a store call, reporting a failure. Returns whether it succeeded.
    @discardableResult
    private func checked(_ id: String, _ body: () throws -> Void) -> Bool {
        do { try body(); return true } catch { fail(id, error.cinmuxMessage); return false }
    }

    // MARK: State

    @discardableResult
    private func readState() -> Bool {
        let records: [SessionRecord]
        let folderList: [FolderRecord]
        do {
            records = try store.sessions()
            folderList = try store.folders()
        } catch {
            fail("", error.cinmuxMessage)
            dataVersion = -1
            return false
        }
        var present = Set<String>()
        for record in records {
            present.insert(record.id)
            if let session = entries[record.id] {
                if session.record.cwd != record.cwd { session.branch = "" }
                session.record = record
            } else {
                entries[record.id] = Session(record: record)
            }
        }
        for id in Array(entries.keys) where !present.contains(id) {
            renderer?.detach(id)
            entries[id] = nil
            operations[id] = nil
        }
        folderRecords = folderList
        if !selectedId.isEmpty && entries[selectedId] == nil { selectedId = "" }
        if view != "all" && view != "attention" && !folderList.contains(where: { $0.id == view }) { view = "all" }
        publish()
        return true
    }

    private func row(_ session: Session) -> SessionRow {
        let record = session.record
        return SessionRow(id: record.id, title: record.title, folderId: record.folderId, pinned: record.pinned, cwd: record.cwd,
                          branch: session.branch, status: session.status, unreadCount: Int(record.unreadCount),
                          noticeTitle: record.noticeTitle, noticeBody: record.noticeBody, noticeSequence: record.noticeSequence,
                          noticeAt: record.noticeAt, terminalError: session.terminalError, activity: record.activity,
                          activityDetail: record.activityDetail, activityAt: record.activityAt, createdAt: record.createdAt)
    }

    private func publish() {
        let sorted = entries.values.sorted { a, b in
            if a.record.pinned != b.record.pinned { return a.record.pinned }
            if a.record.createdAt != b.record.createdAt { return a.record.createdAt > b.record.createdAt }
            return a.record.id < b.record.id
        }
        let all = sorted.map(row)
        let filtered = all.filter { row in
            if !search.isEmpty {
                return [row.title, row.cwd, row.branch].contains { $0.range(of: search, options: [.caseInsensitive]) != nil }
            }
            if view == "attention" { return row.needsAttention }
            return view == "all" || row.folderId == view
        }
        let summaries = folderRecords.map { folder in
            FolderSummary(id: folder.id, name: folder.name, count: entries.values.filter { $0.record.folderId == folder.id }.count)
        }
        let attention = entries.values.filter { $0.record.needsAttention }.count
        // Assign only on change: every assignment invalidates observing views.
        if sessions != all { sessions = all }
        if rows != filtered { rows = filtered }
        if folders != summaries { folders = summaries }
        if attentionCount != attention { attentionCount = attention }
        let snapshot = PublishedState(sessions: all, rows: filtered, folders: summaries, attentionCount: attention,
                                      selectedId: selectedId, search: search, view: view)
        if snapshot != lastPublished {
            lastPublished = snapshot
            onChange?()
        }
    }

    /// Everything `onChange` reports; refreshes that change nothing stay silent.
    private struct PublishedState: Equatable {
        var sessions: [SessionRow]
        var rows: [SessionRow]
        var folders: [FolderSummary]
        var attentionCount: Int
        var selectedId: String
        var search: String
        var view: String
    }

    public func setSearch(_ value: String) {
        guard value != search else { return }
        search = value
        publish()
        refreshBranches()
    }

    public func setView(_ value: String) {
        guard value == "all" || value == "attention" || folderRecords.contains(where: { $0.id == value }) else { return }
        guard value != view else { return }
        view = value
        publish()
        refreshBranches()
    }

    public func selectSession(_ id: String) {
        guard let session = entries[id] else {
            if id.isEmpty { selectedId = ""; publish() }
            return
        }
        let observed = session.record.noticeSequence
        selectedId = id
        // The initial pre-reconcile selection restores the interface, not user intent.
        if session.reconciled { acknowledge(id, observedSequence: observed) }
        publish()
        if session.reconciled && !session.panes.isEmpty && session.terminalError.isEmpty { attach(id) }
        refreshBranches()
    }

    /// Selects the next (`delta` > 0) or previous row, wrapping around.
    public func navigate(_ delta: Int) {
        let ids = rows.map(\.id)
        guard !ids.isEmpty, delta != 0 else { return }
        var index = ids.firstIndex(of: selectedId) ?? (delta > 0 ? -1 : 0)
        index = (index + (delta > 0 ? 1 : -1) + ids.count) % ids.count
        selectSession(ids[index])
    }

    public func renameSession(_ id: String, title: String) { if checked(id, { try store.renameSession(id, title: title) }) { readState() } }
    public func setPinned(_ id: String, _ pinned: Bool) { if checked(id, { try store.setPinned(id, pinned) }) { readState() } }
    public func moveSession(_ id: String, folderId: String) { if checked(id, { try store.moveSession(id, folderId: folderId) }) { readState() } }
    public func createFolder(_ name: String) { if checked("", { try store.createFolder(id: newIdentifier(), name: name) }) { readState() } }
    public func renameFolder(_ id: String, name: String) { if checked("", { try store.renameFolder(id, name: name) }) { readState() } }
    public func deleteFolder(_ id: String) { if checked("", { try store.deleteFolder(id) }) { readState() } }

    public func acknowledge(_ id: String, observedSequence: Int64) {
        guard let session = entries[id], observedSequence > session.record.readSequence else { return }
        if checked(id, { try store.acknowledge(id, observedSequence: observedSequence) }) { readState() }
    }

    /// Selects the session that most recently started needing attention.
    public func selectNextAttention() {
        var newest: Session?
        for session in entries.values where session.record.needsAttention {
            guard let current = newest else { newest = session; continue }
            let a = session.record.attentionAt, b = current.record.attentionAt
            if a > b || (a == b && session.record.id < current.record.id) { newest = session }
        }
        guard let newest else { return }
        setSearch("")
        setView("all")
        selectSession(newest.record.id)
    }

    private func usableCwd(_ id: String, _ cwd: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue,
              Darwin.access(cwd, R_OK | X_OK) == 0 else {
            fail(id, "Working directory is missing or inaccessible: \(cwd). Choose another directory or cancel.")
            return false
        }
        return true
    }

    private var shell: String { HostEnvironment.shell(environment: hostEnvironment) }

    private static func activePane(_ panes: [TmuxPane]) -> TmuxPane? { panes.first { $0.windowActive && $0.paneActive } }

    private func activeCwd(_ session: Session) -> String {
        if let pane = Self.activePane(session.panes), !pane.dead, let path = ProcessIdentity.currentDirectory(pid: pane.pid) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { return path }
        }
        return session.record.cwd
    }

    /// The directory a new session starts in by default: the selected session's, else home.
    public var defaultDirectory: String {
        if let active = entries[selectedId] { return activeCwd(active) }
        return NSHomeDirectory()
    }

    /// Creates and starts a session. An empty `cwd` uses `defaultDirectory`.
    public func createSession(folderId: String, cwd requested: String) {
        let cwd = requested.isEmpty ? defaultDirectory : requested
        guard usableCwd("", cwd) else { onDirectoryRequired?("", folderId, cwd); return }
        let titles = Set(entries.values.map(\.record.title))
        var number = 1
        while titles.contains("Terminal \(number)") { number += 1 }
        let record = SessionRecord(id: newIdentifier(), folderId: folderId, title: "Terminal \(number)", cwd: cwd, createdAt: currentMilliseconds())
        guard checked("", { try store.insertSession(record) }), readState() else { return }
        setSearch("")
        setView(folderId.isEmpty ? "all" : folderId)
        selectedId = record.id
        entries[record.id]?.status = .starting
        publish()
        enqueue(record.id) { [weak self] done in self?.startOwned(record.id, cwd: cwd, done: done) }
    }

    /// Starts a stopped session's shells. An empty `cwd` uses its recorded directory.
    public func startSession(_ id: String, cwd requested: String = "") {
        enqueue(id) { [weak self] done in
            guard let self, let session = self.entries[id] else { done(); return }
            let cwd = requested.isEmpty ? session.record.cwd : requested
            guard self.usableCwd(id, cwd) else { self.onDirectoryRequired?(id, "", cwd); done(); return }
            self.startOwned(id, cwd: cwd, done: done)
        }
    }

    // MARK: tmux reconciliation

    private func owned(_ panes: [TmuxPane], _ id: String) -> [TmuxPane] {
        let name = Tmux.sessionName(id)
        return panes.filter { $0.sessionName == name }
    }

    /// (ok, panes): ok is false when tmux failed; no server means ok with no panes.
    private func snapshot(_ callback: @escaping @MainActor (Bool, [TmuxPane]) -> Void) {
        tmux(["list-panes", "-a", "-F", Tmux.paneFormat]) { [weak self] result in
            guard let self else { return }
            guard result.ok else {
                if !result.timedOut && Tmux.serverAbsent(socket: self.store.tmuxSocket, stderr: result.error) { callback(true, []); return }
                self.fail("", result.errorText)
                callback(false, [])
                return
            }
            do { callback(true, try Tmux.parsePanes(result.output)) } catch {
                self.fail("", error.cinmuxMessage)
                callback(false, [])
            }
        }
    }

    private func applySnapshot(_ panes: [TmuxPane]) {
        for session in entries.values where !busy.contains(session.record.id) {
            let id = session.record.id
            session.panes = owned(panes, id)
            session.reconciled = true
            session.status = session.panes.contains { !$0.dead } ? .running : .stopped
            let cwd = activeCwd(session)
            if cwd != session.record.cwd && checked(id, { try store.updateCwd(id, cwd: cwd) }) {
                session.record.cwd = cwd
                session.branch = ""
            }
        }
        publish()
        if let active = entries[selectedId], active.reconciled, !active.panes.isEmpty, active.terminalError.isEmpty, !busy.contains(selectedId) {
            attach(selectedId)
        }
        refreshBranches()
    }

    /// Re-reads the database and reconciles with tmux. Runs every second.
    public func refresh() {
        guard !shuttingDown else { return }
        // Process exit does not change SQLite's data_version. Reconcile activity at
        // the normal metadata cadence even while a tmux request is still pending.
        readState()
        guard !refreshing else { return }
        refreshing = true
        snapshot { [weak self] ok, panes in
            guard let self else { return }
            self.refreshing = false
            if ok { self.applySnapshot(panes) }
        }
    }

    private func startOwned(_ id: String, cwd: String, done: @escaping Done) {
        snapshot { [weak self] ok, all in
            guard let self, let session = self.entries[id] else { done(); return }
            guard ok else {
                if session.status == .starting { session.status = .stopped; self.publish() }
                done()
                return
            }
            let panes = self.owned(all, id)
            session.panes = panes
            session.reconciled = true
            if panes.contains(where: { !$0.dead }) {
                session.status = .running
                self.publish()
                self.attach(id)
                done()
                return
            }
            session.status = .starting
            self.publish()
            let complete: Completion = { [weak self] result in
                guard let self, let current = self.entries[id] else { done(); return }
                if !result.ok {
                    current.status = .stopped
                    self.fail(id, result.errorText)
                } else {
                    current.status = .running
                    if self.checked(id, { try self.store.updateCwd(id, cwd: cwd) }) { current.record.cwd = cwd }
                    current.terminalError = ""
                    self.attach(id)
                }
                self.publish()
                done()
                onMain { [weak self] in self?.refresh() }
            }
            if panes.isEmpty {
                var arguments = ["new-session", "-d", "-s", Tmux.sessionName(id), "-n", "terminal", "-c", cwd]
                var environment = self.hostEnvironment
                environment["CINMUX_SESSION_ID"] = id
                environment["CINMUX_STATE_DIR"] = self.store.stateDirectory
                environment["CINMUX_TMUX_SOCKET"] = self.store.tmuxSocket
                for key in environment.keys.sorted() { arguments += ["-e", key + "=" + environment[key]!] }
                arguments += [self.shell, "-l"]
                self.tmux(arguments, complete)
            } else {
                self.respawn(panes, index: 0, cwd: cwd, complete)
            }
        }
    }

    private func respawn(_ panes: [TmuxPane], index: Int, cwd: String, _ callback: @escaping Completion) {
        guard index < panes.count else { callback(CommandResult(ok: true, timedOut: false, output: Data(), error: Data())); return }
        tmux(["respawn-pane", "-t", panes[index].paneId, "-c", cwd, shell, "-l"]) { [weak self] result in
            if !result.ok { callback(result) } else { self?.respawn(panes, index: index + 1, cwd: cwd, callback) }
        }
    }

    private func attach(_ id: String, force: Bool = false) {
        guard let session = entries[id], !shuttingDown, let renderer else { return }
        if !force && renderer.isAttached(id) { return }
        session.terminalError = ""
        renderer.attach(id, force: force)
        publish()
    }

    /// Replaces the session's terminal client, e.g. after it failed.
    public func reconnectTerminal(_ id: String) {
        enqueue(id) { [weak self] done in
            self?.snapshot { [weak self] ok, panes in
                guard let self else { done(); return }
                if ok {
                    if self.entries[id] != nil && !self.owned(panes, id).isEmpty { self.attach(id, force: true) }
                    else { self.fail(id, "This session is stopped. Use Start session to create a shell.") }
                }
                done()
            }
        }
    }

    public enum SplitDirection: String { case right, down }

    public func splitActive(_ direction: SplitDirection) {
        let id = selectedId
        enqueue(id) { [weak self] done in
            self?.snapshot { [weak self] ok, all in
                guard let self, ok, self.entries[id] != nil else { done(); return }
                guard let pane = Self.activePane(self.owned(all, id)), !pane.dead else {
                    self.fail(id, "No running active pane to split")
                    done()
                    return
                }
                let cwd = ProcessIdentity.currentDirectory(pid: pane.pid) ?? ""
                guard self.usableCwd(id, cwd) else { done(); return }
                self.tmux(["split-window", direction == .right ? "-h" : "-v", "-t", pane.paneId, "-c", cwd, self.shell, "-l"]) { [weak self] result in
                    if !result.ok { self?.fail(id, result.errorText) }
                    done()
                    onMain { [weak self] in self?.refresh() }
                }
            }
        }
    }

    /// Closes the active pane, or the whole session when it is the last one.
    public func closeActivePane() {
        let id = selectedId
        enqueue(id) { [weak self] done in
            self?.snapshot { [weak self] ok, all in
                guard let self, ok else { done(); return }
                let panes = self.owned(all, id)
                if panes.count <= 1 { self.closeOwned(id, done: done); return }
                guard let pane = Self.activePane(panes) else { self.fail(id, "No active pane to close"); done(); return }
                self.tmux(["kill-pane", "-t", pane.paneId]) { [weak self] result in
                    if !result.ok { self?.fail(id, result.errorText) }
                    done()
                    onMain { [weak self] in self?.refresh() }
                }
            }
        }
    }

    /// Ends the session's shells and removes it.
    public func closeSession(_ id: String) {
        enqueue(id) { [weak self] done in self?.closeOwned(id, done: done) }
    }

    private func closeOwned(_ id: String, done outer: @escaping Done) {
        guard let session = entries[id] else { outer(); return }
        let done: Done = { session.closing = false; outer() }
        snapshot { [weak self] ok, before in
            guard let self, ok else { done(); return }
            // Killing tmux normally disconnects the terminal view before the verification returns.
            session.closing = true
            let verify: Completion = { [weak self] result in
                guard let self else { done(); return }
                if result.ok { self.renderer?.detach(id) }
                self.snapshot { [weak self] checkedSnapshot, after in
                    guard let self, checkedSnapshot else { done(); return }
                    if !self.owned(after, id).isEmpty {
                        self.fail(id, result.ok ? "Session is still present; its entry was not removed" : result.errorText)
                        done()
                        return
                    }
                    if self.checked(id, { try self.store.deleteSession(id) }) {
                        self.renderer?.detach(id)
                        self.entries[id] = nil
                        if self.selectedId == id { self.selectedId = "" }
                        self.readState()
                    }
                    done()
                }
            }
            if self.owned(before, id).isEmpty { verify(CommandResult(ok: true, timedOut: false, output: Data(), error: Data())) }
            else { self.tmux(["kill-session", "-t", Tmux.exactTarget(id)], verify) }
        }
    }

    // MARK: git

    private func refreshBranches() {
        guard let gitProgram else { return }
        var paths = Set(rows.compactMap { entries[$0.id]?.record.cwd })
        if let selected = entries[selectedId] { paths.insert(selected.record.cwd) }
        let now = currentMilliseconds()
        for cwd in paths {
            var entry = git[cwd] ?? GitEntry()
            if entry.pending { continue }
            if entry.checkedAt != 0 && now - entry.checkedAt < 5000 { updateBranch(cwd, entry.branch); continue }
            entry.pending = true
            git[cwd] = entry
            let finish: @MainActor (String) -> Void = { [weak self] branch in
                guard let self else { return }
                self.git[cwd] = GitEntry(branch: branch, checkedAt: currentMilliseconds(), pending: false)
                self.updateBranch(cwd, branch)
            }
            command(gitProgram, ["-C", cwd, "symbolic-ref", "--quiet", "--short", "HEAD"], environment: hostEnvironment) { [weak self] result in
                if result.ok { finish(String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)); return }
                if result.timedOut { finish(""); return }
                self?.command(gitProgram, ["-C", cwd, "rev-parse", "--short", "HEAD"], environment: self?.hostEnvironment ?? [:]) { detached in
                    finish(detached.ok ? "detached:" + String(decoding: detached.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : "")
                }
            }
        }
    }

    private func updateBranch(_ cwd: String, _ branch: String) {
        var changed = false
        for session in entries.values where session.record.cwd == cwd && session.branch != branch {
            session.branch = branch
            changed = true
        }
        if changed { publish() }
    }

    // MARK: TerminalRendererDelegate

    public func rendererReady(_ id: String) {
        guard let session = entries[id] else { return }
        session.terminalError = ""
        publish()
    }

    public func rendererLost(_ id: String, message: String) {
        guard let session = entries[id], !shuttingDown else { return }
        // Blocks automatic reattachment while the snapshot decides.
        session.terminalError = message
        publish()
        // A view also ends when its tmux session does (last pane closed,
        // server exited): that is a stop the snapshot reports, not a failure.
        snapshot { [weak self] ok, panes in
            guard let self, let current = self.entries[id], !self.shuttingDown else { return }
            let ended = ok && self.owned(panes, id).isEmpty
            if ended { if current.terminalError == message { current.terminalError = "" } }
            else if !current.closing { self.fail(id, message) }
            if ok { self.applySnapshot(panes) } else { self.publish() }
        }
    }

    public func rendererInteracted(_ id: String) {
        guard let session = entries[id] else { return }
        acknowledge(id, observedSequence: session.record.noticeSequence)
    }
}
