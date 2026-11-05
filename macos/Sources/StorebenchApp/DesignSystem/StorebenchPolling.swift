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
}
