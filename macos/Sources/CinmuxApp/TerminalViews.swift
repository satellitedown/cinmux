import AppKit
import CinmuxCore
import Observation
import SwiftTerm
import SwiftUI

/// The app's renderer: one SwiftTerm view per attached session, each running
/// `tmux attach` against the private server. Views outlive selection changes,
/// so switching sessions is instant and scrollback stays put.
@MainActor
@Observable
final class TerminalViews: TerminalRenderer {
    @ObservationIgnored weak var delegate: TerminalRendererDelegate?
    /// Sessions whose client has drawn its first output.
    private(set) var ready: Set<String> = []
    @ObservationIgnored private(set) var views: [String: SessionTerminalView] = [:]
    @ObservationIgnored private let socket: String
    @ObservationIgnored private let tmuxProgram: String?
    @ObservationIgnored private let environment: [String]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored var appearance = TerminalAppearance.current()

    init(socket: String) {
        self.socket = socket
        let host = HostEnvironment.current()
        tmuxProgram = HostEnvironment.findExecutable("tmux", environment: host)
        environment = Tmux.clientEnvironment(host).map { "\($0.key)=\($0.value)" }.sorted()
    }

    func view(for id: String) -> SessionTerminalView? { views[id] }

    func attach(_ id: String, force: Bool) {
        if force { detach(id) }
        guard views[id] == nil else { return }
        guard let tmuxProgram else {
            delegate?.rendererLost(id, message: "tmux is not installed. Install it with: brew install tmux")
            return
        }
        generation += 1
        let view = SessionTerminalView(sessionId: id, generation: generation, owner: self)
        appearance.apply(to: view)
        views[id] = view
        view.startProcess(executable: tmuxProgram, args: Tmux.attachArguments(socket: socket, id: id), environment: environment)
    }

    func detach(_ id: String) {
        guard let view = views.removeValue(forKey: id) else { return }
        ready.remove(id)
        view.owner = nil
        view.terminate()
        view.removeFromSuperview()
    }

    func isAttached(_ id: String) -> Bool { views[id] != nil }

    func detachAll() {
        for id in Array(views.keys) { detach(id) }
    }

    func apply(_ appearance: TerminalAppearance) {
        guard appearance != self.appearance else { return }
        self.appearance = appearance
        for view in views.values { appearance.apply(to: view) }
    }

    // Called by views; `generation` rejects events from a replaced client.

    fileprivate func viewDrewFirstOutput(_ view: SessionTerminalView) {
        guard views[view.sessionId] === view else { return }
        ready.insert(view.sessionId)
        delegate?.rendererReady(view.sessionId)
    }

    fileprivate func viewExited(_ view: SessionTerminalView, exitCode: Int32?) {
        guard views[view.sessionId] === view else { return }
        views[view.sessionId] = nil
        ready.remove(view.sessionId)
        view.removeFromSuperview()
        let code = exitCode.map(String.init) ?? "signal"
        delegate?.rendererLost(view.sessionId, message: "Terminal view exited (code \(code)). The tmux session is unaffected; reconnect to view it.")
    }

    fileprivate func viewInteracted(_ view: SessionTerminalView) {
        guard views[view.sessionId] === view else { return }
        delegate?.rendererInteracted(view.sessionId)
    }
}

/// A SwiftTerm view bound to one session's tmux client.
final class SessionTerminalView: LocalProcessTerminalView {
    let sessionId: String
    let generation: Int
    weak var owner: TerminalViews?
    private var drewOutput = false

    init(sessionId: String, generation: Int, owner: TerminalViews) {
        self.sessionId = sessionId
        self.generation = generation
        self.owner = owner
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        // tmux owns scrollback (the wheel scrolls it through mouse reporting), so
        // SwiftTerm's own scroller would only reserve an empty gutter.
        for case let scroller as NSScroller in subviews { scroller.isHidden = true }
    }

    required init?(coder: NSCoder) { fatalError("SessionTerminalView is not decodable") }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        if !drewOutput {
            drewOutput = true
            owner?.viewDrewFirstOutput(self)
        }
    }

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        super.processTerminated(source, exitCode: exitCode)
        owner?.viewExited(self, exitCode: exitCode)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        super.send(source: source, data: data)
        owner?.viewInteracted(self)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        owner?.viewInteracted(self)
    }
}

/// Font and colors for every terminal view.
struct TerminalAppearance: Equatable {
    var dark: Bool
    var fontName: String
    var fontSize: Double
    var optionAsMeta: Bool

    static let fontSizeKey = "terminalFontSize"
    static let fontNameKey = "terminalFontName"
    static let optionAsMetaKey = "optionAsMetaKey"
    static let defaultFontSize = 13.0

