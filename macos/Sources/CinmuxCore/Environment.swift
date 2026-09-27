import Foundation
import Darwin

public let cinmuxVersion = "1.1.0"

/// Runs `body` on the main thread after the current event finishes.
public func onMain(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
}

public enum CinmuxError: Error, CustomStringConvertible, Equatable {
    case message(String)
    /// The reporting process is not (or no longer) the live process that asked.
    case invalidReporter(String)

    public var description: String {
        switch self {
        case .message(let text), .invalidReporter(let text): return text
        }
    }
}

extension Error {
    /// The user-facing text of a Cinmux or system error.
    public var cinmuxMessage: String { (self as? CinmuxError)?.description ?? localizedDescription }
}

/// Process environment and executable lookup that behave the same whether
/// Cinmux starts from Finder (launchd's minimal environment) or a login shell.
public enum HostEnvironment {
    /// Directories that hold Homebrew/MacPorts tools but are absent from the
    /// environment launchd gives apps started from Finder or the Dock.
    static let extraPaths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/opt/local/bin"]

    public static func current() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX"] = nil
        environment["TMUX_PANE"] = nil
        // Finder-launched apps get no locale: shells and tmux would fall back to ASCII.
        if (environment["LANG"] ?? "").isEmpty && (environment["LC_ALL"] ?? "").isEmpty && (environment["LC_CTYPE"] ?? "").isEmpty {
            environment["LANG"] = defaultLocale()
        }
        var path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if path.isEmpty { path = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] }
        for extra in extraPaths where !path.contains(extra) && FileManager.default.fileExists(atPath: extra) { path.append(extra) }
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }

    static func defaultLocale() -> String {
        let identifier = Locale.current.identifier.split(separator: "@").first.map(String.init) ?? ""
        let candidate = identifier + ".UTF-8"
        if !identifier.isEmpty && FileManager.default.fileExists(atPath: "/usr/share/locale/" + candidate) { return candidate }
        return "en_US.UTF-8"
    }

    /// Finds an executable on PATH, then in the usual package-manager locations.
    public static func findExecutable(_ name: String, environment: [String: String] = current()) -> String? {
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += extraPaths + ["/usr/bin", "/bin"]
        for directory in directories where directory.hasPrefix("/") {
            let candidate = directory + "/" + name
            if access(candidate, X_OK) == 0, isRegularFile(candidate) { return candidate }
        }
        return nil
    }

    /// The user's login shell: $SHELL, then the account database, then /bin/sh.
    public static func shell(environment: [String: String]) -> String {
        func usable(_ value: String) -> Bool { value.hasPrefix("/") && isRegularFile(value) && access(value, X_OK) == 0 }
        if let value = environment["SHELL"], usable(value) { return value }
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let value = String(cString: raw)
            if usable(value) { return value }
        }
        return "/bin/sh"
    }

    static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }
}

public enum Paths {
    /// The running executable, with symlinks (e.g. Homebrew's bin links) resolved.
    public static func executable() -> String? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return canonical(String(cString: buffer))
    }

    /// realpath(3): absolute, symlink-free, or nil when the path does not exist.
    public static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Collapses ".", ".." and repeated separators without touching the filesystem.
    public static func clean(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == "..", let last = parts.last, last != ".." { parts.removeLast(); continue }
            if part == ".." && absolute { continue }
            parts.append(part)
        }
        let joined = parts.joined(separator: "/")
        return absolute ? "/" + joined : (joined.isEmpty ? "." : joined)
    }

    /// Where the installed bundle or checkout keeps a shared resource file.
    public static func resource(_ name: String) -> String? {
        var candidates: [String] = []
        if let executable = executable() {
            let directory = (executable as NSString).deletingLastPathComponent
            candidates.append(directory + "/../Resources/" + name)      // Cinmux.app/Contents/{MacOS,Helpers}
            candidates.append(directory + "/../share/cinmux/" + name)   // a plain prefix install
        }
        // A development build run from the checkout: macos/Sources/CinmuxCore/ → resources/.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        candidates.append(source.appendingPathComponent("../../../resources/" + name).path)
        return candidates.lazy.map(clean).first { HostEnvironment.isRegularFile($0) }
    }
}
