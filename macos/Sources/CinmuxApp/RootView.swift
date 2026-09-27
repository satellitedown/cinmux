import CinmuxCore
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) var colorScheme
    @AppStorage(TerminalAppearance.fontSizeKey) var fontSize = TerminalAppearance.defaultFontSize
    @AppStorage(TerminalAppearance.fontNameKey) var fontName = ""
    @AppStorage(TerminalAppearance.optionAsMetaKey) var optionAsMeta = true

    var body: some View {
        Group {
            if let controller = model.controller, let terminals = model.terminals {
                workspace(controller, terminals)
            } else {
                StartupError(message: model.startupError ?? "Cinmux could not start.")
            }
        }
        .ignoresSafeArea()
    }

    private var appearance: TerminalAppearance {
        TerminalAppearance(dark: colorScheme == .dark, fontName: fontName, fontSize: fontSize, optionAsMeta: optionAsMeta)
    }

    private func workspace(_ controller: SessionController, _ terminals: TerminalViews) -> some View {
        HStack(spacing: 0) {
            if model.sidebarVisible {
                Sidebar(model: model, controller: controller)
                    .frame(width: model.sidebarWidth)
                    .overlay(alignment: .trailing) { SidebarResizer(width: $model.sidebarWidth) }
                    .transition(.move(edge: .leading))
            }
            ContentCard(model: model, controller: controller, terminals: terminals, palette: appearance.palette)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: model.sidebarVisible ? 12 : 0,
                                                  bottomLeadingRadius: model.sidebarVisible ? 12 : 0, style: .continuous))
                .overlay {
                    if model.sidebarVisible {
                        UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.10), lineWidth: 1)
                            .padding(.trailing, -2)
                            .allowsHitTesting(false)
                    }
                }
        }
        .background(SidebarBackground())
        .animation(.easeOut(duration: 0.16), value: model.sidebarVisible)
        .focusedSceneValue(\.commandState, CommandState(selected: controller.selected, folders: controller.folders,
                                                         attentionCount: controller.attentionCount, sidebarVisible: model.sidebarVisible))
        .onAppear { terminals.apply(appearance) }
        .onChange(of: appearance) { _, value in terminals.apply(value) }
        .confirmationDialog(model.confirmation?.title ?? "", isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } }),
                            presenting: model.confirmation) { confirmation in
            Button(confirmation.confirmText, role: .destructive) { model.accept(confirmation) }
            Button("Cancel", role: .cancel) { model.confirmation = nil; model.focusTerminal() }
        } message: { confirmation in
            Text(confirmation.message)
        }
        .alert("Unable to complete action", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }),
               presenting: model.failure) { failure in
            if let recovery = failure.recovery {
                Button("Cancel", role: .cancel) { model.failure = nil }
                Button("Choose directory") { model.chooseDirectory(for: recovery) }
            } else {
                Button("Dismiss", role: .cancel) { model.failure = nil }
            }
        } message: { failure in
            Text(failure.message)
        }
    }
}

/// Drag the sidebar's trailing edge to resize it.
private struct SidebarResizer: View {
    @Binding var width: Double
    @State var start: Double?

    var body: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let origin = start ?? width
                    start = origin
                    width = max(200, min(420, origin + value.translation.width))
                }
                .onEnded { _ in start = nil })
            .offset(x: 3)
    }
}

private struct ContentCard: View {
    let model: AppModel
    let controller: SessionController
    let terminals: TerminalViews
    let palette: Palette

    private var selected: SessionRow? { controller.selected }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model, controller: controller)
            ZStack {
                Color(nsColor: palette.background)
                TerminalBody(model: model, controller: controller, terminals: terminals)
            }
            if let selected { StatusBar(row: selected) }
        }
        .background(Color(nsColor: palette.background))
    }
}

private struct TopBar: View {
    let model: AppModel
    let controller: SessionController

    private var selected: SessionRow? { controller.selected }
    private var running: Bool { selected?.status == .running }

