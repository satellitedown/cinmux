import Foundation
import Testing
@testable import CinmuxCore

/// Stands in for SwiftTerm/TUI views: records attachment and reports loss on demand.
@MainActor
final class FakeRenderer: TerminalRenderer {
    weak var delegate: TerminalRendererDelegate?
    private var attached: Set<String> = []
    func attach(_ id: String, force: Bool) { attached.insert(id) }
    func detach(_ id: String) { attached.remove(id) }
    func isAttached(_ id: String) -> Bool { attached.contains(id) }
    func lose(_ id: String, _ message: String) {
        attached.remove(id)
        delegate?.rendererLost(id, message: message)
    }
}

/// Real tmux behaviour, ported from tests/backend_test.cpp.
@Suite(.serialized, .enabled(if: tmuxAvailable, "needs tmux"))
@MainActor
struct ControllerTests {
    /// Runs `body` with SHELL=/bin/sh so pane PIDs are plain shells.
    private func withPlainShell(_ body: () async throws -> Void) async rethrows {
        let previous = ProcessInfo.processInfo.environment["SHELL"]
        setenv("SHELL", "/bin/sh", 1)
        defer { if let previous { setenv("SHELL", previous, 1) } else { unsetenv("SHELL") } }
        try await body()
    }

    @Test func lifecyclePreservesShellsAndClosesOnlyOwnedSession() async throws {
        try await withPlainShell {
            let profile = try TemporaryProfile()
            let store = try profile.store()
            let server = PrivateServer(socket: store.tmuxSocket)
            var first = "", second = ""
            var firstPid: Int64 = 0, secondPid: Int64 = 0
            do {
                let controller = SessionController(store: store, renderer: nil)
                defer { controller.shutdown() }
                controller.createSession(folderId: "", cwd: profile.path)
                first = controller.selectedId
                #expect(StateStore.validId(first))
                #expect(await eventually { controller.selected?.status == .running })
                #expect(await eventually { server.owned(first).count == 1 })
                firstPid = try #require(server.owned(first).first).pid
                controller.createSession(folderId: "", cwd: profile.path)
                second = controller.selectedId
                #expect(await eventually { controller.selected?.status == .running })
                #expect(await eventually { server.owned(second).count == 1 })
                secondPid = try #require(server.owned(second).first).pid
                controller.createFolder("Live")
                let folder = try #require(controller.folders.first).id
                controller.moveSession(first, folderId: folder)
                controller.deleteFolder(folder)
                #expect(try store.sessions().first { $0.id == first }?.folderId == "")
                #expect(server.owned(first).first?.pid == firstPid)
            }
            #expect(server.owned(first).first?.pid == firstPid)
            #expect(server.owned(second).first?.pid == secondPid)
            do {
                let reopened = SessionController(store: store, renderer: nil)
                defer { reopened.shutdown() }
                reopened.selectSession(first)
                #expect(await eventually { reopened.selected?.status == .running })
                reopened.reconnectTerminal(first)
                reopened.startSession(first)
                reopened.splitActive(.right)
                #expect(await eventually { server.owned(first).count == 2 })
                #expect(server.owned(first).contains { $0.pid == firstPid })
                #expect(server.owned(second).first?.pid == secondPid)
                reopened.closeSession(first)
                #expect(await eventually { reopened.totalCount == 1 })
                #expect(server.owned(first).isEmpty)
                #expect(server.owned(second).first?.pid == secondPid)
                #expect(server.run(["kill-session", "-t", Tmux.exactTarget(second)]).ok)
            }
            do {
                let stopped = SessionController(store: store, renderer: nil)
                defer { stopped.shutdown() }
                stopped.selectSession(second)
                stopped.refresh()
                try await Task.sleep(for: .milliseconds(1200))
                #expect(stopped.selected?.status == .stopped)
                #expect(server.owned(second).isEmpty)
                #expect(stopped.totalCount == 1)
                stopped.startSession(second)
                #expect(await eventually { stopped.selected?.status == .running })
                #expect(await eventually { server.owned(second).count == 1 })
                #expect(server.owned(second).first?.pid != secondPid)
            }
        }
    }

