import Foundation

public struct FolderRecord: Equatable, Sendable {
    public var id: String
    public var name: String
    public var position: Int
}

public enum Activity: String, Sendable, CaseIterable {
    case idle, working, waiting, done
}

public struct SessionRecord: Equatable, Sendable {
    public var id: String
    /// Empty when the session is not in a folder.
    public var folderId = ""
    public var title: String
    public var pinned = false
    public var cwd: String
    /// Milliseconds since the epoch.
    public var createdAt: Int64
    public var noticeSequence: Int64 = 0
    public var readSequence: Int64 = 0
    public var noticeTitle = ""
    public var noticeBody = ""
    public var noticeAt: Int64 = 0
    public var activity: Activity = .idle
    public var activityDetail = ""
    public var activityAt: Int64 = 0

    public init(id: String, folderId: String = "", title: String, pinned: Bool = false, cwd: String, createdAt: Int64) {
        self.id = id
        self.folderId = folderId
        self.title = title
        self.pinned = pinned
        self.cwd = cwd
        self.createdAt = createdAt
    }

    public var unreadCount: Int64 { max(0, noticeSequence - readSequence) }
    public var needsAttention: Bool { noticeSequence > readSequence || activity == .waiting }
    /// When the session last started needing attention.
    public var attentionAt: Int64 {
        max(noticeSequence > readSequence ? noticeAt : 0, activity == .waiting ? activityAt : 0)
    }
}

public struct TmuxPane: Equatable, Sendable {
    public var sessionName: String
    public var sessionId: String
    public var paneId: String
    public var windowId: String
    public var pid: Int64
    public var windowActive: Bool
    public var paneActive: Bool
    public var dead: Bool
}

/// A reporting process: its PID plus what makes that PID unique over time.
public struct ActivityReporter: Equatable, Sendable {
    public var pid: Int64
    public var bootId: String
    /// Process start time. Linux stores clock ticks; macOS stores microseconds since the epoch.
    public var startTicks: Int64
}

public func currentMilliseconds() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

public func newIdentifier() -> String { UUID().uuidString.lowercased() }