    var body: some View {
        HStack(spacing: 6) {
            if !model.sidebarVisible {
                Spacer().frame(width: Chrome.trafficLightsWidth - 12)
                BarButton(symbol: "sidebar.left", help: "Show sidebar (⌃⌘S)") { model.sidebarVisible = true }
                BarButton(symbol: "square.and.pencil", help: "New tab (⌘T)") { model.newTab() }
            }
            if let selected {
                Text(selected.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, model.sidebarVisible ? 8 : 4)
                Menu {
                    MoreMenu(model: model, controller: controller)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 26, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                ActivityChip(row: selected)
            }
            Spacer(minLength: 12)
            BarButton(symbol: "rectangle.split.2x1", help: "Split right (⌘D)") { model.split(.right) }
                .disabled(!running)
            BarButton(symbol: "rectangle.split.1x2", help: "Split down (⇧⌘D)") { model.split(.down) }
                .disabled(!running)
            BarButton(symbol: controller.attentionCount > 0 ? "bell.badge" : "bell", help: "Next attention (⌘J)",
                      active: controller.attentionCount > 0) { model.nextAttention() }
                .disabled(controller.attentionCount == 0)
            if selected == nil {
                Menu {
                    MoreMenu(model: model, controller: controller)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 26, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, Chrome.barInset)
        .frame(height: Chrome.barHeight, alignment: .top)
        .titleBarArea()
    }
}

/// The header "More" menu (Linux AppHeader moreMenu).
private struct MoreMenu: View {
    let model: AppModel
    let controller: SessionController

    var body: some View {
        let selected = controller.selected
        Button("New tab") { model.newTab() }
        Button("New folder") { model.beginNewFolder() }
        Divider()
        Button("Rename session") { model.beginRename() }.disabled(selected == nil)
        Button("Split right") { model.split(.right) }.disabled(selected?.status != .running)
        Button("Split down") { model.split(.down) }.disabled(selected?.status != .running)
        if let selected {
            Button(selected.pinned ? "Unpin session" : "Pin session") { controller.setPinned(selected.id, !selected.pinned) }
            Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: selected.cwd) }
        }
        Divider()
        Button(model.sidebarVisible ? "Hide sidebar" : "Show sidebar") { model.sidebarVisible.toggle() }
        Divider()
        Button("Close pane…", role: .destructive) { model.confirmClosePane() }.disabled(selected == nil)
        Button("Close session…", role: .destructive) { model.confirmCloseSession() }.disabled(selected == nil)
        Divider()
        Button("Quit Cinmux") { NSApp.terminate(nil) }
    }
}

/// What the session's agent is doing, next to the title.
private struct ActivityChip: View {
    let row: SessionRow

    var body: some View {
        if row.status == .running && row.activity != .idle || row.status == .starting {
            HStack(spacing: 5) {
                ActivityGlyph(row: row)
                Text(row.activityLabel + (row.activityDetail.isEmpty ? "" : " · " + row.activityDetail))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 12))
            .foregroundStyle(row.activity == .waiting ? Color.orange : Color.secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .help(row.activityDetail.isEmpty ? row.activityLabel : row.activityDetail)
        }
    }
}

/// The terminal, or why it is not shown (Linux TerminalPane).
private struct TerminalBody: View {
    let model: AppModel
    let controller: SessionController
    let terminals: TerminalViews

    var body: some View {
        if let selected = controller.selected {
            let ready = terminals.ready.contains(selected.id) && selected.terminalError.isEmpty
            ZStack(alignment: .topTrailing) {
                TerminalHost(view: terminals.view(for: selected.id), focusToken: model.terminalFocusToken)
                    .padding(.leading, 12)
                    .padding(.trailing, 4)
                    .padding(.vertical, 4)
                    .opacity(ready ? 1 : 0)
                if ready && selected.status == .stopped {
                    Button("Start session") { model.startSelected() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(14)
                }
                if !ready {
                    placeholder(selected)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: "apple.terminal")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text("What should we work on?")
                    .font(.system(size: 26, weight: .regular))
                Label("New tabs start in \(controller.defaultDirectory.abbreviatingHome)", systemImage: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Button("Create a terminal session") { model.newTab() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholder(_ selected: SessionRow) -> some View {
        VStack(spacing: 12) {
            Text(!selected.terminalError.isEmpty ? "Terminal unavailable"
                 : selected.status == .starting ? "Starting session…"
                 : selected.status == .stopped ? "Session stopped" : "Connecting terminal…")
                .font(.system(size: 17, weight: .semibold))
            if !selected.terminalError.isEmpty || selected.status == .stopped {
                Text(!selected.terminalError.isEmpty
                     ? selected.terminalError + (selected.status == .running ? "\nThe session and its jobs are still running." : "")
                     : "Start a fresh shell in the saved working directory. Previous commands will not be replayed.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            if selected.status == .stopped {
                Button("Start session") { model.startSelected() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else if !selected.terminalError.isEmpty {
                Button("Reconnect terminal") { model.reconnectSelected() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: 440)
        .padding(20)
    }
}

/// Working directory and branch under the terminal, like the Codex composer bar.
private struct StatusBar: View {
    let row: SessionRow

    var body: some View {
        HStack(spacing: 14) {
            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: row.cwd)
            } label: {
                Label(row.cwd.abbreviatingHome, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help("Reveal \(row.cwd) in Finder")
            if !row.branch.isEmpty {
                Label(row.branch.branchLabel, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if row.unreadCount > 0 {
                Label(row.noticeTitle.isEmpty ? "\(row.unreadCount) unread" : row.noticeTitle, systemImage: "bell.fill")
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .help(row.noticeBody.isEmpty ? row.noticeTitle : row.noticeTitle + "\n" + row.noticeBody)
            }
            Text(row.statusLabel)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }
}

private struct StartupError: View {
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("Cinmux cannot start").font(.system(size: 17, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: 460)
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffect(material: .windowBackground))
    }
}
