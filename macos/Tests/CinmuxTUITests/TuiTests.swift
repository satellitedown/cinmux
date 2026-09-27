import CinmuxCore
import Foundation
import Testing
@testable import CinmuxTUI

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

private func feedBytewise(_ parser: inout InputParser, _ data: [UInt8]) -> [InputEvent] {
    var events: [InputEvent] = []
    for byte in data { events += parser.feed([byte]) }
    return events
}

@Test func keysSurviveSplitReads() {
    let cases: [(name: String, data: [UInt8], key: Key, value: UInt32, modifiers: KeyModifiers)] = [
        ("kitty Ctrl+Shift+N", bytes("\u{1b}[110;6u"), .character, UInt32(UInt8(ascii: "n")), [.ctrl, .shift]),
        ("modifyOtherKeys Ctrl+Shift+N", bytes("\u{1b}[27;6;110~"), .character, UInt32(UInt8(ascii: "n")), [.ctrl, .shift]),
        ("legacy Ctrl+Alt+N", [0x1b, 0x0e], .character, UInt32(UInt8(ascii: "n")), [.ctrl, .alt]),
        ("Ctrl+R", [0x12], .character, UInt32(UInt8(ascii: "r")), .ctrl),
        ("Ctrl+Alt+PageUp", bytes("\u{1b}[5;7~"), .pageUp, 0, [.ctrl, .alt]),
        ("Shift+F10", bytes("\u{1b}[21;2~"), .function, 10, .shift),
        ("Ctrl+Alt+Left", bytes("\u{1b}[1;7D"), .left, 0, [.ctrl, .alt]),
        ("SS3 Up", bytes("\u{1b}OA"), .up, 0, []),
        ("kitty Shift+Enter", bytes("\u{1b}[13;2u"), .enter, 0, .shift),
        ("shifted text", bytes("\u{1b}[27;2;97~"), .character, UInt32(UInt8(ascii: "A")), []),
        ("UTF-8", [0xe4, 0xb8, 0xad], .character, 0x4e2d, []),
    ]
    for test in cases {
        var parser = InputParser()
        let events = feedBytewise(&parser, test.data)
        #expect(!parser.pending, "\(test.name)")
        #expect(events.count == 1, "\(test.name)")
        guard let event = events.first else { continue }
        #expect(event.type == .key, "\(test.name)")
        #expect(event.key == test.key, "\(test.name)")
        #expect(event.modifiers == test.modifiers, "\(test.name)")
        if event.key == .function { #expect(UInt32(event.function) == test.value, "\(test.name)") }
        else if event.key == .character { #expect(event.codepoint == test.value, "\(test.name)") }
    }
}

@Test func escapeWaitsForTimeout() {
    var parser = InputParser()
    #expect(parser.feed([0x1b]).isEmpty)
    #expect(parser.pending)
    var events = parser.flush()
    #expect(events.count == 1)
    #expect(events.first?.key == .escape)
    #expect(events.first?.modifiers == [])
    #expect(!parser.pending)
    // Two quick presses share one read: the chrome treats Alt+Escape as Escape.
    #expect(parser.feed([0x1b, 0x1b]).isEmpty)
    events = parser.flush()
    #expect(events.count == 1)
    #expect(events.first?.key == .escape)
    #expect(events.first?.modifiers == .alt)
    // Replies to the startup keyboard query never become keys.
    events = parser.feed(bytes("\u{1b}[?1u\u{1b}[?62;22c"))
    #expect(events.count == 2)
    #expect(events.first?.type == .keyboardFlags)
    #expect(events.first?.flags == 1)
    #expect(events.last?.type == .primaryAttributes)
    // Key releases and bare modifier keys (kitty) are not input.
    #expect(parser.feed(bytes("\u{1b}[97;1:3u\u{1b}[57441;2u")).isEmpty)
}

@Test func pasteKeepsEscapesAcrossReads() {
    var parser = InputParser()
    var events: [InputEvent] = []
    for chunk in ["\u{1b}[200~ab", "\u{1b}[Ac\n", "d\u{1b}[20", "1~x"] {
        events += parser.feed(bytes(chunk))
        if chunk.hasSuffix("20") { #expect(parser.pasting) }
    }
    #expect(events.count == 2)
    #expect(events.first?.type == .paste)
    #expect(events.first?.text == bytes("ab\u{1b}[Ac\nd"))
    #expect(events.last?.key == .character)
    #expect(events.last?.codepoint == UInt32(UInt8(ascii: "x")))
    #expect(!parser.pending)
}

@Test func mouseDistinguishesHoverDragAndWheel() {
    var parser = InputParser()
    let events = parser.feed(bytes("\u{1b}[<35;10;5M\u{1b}[<32;11;5M\u{1b}[<0;1;1M\u{1b}[<0;1;1m\u{1b}[<65;3;4M\u{1b}[<18;2;2M"))
    try? #require(events.count == 6)
    guard events.count == 6 else { return }
    for event in events { #expect(event.type == .mouse) }
    #expect(events[0].action == .move)
    #expect(events[0].button == .none)
    #expect(events[0].x == 9)
    #expect(events[0].y == 4)
    #expect(events[1].action == .move)
    #expect(events[1].button == .left)
    #expect(events[2].action == .press)
    #expect(events[2].x == 0)
    #expect(events[3].action == .release)
    #expect(events[3].button == .left)
    #expect(events[4].action == .wheelDown)
    #expect(events[5].action == .press)
    #expect(events[5].button == .right)
    #expect(events[5].modifiers == .ctrl)
}

@Test func surfaceNeverStoresControlCharacters() {
    var surface = Surface()
    surface.resize(cols: 8, rows: 1)
    // Session titles and notification text come from any local process.
    #expect(surface.text(0, 0, "a\u{1b}[2J\u{07}\u{9b}z", TuiStyle()) == 8)
    for x in 0..<surface.cols {
        let c = surface[x, 0].chars[0]
        #expect(c >= 0x20 && (c < 0x7f || c > 0x9f), "control U+\(String(c, radix: 16)) at column \(x)")
    }
    #expect(surface[1, 0].chars[0] == 0xfffd)
    // A wide character never straddles the right edge.
    surface.text(7, 0, "中", TuiStyle())
    #expect(surface[7, 0].chars[0] == 0x20)
    #expect(surface[7, 0].width == 1)
}

// MARK: - A real tmux client

@MainActor
private final class Recorder: TerminalRendererDelegate {
    var ready: [String] = []
    var lost: [(id: String, message: String)] = []
    var interacted = 0
    func rendererReady(_ id: String) { ready.append(id) }
    func rendererLost(_ id: String, message: String) { lost.append((id: id, message: message)) }
    func rendererInteracted(_ id: String) { interacted += 1 }
}

@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

@MainActor
private func screenText(_ terminals: TuiTerminals, _ id: String) -> String {
    var surface = Surface()
    surface.resize(cols: 80, rows: 24)
    _ = terminals.paint(id, &surface, 0, 0, 80, 24)
    var text = String.UnicodeScalarView()
    for y in 0..<surface.rows {
        for x in 0..<surface.cols where surface[x, y].width != 0 {
            if let scalar = Unicode.Scalar(surface[x, y].chars[0]) { text.append(scalar) }
        }
        text.append("\n")
    }
    return String(text)
}

@MainActor
@Test(.enabled(if: HostEnvironment.findExecutable("tmux") != nil))
func viewShowsOutputAndReportsLoss() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cinmux-tui-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = StateStore(directory: directory.path)
    try store.open()
    let id = newIdentifier()
    let socket = store.tmuxSocket
    let tmux = try #require(HostEnvironment.findExecutable("tmux"))
    let environment = HostEnvironment.current()
    defer { _ = Command.run(tmux, ["-S", socket, "kill-server"], environment: environment) }
    let created = Command.run(tmux, ["-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", Tmux.sessionName(id),
                                     "-x", "80", "-y", "24", "/bin/sh"], environment: environment)
    try #require(created.ok)

    let terminals = TuiTerminals(store: store)
    let recorder = Recorder()
    terminals.delegate = recorder
    terminals.setSize(cols: 80, rows: 24)
    terminals.setSelected(id)
    // `cinmux tui` attaches from main-queue work, which runs on dispatch threads that
    // block signals once dispatchMain() parks the main thread; the client must not inherit that.
    var blocked: sigset_t = (1 << sigset_t(SIGWINCH - 1)) | (1 << sigset_t(SIGTERM - 1))
    var previous: sigset_t = 0
    pthread_sigmask(SIG_BLOCK, &blocked, &previous)
    terminals.attach(id, force: false)
    pthread_sigmask(SIG_SETMASK, &previous, nil)
    let becameReady = await eventually { recorder.ready.count == 1 }
    try #require(becameReady)

    for scalar in "echo tui-$((6*7))".unicodeScalars {
        var key = InputEvent()
        key.key = .character
        key.codepoint = scalar.value
        terminals.sendKey(id, key)
    }
    var enter = InputEvent()
    enter.key = .enter
    terminals.sendKey(id, enter)
    #expect(recorder.interacted > 0)
    // The shell's own expansion proves the keys reached it and its output came back.
    let echoed = await eventually { screenText(terminals, id).contains("tui-42") }
    #expect(echoed)
    // A new terminal area size reaches the tmux client (SIGWINCH must not be blocked in it).
    terminals.setSize(cols: 60, rows: 20)
    let resized = await eventually {
        let clients = Command.run(tmux, ["-S", socket, "list-clients", "-F", "#{client_width}x#{client_height}"], environment: environment)
        return String(decoding: clients.output, as: UTF8.self) == "60x20\n"
    }
    #expect(resized)

    terminals.detach(id)
    #expect(!terminals.isAttached(id))
    try await Task.sleep(for: .milliseconds(300))
    #expect(recorder.lost.isEmpty)

    terminals.attach(id, force: false)
    let reattached = await eventually { terminals.hasOutput(id) }
    try #require(reattached)
    try #require(Command.run(tmux, ["-S", socket, "kill-session", "-t", Tmux.exactTarget(id)], environment: environment).ok)
    let reported = await eventually { recorder.lost.count == 1 }
    try #require(reported)
    #expect(recorder.lost.first?.id == id)
    #expect(!(recorder.lost.first?.message.isEmpty ?? true))
    #expect(!terminals.isAttached(id))
}
