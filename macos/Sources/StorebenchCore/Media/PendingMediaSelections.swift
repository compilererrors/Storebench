import Foundation
import Observation

/// Selected originals survive closing their editing sheet and failed local saves.
@MainActor @Observable public final class PendingScreenshotSelection: Identifiable {
    public let id = UUID(), scope: MediaDraftScope, platform: String, setId: String?, displayType: String?
    @ObservationIgnored public var didChange: @MainActor () -> Void = {}
    public private(set) var selection: ScreenshotSelection? { didSet { didChange() } }
    public private(set) var status = ""
    public private(set) var problem: String?
    public private(set) var reading = false { didSet { didChange() } }
    public private(set) var readProgress: SelectedFiles.ReadProgress?
    public private(set) var validating = false { didSet { didChange() } }
    public private(set) var saving = false { didSet { didChange() } }
    public private(set) var editing = false { didSet { didChange() } }
    public private(set) var active = true
    /// Images whose alpha channel was replaced with white when they were read.
    public private(set) var flattened = 0
    @ObservationIgnored private let urls: [URL]
    @ObservationIgnored private let read: @MainActor ([URL], @escaping @MainActor @Sendable (SelectedFiles.ReadProgress) -> Void) async throws -> ScreenshotSelection
    @ObservationIgnored private let write: @MainActor (ScreenshotSelection) async throws -> MediaAdditionReceipt
    @ObservationIgnored private var operation: UUID?
    @ObservationIgnored private var validation: UUID?
    @ObservationIgnored private var validatedRevision: String?
    @ObservationIgnored private var validationTask: Task<Void, Never>?
    public var dirty: Bool { selection.map { !$0.items.isEmpty } ?? !urls.isEmpty }
    public var busy: Bool { reading || validating || saving || editing }
    public var ready: Bool { active && !busy && dirty && selection != nil && validatedRevision == selection?.revision && problem == nil }
    public var state: ListingSaveWorkflow.State {
        .init(dirty: dirty, blocked: !active || busy || (dirty && !ready), signature: selection?.revision ?? id.uuidString)
    }
    public init(scope: MediaDraftScope, platform: String, setId: String?, displayType: String?, urls: [URL],
                read: (@MainActor ([URL]) async throws -> ScreenshotSelection)? = nil,
                save: @escaping @MainActor (ScreenshotSelection) async throws -> MediaAdditionReceipt) {
        self.scope = scope; self.platform = platform; self.setId = setId; self.displayType = displayType; self.urls = urls
        self.read = { urls, progress in
                    if let read { return try await read(urls) }
                    let scopes = urls.filter { $0.startAccessingSecurityScopedResource() }
                    defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }
                    return ScreenshotSelection(try await SelectedFiles.readAsync(urls, purpose: .screenshotEditing, progress: progress))
        }
        self.write = save
    }
    public func load() async {
        guard active, !busy, selection == nil, !Task.isCancelled else { return }
        let ticket = UUID(); operation = ticket; reading = true; readProgress = nil; status = ""
        defer { if owns(ticket) { operation = nil; reading = false } }
        do {
            let value = try await read(urls) { [weak self] update in
                guard let self, self.owns(ticket), self.reading, !Task.isCancelled else { return }
                self.readProgress = update
            }; try Task.checkCancellation()
            guard owns(ticket) else { return }
            let opaque = await Task.detached { var copy = value; let count = copy.removeTransparency(); return (copy, count) }.value
            guard owns(ticket), !Task.isCancelled else { return }
            selection = opaque.0; flattened = opaque.1; validate()
        } catch {
            if owns(ticket) { status = "Choose up to 10 readable PNG or JPEG files, no larger than 80 MB each. Retry the selection or remove it; no images were added." }
        }
    }
    /// Reads, checks and saves the selection in one step, so added files go straight into the draft.
    /// Anything that cannot be saved stays selected with its problem, ready to fix or discard.
    public func add() async -> Bool {
        guard active, !Task.isCancelled else { return false }
        if selection == nil { await load() }
        await validationTask?.value
        guard active, !Task.isCancelled, ready else { return false }
        return await save()
    }
    public func setEditing(_ value: Bool) { guard active, !saving, !reading else { return }; editing = value }
    public func move(_ id: String, by offset: Int) { edit { $0.move(id, by: offset) } }
    public func reorder(_ order: [String], expectedRevision: String) -> Bool {
        guard active, !reading, !saving, !editing, var value = selection, value.reorder(order, expectedRevision: expectedRevision) else { return false }
        selection = value; validate(); status = "Selection order changed."; return true
    }
    public func move(_ id: String, to target: String) -> Bool {
        guard active, !reading, !saving, !editing, var value = selection else { return false }
        guard value.move(id, to: target) else { return false }; selection = value; validate(); return true
    }
    public func remove(_ id: String) { edit { $0.remove(id) } }
    public func restore(_ id: String) { edit { $0.restore(id) } }
    public func apply(_ id: String, data: Data, edits: ScreenshotEdits) throws {
        guard active, !reading, !saving, selection?.items.contains(where: { $0.id == id }) == true else { throw ScreenshotEditFailure.edits }
        try selection?.apply(id, data: data, edits: edits); status = ""; validate()
    }
    public func clear() {
        guard active, !reading, !saving, !editing else { return }
        selection = ScreenshotSelection(items: []); status = ""; validate()
    }
    public func retire() {
        active = false; operation = nil; validation = nil; validationTask?.cancel(); validationTask = nil
        reading = false; validating = false; saving = false; editing = false
        readProgress = nil
    }
    public func save() async -> Bool {
        guard active, !Task.isCancelled else { return false }
        guard dirty else { return !busy }
        guard ready, let snapshot = selection else { return false }
        let ticket = UUID(); operation = ticket; saving = true; status = ""
        defer { if owns(ticket) { operation = nil; saving = false } }
        do {
            let receipt = try await write(snapshot)
            guard receipt.scope == scope, receipt.count == snapshot.items.count else { throw DraftFailure.invalid }
            guard owns(ticket) else { return true }
            // Clearing acknowledges this exact selection, rather than any replacement input.
            if selection?.revision == snapshot.revision { selection = ScreenshotSelection(items: []); validatedRevision = selection?.revision; problem = nil }
            status = (receipt.count == 1 ? "1 screenshot" : "\(receipt.count) screenshots") + " added and saved on this Mac."
                + (flattened == 0 ? "" : " Transparency was replaced with white in \(flattened == 1 ? "1 image" : "\(flattened) images"), as Apple requires.")
            flattened = 0; return true
        } catch {
            guard owns(ticket) else { return false }
            if let failure = error as? ScreenshotFailure { status = failure.message + " The files are kept so you can fix them or try again." }
            else if let failure = error as? DraftFailure { status = failure.message }
            else { status = "The images could not be saved. The files are kept so you can try again." }
            return false
        }
    }
    private func edit(_ change: (inout ScreenshotSelection) -> Void) {
        guard active, !reading, !saving, !editing, var value = selection else { return }
        change(&value); selection = value; status = ""; validate()
    }
    private func validate() {
        validationTask?.cancel(); validatedRevision = nil; problem = nil
        guard let snapshot = selection, !snapshot.items.isEmpty else { validation = nil; validating = false; validatedRevision = selection?.revision; return }
        let ticket = UUID(), platform = platform, displayType = displayType
        validation = ticket; validating = true
        validationTask = Task { [weak self] in
            let owned = Task.detached { snapshot.problem(platform: platform, displayType: displayType) }
            let issue = await withTaskCancellationHandler(operation: { await owned.value }, onCancel: { owned.cancel() })
            guard let self, self.active, !Task.isCancelled, self.validation == ticket, self.selection?.revision == snapshot.revision else { return }
            self.problem = issue; self.validatedRevision = snapshot.revision; self.validating = false; self.validation = nil; self.validationTask = nil
        }
    }
    private func owns(_ ticket: UUID) -> Bool { active && operation == ticket }
}

