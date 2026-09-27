import Foundation
import Testing
@testable import CinmuxCore

/// The on-disk contract shared with the Linux build (tests/backend_test.cpp).
@Suite(.serialized)
struct StoreTests {
    @Test func notificationAcknowledgesOnlyObservedSequence() throws {
        let profile = try TemporaryProfile()
        let gui = try profile.store()
        let session = record(profile.path)
        try gui.insertSession(session)
        let cli = try profile.store(create: false)
        #expect(try cli.notify(session.id, title: "First", body: "Observed"))
        let observed = try gui.sessions()
        #expect(observed.first?.noticeSequence == 1)
        let literal = "<b>not markup</b> '$()'\nsecond line"
        try cli.notify(session.id, title: "Second", body: literal)
        try gui.acknowledge(session.id, observedSequence: observed[0].noticeSequence)
        var after = try gui.sessions()[0]
        #expect(after.unreadCount == 1)
        #expect(after.noticeTitle == "Second")
        #expect(after.noticeBody == literal)
        try gui.acknowledge(session.id, observedSequence: 0)
        after = try gui.sessions()[0]
        #expect(after.unreadCount == 1)
        try gui.acknowledge(session.id, observedSequence: 999)
        after = try gui.sessions()[0]
        #expect(after.readSequence == after.noticeSequence)
    }

    @Test func notifyReportsUnknownSessions() throws {
        let profile = try TemporaryProfile()
        let store = try profile.store()
        #expect(try store.notify(newIdentifier(), title: "Nobody", body: "") == false)
        #expect(throws: CinmuxError.self) { try store.notify("NOT-A-UUID", title: "x", body: "") }
    }