    /// Apps started from Finder get no locale at all; shells must still run in UTF-8.
    @Test func terminalPreservesUtf8Locale() async throws {
        let saved = ["LANG", "LC_ALL", "LC_CTYPE"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (name, _) in saved { unsetenv(name) }
        defer { for (name, value) in saved { if let value { setenv(name, value, 1) } } }
        try await withPlainShell {
            let profile = try TemporaryProfile()
            let store = try profile.store()
            let server = PrivateServer(socket: store.tmuxSocket)
            let controller = SessionController(store: store, renderer: nil)
            defer { controller.shutdown() }
            controller.createSession(folderId: "", cwd: profile.path)
            #expect(await eventually { controller.selected?.status == .running })
            #expect(await eventually { server.owned(controller.selectedId).count == 1 })
            let target = try #require(server.owned(controller.selectedId).first).paneId
            #expect(server.run(["send-keys", "-t", target, "locale charmap", "Enter"]).ok)
            #expect(await eventually(3) {
                String(decoding: server.run(["capture-pane", "-p", "-t", target]).output, as: UTF8.self)
                    .split(separator: "\n").contains("UTF-8")
            })
        }
    }

    /// Agents in any pane report through `cinmux`, so the helper directory must
    /// reach the shells of new sessions and of split panes alike.
    @Test func panesFindTheCliOnPath() async throws {
        try await withPlainShell {
            let profile = try TemporaryProfile()
            let store = try profile.store()
            let server = PrivateServer(socket: store.tmuxSocket)
            let helper = profile.path + "/helper"
            try FileManager.default.createDirectory(atPath: helper, withIntermediateDirectories: true)
            let controller = SessionController(store: store, renderer: nil, helperDirectory: helper)
            defer { controller.shutdown() }
            controller.createSession(folderId: "", cwd: profile.path)
            let id = controller.selectedId
            #expect(await eventually { controller.selected?.status == .running && server.owned(id).count == 1 })
            controller.splitActive(.right)
            #expect(await eventually { server.owned(id).count == 2 })
            for pane in server.owned(id) {
                #expect(server.run(["send-keys", "-t", pane.paneId, "echo \"PATH=$PATH\"", "Enter"]).ok)
            }
            for pane in server.owned(id) {
                #expect(await eventually(3) {
                    String(decoding: server.run(["capture-pane", "-p", "-J", "-t", pane.paneId]).output, as: UTF8.self)
                        .split(separator: "\n")
                        .contains { $0.hasPrefix("PATH=") && $0.dropFirst(5).split(separator: ":").contains(Substring(helper)) }
                })
            }
        }
    }

    @Test func viewLossReportsOnlyRendererFailures() async throws {
        let profile = try TemporaryProfile()
        let store = try profile.store()
        let server = PrivateServer(socket: store.tmuxSocket)
        let renderer = FakeRenderer()
        let controller = SessionController(store: store, renderer: renderer)
        defer { controller.shutdown() }
        var errors: [String] = []
        controller.onFailure = { _, message in errors.append(message) }
        controller.createSession(folderId: "", cwd: profile.path)
        let id = controller.selectedId
        #expect(await eventually { controller.selected?.status == .running })
        #expect(await eventually { renderer.isAttached(id) })

        // The view dies while its session keeps running: a failure worth reporting.
        renderer.lose(id, "renderer crashed")
        #expect(await eventually(5) { errors.count == 1 })
        #expect(errors.first == "renderer crashed")
        #expect(controller.selected?.terminalError == "renderer crashed")

        // The session itself ends (last pane closed, server exited): the view's
        // loss is a stop, shown as "Session stopped" rather than an error.
        controller.reconnectTerminal(id)
        #expect(await eventually { renderer.isAttached(id) && controller.selected?.terminalError == "" })
        #expect(server.run(["kill-session", "-t", Tmux.exactTarget(id)]).ok)
        renderer.lose(id, "[exited]")
        #expect(await eventually { controller.selected?.status == .stopped })
        try await Task.sleep(for: .milliseconds(300))
        #expect(errors.count == 1)
        #expect(controller.selected?.terminalError == "")
    }

    @Test func waitingSurvivesSelectionAndAcknowledgement() async throws {
        let profile = try TemporaryProfile()
        let gui = try profile.store()
        let waiting = record(profile.path)
        let other = record(profile.path)
        try gui.insertSession(waiting)
        try gui.insertSession(other)
        let controller = SessionController(store: gui, renderer: nil)
        defer { controller.shutdown() }
        let cli = try profile.store(create: false)
        let reporter = try selfReporter()
        try cli.setActivity(waiting.id, state: .waiting, reporter: reporter, detail: "Needs permission")
        try cli.notify(waiting.id, title: "Review", body: "")
        #expect(await eventually(1.5) { controller.attentionCount == 1 })
        // Repeating the user action also waits for initial tmux reconciliation, when
        // selection starts acknowledging notifications rather than restoring state.
        #expect(await eventually(1.5) {
            controller.selectSession(waiting.id)
            return controller.selected?.unreadCount == 0
        })
        #expect(controller.selected?.activity == .waiting)
        #expect(controller.selected?.activityDetail == "Needs permission")
        #expect(controller.attentionCount == 1)
        controller.setView("attention")
        #expect(controller.rows.map(\.id) == [waiting.id])
        controller.selectSession(other.id)
        controller.selectNextAttention()
        #expect(controller.selectedId == waiting.id)
        #expect(controller.attentionCount == 1)
        try cli.setActivity(waiting.id, state: .done, reporter: reporter, detail: "")
        #expect(await eventually(1.5) { controller.selected?.activity == .done })
        #expect(controller.attentionCount == 0)
        controller.selectSession(other.id)
        controller.selectSession(waiting.id)
        #expect(controller.selected?.activity == .done)
    }

    @Test func activityReconcilesDeadReporters() async throws {
        let profile = try TemporaryProfile()
        let gui = try profile.store()
        let session = record(profile.path)
        try gui.insertSession(session)
        let child = try Sleeper()
        try gui.setActivity(session.id, state: .working, reporter: selfReporter(), detail: "Still working")
        try gui.setActivity(session.id, state: .waiting, reporter: ProcessIdentity.reporter(pid: child.pid), detail: "Child prompt")
        let controller = SessionController(store: gui, renderer: nil)
        defer { controller.shutdown() }
        controller.selectSession(session.id)
        #expect(controller.selected?.activity == .waiting)
        child.kill()
        // No database write accompanies this exit: the refresh cadence must notice
        // liveness and expose the remaining reporter rather than Idle/Done.
        #expect(await eventually(2) { controller.selected?.activity == .working })
        #expect(controller.selected?.activityDetail == "Still working")
        #expect(controller.attentionCount == 0)
    }

    @Test func notificationReloadRetriesAfterReadFailure() async throws {
        let profile = try TemporaryProfile()
        let gui = try profile.store()
        let session = record(profile.path)
        try gui.insertSession(session)
        let cli = try profile.store(create: false)
        let controller = SessionController(store: gui, renderer: nil)
        defer { controller.shutdown() }
        var errors = 0
        controller.onFailure = { _, _ in errors += 1 }
        #expect(try cli.notify(session.id, title: "Needs input", body: ""))
        // Interrupt a reload after the notification commits, then repair through the
        // reader's connection: its data_version does not change for its own commits.
        let other = try Database(path: profile.path + "/state.sqlite")
        try other.execute("ALTER TABLE folders RENAME TO unavailable_folders")
        #expect(await eventually(1.5) { errors > 0 })
        #expect(controller.attentionCount == 0)
        try #require(gui.database).execute("ALTER TABLE unavailable_folders RENAME TO folders")
        #expect(await eventually(1.5) { controller.attentionCount == 1 })
    }
}
