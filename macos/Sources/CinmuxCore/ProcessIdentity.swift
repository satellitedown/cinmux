import Foundation
import Darwin

/// macOS equivalents of Linux's /proc/sys/kernel/random/boot_id,
/// /proc/<pid>/stat start time and /proc/<pid>/cwd.
public enum ProcessIdentity {
    public static func bootId() throws -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else {
            throw CinmuxError.message("Cannot read the macOS boot session identity")
        }
        var buffer = [CChar](repeating: 0, count: size + 1)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else {
            throw CinmuxError.message("Cannot read the macOS boot session identity")
        }
        let identity = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard StateStore.validId(identity) else { throw CinmuxError.message("Invalid macOS boot session identity") }
        return identity
    }

    public static func reporter(pid: Int64) throws -> ActivityReporter {
        try reporter(pid: pid, bootId: bootId())
    }

    static func reporter(pid: Int64, bootId: String) throws -> ActivityReporter {
        guard pid > 0, pid <= Int64(Int32.max) else {
            throw CinmuxError.message("--pid must identify a live process owned by this user")
        }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid() else {
            throw CinmuxError.message("Cannot inspect live user-owned process \(pid)")
        }
        let zombie: UInt32 = 5 // SZOMB in <sys/proc.h>
        let started = Int64(info.pbi_start_tvsec) * 1_000_000 + Int64(info.pbi_start_tvusec)
        guard Int64(info.pbi_pid) == pid, info.pbi_status != zombie, started > 0 else {
            throw CinmuxError.message("Process \(pid) is no longer live or has an invalid identity")
        }
        return ActivityReporter(pid: pid, bootId: bootId, startTicks: started)
    }

    /// The current directory of a live process owned by this user.
    public static func currentDirectory(pid: Int64) -> String? {
        guard pid > 0, pid <= Int64(Int32.max) else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(Int32(pid), PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.hasPrefix("/") ? path : nil
    }
}
