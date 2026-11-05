public struct SyncStatusPresentation: Sendable {
    public enum Tone: String, Sendable { case success, warning, danger, neutral }
    public let label: String, icon: String, tone: Tone
    public init(_ state: SyncItem.State) {
        switch state {
        case .synced: label = "Synced"; icon = "check"; tone = .success
        case .ready: label = "Ready"; icon = "check"; tone = .success
        case .failed: label = "Failed"; icon = "warning"; tone = .danger
        case .partial: label = "Partial"; icon = "warning"; tone = .warning
        case .attention: label = "Attention"; icon = "warning"; tone = .warning
        case .running: label = "Syncing"; icon = "refresh"; tone = .neutral
        case .pending: label = "Pending"; icon = "info"; tone = .neutral
        case .unchecked: label = "Unchecked"; icon = "info"; tone = .neutral
        case .waiting: label = "Waiting"; icon = "info"; tone = .neutral
        }
    }
}
