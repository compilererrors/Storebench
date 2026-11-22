import StorebenchCore
import SwiftUI

/// Repeated reads of saved state for a view, such as job progress or library status.
///
/// Reads never overlap: each one finishes before the next wait starts. Polling stops as soon as the task is
/// cancelled (the view disappeared or its task identity changed) or `current` reports that a newer owner took
/// over, and a read after a wait only runs while its owner is still current. Polling only reads; any write keeps
/// its own lock and validation.
enum StorebenchPolling {
    @MainActor
    static func repeating(every interval: Duration, readFirst: Bool = true, while current: () -> Bool, _ read: () async -> Void) async {
        if readFirst {
            guard !Task.isCancelled, current() else { return }
            await read()
        }
        while !Task.isCancelled, current() {
            do { try await Task.sleep(for: interval) } catch { return }
            guard !Task.isCancelled, current() else { return }
            await read()
        }
    }

    /// As `repeating`, for a read of saved state. `stamp` gives a token that changes whenever what the read shows may have
    /// changed. After the first read, a repeat is skipped while the token stays the same. `working` says that something shown
    /// is still in progress or could not be read, which always reads again; a read older than `SavedStateWatch.staleAfter` is
    /// repeated too. A command that reads directly, such as Refresh, is unaffected.
    @MainActor
    static func repeating(every interval: Duration, stamp: @MainActor () async -> String?, working: @MainActor () -> Bool,
                          while current: () -> Bool, _ read: () async -> Void) async {
        var watch = SavedStateWatch()
        func readNow() async {
            let token = await stamp()
            guard !Task.isCancelled, current(), watch.due(token, working: working()) else { return }
            await read()
            watch.read(token)
        }
        guard !Task.isCancelled, current() else { return }
        await readNow()
        while !Task.isCancelled, current() {
            do { try await Task.sleep(for: interval) } catch { return }
            guard !Task.isCancelled, current() else { return }
            await readNow()
        }
    }
}
