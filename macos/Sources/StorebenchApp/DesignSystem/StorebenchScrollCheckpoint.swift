import AppKit
import StorebenchCore
import SwiftUI


extension View {
    func historyDisclosure(_ key: String, isExpanded: Binding<Bool>) -> some View {
        modifier(HistoryDisclosure(key: key, value: isExpanded))
    }
}
private struct HistoryDisclosure: ViewModifier {
    let key: String
    @Binding var value: Bool
    @Environment(\.navigationPresentation) private var history
    @Environment(\.collectionPersistence) private var persistence
    @State private var owner: NavigationPresentationContext?
    @State private var savedOwner: CollectionPersistenceContext?
    @State private var loadedKey = ""
    @State private var ready = false
    @State private var write: Task<Void, Never>?
    private var savedKey: String { CollectionViewPreferences.key([persistence.view, history?.scope ?? "", "disclosure", key]) }
    private func restore() {
        owner = history
        if let history, let saved = history.store.collection(history.scope + "/" + key, entry: history.entry, as: Bool.self) { value = saved }
    }
    private func save() {
        if let owner { owner.store.saveCollection(value, key: owner.scope + "/" + key, entry: owner.entry) }
        guard ready, savedKey == loadedKey, let store = savedOwner?.store, let preference = try? CollectionViewPreferences(openingLimit: value ? -1 : 0) else { return }
        let previous = write, key = loadedKey
        write = Task { await previous?.value; try? await store.saveCollectionViewPreference(key, value: preference) }
    }
    func body(content: Content) -> some View {
        content.onAppear { restore() }.onDisappear { save() }
            .task(id: persistence.taskIdentity + savedKey) {
                ready = false; savedOwner = persistence; loadedKey = savedKey
                let key = savedKey, expected = value
                guard let store = persistence.store else { return }
                do {
                    let saved = try await store.collectionViewPreference(key)
                    guard !Task.isCancelled, key == savedKey else { return }
                    let remembered = history.flatMap { $0.store.collection($0.scope + "/" + self.key, entry: $0.entry, as: Bool.self) }
                    if let saved, value == expected, remembered == nil { value = saved.openingLimit == -1 }
                    ready = true; save()
                } catch { ready = false }
            }
            .onChange(of: value) { save() }
            .onChange(of: history?.entry) { save(); restore() }
    }
}

extension View {
    /// Keeps a view's own choice, such as a sub-tab, selection, filter or page, with the history entry, so Back and Forward return to it.
    /// Nothing is written to disk. Group choices that reset each other into one value so restoring them never triggers those resets.
    func historyValue<Value: Equatable>(_ key: String, _ value: Binding<Value>) -> some View {
        modifier(HistoryValue(key: key, value: value))
    }
}
private struct HistoryValue<Value: Equatable>: ViewModifier {
    let key: String
    @Binding var value: Value
    @Environment(\.navigationPresentation) private var history
    @State private var owner: NavigationPresentationContext?
    private func restore() {
        owner = history
        if let history, let saved = history.store.collection(history.scope + "/value/" + key, entry: history.entry, as: Value.self) { value = saved }
    }
    private func save() { if let owner { owner.store.saveCollection(value, key: owner.scope + "/value/" + key, entry: owner.entry) } }
    func body(content: Content) -> some View {
        content.onAppear { restore() }.onDisappear { save() }
            .onChange(of: value) { save() }
            .onChange(of: history?.entry) { save(); restore() }
    }
}

struct NavigationPresentationContext {
    let store: NavigationPresentation, entry: UUID
    var scope = ""
    func scoped(_ value: String) -> Self { Self(store: store, entry: entry, scope: scope + "/" + value) }
    /// The last result this window read for `key`, shown at once while the view reads again in the background.
    @MainActor func rememberedRead<Value>(_ key: String, as type: Value.Type = Value.self) -> Value? { store.remembered(read: key, as: type)?.value }
    @MainActor func rememberRead<Value>(_ value: Value, _ key: String) { store.remember(value, read: key) }
    /// When the read a view shows from `rememberedRead` was taken, for its "Last read" line.
    @MainActor func rememberedReadAt(_ key: String) -> Date? { store.readAt(key) }
    /// Encodable reads are also saved in the encrypted database, so they show at once after the next launch too.
    @MainActor func rememberedRead<Value: Decodable>(_ key: String, as type: Value.Type = Value.self) -> Value? { store.remembered(read: key, as: type)?.value }
    @MainActor func rememberRead<Value: Codable & Sendable>(_ value: Value, _ key: String) { store.remember(value, read: key) }
    /// The remembered read, decoding one saved by an earlier launch away from the main thread.
    @MainActor func rememberedDecodedRead<Value: Decodable & Sendable>(_ key: String, as type: Value.Type = Value.self) async -> Value? { await store.rememberedDecoded(read: key, as: type)?.value }
}
private struct NavigationPresentationKey: EnvironmentKey { static let defaultValue: NavigationPresentationContext? = nil }
extension EnvironmentValues {
    var navigationPresentation: NavigationPresentationContext? {
        get { self[NavigationPresentationKey.self] }
        set { self[NavigationPresentationKey.self] = newValue }
    }
}

