import Foundation

public struct ReviewInformationVersion: Sendable, Identifiable, Equatable {
    public let id, name, platform, state: String
    public var editable: Bool { Apple.editable.contains(state) }
    public init(id: String, name: String, platform: String, state: String) { self.id = id; self.name = name; self.platform = platform; self.state = state }
}

public struct AppleReviewAttachment: Sendable, Identifiable, Equatable {
    public let id, fileName, state: String
}

/// Presentation contains only a saved-password flag; the saved password never reaches an input.
public struct ReviewInformationSnapshot: Sendable {
    public let accountId, appId, versionId: String
    public let versions: [ReviewInformationVersion]
    public let fields: ReviewInformation
    public let demoPasswordSaved: Bool
    public let revision: Int
    public let sandbox: [SandboxException]
    public let attachment: ReviewAttachment?
    public let inheritedAttachmentFrom, reusedFrom: String?
    public let unavailablePreviousAttachments: [String]
    public let appleAttachments: [AppleReviewAttachment]
    public let layout: ReviewInformationLayout
    public var version: ReviewInformationVersion? { versions.first { $0.id == versionId } }
    public init(accountId: String, appId: String, versionId: String, versions: [ReviewInformationVersion], fields: ReviewInformation, demoPasswordSaved: Bool, revision: Int, sandbox: [SandboxException], attachment: ReviewAttachment?, inheritedAttachmentFrom: String?, reusedFrom: String?, unavailablePreviousAttachments: [String], appleAttachments: [AppleReviewAttachment], layout: ReviewInformationLayout) {
        self.accountId = accountId; self.appId = appId; self.versionId = versionId; self.versions = versions; self.fields = fields.hiddenPassword; self.demoPasswordSaved = demoPasswordSaved; self.revision = revision
        self.sandbox = sandbox; self.attachment = attachment; self.inheritedAttachmentFrom = inheritedAttachmentFrom; self.reusedFrom = reusedFrom; self.unavailablePreviousAttachments = unavailablePreviousAttachments; self.appleAttachments = appleAttachments; self.layout = layout
    }
}

/// A successful local save remains acknowledged even when Apple's review preparation fails.
public struct ReviewInformationSaveReceipt: Sendable {
    public let accountId, appId, versionId: String
    public let revision: Int
    public let fields: ReviewInformation
    public let demoPasswordSaved: Bool
    public let sandbox: [SandboxException]
    public let attachment: ReviewAttachment?
}

public struct ReviewInformationPreparation: Sendable {
    public let saved: ReviewInformationSaveReceipt
    public let review: PublishReview?
    public let issue: String?
}

