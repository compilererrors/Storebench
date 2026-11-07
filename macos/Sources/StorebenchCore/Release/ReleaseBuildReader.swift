import Foundation

/// Reads one release screen's build pages. Retiring its owner stops delivery, including failures and callbacks started after
/// navigation. A newer read replaces an older read; a cancelled caller cannot replace one that is still running.
@MainActor public final class ReleaseBuildReader {
    public let scope: String
    public private(set) var active = true
    private var generation: UInt64 = 0
    private let read: @MainActor (_ all: Bool, _ latest: Bool) async throws -> ReleaseBuildPage

    public init(scope: String, read: @escaping @MainActor (_ all: Bool, _ latest: Bool) async throws -> ReleaseBuildPage) {
        self.scope = scope; self.read = read
    }

    public func retire() { active = false; generation &+= 1 }

    /// Delivers the first page before requesting the rest. A continuation failure keeps the first page partial; automatic checks
    /// leave error presentation to an explicit refresh. The caller decides what is shown and remembered.
    public func load(fresh: Bool = false, latest: Bool = false, received: (ReleaseBuildPage) -> Void, failed: (Error, Bool) -> Void) async {
        guard active, !Task.isCancelled else { return }
        generation &+= 1; let starting = generation
        await ScreenReads.reading(fresh: fresh) {
            var shown = false
            do {
                let first = try await read(false, latest)
                try Task.checkCancellation()
                guard active, generation == starting else { return }
                received(first); shown = true
                guard !first.complete, active, generation == starting else { return }
                let every = try await read(true, latest)
                try Task.checkCancellation()
                guard active, generation == starting else { return }
                received(every)
            } catch {
                guard active, generation == starting, !Task.isCancelled, !latest else { return }
                failed(error, shown)
            }
        }
    }
}