/// A failed video remains selected until this exact file is saved or explicitly removed.
@MainActor @Observable public final class PendingPreviewSelection: Identifiable {
    public let id = UUID(), scope: MediaDraftScope, type: String, name: String
    @ObservationIgnored public var didChange: @MainActor () -> Void = {}
    public private(set) var pending = true { didSet { didChange() } }
    public private(set) var saving = false { didSet { didChange() } }
    public private(set) var active = true
    public private(set) var status = ""
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let write: @MainActor (URL) async throws -> MediaAdditionReceipt
    @ObservationIgnored private var operation: UUID?
    public var state: ListingSaveWorkflow.State { .init(dirty: pending, blocked: !active || saving, signature: id.uuidString) }
    public init(scope: MediaDraftScope, type: String, file: URL, save: @escaping @MainActor (URL) async throws -> MediaAdditionReceipt) {
        self.scope = scope; self.type = type; self.file = file; name = file.lastPathComponent; write = save
    }
    public func remove() { guard active, !saving else { return }; pending = false; status = "" }
    public func retire() { active = false; operation = nil; saving = false }
    public func save() async -> Bool {
        guard active, !saving, !Task.isCancelled else { return false }; guard pending else { return true }
        let ticket = UUID(); operation = ticket; saving = true; status = ""
        defer { if active, operation == ticket { operation = nil; saving = false } }
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        do {
            let receipt = try await write(file)
            guard receipt.scope == scope, receipt.count == 1 else { throw DraftFailure.invalid }
            guard active, operation == ticket else { return true }
            pending = false; status = "Preview added and saved on this Mac."; return true
        } catch {
            guard active, operation == ticket else { return false }
            if let failure = error as? PreviewFailure { status = failure.message }
            else if let failure = error as? DraftFailure { status = failure.message }
            else { status = "The app preview could not be saved on this Mac. The file is kept so you can try again." }
            return false
        }
    }
}
