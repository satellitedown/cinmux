/// Shows sessions' tmux clients: SwiftTerm views in the app, cell grids in `cinmux tui`.
@MainActor
public protocol TerminalRenderer: AnyObject {
    var delegate: TerminalRendererDelegate? { get set }
    /// Starts a client for the session. `force` replaces a live one.
    func attach(_ id: String, force: Bool)
    func detach(_ id: String)
    func isAttached(_ id: String) -> Bool
}

@MainActor
public protocol TerminalRendererDelegate: AnyObject {
    /// The client is showing the session.
    func rendererReady(_ id: String)
    /// The client ended or failed; `message` explains why.
    func rendererLost(_ id: String, message: String)
    /// The user typed into or clicked the session.
    func rendererInteracted(_ id: String)
}
