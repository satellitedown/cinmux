import CinmuxCore
import CinmuxTUI
import Foundation

let arguments = CommandLine.arguments

if arguments.count > 1 && arguments[1] == "tui" {
    // Top-level code runs on the main thread; the TUI and its controller are main-actor bound.
    exit(MainActor.assumeIsolated { runTui(arguments) })
}

if arguments.count == 1 {
    // Like the Linux build, a bare `cinmux` opens the workspace window: the app
    // bundle this helper lives in (Cinmux.app/Contents/Helpers/cinmux), else
    // whichever Cinmux.app Launch Services knows.
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    if let executable = Paths.executable() {
        let bundle = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        open.arguments = bundle.pathExtension == "app" ? [bundle.path] : ["-b", "io.niay.cinmux"]
    } else {
        open.arguments = ["-b", "io.niay.cinmux"]
    }
    do {
        try open.run()
        open.waitUntilExit()
        if open.terminationStatus == 0 { exit(0) }
    } catch {}
    FileHandle.standardError.write(Data("cinmux: cannot open Cinmux.app; is it installed?\n".utf8))
    exit(1)
}

exit(runCli(arguments))
