import Foundation

/// The private tmux server's naming and wire formats, shared with the Linux build.
public enum Tmux {
    public static func sessionName(_ id: String) -> String { "cinmux-" + id }
    /// `=` makes tmux match the session name exactly instead of by prefix.
    public static func exactTarget(_ id: String) -> String { "=" + sessionName(id) }

    // tmux sanitizes literal control characters in command arguments. These
    // fields contain only our UUID names, numeric IDs and boolean flags.
    public static let paneFormat = "#{session_name}|#{session_id}|#{pane_id}|#{window_id}|#{pane_pid}|#{window_active}|#{pane_active}|#{pane_dead}"

    public static func parsePanes(_ output: Data) throws -> [TmuxPane] {
        var panes: [TmuxPane] = []
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields[0].hasPrefix("cinmux-"), StateStore.validId(String(fields[0].dropFirst(7))) else { continue }
            guard fields.count == 8 else { throw CinmuxError.message("Invalid tmux pane snapshot") }
            guard let pid = Int64(fields[4]), fields[1].hasPrefix("$"), fields[2].hasPrefix("%"), fields[3].hasPrefix("@") else {
                throw CinmuxError.message("Invalid tmux pane identity")
            }
            panes.append(TmuxPane(sessionName: fields[0], sessionId: fields[1], paneId: fields[2], windowId: fields[3], pid: pid,
                                  windowActive: fields[5] == "1", paneActive: fields[6] == "1", dead: fields[7] == "1"))
        }
        return panes
    }

    /// Whether a failed request means "no server", which is an empty snapshot rather than an error.
    public static func serverAbsent(socket: String, stderr: Data) -> Bool {
        let text = String(decoding: stderr, as: UTF8.self)
        return !FileManager.default.fileExists(atPath: socket) || text.contains("no server running on")
            || text.contains("Connection refused") || text.contains("No such file or directory")
    }

    /// tmux also treats a trailing semicolon in an argv element as a command
    /// separator; escape it so literal directories and values survive.
    public static func escape(_ argument: String) -> String {
        guard argument.hasSuffix(";") else { return argument }
        return String(argument.dropLast()) + "\\;"
    }

    /// A renderer's client: attach to exactly this session; `-E` keeps the
    /// server's environment rather than copying the client's into it.
    public static func attachArguments(socket: String, id: String) -> [String] {
        ["-u", "-S", socket, "attach-session", "-E", "-t", exactTarget(id)]
    }

    /// The environment for an attaching client. The private server's
    /// configuration grants RGB, clipboard and extended keys to this TERM.
    public static func clientEnvironment(_ host: [String: String]) -> [String: String] {
        var environment = host
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        return environment
    }
}

public struct CommandResult: Sendable {
    public var ok: Bool
    public var timedOut: Bool
    public var output: Data
    public var error: Data

    public var errorText: String {
        let text = String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Command failed without an error message" : text
    }
}

public enum Command {
    public static let timeout: TimeInterval = 5

    /// Runs a program to completion, killing it after `timeout` seconds.
    public static func run(_ program: String, _ arguments: [String], environment: [String: String],
                           timeout: TimeInterval = Command.timeout) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            return CommandResult(ok: false, timedOut: false, output: Data(), error: Data(error.localizedDescription.utf8))
        }
        let collected = Collected()
        let readers = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: readers) {
            collected.set(output: output.fileHandleForReading.readDataToEndOfFile())
        }
        DispatchQueue.global(qos: .userInitiated).async(group: readers) {
            collected.set(error: error.fileHandleForReading.readDataToEndOfFile())
        }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            kill(process.processIdentifier, SIGKILL)
            exited.wait()
        }
        // A daemonizing child could keep a pipe open; do not wait on it forever.
        _ = readers.wait(timeout: .now() + 1)
        var errorData = collected.error
        if timedOut {
            if !errorData.isEmpty { errorData.append(0x0a) }
            errorData.append(Data("Command timed out after \(Int(timeout)) seconds".utf8))
        }
        let ok = !timedOut && process.terminationReason == .exit && process.terminationStatus == 0
        return CommandResult(ok: ok, timedOut: timedOut, output: collected.output, error: errorData)
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var outputData = Data()
        private var errorData = Data()
        var output: Data { lock.withLock { outputData } }
        var error: Data { lock.withLock { errorData } }
        func set(output: Data) { lock.withLock { outputData = output } }
        func set(error: Data) { lock.withLock { errorData = error } }
    }
}
