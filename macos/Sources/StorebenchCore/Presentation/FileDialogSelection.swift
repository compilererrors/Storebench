/// Keeps a file dialog's target until its completion, independently of presentation dismissal.
public struct FileDialogSelection<Context: Sendable>: Sendable {
    public var isPresented = false
    private var context: Context?
    public var pending: Bool { context != nil }
    public init() {}

    @discardableResult public mutating func begin(_ context: Context) -> Bool {
        guard self.context == nil else { return false }
        self.context = context; isPresented = true; return true
    }

    public mutating func finish() -> Context? {
        let selected = context
        context = nil; isPresented = false
        return selected
    }
}
