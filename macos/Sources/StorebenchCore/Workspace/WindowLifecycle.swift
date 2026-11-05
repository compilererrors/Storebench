import Foundation

public enum WindowLifecycle {
    public static let workspaceID = "workspace"
    public static let openWorkspaceTitle = "Open Storebench"
    public enum Role: Sendable { case workspace, settings, auxiliary }
    public struct Window: Sendable {
        public let id: Int, role: Role, visible: Bool, miniaturized: Bool, closing: Bool
        public init(id: Int, role: Role, visible: Bool, miniaturized: Bool = false, closing: Bool = false) {
            self.id = id; self.role = role; self.visible = visible; self.miniaturized = miniaturized; self.closing = closing
        }
    }
    public enum Reopen: Equatable, Sendable { case present(Int), createWorkspace }
    public static func reopen(_ windows: [Window], lastWorkspace: Int? = nil) -> Reopen {
        let candidates = windows.filter { $0.role == .workspace && !$0.closing }
        if let previous = candidates.first(where: { $0.id == lastWorkspace }) { return .present(previous.id) }
        if let existing = candidates.first(where: { $0.visible || $0.miniaturized }) ?? candidates.first { return .present(existing.id) }
        return .createWorkspace
    }
}
