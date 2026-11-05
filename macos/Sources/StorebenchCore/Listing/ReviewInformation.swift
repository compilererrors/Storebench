import CryptoKit
import Foundation

/// App Review Information for one Apple version: contact, demo account and notes, saved locally until published.
public struct ReviewInformation: Equatable, Sendable {
    public var contactFirstName = "", contactLastName = "", contactPhone = "", contactEmail = ""
    public var demoAccountRequired = false
    public var demoAccountName = "", demoAccountPassword = "", notes = ""
    public init() {}
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.json == rhs.json }

    static let limits: [(String, Int)] = [("contactFirstName", 100), ("contactLastName", 100), ("contactPhone", 100), ("contactEmail", 254), ("demoAccountName", 500), ("demoAccountPassword", 500), ("notes", 4000)]

    func value(_ key: String) -> String {
        switch key { case "contactFirstName": contactFirstName; case "contactLastName": contactLastName; case "contactPhone": contactPhone; case "contactEmail": contactEmail
        case "demoAccountName": demoAccountName; case "demoAccountPassword": demoAccountPassword; default: notes }
    }

    /// Validates App Review information: trimmed text within Apple's limits, a contact, and demo credentials only when required.
    public func validated() throws -> ReviewInformation {
        var result = ReviewInformation()
        for (key, limit) in Self.limits {
            let text = value(key)
            guard text.utf16.count <= limit, !text.unicodeScalars.contains(where: { $0.value < 0x20 && ![0x09, 0x0A, 0x0D].contains($0.value) }) else { throw PublishFailure.invalid("Check \(key): it must be text of at most \(limit) characters.") }
            let trimmed = TextSemantics.trim(text)
            switch key { case "contactFirstName": result.contactFirstName = trimmed; case "contactLastName": result.contactLastName = trimmed; case "contactPhone": result.contactPhone = trimmed
            case "contactEmail": result.contactEmail = trimmed; case "demoAccountName": result.demoAccountName = trimmed; case "demoAccountPassword": result.demoAccountPassword = trimmed; default: result.notes = trimmed }
        }
        result.demoAccountRequired = demoAccountRequired
        guard result.notes.utf8.count <= 4000 else { throw PublishFailure.invalid("App Review notes must be at most 4,000 UTF-8 bytes.") }
        guard !result.contactFirstName.isEmpty, !result.contactLastName.isEmpty, !result.contactPhone.isEmpty, TestFlightAccess.validEmail(result.contactEmail) else {
            throw PublishFailure.invalid("Enter the App Review contact name, phone and a valid email address.")
        }
        if result.demoAccountRequired && (result.demoAccountName.isEmpty || result.demoAccountPassword.isEmpty) { throw PublishFailure.invalid("Enter both demo account name and password, or choose No demo account required.") }
        if !result.demoAccountRequired { result.demoAccountName = ""; result.demoAccountPassword = "" }
        return result
    }

    /// App Store Connect's names for the required fields that are still empty, in the order its form shows them.
    public var missing: [String] {
        var result: [String] = []
        if demoAccountRequired {
            if TextSemantics.trim(demoAccountName).isEmpty { result.append("User name") }
            if TextSemantics.trim(demoAccountPassword).isEmpty { result.append("Password") }
        }
        for (value, label) in [(contactFirstName, "First name"), (contactLastName, "Last name"), (contactPhone, "Phone number")] where TextSemantics.trim(value).isEmpty { result.append(label) }
        if !TestFlightAccess.validEmail(TextSemantics.trim(contactEmail)) { result.append("Email") }
        return result
    }

    var json: JSONText {
        .object(Self.limits.map { ($0.0, .string(value($0.0))) } + [("demoAccountRequired", .bool(demoAccountRequired))])
    }

    init(_ value: JSONText?) {
        for (key, _) in Self.limits {
            let text = value?[key]?.text ?? ""
            switch key { case "contactFirstName": contactFirstName = text; case "contactLastName": contactLastName = text; case "contactPhone": contactPhone = text; case "contactEmail": contactEmail = text
            case "demoAccountName": demoAccountName = text; case "demoAccountPassword": demoAccountPassword = text; default: notes = text }
        }
        demoAccountRequired = value?["demoAccountRequired"] == .bool(true)
    }

    /// Shown in reviews; the demo password is never displayed.
    public var display: String {
        var lines = ["Review contact: \([contactFirstName, contactLastName].filter { !$0.isEmpty }.joined(separator: " ").isEmpty ? "Missing" : [contactFirstName, contactLastName].filter { !$0.isEmpty }.joined(separator: " "))",
                     "Email: \(contactEmail.isEmpty ? "Missing" : contactEmail)", "Phone: \(contactPhone.isEmpty ? "Missing" : contactPhone)", "Demo account required: \(demoAccountRequired ? "Yes" : "No")"]
        if demoAccountRequired { lines += ["Demo username: \(demoAccountName.isEmpty ? "Missing" : demoAccountName)", "Demo password: \(demoAccountPassword.isEmpty ? "Missing" : "Set")"] }
        lines.append("Notes: \(notes.isEmpty ? "Empty" : notes)")
        return lines.joined(separator: "\n")
    }
}