extension ReviewInformation {
    static func priorVersions(_ versions: [AppStoreConnectClient.Resource], versionId: String) -> [AppStoreConnectClient.Resource] {
        guard let selected = versions.first(where: { $0.id == versionId }) else { return [] }
        func number(_ source: String) -> Double {
            let value = TextSemantics.trim(source)
            if value.isEmpty { return 0 }
            for (prefix, radix) in [("0x", 16), ("0b", 2), ("0o", 8)] where value.lowercased().hasPrefix(prefix) {
                var result: Double = 0
                let digits = value.dropFirst(2)
                guard !digits.isEmpty else { return 0 }
                for character in digits { guard let digit = character.hexDigitValue, digit < radix else { return 0 }; result = result * Double(radix) + Double(digit) }
                return result
            }
            guard value.range(of: #"^[+-]?(?:Infinity|(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)$"#, options: .regularExpression) != nil, let result = Double(value), !result.isNaN else { return 0 }
            return result
        }
        func compare(_ lhs: String, _ rhs: String) -> Int {
            let left = lhs.split(separator: ".", omittingEmptySubsequences: false).map { number(String($0)) }
            let right = rhs.split(separator: ".", omittingEmptySubsequences: false).map { number(String($0)) }
            for index in 0..<max(left.count, right.count) {
                let difference = (index < left.count ? left[index] : 0) - (index < right.count ? right[index] : 0)
                if difference != 0 && !difference.isNaN { return difference > 0 ? 1 : -1 }
            }
            return 0
        }
        return Array(versions.enumerated().filter { _, item in
            item.id != versionId && item.attributes?["platform"] == selected.attributes?["platform"] && compare(item.attributes?["versionString"]?.string ?? "", selected.attributes?["versionString"]?.string ?? "") < 0
        }.sorted { lhs, rhs in
            let order = compare(lhs.element.attributes?["versionString"]?.string ?? "", rhs.element.attributes?["versionString"]?.string ?? "")
            return order == 0 ? lhs.offset < rhs.offset : order > 0
        }.prefix(10).map(\.element))
    }

    static func scopedAttachments(_ resources: [AppStoreConnectClient.Resource], detailId: String) throws -> [AppStoreConnectClient.Resource] {
        var seen = Set<String>()
        guard resources.allSatisfy({ $0.type == "appStoreReviewAttachments" && !$0.id.isEmpty && seen.insert($0.id).inserted && Apple.within($0, "appStoreReviewDetail", "appStoreReviewDetails", detailId) }) else {
            throw PublishFailure.invalid("Apple returned incomplete, duplicate or unrelated App Review attachments.")
        }
        return resources
    }
    static func attachmentSnapshot(_ item: AppStoreConnectClient.Resource, detailId: String) throws -> JSONText {
        _ = try scopedAttachments([item], detailId: detailId)
        guard let name = item.attributes?["fileName"]?.string, !name.isEmpty, case .number(let size)? = item.attributes?["fileSize"], size.isFinite, size >= 1, size <= 9_007_199_254_740_991, size.rounded(.towardZero) == size,
              case .object(let delivery)? = item.attributes?["assetDeliveryState"], let state = delivery["state"]?.string, !state.isEmpty else { throw PublishFailure.invalid("Apple returned invalid App Review attachment information.") }
        let checksum: JSONText
        switch item.attributes?["sourceFileChecksum"] {
        case .string(let text)?: checksum = .string(text)
        case nil, .null?: checksum = .null
        default: throw PublishFailure.invalid("Apple returned invalid App Review attachment information.")
        }
        return .array([.string(item.id), .string(name), .number(size), checksum, .string(state)])
    }
    public static func attachmentDigest(_ item: AppStoreConnectClient.Resource, detailId: String) throws -> String { try attachmentSnapshot(item, detailId: detailId).sha256 }
}

extension WorkspaceSession {
    private func reviewSelection(account: Account, appId: String, versionId: String?, client: AppStoreConnectClient) async throws -> (versions: [AppStoreConnectClient.Resource], version: AppStoreConnectClient.Resource, remote: AppStoreConnectClient.Resource?) {
        guard account.appIds.contains(appId) else { throw PublishFailure.invalid("Choose a configured app and Apple version.") }
        try requirePublishingAccount(account, appId: appId, client: client)
        let versions = try await client.list("/v1/apps/\(appId)/appStoreVersions?include=app&limit=200")
        var seen = Set<String>()
        guard versions.allSatisfy({ $0.type == "appStoreVersions" && $0.id.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil && seen.insert($0.id).inserted && Apple.owned($0, "app", "apps", appId) }) else { throw PublishFailure.invalid("Apple returned versions outside the selected app.") }
        let version: AppStoreConnectClient.Resource?
        if let versionId, !versionId.isEmpty { version = versions.first { $0.id == versionId } }
        else { version = versions.first { Apple.editable.contains(Apple.state($0)) } ?? versions.first }
        guard let version else { throw PublishFailure.invalid("Choose an Apple version belonging to this app.") }
        return (versions, version, try await reviewDetail(versionId: version.id, client: client))
    }
    private func previousReviewInformation(versions: [AppStoreConnectClient.Resource], versionId: String, client: AppStoreConnectClient) async throws -> (version: AppStoreConnectClient.Resource, detail: AppStoreConnectClient.Resource)? {
        for version in ReviewInformation.priorVersions(versions, versionId: versionId) {
            if let detail = try await reviewDetail(versionId: version.id, client: client) { return (version, detail) }
        }
        return nil
    }
    private func reviewVersion(_ version: AppStoreConnectClient.Resource) -> ReviewInformationVersion {
        let platform = version.attributes?["platform"]?.string ?? ""
        return ReviewInformationVersion(id: version.id, name: "\(Releases.platformName(platform)) \(version.attributes?["versionString"]?.string ?? "")", platform: platform, state: Apple.state(version))
    }
    private func reviewAttachments(detailId: String, client: AppStoreConnectClient) async throws -> [AppStoreConnectClient.Resource] {
        try ReviewInformation.scopedAttachments(await client.list("/v1/appStoreReviewDetails/\(detailId)/appStoreReviewAttachments?limit=200"), detailId: detailId)
    }
    public func reviewInformationSnapshot(account: Account, appId: String, versionId: String? = nil, client: AppStoreConnectClient) async throws -> ReviewInformationSnapshot {
        let selected = try await reviewSelection(account: account, appId: appId, versionId: versionId, client: client)
        let saved = try reviewInformationDraft(accountId: account.id, appId: appId, versionId: selected.version.id)
        let prior = saved.revision == 0 && selected.remote == nil ? try await previousReviewInformation(versions: selected.versions, versionId: selected.version.id, client: client) : nil
        let priorDraft = try prior.map { try reviewInformationDraft(accountId: account.id, appId: appId, versionId: $0.version.id) }
        let raw = saved.revision > 0 ? saved.fields : ReviewInformation((selected.remote ?? prior?.detail).map { Planner.resource($0)["attributes"] } ?? nil)
        let currentAttachments: [AppStoreConnectClient.Resource]
        if let remote = selected.remote { currentAttachments = try await reviewAttachments(detailId: remote.id, client: client) } else { currentAttachments = [] }
        let inherited = saved.revision == 0 ? priorDraft?.attachment : nil
        let attachment = saved.attachment ?? inherited
        let previousAttachments = prior != nil && attachment == nil ? try await reviewAttachments(detailId: prior!.detail.id, client: client) : []
        let layout = try reviewInformationLayout(accountId: account.id, appId: appId)
        try Task.checkCancellation()
        return ReviewInformationSnapshot(accountId: account.id, appId: appId, versionId: selected.version.id, versions: selected.versions.map(reviewVersion), fields: raw.hiddenPassword, demoPasswordSaved: !raw.demoAccountPassword.isEmpty,
                                         revision: saved.revision, sandbox: saved.revision > 0 ? saved.sandbox : priorDraft?.sandbox ?? [], attachment: attachment, inheritedAttachmentFrom: inherited == nil ? nil : prior?.version.id,
                                         reusedFrom: prior.map { reviewVersion($0.version).name }, unavailablePreviousAttachments: previousAttachments.map { $0.attributes?["fileName"]?.string ?? "Attachment" },
                                         appleAttachments: currentAttachments.map { AppleReviewAttachment(id: $0.id, fileName: $0.attributes?["fileName"]?.string ?? "Attachment", state: Apple.delivery($0).isEmpty ? "Unknown" : Apple.delivery($0)) }, layout: layout)
    }