    @Test func folderDeletionPreservesEntryIdentity() throws {
        let profile = try TemporaryProfile()
        let store = try profile.store()
        let folder = newIdentifier()
        try store.createFolder(id: folder, name: "Straße")
        #expect(throws: CinmuxError.message("A folder with that name already exists")) {
            try store.createFolder(id: newIdentifier(), name: "STRASSE")
        }
        let session = record(profile.path, folder: folder)
        try store.insertSession(session)
        #expect(try store.notify(session.id, title: "Needs attention", body: "Keep this"))
        try store.deleteFolder(folder)
        let after = try store.sessions()
        #expect(after.count == 1)
        #expect(after[0].id == session.id)
        #expect(after[0].cwd == session.cwd)
        #expect(after[0].folderId.isEmpty)
        #expect(after[0].unreadCount == 1)
    }

    @Test func activityMigratesVersionOneWithoutLosingRecords() throws {
        let profile = try TemporaryProfile()
        let folder = newIdentifier()
        let first = newIdentifier()
        let second = newIdentifier()
        do {
            let db = try Database(path: profile.path + "/state.sqlite")
            try db.execute("CREATE TABLE folders(id TEXT PRIMARY KEY, name TEXT NOT NULL, position INTEGER NOT NULL)")
            try db.execute("CREATE TABLE sessions(id TEXT PRIMARY KEY, folder_id TEXT REFERENCES folders(id) ON DELETE SET NULL, title TEXT NOT NULL, pinned INTEGER NOT NULL DEFAULT 0, cwd TEXT NOT NULL, created_at INTEGER NOT NULL, notice_seq INTEGER NOT NULL DEFAULT 0, read_seq INTEGER NOT NULL DEFAULT 0, notice_title TEXT NOT NULL DEFAULT '', notice_body TEXT NOT NULL DEFAULT '', notice_at INTEGER NOT NULL DEFAULT 0)")
            try db.execute("INSERT INTO folders VALUES(?, 'Saved folder', 7)", [.text(folder)])
            try db.execute("INSERT INTO sessions VALUES(?, ?, 'Pinned session', 1, ?, 123, 9, 7, 'Review', 'Keep <literal> content', 456)",
                           [.text(first), .text(folder), .text(profile.path)])
            try db.execute("INSERT INTO sessions(id,title,cwd,created_at) VALUES(?,'Unfiled',?,789)", [.text(second), .text(profile.path)])
            try db.execute("PRAGMA user_version=1")
        }
        let migrated = try profile.store(create: false)
        var entries = try migrated.sessions()
        let folders = try migrated.folders()
        #expect(entries.count == 2)
        #expect(entries[0].id == first)
        #expect(entries[0].folderId == folder)
        #expect(entries[0].title == "Pinned session")
        #expect(entries[0].pinned)
        #expect(entries[0].cwd == profile.path)
        #expect(entries[0].createdAt == 123)
        #expect(entries[0].noticeSequence == 9)
        #expect(entries[0].readSequence == 7)
        #expect(entries[0].noticeTitle == "Review")
        #expect(entries[0].noticeBody == "Keep <literal> content")
        #expect(entries[0].noticeAt == 456)
        #expect(entries[1].id == second)
        #expect(entries[1].folderId.isEmpty)
        #expect(entries[1].title == "Unfiled")
        #expect(entries[1].createdAt == 789)
        #expect(folders == [FolderRecord(id: folder, name: "Saved folder", position: 7)])

        let writer = try profile.store(create: false)
        #expect(try writer.setActivity(first, state: .waiting, reporter: selfReporter(), detail: "Choose permission"))
        try writer.notify(first, title: "New notice", body: "")
        try migrated.acknowledge(first, observedSequence: 9)
        entries = try migrated.sessions()
        #expect(entries[0].unreadCount == 1)
        #expect(entries[0].activity == .waiting)
        #expect(entries[0].activityDetail == "Choose permission")
    }

    @Test(arguments: [0, 1, 3])
    func activityRejectsUnrecognizedSchemas(version: Int) throws {
        let profile = try TemporaryProfile()
        let db = try Database(path: profile.path + "/state.sqlite")
        try db.execute("CREATE TABLE irreplaceable(value TEXT)")
        try db.execute("INSERT INTO irreplaceable VALUES('preserve me')")
        try db.execute("PRAGMA user_version=\(version)")
        #expect(throws: CinmuxError.self) { try profile.store(create: false) }
        var values: [String] = []
        try db.query("SELECT value FROM irreplaceable") { values.append($0.text(0)) }
        #expect(values == ["preserve me"])
        #expect(try db.scalar("PRAGMA user_version") == Int64(version))
    }

    @Test func activityAggregatesIndependentReporters() throws {
        let profile = try TemporaryProfile()
        let gui = try profile.store()
        let session = record(profile.path)
        try gui.insertSession(session)
        let cli = try profile.store(create: false)
        let child = try Sleeper()
        let first = try selfReporter()
        let second = try ProcessIdentity.reporter(pid: child.pid)
        let literal = "<b>not markup</b> '$()'\nChoose"
        #expect(try gui.setActivity(session.id, state: .working, reporter: first, detail: "First"))
        #expect(try cli.setActivity(session.id, state: .working, reporter: second, detail: "Second"))
        try gui.setActivity(session.id, state: .idle, reporter: first, detail: "")
        var entry = try gui.sessions()[0]
        #expect(entry.activity == .working)
        #expect(entry.activityDetail == "Second")
        try gui.setActivity(session.id, state: .done, reporter: first, detail: "")
        #expect(try gui.sessions()[0].activity == .working)
        try cli.setActivity(session.id, state: .waiting, reporter: second, detail: literal)
        try gui.setActivity(session.id, state: .working, reporter: first, detail: "First")
        entry = try gui.sessions()[0]
        #expect(entry.activity == .waiting)
        #expect(entry.activityDetail == literal)
        try cli.setActivity(session.id, state: .done, reporter: second, detail: "Completed")
        #expect(try gui.sessions()[0].activity == .working)
        try gui.setActivity(session.id, state: .idle, reporter: first, detail: "")
        let reopened = try profile.store(create: false)
        entry = try reopened.sessions()[0]
        #expect(entry.activity == .done)
        #expect(entry.activityDetail == "Completed")
        try cli.setActivity(session.id, state: .idle, reporter: second, detail: "")
        entry = try reopened.sessions()[0]
        #expect(entry.activity == .idle)
        #expect(entry.activityDetail.isEmpty)
    }

    @Test func forgedAndStaleReportersAreRejected() throws {
        let profile = try TemporaryProfile()
        let gui = try profile.store()
        let session = record(profile.path)
        try gui.insertSession(session)
        let parent = try selfReporter()
        try gui.setActivity(session.id, state: .working, reporter: parent, detail: "Still working")
        var forged = parent
        forged.startTicks += 1
        #expect(throws: CinmuxError.invalidReporter("Reporter process identity changed")) {
            try gui.setActivity(session.id, state: .done, reporter: forged, detail: "")
        }
        #expect(try gui.sessions()[0].activity == .working)

        // A saved record referring to an earlier owner of this live PID, or to another boot, is stale.
        let db = try Database(path: profile.path + "/state.sqlite")
        try db.execute("UPDATE session_activity SET start_ticks=start_ticks+1")
        #expect(try gui.sessions()[0].activity == .idle)
        try gui.setActivity(session.id, state: .done, reporter: parent, detail: "")
        try db.execute("UPDATE session_activity SET boot_id=?", [.text(newIdentifier())])
        #expect(try gui.sessions()[0].activity == .idle)

        let child = try Sleeper()
        let reporter = try ProcessIdentity.reporter(pid: child.pid)
        try gui.setActivity(session.id, state: .done, reporter: reporter, detail: "")
        child.kill()
        #expect(try profile.store(create: false).sessions()[0].activity == .idle)
        #expect(throws: CinmuxError.self) { try ProcessIdentity.reporter(pid: reporter.pid) }
    }

    @Test func cliStoreDoesNotCreateState() throws {
        let profile = try TemporaryProfile()
        let cli = try profile.store(create: false)
        #expect(!cli.exists)
        #expect(try cli.sessions().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: profile.path + "/state.sqlite"))
    }

    @Test func profileHashMatchesLinux() {
        // Computed by the Linux build's QCryptographicHash for the same canonical directory.
        #expect(StateStore.profileHash("/private/tmp") == "11fe14a563f7aed6")
    }
}

@Suite struct TmuxFormatTests {
    @Test func parsesOnlyCinmuxPanes() throws {
        let id = newIdentifier()
        let output = Data("""
        other|$0|%0|@0|10|1|1|0
        cinmux-\(id)|$1|%2|@3|4242|1|0|1
        cinmux-not-a-uuid|$1|%2|@3|1|1|1|0

        """.utf8)
        let panes = try Tmux.parsePanes(output)
        #expect(panes == [TmuxPane(sessionName: "cinmux-" + id, sessionId: "$1", paneId: "%2", windowId: "@3", pid: 4242,
                                   windowActive: true, paneActive: false, dead: true)])
        #expect(throws: CinmuxError.message("Invalid tmux pane identity")) {
            try Tmux.parsePanes(Data("cinmux-\(id)|1|%2|@3|4242|1|0|1".utf8))
        }
        #expect(throws: CinmuxError.message("Invalid tmux pane snapshot")) {
            try Tmux.parsePanes(Data("cinmux-\(id)|$1|%2".utf8))
        }
    }

    @Test func escapesTrailingSemicolons() {
        #expect(Tmux.escape("/tmp/a;") == "/tmp/a\\;")
        #expect(Tmux.escape("a;b") == "a;b")
    }
}