public struct ReviewAttachment: Equatable, Sendable { public let hash, fileName, ext: String; public let size: Int }

public struct ReviewInformationDraft: Equatable, Sendable {
    public var fields = ReviewInformation()
    public var sandbox: [SandboxException] = []
    public var attachment: ReviewAttachment?
    public let revision: Int
}

extension WorkspaceSession {
    func reviewDraftKey(_ accountId: String, _ appId: String, _ versionId: String) throws -> String {
        guard accountId.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil, appId.range(of: "^[0-9]+$", options: .regularExpression) != nil,
              versionId.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil else { throw PublishFailure.invalid("Invalid App Review draft identity.") }
        return "\(accountId):\(appId):\(versionId)"
    }

    public func reviewInformationDraft(accountId: String, appId: String, versionId: String) throws -> ReviewInformationDraft {
        let key = try reviewDraftKey(accountId, appId, versionId)
        return try storeAccess { store in
            guard let document = try store.document(namespace: "review_information_drafts", key: key) else { return ReviewInformationDraft(revision: 0) }
            let value = try JSONText.parse(document.payload)
            var draft = ReviewInformationDraft(fields: try ReviewInformation.decodeSaved(value["fields"]), sandbox: try SandboxException.decode(value["sandbox"]), revision: document.revision)
            draft.attachment = try ReviewAttachment.decode(value["attachment"])
            return draft
        }
    }