    public func saveReviewInformationLocally(account: Account, appId: String, versionId: String, fields: ReviewInformation, sandbox: [SandboxException], attachment: (name: String, data: Data)?, keepAttachment: Bool,
                                            expectedRevision: Int, inheritedAttachment: ReviewAttachment? = nil, inheritFromVersionId: String? = nil, client: AppStoreConnectClient) async throws -> ReviewInformationSaveReceipt {
        let selected = try await reviewSelection(account: account, appId: appId, versionId: versionId, client: client)
        let previous = try reviewInformationDraft(accountId: account.id, appId: appId, versionId: versionId)
        guard expectedRevision == previous.revision else { throw PublishFailure.invalid("App Review Information changed in another window. Reload and compare before saving.") }
        let prior = selected.remote == nil && previous.revision == 0 ? try await previousReviewInformation(versions: selected.versions, versionId: versionId, client: client) : nil
        var desired = fields
        if desired.demoAccountRequired && desired.demoAccountPassword.isEmpty {
            let remote = ReviewInformation(selected.remote.map { Planner.resource($0)["attributes"] } ?? nil), old = ReviewInformation(prior.map { Planner.resource($0.detail)["attributes"] } ?? nil)
            desired.demoAccountPassword = !previous.fields.demoAccountPassword.isEmpty ? previous.fields.demoAccountPassword : !remote.demoAccountPassword.isEmpty ? remote.demoAccountPassword : old.demoAccountPassword
        }
        if let inheritFromVersionId, inheritFromVersionId != prior?.version.id { throw PublishFailure.invalid("The previous Apple version changed. Reload before saving its attachment.") }
        try Task.checkCancellation()
        let saved = try saveReviewInformationDraft(accountId: account.id, appId: appId, versionId: versionId, fields: desired, sandbox: sandbox, attachment: attachment, keepAttachment: keepAttachment, expectedRevision: expectedRevision,
                                                  inheritedAttachment: inheritedAttachment, inheritFromVersionId: inheritFromVersionId)
        return ReviewInformationSaveReceipt(accountId: account.id, appId: appId, versionId: versionId, revision: saved.revision, fields: saved.fields.hiddenPassword, demoPasswordSaved: !saved.fields.demoAccountPassword.isEmpty, sandbox: saved.sandbox, attachment: saved.attachment)
    }
    public func saveAndPrepareReviewInformation(account: Account, appId: String, versionId: String, fields: ReviewInformation, sandbox: [SandboxException], attachment: (name: String, data: Data)?, keepAttachment: Bool,
                                               expectedRevision: Int, inheritedAttachment: ReviewAttachment? = nil, inheritFromVersionId: String? = nil, client: AppStoreConnectClient) async throws -> ReviewInformationPreparation {
        let saved = try await saveReviewInformationLocally(account: account, appId: appId, versionId: versionId, fields: fields, sandbox: sandbox, attachment: attachment, keepAttachment: keepAttachment, expectedRevision: expectedRevision,
                                                         inheritedAttachment: inheritedAttachment, inheritFromVersionId: inheritFromVersionId, client: client)
        do {
            let review = try await preparePublishing(account: account, request: PublishRequest(accountId: account.id, appId: appId, scope: .reviewInfo, versionId: versionId), client: client)
            return ReviewInformationPreparation(saved: saved, review: review, issue: nil)
        } catch { return ReviewInformationPreparation(saved: saved, review: nil, issue: (error as? PublishFailure)?.message ?? "The local draft was saved, but the Apple review could not be prepared. Retry from this saved revision.") }
    }

