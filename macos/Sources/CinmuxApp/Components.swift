import AppKit
import CinmuxCore
import SwiftUI

/// The sidebar backdrop: translucent material, deepened toward the Codex app's tone.
struct SidebarBackground: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VisualEffect()
            .overlay(colorScheme == .dark ? Color.black.opacity(0.28) : Color.white.opacity(0.25))
    }
}

/// Translucent sidebar material, like Finder's.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

/// Where the traffic lights sit when the title bar is hidden.
enum Chrome {
    static let trafficLightsWidth: CGFloat = 78
    static let barHeight: CGFloat = 36
    /// Bar controls are 26pt tall; this centers them on the traffic lights (14pt down).
    static let barInset: CGFloat = 1
}

/// Lets an empty strip move the window and double-click zoom it, like a title bar.
struct TitleBarArea: ViewModifier {
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .onTapGesture(count: 2) { NSApp.keyWindow?.performZoom(nil) }
    }
}

extension View {
    func titleBarArea() -> some View { modifier(TitleBarArea()) }

    /// Focuses a field once it is on screen. The terminal is an AppKit first
    /// responder that SwiftUI focus does not displace, so release it first.
    func focusOnAppear(_ focused: FocusState<Bool>.Binding) -> some View {
        onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if let window = NSApp.keyWindow, window.firstResponder is NSView, !(window.firstResponder is NSText) {
                    window.makeFirstResponder(nil)
                }
                focused.wrappedValue = true
            }
        }
    }
}

/// A rounded sidebar row background: selected, drop target, hovered or none.
struct RowBackground: View {
    var selected = false
    var targeted = false
    var hovered = false

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(fill)
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1)
                }
            }
    }

    private var fill: Color {
        if targeted { return Color.accentColor.opacity(0.14) }
        if selected { return Color.primary.opacity(0.10) }
        if hovered { return Color.primary.opacity(0.05) }
        return .clear
    }
}

/// A borderless toolbar button with an SF Symbol and a tooltip.
struct BarButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    @State var hovered = false
    @Environment(\.isEnabled) var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hovered && enabled ? 0.07 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Spinner for working and starting sessions.
struct Spinner: View {
    var color: Color = .accentColor

    var body: some View {
        TimelineView(.animation) { context in
            let turns = context.date.timeIntervalSinceReferenceDate / 1.1
            Circle()
                .trim(from: 0.1, to: 0.8)
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees((turns - turns.rounded(.down)) * 360))
        }
        .frame(width: 11, height: 11)
    }
}

extension SessionRow {
    var working: Bool { status == .starting || (status == .running && activity == .working) }

    var statusLabel: String {
        switch status {
        case .starting: return "Starting"
        case .running: return "Running"
        case .stopped: return "Stopped"
        }
    }

    var activityLabel: String {
        guard status == .running else { return statusLabel }
        switch activity {
        case .working: return "Working"
        case .waiting: return "Needs input"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }

    /// The Linux session tooltip, line for line.
    var details: String {
        var lines = [title, cwd.abbreviatingHome]
        if !branch.isEmpty { lines.append(branch) }
        lines.append(statusLabel)
        if status == .running { lines.append(activityLabel + (activityDetail.isEmpty ? "" : ": " + activityDetail)) }
        if pinned { lines.append("Pinned") }
        if unreadCount > 0 { lines.append("\(unreadCount) unread notifications") }
        if !noticeTitle.isEmpty { lines.append(noticeTitle + (noticeBody.isEmpty ? "" : "\n" + noticeBody)) }
        if !terminalError.isEmpty { lines.append(terminalError) }
        return lines.joined(separator: "\n")
    }
}

/// The trailing status glyph of a session row.
struct ActivityGlyph: View {
    let row: SessionRow

    var body: some View {
        Group {
            if row.working {
                Spinner(color: row.status == .running ? .accentColor : .secondary)
            } else if row.status == .running && row.activity == .waiting {
                Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
            } else if row.status == .running && row.activity == .done {
                Image(systemName: "checkmark.circle").foregroundStyle(Color.accentColor)
            } else {
                EmptyView()
            }
        }
        .font(.system(size: 12))
        .accessibilityHidden(true)
    }
}

extension String {
    /// "/Users/me/src" → "~/src".
    var abbreviatingHome: String {
        let home = NSHomeDirectory()
        if self == home { return "~" }
        if hasPrefix(home + "/") { return "~" + dropFirst(home.count) }
        return self
    }

    /// The branch shown in the status bar: "detached:abc123" → "abc123 (detached)".
    var branchLabel: String {
        hasPrefix("detached:") ? String(dropFirst("detached:".count)) + " (detached)" : self
    }
}