    /// Saves the draft only onto the revision the form loaded; an attachment file is encrypted into local media first.
    public func saveReviewInformationDraft(accountId: String, appId: String, versionId: String, fields: ReviewInformation, sandbox: [SandboxException]? = nil, attachment: (name: String, data: Data)?, keepAttachment: Bool, expectedRevision: Int,
                                           inheritedAttachment: ReviewAttachment? = nil, inheritFromVersionId: String? = nil) throws -> ReviewInformationDraft {
        let key = try reviewDraftKey(accountId, appId, versionId), checked = try fields.validated()
        guard expectedRevision >= 0 else { throw PublishFailure.invalid("Reload the App Review form before saving.") }
        let checkedSandbox = try sandbox.map(SandboxException.validate)
        let sourceKey = try inheritFromVersionId.map { source in
            guard source != versionId else { throw PublishFailure.invalid("Choose the previous version's attachment again before saving.") }
            return try reviewDraftKey(accountId, appId, source)
        }
        let mutex = "review_info_" + JSONText.string(key).rawSHA256.prefix(40)
        return try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("\(mutex).mutex")) {
                let current = try store.document(namespace: "review_information_drafts", key: key)
                guard (current?.revision ?? 0) == expectedRevision else { throw PublishFailure.invalid("App Review Information changed in another window. Reload and compare before saving.") }
                let currentValue = try current.map { try JSONText.parse($0.payload) }
                let storedSandbox = try checkedSandbox ?? SandboxException.decode(currentValue?["sandbox"])
                var saved: JSONText?
                var inheritedSource: JSONText?
                if let attachment {
                    guard !attachment.data.isEmpty, attachment.data.count <= ReviewAttachment.maximumBytes else { throw PublishFailure.invalid("Choose an attachment up to 50 MB.") }
                    let ext = try ReviewAttachment.validateUploadName(attachment.name)
                    let written = try media.write(attachment.data, limit: ReviewAttachment.maximumBytes)
                    saved = ReviewAttachment(hash: written.hash, fileName: attachment.name, ext: ext, size: written.length).json
                } else if keepAttachment, let existing = try ReviewAttachment.decode(currentValue?["attachment"]) { saved = existing.json }
                else if keepAttachment, let inheritedAttachment, let sourceKey {
                    guard current == nil, let source = try store.document(namespace: "review_information_drafts", key: sourceKey) else { throw PublishFailure.invalid("The previous version's attachment changed. Choose the file again.") }
                    let value = try JSONText.parse(source.payload)
                    guard try ReviewAttachment.decode(value["attachment"]) == inheritedAttachment, try media.metadata(inheritedAttachment.hash) == inheritedAttachment.size else { throw PublishFailure.invalid("The previous version's attachment changed or is unavailable. Choose the file again.") }
                    inheritedSource = inheritedAttachment.json; saved = inheritedAttachment.json
                } else if inheritedAttachment != nil || sourceKey != nil { throw PublishFailure.invalid("Choose the previous version's attachment again before saving.") }
                var value: [(String, JSONText)] = [("fields", checked.json), ("sandbox", .array(storedSandbox.map(\.json)))]
                if let saved { value.append(("attachment", saved)) }
                try store.transaction { now in
                    guard try now("review_information_drafts", key)?.revision == current?.revision else { throw PublishFailure.invalid("App Review Information changed in another window. Reload and compare before saving.") }
                    if let sourceKey, let inheritedSource {
                        guard let source = try now("review_information_drafts", sourceKey), try ReviewAttachment.decode(JSONText.parse(source.payload)["attachment"]) == ReviewAttachment.decode(inheritedSource) else { throw PublishFailure.invalid("The previous version's attachment changed. Choose the file again.") }
                    }
                    return [.put(namespace: "review_information_drafts", key: key, json: JSONText.object(value).data)]
                }
                guard let committed = try store.document(namespace: "review_information_drafts", key: key) else { throw PublishFailure.invalid("The local App Review save could not be confirmed.") }
                return ReviewInformationDraft(fields: checked, sandbox: storedSandbox, attachment: try ReviewAttachment.decode(saved), revision: committed.revision)
            }
        }
    }

    /// Plans the App Review information writes: contact, demo account and notes, plus a new attachment when one is saved.
    func planReviewInformation(_ planner: Planner) async throws -> String {
        let request = planner.request
        guard let version = try await appVersions(planner).first(where: { $0.id == request.versionId }) else { throw PublishFailure.invalid("Choose an Apple version belonging to this app.") }
        guard Apple.editable.contains(Apple.state(version)) else { throw PublishFailure.invalid("App Review Information cannot be edited in this Apple version's current state.") }
        let name = "\(Releases.platformName(version.attributes?["platform"]?.string ?? "")) \(version.attributes?["versionString"]?.string ?? "")"
        if let attachmentId = request.reviewAttachmentId {
            guard let detail = try await reviewDetail(versionId: version.id, client: planner.client) else { throw PublishFailure.invalid("This Apple version has no App Review attachments to remove.") }
            let attachments = try ReviewInformation.scopedAttachments(await planner.list("/v1/appStoreReviewDetails/\(detail.id)/appStoreReviewAttachments?limit=200"), detailId: detail.id)
            guard let attachment = attachments.first(where: { $0.id == attachmentId }) else { throw PublishFailure.invalid("The selected App Review attachment is no longer at Apple. Reload and choose again.") }
            let digest = try ReviewInformation.attachmentDigest(attachment, detailId: detail.id), fileName = attachment.attributes?["fileName"]?.string ?? "Attachment"
            planner.add(.api, method: "DELETE", path: [.string("appStoreReviewAttachments"), .string(attachment.id)], label: "Remove \(fileName) from App Review", detail: "\(name) · Only this Apple attachment will be removed.",
                        before: "\(fileName) · \(Apple.delivery(attachment).lowercased().replacingOccurrences(of: "_", with: " "))", after: "Removed",
                        guard: .object([("kind", .string("review-attachment-delete")), ("digest", .string(digest)), ("versionId", .string(version.id)), ("detailId", .string(detail.id))]))
            planner.notes.append("Apple allows removing an App Review attachment before submission. This review removes only the selected Apple file; local drafts are kept.")
            return "Remove App Review attachment · \(fileName)"
        }
        let draft = try reviewInformationDraft(accountId: request.accountId, appId: request.appId, versionId: version.id)
        guard draft.revision > 0 else { throw PublishFailure.invalid("Enter App Review Information and save it first.") }
        let fields = try draft.fields.validated()
        planner.evidence.append(.object([("draft", fields.json), ("sandbox", .array(draft.sandbox.map(\.json))), ("attachment", draft.attachment?.json ?? .null)]))
        let remote = try await reviewDetail(versionId: version.id, client: planner.client)
        if let remote { planner.evidence.append(.object([("reviewDetail", Planner.resource(remote))])) }
        let old = ReviewInformation(remote.map { Planner.resource($0)["attributes"] } ?? nil)
        var changes: [(String, JSONText)] = []
        let desired: [(String, JSONText)]
        if case .object(let pairs) = fields.json { desired = pairs } else { desired = [] }
        for (key, entry) in desired {
            let current = remote?.attributes?[key]
            let same: Bool
            switch entry { case .string(let text): same = current?.string == text; case .bool(let flag): same = current == .bool(flag); default: same = false }
            if !same { changes.append((key, entry)) }
        }
        var detailId: JSONText = remote.map { .string($0.id) } ?? .null
        if remote == nil {
            detailId = Apple.ref(planner.add(.api, method: "POST", path: [.string("appStoreReviewDetails")], label: "Add App Review Information", detail: "\(name) · Contact, sign-in and notes. Password contents are hidden in this review.",
                                             before: "No review information at Apple", after: fields.display,
                                             body: .object([("data", .object([("type", .string("appStoreReviewDetails")), ("attributes", fields.json), ("relationships", .object([("appStoreVersion", Apple.relationship("appStoreVersions", .string(version.id)))]))]))])))
        } else if !changes.isEmpty {
            planner.add(.api, method: "PATCH", path: [.string("appStoreReviewDetails"), .string(remote!.id)], label: "Update App Review Information", detail: "\(name) · Contact, sign-in and notes. Password contents are hidden in this review.",
                        before: old.display, after: fields.display, body: .object([("data", .object([("type", .string("appStoreReviewDetails")), ("id", .string(remote!.id)), ("attributes", .object(changes))]))]))
        }
        if let attachment = draft.attachment {
            let asset = try describeAsset(revisionId: version.id, hash: attachment.hash, storage: "review-attachment", ext: attachment.ext, fileName: attachment.fileName, accountId: request.accountId, appId: request.appId)
            var existing: [AppStoreConnectClient.Resource] = []
            if let remote {
                existing = try await planner.list("/v1/appStoreReviewDetails/\(remote.id)/appStoreReviewAttachments?limit=200")
                _ = try ReviewInformation.scopedAttachments(existing, detailId: remote.id)
            }
            if !existing.contains(where: { $0.attributes?["sourceFileChecksum"]?.string == asset["checksum"]?.text && $0.attributes?["fileName"]?.string == attachment.fileName && Apple.delivery($0) == "COMPLETE" }) {
                let reservation = planner.add(.api, method: "POST", path: [.string("appStoreReviewAttachments")], label: "Attach \(attachment.fileName) for App Review", detail: "\(String(format: "%.2f", Double(attachment.size) / 1_000_000)) MB · Existing Apple attachments are kept.",
                                              after: attachment.fileName, body: .object([("data", .object([("type", .string("appStoreReviewAttachments")), ("attributes", .object([("fileName", .string(attachment.fileName)), ("fileSize", .number(Double(attachment.size)))])),
                                                                                                         ("relationships", .object([("appStoreReviewDetail", Apple.relationship("appStoreReviewDetails", detailId))]))]))]))
                planner.steps[planner.steps.count - 1].group = reservation
                let id = Apple.ref(reservation)
                planner.add(.upload, path: [.string("appStoreReviewAttachments"), id], label: "Upload \(attachment.fileName)", detail: "Encrypted local attachment to Apple's reserved upload URL.", asset: asset, group: reservation)
                planner.add(.api, method: "PATCH", path: [.string("appStoreReviewAttachments"), id], label: "Complete \(attachment.fileName)", detail: "Ask Apple to verify the uploaded file.",
                            body: .object([("data", .object([("type", .string("appStoreReviewAttachments")), ("id", id), ("attributes", .object([("uploaded", .bool(true)), ("sourceFileChecksum", asset["checksum"]!)]))]))]), group: reservation)
                planner.add(.verify, path: [.string("appStoreReviewAttachments"), id], label: "Verify \(attachment.fileName)", detail: "Wait for Apple to process this attachment.", group: reservation)
            }
        }
        if !draft.sandbox.isEmpty { planner.notes.append("App Sandbox temporary exception notes are saved locally only. Copy them to this macOS version in App Store Connect: click Apps, select the app and click the macOS version in the sidebar. Apple's public API has no matching write operation.") }
        planner.notes.append("This saves App Review Information on the selected Apple version. It does not submit the version for review.")
        return "App Review Information · \(name)"
    }
}
