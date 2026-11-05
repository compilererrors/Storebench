/// Clipboard preparation accepts only public codes. Failure exposes that exact fixed text for manual copying.
public struct IssueCopy: Sendable {
    public enum Part: Sendable { case code, details }
    public let code: String
    public private(set) var copied: Part?
    public private(set) var pending: Part?
    public private(set) var fallback: String?
    public let reply: String?
    public init(code: String, reply: String? = nil) { self.code = ReportingMessages.normalized(code); self.reply = reply }
    public mutating func begin(_ part: Part) -> String? {
        guard pending == nil else { return nil }
        pending = part
        return part == .code ? code : ReportingMessages.issueDetails(code, reply: reply)
    }
    public mutating func finish(_ part: Part, success: Bool) {
        guard pending == part else { return }
        pending = nil; copied = success ? part : nil
        fallback = success ? nil : part == .code ? code : ReportingMessages.issueDetails(code, reply: reply)
    }
    public mutating func dismissFallback() { fallback = nil }
    /// The confirmation shows briefly; the command then reads as before.
    public mutating func clearCopied() { copied = nil }
    public var status: String { switch copied { case .code?: "Error code copied"; case .details?: "Issue details copied"; case nil: "" } }
}