    public func reviewInformationLayout(accountId: String, appId: String) throws -> ReviewInformationLayout {
        let key = try reviewDraftKey(accountId, appId, "view")
        return try storeAccess { store in
            guard let document = try store.document(namespace: "review_information_layout", key: key) else { return ReviewInformationLayout() }
            return try ReviewInformationLayout(JSONText.parse(document.payload))
        }
    }
    public func saveReviewInformationLayout(accountId: String, appId: String, section: ReviewInformationLayout.Section, expanded: Bool) throws -> ReviewInformationLayout {
        let key = try reviewDraftKey(accountId, appId, "view"), mutex = "review_info_view_" + JSONText.string(key).rawSHA256.prefix(40)
        return try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("\(mutex).mutex")) {
                let current = try store.document(namespace: "review_information_layout", key: key)
                var value = try current.map { try ReviewInformationLayout(JSONText.parse($0.payload)) } ?? ReviewInformationLayout()
                if section == .access { value.access = expanded } else { value.sandbox = expanded }
                try store.transaction { now in
                    guard try now("review_information_layout", key)?.revision == current?.revision else { throw PublishFailure.invalid("The App Review layout changed. Toggle the section again to retry.") }
                    return [.put(namespace: "review_information_layout", key: key, json: value.json.data)]
                }
                return value
            }
        }
    }
}
