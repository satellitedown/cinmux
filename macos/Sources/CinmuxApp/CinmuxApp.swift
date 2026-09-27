import AppKit
import CinmuxCore
import SwiftUI

struct CinmuxMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("Cinmux", id: "main") {
            RootView(model: delegate.model)
                .frame(minWidth: 760, minHeight: 540)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 840)
        .commands { CinmuxCommands(model: delegate.model) }

        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = model
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    /// Stay running with the window closed: notifications keep arriving and
    /// clicking the Dock icon reopens the workspace. Sessions live in tmux either way.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// What the menu bar needs from the key window. Commands only track focused
/// values reliably; they do not re-render for changes to the observed model.
struct CommandState: Equatable {
    var selected: SessionRow?
    var folders: [FolderSummary]
    var attentionCount: Int
    var sidebarVisible: Bool
}

struct CommandStateKey: FocusedValueKey { typealias Value = CommandState }

extension FocusedValues {
    var commandState: CommandState? {
        get { self[CommandStateKey.self] }
        set { self[CommandStateKey.self] = newValue }
    }
}

struct CinmuxCommands: Commands {
    let model: AppModel
    @FocusedValue(\.commandState) private var state

    var body: some Commands {
        let selected = state?.selected
        let running = selected?.status == .running
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { model.newTab() }
                .keyboardShortcut("t")
            Button("New Folder") { model.beginNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w")
            Button("Close Pane…") { model.confirmClosePane() }
                .disabled(selected == nil)
            Button("Close Tab…") { model.confirmCloseSession() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(selected == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Search Tabs") { model.showSearch() }
                .keyboardShortcut("f")
        }
        CommandGroup(replacing: .sidebar) {
            Button(state?.sidebarVisible == false ? "Show Sidebar" : "Hide Sidebar") { model.sidebarVisible.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Button("Show All Tabs") { model.showAllTabs() }
            Divider()
        }
        CommandMenu("Tab") {
            Button("Rename Tab…") { model.beginRename() }
                .keyboardShortcut("r")
                .disabled(selected == nil)
            Button(selected?.pinned == true ? "Unpin Tab" : "Pin Tab") {
                if let selected { model.controller?.setPinned(selected.id, !selected.pinned) }
            }
            .disabled(selected == nil)
            Menu("Move to Folder") {
                Button("Unfiled") { if let selected { model.controller?.moveSession(selected.id, folderId: "") } }
                    .disabled(selected?.folderId.isEmpty ?? true)
                if let folders = state?.folders, !folders.isEmpty {
                    Divider()
                    ForEach(folders) { folder in
                        Button(folder.name) { if let selected { model.controller?.moveSession(selected.id, folderId: folder.id) } }
                            .disabled(selected?.folderId == folder.id)
                    }
                }
            }
            .disabled(selected == nil)
            Divider()
            Button("Split Right") { model.split(.right) }
                .keyboardShortcut("d")
                .disabled(!running)
            Button("Split Down") { model.split(.down) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!running)
            Divider()
            Button("Start Session") { model.startSelected() }
                .disabled(selected?.status != .stopped)
            Button("Reconnect Terminal") { model.reconnectSelected() }
                .disabled(selected == nil || selected?.status == .stopped)
            Divider()
            Button("Previous Tab") { model.navigate(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Tab") { model.navigate(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Jump to Tab That Needs You") { model.nextAttention() }
                .keyboardShortcut("j")
                .disabled((state?.attentionCount ?? 0) == 0)
        }
    }
}

struct SettingsView: View {
    @AppStorage(TerminalAppearance.fontSizeKey) var fontSize = TerminalAppearance.defaultFontSize
    @AppStorage(TerminalAppearance.fontNameKey) var fontName = ""
    @AppStorage(TerminalAppearance.optionAsMetaKey) var optionAsMeta = true

    var body: some View {
        Form {
            Picker("Terminal font", selection: $fontName) {
                Text("SF Mono").tag("")
                ForEach(TerminalAppearance.monospacedFamilies, id: \.self) { family in Text(family).tag(family) }
            }
            Stepper(value: $fontSize, in: 9...28, step: 1) {
                LabeledContent("Font size", value: "\(Int(fontSize)) pt")
            }
            Toggle("Use Option as Meta key", isOn: $optionAsMeta)
            Text("Needed for the Option shortcuts inside a tab, such as Option-Return to split. Turn it off to type accented characters with Option.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
