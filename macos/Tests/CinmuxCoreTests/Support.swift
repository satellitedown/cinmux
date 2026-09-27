import Foundation
@testable import CinmuxCore

/// A private state directory, removed with its runtime directory afterwards.
final class TemporaryProfile {
    let path: String

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cinmux-test-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        path = Paths.canonical(base.path) ?? base.path
    }

    /// Opens a store: `create: true` is the app, `false` the CLI.
    func store(create: Bool = true) throws -> StateStore {
        let store = StateStore(directory: path, create: create)
        try store.open()
        return store
    }

    deinit {
        // Derived from the path, so it is cleaned even when opening a store failed.
        let runtime = NSHomeDirectory() + "/Library/Caches/cinmux/cinmux-" + StateStore.profileHash(path)
        if FileManager.default.fileExists(atPath: runtime + "/tmux.sock") {
            PrivateServer(socket: runtime + "/tmux.sock").run(["kill-server"])
        }
        try? FileManager.default.removeItem(atPath: runtime)
        try? FileManager.default.removeItem(atPath: path)
    }
}

func record(_ cwd: String, folder: String = "") -> SessionRecord {
    SessionRecord(id: newIdentifier(), folderId: folder, title: "Terminal", cwd: cwd, createdAt: 1)
}

/// A child process that stays alive until killed.
final class Sleeper {
    let process = Process()

    init() throws {
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
    }

    var pid: Int64 { Int64(process.processIdentifier) }

    func kill() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    deinit { kill() }
}

/// The test's own identity as an activity reporter.
func selfReporter() throws -> ActivityReporter {
    try ProcessIdentity.reporter(pid: Int64(getpid()))
}

/// Runs tmux against a profile's private server.
struct PrivateServer {
    let socket: String

    @discardableResult
    func run(_ arguments: [String]) -> CommandResult {
        let tmux = HostEnvironment.findExecutable("tmux") ?? "/usr/bin/false"
        return Command.run(tmux, ["-S", socket] + arguments, environment: HostEnvironment.current())
    }

    func owned(_ id: String) -> [TmuxPane] {
        let result = run(["list-panes", "-a", "-F", Tmux.paneFormat])
        return ((try? Tmux.parsePanes(result.output)) ?? []).filter { $0.sessionName == Tmux.sessionName(id) }
    }
}

/// Polls `condition` on the main actor, letting queued work run between checks.
@MainActor
func eventually(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}

let tmuxAvailable = HostEnvironment.findExecutable("tmux") != nil
