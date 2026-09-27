import CryptoKit
import Darwin
import Foundation

/// The shared on-disk state: the same directory layout, SQLite schema and
/// tmux socket naming as the Linux build.
public final class StateStore {
    public static let activityDetailLimit = 1024

    public private(set) var stateDirectory: String
    public private(set) var runtimeDirectory = ""
    public private(set) var profileHash = ""
    /// Whether the database exists. A non-creating store (the CLI) leaves it absent.
    public private(set) var exists = false
    public var tmuxSocket: String { runtimeDirectory + "/tmux.sock" }

    private let create: Bool
    private(set) var database: Database?
    private var opened = false

    /// `directory` overrides CINMUX_STATE_DIR / XDG_DATA_HOME resolution.
    public init(directory: String? = nil, create: Bool = true) {
        self.stateDirectory = directory ?? ""
        self.create = create
    }

    public func open() throws {
        if opened { return }
        let environment = ProcessInfo.processInfo.environment
        if stateDirectory.isEmpty {
            if let explicit = environment["CINMUX_STATE_DIR"], !explicit.isEmpty {
                stateDirectory = explicit
            } else {
                var data = environment["XDG_DATA_HOME"] ?? ""
                if data.isEmpty { data = NSHomeDirectory() + "/.local/share" }
                stateDirectory = data + "/cinmux"
            }
        }
        guard stateDirectory.hasPrefix("/") else { throw CinmuxError.message("CINMUX_STATE_DIR must be an absolute path") }
        stateDirectory = Paths.clean(stateDirectory)
        if !FileManager.default.fileExists(atPath: stateDirectory) {
            if !create { return }
            do { try FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true) } catch {
                throw CinmuxError.message("Cannot create state directory: \(stateDirectory)")
            }
        }
        guard let canonical = Paths.canonical(stateDirectory) else {
            throw CinmuxError.message("Cannot resolve state directory: \(stateDirectory)")
        }
        stateDirectory = canonical
        try Self.requireOwnedDirectory(stateDirectory)
        if create && chmod(stateDirectory, 0o700) != 0 { throw CinmuxError.message("Cannot secure state directory: \(stateDirectory)") }
        profileHash = Self.profileHash(stateDirectory)
        let databasePath = stateDirectory + "/state.sqlite"
        exists = FileManager.default.fileExists(atPath: databasePath)
        if !create && !exists { return }
        runtimeDirectory = try Self.runtimeRoot() + "/cinmux-" + profileHash
        if !FileManager.default.fileExists(atPath: runtimeDirectory) && mkdir(runtimeDirectory, 0o700) != 0 {
            throw CinmuxError.message("Cannot create runtime directory: \(runtimeDirectory)")
        }
        try Self.requireOwnedDirectory(runtimeDirectory)
        guard chmod(runtimeDirectory, 0o700) == 0 else { throw CinmuxError.message("Cannot secure runtime directory: \(runtimeDirectory)") }
        let socketCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard tmuxSocket.utf8.count < socketCapacity else {
            throw CinmuxError.message("The Cinmux tmux socket path is too long: \(tmuxSocket)")
        }
        var info = stat()
        if lstat(databasePath, &info) == 0 && ((info.st_mode & S_IFMT) != S_IFREG || info.st_uid != getuid()) {
            throw CinmuxError.message("State database is not a regular file owned by this user")
        }
        let db = try Database(path: databasePath)
        database = db
        try db.execute("PRAGMA busy_timeout=2000")
        try db.execute("PRAGMA foreign_keys=ON")
        let schema = try db.scalar("PRAGMA user_version") ?? 0
        if schema > 2 { throw CinmuxError.message("This state database uses a newer Cinmux schema (\(schema))") }
        if schema < 0 { throw CinmuxError.message("Invalid state database schema") }
        try db.execute("PRAGMA journal_mode=WAL")
        if schema < 2 {
            // Serialize first-open migrations across the GUI and independent CLI writers.
            try db.immediateTransaction { try Self.migrate(db) }
        }
        guard chmod(databasePath, 0o600) == 0 else { throw CinmuxError.message("Cannot secure state database") }
        exists = true
        _ = try sessions()
        _ = try folders()
        opened = true
    }

    /// Names the runtime directory: the first 16 hex digits of sha256(canonical state directory), as on Linux.
    static func profileHash(_ canonicalDirectory: String) -> String {
        String(SHA256.hash(data: Data(canonicalDirectory.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// Where per-profile sockets live. Unlike /tmp and $TMPDIR, macOS never
    /// ages files out of here, so a long-lived tmux socket cannot vanish; and
    /// unlike $XDG_RUNTIME_DIR, it is the same for Finder apps and SSH logins.
    static func runtimeRoot() throws -> String {
        let root = NSHomeDirectory() + "/Library/Caches/cinmux"
        if !FileManager.default.fileExists(atPath: root) {
            do { try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch {
                throw CinmuxError.message("Cannot create runtime directory: \(root)")
            }
        }
        try requireOwnedDirectory(root)
        return root
    }

    private static func requireOwnedDirectory(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
            throw CinmuxError.message("Directory is missing, not a real directory, or not owned by this user: \(path)")
        }
    }

    private static func migrate(_ db: Database) throws {
        let current = try db.scalar("PRAGMA user_version") ?? 0
        if current == 2 { return }
        if current < 0 || current > 2 { throw CinmuxError.message("Unsupported state database schema (\(current))") }
        if current == 0 {
            var foreign = false
            try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'") { _ in foreign = true }
            if foreign { throw CinmuxError.message("Refusing to replace an unrecognized state database") }
            try db.execute("CREATE TABLE folders(id TEXT PRIMARY KEY, name TEXT NOT NULL, position INTEGER NOT NULL)")
            try db.execute("CREATE TABLE sessions(id TEXT PRIMARY KEY, folder_id TEXT REFERENCES folders(id) ON DELETE SET NULL, title TEXT NOT NULL, pinned INTEGER NOT NULL DEFAULT 0, cwd TEXT NOT NULL, created_at INTEGER NOT NULL, notice_seq INTEGER NOT NULL DEFAULT 0, read_seq INTEGER NOT NULL DEFAULT 0, notice_title TEXT NOT NULL DEFAULT '', notice_body TEXT NOT NULL DEFAULT '', notice_at INTEGER NOT NULL DEFAULT 0)")
        } else {
            // Do not label an incomplete/unrecognized v1 database as migrated.
            try db.execute("SELECT id, name, position FROM folders LIMIT 0")
            try db.execute("SELECT id, folder_id, title, pinned, cwd, created_at, notice_seq, read_seq, notice_title, notice_body, notice_at FROM sessions LIMIT 0")
        }
        try db.execute("CREATE TABLE session_activity(session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, pid INTEGER NOT NULL CHECK(pid>0), boot_id TEXT NOT NULL, start_ticks INTEGER NOT NULL CHECK(start_ticks>0), state TEXT NOT NULL CHECK(state IN ('working','waiting','done')), detail TEXT NOT NULL DEFAULT '' CHECK(length(detail)<=1024), updated_at INTEGER NOT NULL, PRIMARY KEY(session_id,pid,boot_id,start_ticks))")
        try db.execute("PRAGMA user_version=2")
    }

    private func db() throws -> Database {
        guard let database else { throw CinmuxError.message("The state database is not open") }
        return database
    }

    // MARK: Reads

    public func sessions() throws -> [SessionRecord] {
        guard exists else { return [] }
        let db = try db()
        var result: [SessionRecord] = []
        try db.query("SELECT id, folder_id, title, pinned, cwd, created_at, notice_seq, read_seq, notice_title, notice_body, notice_at FROM sessions ORDER BY pinned DESC, created_at DESC, id ASC") { row in
            var record = SessionRecord(id: row.text(0), folderId: row.text(1), title: row.text(2), pinned: row.int(3) != 0, cwd: row.text(4), createdAt: row.int(5))
            record.noticeSequence = row.int(6)
            record.readSequence = row.int(7)
            record.noticeTitle = row.text(8)
            record.noticeBody = row.text(9)
            record.noticeAt = row.int(10)
            guard Self.validId(record.id), record.folderId.isEmpty || Self.validId(record.folderId) else {
                throw CinmuxError.message("Invalid session identity in state database")
            }
            result.append(record)
        }
        let activity = try activities()
        for index in result.indices {
            guard let value = activity[result[index].id] else { continue }
            result[index].activity = value.state
            result[index].activityDetail = value.detail
            result[index].activityAt = value.updatedAt
        }
        return result
    }

    public func folders() throws -> [FolderRecord] {
        guard exists else { return [] }
        var result: [FolderRecord] = []
        try db().query("SELECT id, name, position FROM folders ORDER BY position, id") { row in
            result.append(FolderRecord(id: row.text(0), name: row.text(1), position: Int(row.int(2))))
        }
        return result
    }

    /// PRAGMA data_version: changes whenever another connection commits.
    public func dataVersion() throws -> Int64 {
        try db().scalar("PRAGMA data_version") ?? 0
    }

    private struct SessionActivity { var state: Activity; var detail: String; var updatedAt: Int64 }

    /// The strongest live report per session; reports from exited processes are deleted.
    private func activities() throws -> [String: SessionActivity] {
        let db = try db()
        var result: [String: SessionActivity] = [:]
        var bootId: String?
        var processes: [Int64: ActivityReporter?] = [:]
        var stale: [[SQLValue]] = []
        try db.query("SELECT session_id,pid,boot_id,start_ticks,state,detail,updated_at FROM session_activity ORDER BY CASE state WHEN 'waiting' THEN 3 WHEN 'working' THEN 2 ELSE 1 END DESC,updated_at DESC,pid ASC,boot_id ASC,start_ticks ASC") { row in
            if bootId == nil { bootId = try ProcessIdentity.bootId() }
            let id = row.text(0)
            let reporter = ActivityReporter(pid: row.int(1), bootId: row.text(2), startTicks: row.int(3))
            if processes[reporter.pid] == nil {
                processes[reporter.pid] = .some(try? ProcessIdentity.reporter(pid: reporter.pid, bootId: bootId!))
            }
            guard processes[reporter.pid]! == reporter else {
                stale.append([.text(id), .int(reporter.pid), .text(reporter.bootId), .int(reporter.startTicks)])
                return
            }
            if result[id] == nil, let state = Activity(rawValue: row.text(4)) {
                result[id] = SessionActivity(state: state, detail: row.text(5), updatedAt: row.int(6))
            }
        }
        if stale.isEmpty { return result }
        try db.immediateTransaction {
            // Exact identity deletion cannot erase a new report from a reused PID.
            for identity in stale {
                try db.execute("DELETE FROM session_activity WHERE session_id=? AND pid=? AND boot_id=? AND start_ticks=?", identity)
            }
        }
        return result
    }

    // MARK: Writes

    public func insertSession(_ record: SessionRecord) throws {
        let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validId(record.id), !title.isEmpty, record.cwd.hasPrefix("/") else { throw CinmuxError.message("Invalid session record") }
        try db().execute("INSERT INTO sessions(id,folder_id,title,pinned,cwd,created_at) VALUES(?,?,?,?,?,?)",
                         [.text(record.id), .nullable(record.folderId), .text(title), .bool(record.pinned), .text(record.cwd), .int(record.createdAt)])
    }

    public func renameSession(_ id: String, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CinmuxError.message("Session title cannot be blank") }
        try db().execute("UPDATE sessions SET title=? WHERE id=?", [.text(trimmed), .text(id)])
    }

    public func setPinned(_ id: String, _ pinned: Bool) throws {
        try db().execute("UPDATE sessions SET pinned=? WHERE id=?", [.bool(pinned), .text(id)])
    }

    public func moveSession(_ id: String, folderId: String) throws {
        try db().execute("UPDATE sessions SET folder_id=? WHERE id=?", [.nullable(folderId), .text(id)])
    }

    public func updateCwd(_ id: String, cwd: String) throws {
        try db().execute("UPDATE sessions SET cwd=? WHERE id=?", [.text(cwd), .text(id)])
    }

    public func deleteSession(_ id: String) throws {
        try db().execute("DELETE FROM sessions WHERE id=?", [.text(id)])
    }

    private func validateFolderName(_ name: String, except: String = "") throws {
        let candidate = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { throw CinmuxError.message("Folder name cannot be blank") }
        let folded = Self.caseFolded(candidate)
        for folder in try folders() where folder.id != except && Self.caseFolded(folder.name) == folded {
            throw CinmuxError.message("A folder with that name already exists")
        }
    }

    /// Full Unicode case folding ("Straße" and "STRASSE" match), like ICU's
    /// u_strCaseCompare on Linux: uppercasing expands ß to SS before lowering.
    static func caseFolded(_ text: String) -> String { text.uppercased().lowercased() }

    public func createFolder(id: String, name: String) throws {
        guard Self.validId(id) else { throw CinmuxError.message("Invalid folder identity") }
        try validateFolderName(name)
        try db().execute("INSERT INTO folders(id,name,position) VALUES(?,?,COALESCE((SELECT MAX(position)+1 FROM folders),0))",
                         [.text(id), .text(name.trimmingCharacters(in: .whitespacesAndNewlines))])
    }

    public func renameFolder(_ id: String, name: String) throws {
        try validateFolderName(name, except: id)
        try db().execute("UPDATE folders SET name=? WHERE id=?", [.text(name.trimmingCharacters(in: .whitespacesAndNewlines)), .text(id)])
    }

    public func deleteFolder(_ id: String) throws {
        try db().execute("DELETE FROM folders WHERE id=?", [.text(id)])
    }

    /// Records a durable notification. Returns false when the session does not exist.
    @discardableResult
    public func notify(_ id: String, title: String, body: String) throws -> Bool {
        guard Self.validId(id), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CinmuxError.message("A valid session UUID and nonblank title are required")
        }
        guard exists else { return false }
        let db = try db()
        try db.execute("UPDATE sessions SET notice_seq=notice_seq+1, notice_title=?, notice_body=?, notice_at=? WHERE id=?",
                       [.text(title), .text(body), .int(currentMilliseconds()), .text(id)])
        return db.changes == 1
    }

    public func acknowledge(_ id: String, observedSequence: Int64) throws {
        try db().execute("UPDATE sessions SET read_seq=MAX(read_seq,MIN(?,notice_seq)) WHERE id=?", [.int(observedSequence), .text(id)])
    }

    /// Records (or, for idle, clears) one process's activity report.
    /// Returns false when the session does not exist; throws `.invalidReporter`
    /// when the reporting process is no longer the one that asked.
    @discardableResult
    public func setActivity(_ id: String, state: Activity, reporter: ActivityReporter, detail: String) throws -> Bool {
        guard Self.validId(id), detail.utf16.count <= Self.activityDetailLimit else {
            throw CinmuxError.message("A valid session UUID, activity state and detail of at most \(Self.activityDetailLimit) characters are required")
        }
        guard exists else { return false }
        let db = try db()
        return try db.immediateTransaction {
            var present = false
            try db.query("SELECT 1 FROM sessions WHERE id=?", [.text(id)]) { _ in present = true }
            guard present else { return false }
            // Recheck after obtaining the write lock: PID reuse while waiting must not
            // transfer a previous process's pending report to a new owner.
            let current: ActivityReporter
            do { current = try ProcessIdentity.reporter(pid: reporter.pid) } catch {
                throw CinmuxError.invalidReporter(error.cinmuxMessage)
            }
            guard current == reporter else { throw CinmuxError.invalidReporter("Reporter process identity changed") }
            let identity: [SQLValue] = [.text(id), .int(reporter.pid), .text(reporter.bootId), .int(reporter.startTicks)]
            if state == .idle {
                try db.execute("DELETE FROM session_activity WHERE session_id=? AND pid=? AND boot_id=? AND start_ticks=?", identity)
            } else {
                try db.execute("INSERT INTO session_activity(session_id,pid,boot_id,start_ticks,state,detail,updated_at) VALUES(?,?,?,?,?,?,?) ON CONFLICT(session_id,pid,boot_id,start_ticks) DO UPDATE SET state=excluded.state,detail=excluded.detail,updated_at=excluded.updated_at",
                               identity + [.text(state.rawValue), .text(detail), .int(currentMilliseconds())])
            }
            return true
        }
    }

    // MARK: Identity

    public static func validId(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            if index == 8 || index == 13 || index == 18 || index == 23 {
                if byte != UInt8(ascii: "-") { return false }
            } else if !((byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))) {
                return false
            }
        }
        return true
    }
}
