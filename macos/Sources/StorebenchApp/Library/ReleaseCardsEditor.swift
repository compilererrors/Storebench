import Foundation
import Observation
import StorebenchCore

/// Layout changes are immediate; ordered saves merge them with settings changed in another window.
@MainActor @Observable final class ReleaseCardsEditor {
    let session: WorkspaceSession
    private(set) var preferences: ReleaseCardPreferences?
    private(set) var status = ""
    private(set) var reading = false
    private(set) var saving = false
    private var pending: [ReleaseCardPreferences.Change] = []
    private var generation = 0
    init(session: WorkspaceSession) { self.session = session }
    /// One editor per session, kept while the window lives, so the Overview shows its cards at once when the user comes back to it.
    private static let kept = NSMapTable<WorkspaceSession, ReleaseCardsEditor>.weakToStrongObjects()
    static func shared(for session: WorkspaceSession) -> ReleaseCardsEditor {
        if let editor = kept.object(forKey: session) { return editor }
        let editor = ReleaseCardsEditor(session: session); kept.setObject(editor, forKey: session); return editor
    }

    func load(keys: [String] = []) async {
        guard !reading, pending.isEmpty else { return }
        let expected = generation
        reading = true; defer { reading = false }
        do {
            let saved = try await session.updateReleaseCardPreferences(.observe(keys))
            guard !Task.isCancelled, generation == expected else { return }
            var shown = saved
            for change in pending { shown = try shown.applying(change) }
            preferences = shown; if pending.isEmpty { status = "" }
        } catch {
            if !Task.isCancelled { status = "Release card preferences could not be read. Your saved choices have been kept." }
        }
    }
    func change(_ change: ReleaseCardPreferences.Change) {
        guard let preferences, let next = try? preferences.applying(change) else { return }
        generation += 1; self.preferences = next; pending.append(change); retry()
    }
    func retry() {
        guard !saving, !pending.isEmpty else { return }
        saving = true
        Task {
            defer { saving = false }
            while let change = pending.first {
                do {
                    let saved = try await session.updateReleaseCardPreferences(change)
                    pending.removeFirst()
                    var shown = saved
                    for change in pending { shown = try shown.applying(change) }
                    generation += 1; preferences = shown; status = ""
                } catch {
                    status = "Your layout is kept here but could not be saved. Choose Try Again to remember it next time."
                    return
                }
            }
        }
    }
}