    static func current(dark: Bool? = nil) -> TerminalAppearance {
        let defaults = UserDefaults.standard
        let size = defaults.object(forKey: fontSizeKey) as? Double ?? defaultFontSize
        let name = defaults.string(forKey: fontNameKey) ?? ""
        let meta = defaults.object(forKey: optionAsMetaKey) as? Bool ?? true
        let isDark = dark ?? (NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        return TerminalAppearance(dark: isDark, fontName: name, fontSize: size, optionAsMeta: meta)
    }

    /// The chosen family (default SF Mono), falling back to the bundled Nerd Font
    /// symbols so prompt icons render as they do in Ghostty. The fallback needs
    /// a regular font: CoreText ignores cascade lists on the system UI font.
    var font: NSFont {
        _ = Self.fontsRegistered
        let chosen = fontName.isEmpty ? nil : NSFontManager.shared.font(withFamily: fontName, traits: [], weight: 5, size: fontSize)
        let base = chosen ?? NSFont(name: "SFMono-Regular", size: fontSize) ?? NSFont(name: "Menlo-Regular", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let cascade = [NSFontDescriptor(name: Self.symbolsFontName, size: fontSize)]
        return NSFont(descriptor: base.fontDescriptor.addingAttributes([.cascadeList: cascade]), size: fontSize) ?? base
    }

    static let symbolsFontName = "SymbolsNFM"

    /// Registers, for this process only, the bundled Nerd Font symbols and the
    /// SF Mono faces macOS ships inside Terminal.app (not installed system-wide).
    static let fontsRegistered: Void = {
        var urls: [URL] = []
        if let symbols = Bundle.main.url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf") { urls.append(symbols) }
        let terminalFonts = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts")
        let faces = (try? FileManager.default.contentsOfDirectory(at: terminalFonts, includingPropertiesForKeys: nil)) ?? []
        urls += faces.filter { $0.lastPathComponent.hasPrefix("SF-Mono-") }
        for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
    }()

    /// Installed monospaced families, for the Settings picker.
    static var monospacedFamilies: [String] {
        _ = fontsRegistered
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            // SF Mono is the default entry; the symbols font is only a fallback.
            guard family != "SF Mono", !family.hasPrefix("Symbols Nerd Font"), let traits = manager.availableMembers(ofFontFamily: family)?.first?[3] as? UInt else {
                return false
            }
            return NSFontTraitMask(rawValue: traits).contains(.fixedPitchFontMask)
        }
    }

    var palette: Palette { dark ? .dark : .light }

    @MainActor
    func apply(to view: SessionTerminalView) {
        view.font = font
        let palette = self.palette
        view.nativeBackgroundColor = palette.background
        view.nativeForegroundColor = palette.foreground
        view.caretColor = palette.caret
        view.selectedTextBackgroundColor = palette.selection
        view.installColors(palette.ansi.map { rgb in
            SwiftTerm.Color(red8: UInt16((rgb >> 16) & 0xff), green8: UInt16((rgb >> 8) & 0xff), blue8: UInt16(rgb & 0xff))
        })
        view.optionAsMetaKey = optionAsMeta
    }
}

/// Neutral palettes close to the Codex app: near-black or white canvas,
/// GitHub-style ANSI colors tuned for contrast on each.
struct Palette {
    var background: NSColor
    var foreground: NSColor
    var caret: NSColor
    var selection: NSColor
    var ansi: [UInt32]

    static let dark = Palette(
        background: NSColor(srgbRed: 0x1b / 255, green: 0x1b / 255, blue: 0x1b / 255, alpha: 1),
        foreground: NSColor(srgbRed: 0xe6 / 255, green: 0xe6 / 255, blue: 0xe6 / 255, alpha: 1),
        caret: NSColor(srgbRed: 0xe6 / 255, green: 0xe6 / 255, blue: 0xe6 / 255, alpha: 0.9),
        selection: NSColor(srgbRed: 0x3a / 255, green: 0x5b / 255, blue: 0x8c / 255, alpha: 0.75),
        ansi: [0x2e2e2e, 0xff7b72, 0x7ee787, 0xe3b341, 0x79c0ff, 0xd2a8ff, 0x76e3ea, 0xc9d1d9,
               0x6e7681, 0xffa198, 0x56d364, 0xf2cc60, 0xa5d6ff, 0xe2c5ff, 0xb3f0ff, 0xf0f6fc])

    static let light = Palette(
        background: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        foreground: NSColor(srgbRed: 0x1f / 255, green: 0x23 / 255, blue: 0x28 / 255, alpha: 1),
        caret: NSColor(srgbRed: 0x1f / 255, green: 0x23 / 255, blue: 0x28 / 255, alpha: 0.85),
        selection: NSColor(srgbRed: 0xb6 / 255, green: 0xd4 / 255, blue: 0xfe / 255, alpha: 0.9),
        ansi: [0x24292f, 0xcf222e, 0x116329, 0x9a6700, 0x0969da, 0x8250df, 0x1b7c83, 0x6e7781,
               0x57606a, 0xa40e26, 0x1a7f37, 0x7d4e00, 0x218bff, 0xa475f9, 0x3192aa, 0x8c959f])
}

/// Hosts the selected session's terminal view inside SwiftUI.
struct TerminalHost: NSViewRepresentable {
    let view: SessionTerminalView?
    /// Changes whenever the terminal should take keyboard focus.
    let focusToken: Int

    final class Coordinator { var focusToken = -1 }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let current = container.subviews.first as? SessionTerminalView
        if current !== view {
            current?.removeFromSuperview()
            if let view {
                view.removeFromSuperview()
                view.frame = container.bounds
                view.autoresizingMask = [.width, .height]
                container.addSubview(view)
            }
        }
        if let view, context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            onMain {
                if view.window != nil { view.window?.makeFirstResponder(view) }
            }
        }
    }
}
