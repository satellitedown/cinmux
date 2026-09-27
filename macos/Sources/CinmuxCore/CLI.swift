import Foundation

/// `cinmux notify|activity|list|--help|--version`. Returns the exit status:
/// 0 success, 2 bad arguments or unknown session, 1 runtime failure.
public func runCli(_ args: [String]) -> Int32 {
    func fail(_ code: Int32, _ message: String) -> Int32 {
        FileHandle.standardError.write(Data("cinmux: \(message)\n".utf8))
        return code
    }
    guard args.count >= 2 else { return printHelp() }
    let action = args[1]
    if action == "--help" || action == "-h" || action == "help" { return printHelp() }
    if action == "--version" { print("cinmux \(cinmuxVersion)"); return 0 }
    guard action == "notify" || action == "activity" || action == "list" else { return fail(2, "unknown command; use --help") }

    var id = ProcessInfo.processInfo.environment["CINMUX_SESSION_ID"] ?? ""
    var title = ""
    var body = ""
    var activity: Activity = .idle
    var detail = ""
    var reporter: ActivityReporter?

    /// Parses `--option value` pairs, rejecting unknown and repeated options.
    func options(_ allowed: Set<String>, command: String) -> Result<[String: String], ExitStatus> {
        var values: [String: String] = [:]
        var index = 2
        while index < args.count {
            let option = args[index]
            if option == "--help" || option == "-h" { return .failure(ExitStatus(code: printHelp())) }
            guard allowed.contains(option) else { return .failure(ExitStatus(code: fail(2, "unknown \(command) option: \(option)"))) }
            guard values[option] == nil else { return .failure(ExitStatus(code: fail(2, "duplicate option: \(option)"))) }
            index += 1
            guard index < args.count else { return .failure(ExitStatus(code: fail(2, "missing value for \(option)"))) }
            values[option] = args[index]
            index += 1
        }
        return .success(values)
    }

    if action == "notify" {
        let values: [String: String]
        switch options(["--session", "--title", "--body"], command: "notify") {
        case .success(let parsed): values = parsed
        case .failure(let status): return status.code
        }
        id = values["--session"] ?? id
        title = values["--title"] ?? ""
        body = values["--body"] ?? ""
        guard StateStore.validId(id) else { return fail(2, "provide a lowercase session UUID with --session or CINMUX_SESSION_ID") }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fail(2, "--title must be nonblank") }
    } else if action == "activity" {
        let values: [String: String]
        switch options(["--session", "--state", "--pid", "--detail"], command: "activity") {
        case .success(let parsed): values = parsed
        case .failure(let status): return status.code
        }
        id = values["--session"] ?? id
        detail = values["--detail"] ?? ""
        guard StateStore.validId(id) else { return fail(2, "provide a lowercase session UUID with --session or CINMUX_SESSION_ID") }
        guard let state = Activity(rawValue: values["--state"] ?? "") else { return fail(2, "--state must be idle, working, waiting or done") }
        activity = state
        guard detail.utf16.count <= StateStore.activityDetailLimit else {
            return fail(2, "--detail must contain at most \(StateStore.activityDetailLimit) characters")
        }
        let pidText = values["--pid"] ?? ""
        guard let first = pidText.utf8.first, first != UInt8(ascii: "0"), pidText.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let pid = Int64(pidText) else {
            return fail(2, "--pid must be a positive process ID")
        }
        do { reporter = try ProcessIdentity.reporter(pid: pid) } catch { return fail(2, error.cinmuxMessage) }
    } else if args.count != 3 || args[2] != "--json" {
        if args.count == 3 && (args[2] == "--help" || args[2] == "-h") { return printHelp() }
        return fail(2, "usage: cinmux list --json")
    }

    let store = StateStore(create: false)
    do { try store.open() } catch { return fail(1, error.cinmuxMessage) }
    if action == "notify" {
        do {
            return try store.notify(id, title: title, body: body) ? 0 : fail(2, "unknown session UUID: \(id)")
        } catch { return fail(1, error.cinmuxMessage) }
    }
    if action == "activity", let reporter {
        do {
            return try store.setActivity(id, state: activity, reporter: reporter, detail: detail) ? 0 : fail(2, "unknown session UUID: \(id)")
        } catch CinmuxError.invalidReporter(let message) {
            return fail(2, message)
        } catch { return fail(1, error.cinmuxMessage) }
    }

    let records: [SessionRecord]
    do { records = try store.sessions() } catch { return fail(1, error.cinmuxMessage) }
    var running = Set<String>()
    if !records.isEmpty {
        switch listPanes(store) {
        case .success(let panes): for pane in panes where !pane.dead { running.insert(pane.sessionName) }
        case .failure(let failure): return fail(1, failure.cinmuxMessage)
        }
    }
    let array: [[String: Any]] = records.map { record in
        [
            "id": record.id,
            "title": record.title,
            "folderId": record.folderId.isEmpty ? NSNull() as Any : record.folderId as Any,
            "cwd": record.cwd,
            "status": running.contains(Tmux.sessionName(record.id)) ? "running" : "stopped",
            "unreadCount": record.unreadCount,
            "activity": record.activity.rawValue,
            "activityDetail": record.activityDetail,
        ]
    }
    do {
        // Sorted keys and unescaped slashes match the Linux build's Qt JSON output.
        let data = try JSONSerialization.data(withJSONObject: array, options: [.sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    } catch { return fail(1, error.cinmuxMessage) }
    return 0
}

/// An exit status carried out of argument parsing.
struct ExitStatus: Error { let code: Int32 }

/// A synchronous pane snapshot for one-shot commands. No server is an empty list.
public func listPanes(_ store: StateStore) -> Result<[TmuxPane], CinmuxError> {
    var environment = HostEnvironment.current()
    guard let tmux = HostEnvironment.findExecutable("tmux", environment: environment) else {
        return .failure(.message("tmux is not installed. Install it with: brew install tmux"))
    }
    environment["LC_ALL"] = "C"
    let result = Command.run(tmux, ["-S", store.tmuxSocket, "list-panes", "-a", "-F", Tmux.paneFormat], environment: environment)
    guard result.ok else {
        if !result.timedOut && Tmux.serverAbsent(socket: store.tmuxSocket, stderr: result.error) { return .success([]) }
        return .failure(.message(result.timedOut ? "tmux status request timed out" : result.errorText))
    }
    do { return .success(try Tmux.parsePanes(result.output)) } catch { return .failure(.message(error.cinmuxMessage)) }
}

@discardableResult
public func printHelp() -> Int32 {
    print("""
    Cinmux — persistent terminal workspaces

    Usage:
      cinmux                         Open the workspace window
      cinmux tui                     Open the workspace in this terminal (e.g. over SSH)
      cinmux notify [--session UUID] --title TEXT [--body TEXT]
      cinmux activity --state idle|working|waiting|done --pid PID
                      [--detail TEXT] [--session UUID]
      cinmux list --json
      cinmux --help
      cinmux --version

    notify and activity use CINMUX_SESSION_ID when --session is omitted.
    CINMUX_STATE_DIR selects an absolute, isolated state directory.
    Notifications remain durable when the app is closed.
    Activity --pid is the reporting OMP process, not this CLI process.
    Activity detail is plain text, limited to 1024 characters.
    """)
    return 0
}
