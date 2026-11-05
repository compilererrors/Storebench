import Foundation

/// An editor revision changes only after a save or an explicit choice in the latest-save comparison.
public struct ReviewInformationEditor: Sendable {
    public struct Change: Sendable, Identifiable { public let id, label, saved, edited: String }
    public var fields = ReviewInformation()
    public var sandbox: [SandboxException] = []
    public private(set) var snapshot: ReviewInformationSnapshot?
    public private(set) var latest: ReviewInformationSnapshot?
    public private(set) var attachment: ReviewAttachment?
    public private(set) var selectedFile: SelectedFiles.File?
    public private(set) var inheritedAttachmentFrom: String?
    private var baselineFields = ReviewInformation()
    private var baselineSandbox: [SandboxException] = []
    private var baselineAttachment: ReviewAttachment?
    public init() {}
    public var loaded: Bool { snapshot != nil }
    public var revision: Int { snapshot?.revision ?? 0 }
    public var dirty: Bool { loaded && (fields != baselineFields || sandbox != baselineSandbox || attachment != baselineAttachment || selectedFile != nil) }
    public var inputFingerprint: String { JSONText.array([fields.json, .array(sandbox.map(\.json)), attachment?.json ?? .null, selectedFile.map { .string($0.name) } ?? .null]).sha256 }
    public var attachmentName: String { selectedFile?.name ?? attachment?.fileName ?? "None" }
    public var upload: (name: String, data: Data)? { selectedFile.map { ($0.name, $0.data) } }

    public mutating func load(_ value: ReviewInformationSnapshot) {
        snapshot = value; latest = nil; fields = value.fields; sandbox = value.sandbox; attachment = value.attachment
        baselineFields = fields; baselineSandbox = sandbox; baselineAttachment = attachment; selectedFile = nil; inheritedAttachmentFrom = value.inheritedAttachmentFrom
    }
    public mutating func stage(_ file: SelectedFiles.File) throws {
        _ = try ReviewAttachment.validateUploadName(file.name)
        guard !file.data.isEmpty, file.data.count <= ReviewAttachment.maximumBytes else { throw PublishFailure.invalid("Choose an attachment up to 50 MB.") }
        selectedFile = file; attachment = nil; inheritedAttachmentFrom = nil
    }
    public mutating func removeAttachment() { selectedFile = nil; attachment = nil; inheritedAttachmentFrom = nil }
    public mutating func readLatest(_ value: ReviewInformationSnapshot) throws {
        guard let snapshot, value.accountId == snapshot.accountId, value.appId == snapshot.appId, value.versionId == snapshot.versionId else { throw PublishFailure.invalid("The latest save belongs to another version. Your entries remain here.") }
        latest = value
    }
    public var changes: [Change]? {
        guard let latest else { return nil }
        var rows = ReviewInformation.limits.filter { $0.0 != "demoAccountPassword" }.map { key, _ in
            Change(id: key, label: Self.label(key), saved: latest.fields.value(key), edited: fields.value(key))
        }.filter { !$0.saved.utf8.elementsEqual($0.edited.utf8) }
        if latest.fields.demoAccountRequired != fields.demoAccountRequired { rows.append(Change(id: "required", label: "Sign-in required", saved: latest.fields.demoAccountRequired ? "Yes" : "No", edited: fields.demoAccountRequired ? "Yes" : "No")) }
        let savedPassword = latest.demoPasswordSaved ? "Saved password" : "No saved password"
        let editedPassword = !fields.demoAccountRequired ? "No demo password" : !fields.demoAccountPassword.isEmpty ? "Replacement password entered" : savedPassword
        if !savedPassword.utf8.elementsEqual(editedPassword.utf8) { rows.append(Change(id: "password", label: "Demo password", saved: savedPassword, edited: editedPassword)) }
        let savedSandbox = latest.sandbox.map(\.clipboardText).joined(separator: "\n\n"), editedSandbox = sandbox.map(\.clipboardText).joined(separator: "\n\n")
        if !savedSandbox.utf8.elementsEqual(editedSandbox.utf8) { rows.append(Change(id: "sandbox", label: "Sandbox exceptions", saved: savedSandbox, edited: editedSandbox)) }
        let savedAttachment = latest.attachment?.fileName ?? "None"
        if selectedFile != nil || latest.attachment != attachment { rows.append(Change(id: "attachment", label: "Local attachment", saved: savedAttachment, edited: attachmentName)) }
        return rows
    }
    public mutating func chooseLatest(keepEdits: Bool) {
        guard let latest else { return }
        if !keepEdits { load(latest); return }
        let fileWasEdited = selectedFile != nil || attachment != baselineAttachment
        baselineFields = latest.fields; baselineSandbox = latest.sandbox; baselineAttachment = latest.attachment; snapshot = latest
        if !fileWasEdited { attachment = latest.attachment; inheritedAttachmentFrom = latest.inheritedAttachmentFrom }
        self.latest = nil
    }
    public mutating func acknowledge(_ receipt: ReviewInformationSaveReceipt) throws {
        guard let old = snapshot, old.accountId == receipt.accountId, old.appId == receipt.appId, old.versionId == receipt.versionId else { throw PublishFailure.invalid("The save belongs to another version. Reload its editor.") }
        load(ReviewInformationSnapshot(accountId: old.accountId, appId: old.appId, versionId: old.versionId, versions: old.versions, fields: receipt.fields, demoPasswordSaved: receipt.demoPasswordSaved, revision: receipt.revision,
                                       sandbox: receipt.sandbox, attachment: receipt.attachment, inheritedAttachmentFrom: nil, reusedFrom: nil, unavailablePreviousAttachments: [], appleAttachments: old.appleAttachments, layout: old.layout))
    }
    /// Refreshes remote presentation after publishing without changing the editor revision or unsaved inputs.
    public mutating func refreshApple(_ value: ReviewInformationSnapshot) throws {
        guard let old = snapshot, old.accountId == value.accountId, old.appId == value.appId, old.versionId == value.versionId else { throw PublishFailure.invalid("Choose the current version before refreshing its attachments.") }
        snapshot = ReviewInformationSnapshot(accountId: old.accountId, appId: old.appId, versionId: old.versionId, versions: value.versions, fields: old.fields, demoPasswordSaved: old.demoPasswordSaved, revision: old.revision,
                                             sandbox: old.sandbox, attachment: old.attachment, inheritedAttachmentFrom: old.inheritedAttachmentFrom, reusedFrom: old.reusedFrom, unavailablePreviousAttachments: old.unavailablePreviousAttachments, appleAttachments: value.appleAttachments, layout: old.layout)
    }
    static func label(_ key: String) -> String {
        switch key { case "contactFirstName": "First name"; case "contactLastName": "Last name"; case "contactPhone": "Phone"; case "contactEmail": "Email"; case "demoAccountName": "User name"; default: "Notes" }
    }
}