struct CollectionPersistenceContext {
    let store: (any CollectionViewPreferenceStore)?
    let view: String
    var taskIdentity: String { store.map { String(describing: ObjectIdentifier($0)) } ?? "none" }
}
private struct CollectionPersistenceKey: EnvironmentKey { static let defaultValue = CollectionPersistenceContext(store: nil, view: "") }
extension EnvironmentValues {
    var collectionPersistence: CollectionPersistenceContext {
        get { self[CollectionPersistenceKey.self] }
        set { self[CollectionPersistenceKey.self] = newValue }
    }
}

/// Installed inside the page's primary scroll view, never in an editor or text track.
struct StorebenchScrollCheckpoint: NSViewRepresentable {
    @Environment(\.navigationPresentation) private var context
    func makeNSView(context: Context) -> CheckpointView { CheckpointView() }
    func updateNSView(_ view: CheckpointView, context: Context) { view.configure(self.context) }
    static func dismantleNSView(_ view: CheckpointView, coordinator: ()) { view.retire() }

    final class CheckpointView: NSView {
        private var context: NavigationPresentationContext?
        private weak var owner: NSScrollView?
        private var restoration = ScrollRestoration(nil)
        private let lifetime = PresentationWork()
        private var observedSize: CGSize = .zero
        private var lastOffset: CGPoint = .zero
        private var applying = false
        private var ready = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { capture(); lifetime.end(); owner = nil }
            else { if !lifetime.active, context != nil { start() } else { attach() } }
        }
        isolated deinit { lifetime.end() }
        func configure(_ next: NavigationPresentationContext?) {
            guard context?.entry != next?.entry || context?.store !== next?.store else { attach(); return }
            capture(); lifetime.end(); owner = nil; context = next; ready = false
            restoration = ScrollRestoration(next.map { $0.store.offset($0.entry) })
            lastOffset = next.map { $0.store.offset($0.entry) } ?? .zero
            next?.store.capture = { [weak self] in self?.capture() }
            next?.store.keepScroll = { [weak self] in self?.cancelForInput() }
            if window != nil, next != nil { start() }
        }
        private func start() {
            let ticket = lifetime.begin()
            attach()
            let task = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard !Task.isCancelled, self?.lifetime.accepts(ticket) == true else { return }
                self?.ready = true; self?.restore()
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                guard !Task.isCancelled, self?.lifetime.accepts(ticket) == true else { return }
                self?.restore(finishedWaiting: true)
            }
            lifetime.own({ task.cancel() }, ticket: ticket)
        }
        private func attach() {
            guard window != nil, let scroll = enclosingScrollView, scroll !== owner else { return }
            if owner != nil { owner = nil; start(); return }
            owner = scroll
            observedSize = scroll.documentView?.bounds.size ?? .zero
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            scroll.documentView?.postsFrameChangedNotifications = true
            observe(NSView.boundsDidChangeNotification, object: clip) { view in
                if view.restoration.target != nil { view.restore() }
                else if let size = view.owner?.documentView?.bounds.size, size != view.observedSize { view.observedSize = size }
                else { view.recordOffset() }
            }
            if let document = scroll.documentView { observe(NSView.frameDidChangeNotification, object: document) { $0.restore() } }
            observe(NSScrollView.willStartLiveScrollNotification, object: scroll) { view in view.cancelForInput() }
            let inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown, .leftMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let owner = self.owner, event.window === owner.window else { return }
                    let focused = owner.window?.firstResponder as? NSView
                    let point = owner.convert(event.locationInWindow, from: nil)
                    if event.type == .keyDown ? focused?.isDescendant(of: owner) == true : owner.bounds.contains(point) { self.cancelForInput() }
                }
                return event
            }
            if let inputMonitor { lifetime.own({ NSEvent.removeMonitor(inputMonitor) }, ticket: lifetime.generation) }
            restore()
        }
        private func observe(_ name: Notification.Name, object: AnyObject, action: @escaping @MainActor @Sendable (CheckpointView) -> Void) {
            let token = NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            }
            lifetime.own({ NotificationCenter.default.removeObserver(token) }, ticket: lifetime.generation)
        }
        private func restore(finishedWaiting: Bool = false) {
            guard ready, !applying, let owner, let document = owner.documentView,
                  let point = restoration.resolve(content: document.bounds.size, viewport: owner.contentView.bounds.size, finishedWaiting: finishedWaiting) else { return }
            applying = true; owner.contentView.scroll(to: point); owner.reflectScrolledClipView(owner.contentView); applying = false
            recordOffset()
        }
        private func cancelForInput() { restoration.cancel(); recordOffset() }
        private func recordOffset() {
            guard !applying, restoration.target == nil, let owner else { return }
            lastOffset = owner.contentView.bounds.origin; observedSize = owner.documentView?.bounds.size ?? .zero
            capture()
        }
        private func capture() {
            guard !applying, restoration.target == nil, let context else { return }
            context.store.save(lastOffset, for: context.entry)
        }
        func retire() { capture(); lifetime.end(); owner = nil; context = nil }
    }
}
