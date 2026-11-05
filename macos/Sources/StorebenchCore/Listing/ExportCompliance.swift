import Foundation

public struct EncryptionAnswers: Equatable, Sendable {
    public var appDescription = "", containsProprietaryCryptography = false, containsThirdPartyCryptography = false, availableOnFrenchStore = false
    public init() {}
    var json: JSONText {
        .object([("appDescription", .string(appDescription)), ("containsProprietaryCryptography", .bool(containsProprietaryCryptography)),
                 ("containsThirdPartyCryptography", .bool(containsThirdPartyCryptography)), ("availableOnFrenchStore", .bool(availableOnFrenchStore))])
    }
    var summary: String {
        ["App description: \(appDescription)", "Proprietary cryptography: \(containsProprietaryCryptography ? "Yes" : "No")",
         "Third-party cryptography: \(containsThirdPartyCryptography ? "Yes" : "No")", "Available on the French store: \(availableOnFrenchStore ? "Yes" : "No")"].joined(separator: "\n")
    }
    func validated() throws -> EncryptionAnswers {
        let trimmed = appDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf16.count <= 4000, !appDescription.unicodeScalars.contains(where: { ($0.value < 0x20 && ![0x09, 0x0A, 0x0D].contains($0.value)) || $0.value == 0x7f }) else {
            throw PublishFailure.invalid("Describe this app's encryption use in 1–4,000 characters.")
        }
        var result = self; result.appDescription = trimmed; return result
    }
}

/// The encryption a build uses, in the wording of App Store Connect's export compliance documentation.
public enum EncryptionAlgorithms: String, CaseIterable, Sendable {
    /// In App Store Connect's order and words for "What type of encryption algorithms does your app implement?"
    case proprietary, standard, both, operatingSystem = "operating-system"
    public static let question = "What type of encryption algorithms does your app implement?"
    public var label: String {
        switch self {
        case .proprietary: "Encryption algorithms that are proprietary or not accepted as standard by international standard bodies (IEEE, IETF, ITU, etc.)"
        case .standard: "Standard encryption algorithms instead of, or in addition to, using or accessing the encryption within Apple's operating system"
        case .both: "Both algorithms mentioned above"
        case .operatingSystem: "None of the algorithms mentioned above"
        }
    }
    /// Encryption limited to the operating system is exempt: the build's answer is No and it needs no declaration.
    public var exempt: Bool { self == .operatingSystem }
    /// Whether Apple keeps a declaration for these answers. Apple creates one only for proprietary encryption, or for standard
    /// encryption on the App Store in France; App Store Connect saves standard encryption elsewhere as the build's answer alone.
    public func needsDeclaration(availableOnFrenchStore: Bool) -> Bool { !exempt && ([.proprietary, .both].contains(self) || availableOnFrenchStore) }
    public func answers(description: String, availableOnFrenchStore: Bool) -> EncryptionAnswers {
        var answers = EncryptionAnswers()
        answers.appDescription = description; answers.availableOnFrenchStore = availableOnFrenchStore
        answers.containsThirdPartyCryptography = [.standard, .both].contains(self); answers.containsProprietaryCryptography = [.proprietary, .both].contains(self)
        return answers
    }
    /// The description Apple's API needs for a declaration, built from the answers. App Store Connect does not ask for one, so
    /// Storebench asks only App Store Connect's questions and shows this text in the review.
    public func description(availableOnFrenchStore: Bool) -> String {
        let uses = switch self {
        case .proprietary: "Uses proprietary encryption algorithms or ones not accepted as standard by international standard bodies."
        case .standard: "Uses standard encryption algorithms in addition to the encryption within Apple's operating system."
        case .both: "Uses proprietary and standard encryption algorithms in addition to the encryption within Apple's operating system."
        case .operatingSystem: "Uses only the encryption within Apple's operating system."
        }
        return uses + (availableOnFrenchStore ? " Available on the App Store in France." : " Not available on the App Store in France.")
    }
    /// The documents Apple asks for, as its export compliance documentation lists them.
    public func documentation(availableOnFrenchStore: Bool) -> String {
        switch (exempt, [.proprietary, .both].contains(self), availableOnFrenchStore) {
        case (true, _, _), (false, false, false): "No documentation required in App Store Connect."
        case (false, false, true): "Apple asks for your French encryption declaration."
        case (false, true, false): "Apple asks for your US Commodity Classification Automated Tracking System (CCATS)."
        case (false, true, true): "Apple asks for your US Commodity Classification Automated Tracking System (CCATS) and your French encryption declaration."
        }
    }
}

/// App Store Connect's export compliance questions for a build, in its order: the algorithms, then, for encryption that
/// needs a declaration, availability in France. A description is optional, as App Store Connect asks for none.
public struct EncryptionQuestionnaire: Equatable, Sendable {
    public var algorithms = "", france = "", description = ""
    public init() {}
    public var chosen: EncryptionAlgorithms? { EncryptionAlgorithms(rawValue: algorithms) }
    public var started: Bool { !algorithms.isEmpty || !france.isEmpty || !description.isEmpty }
    /// The next answer still needed, or nil when the review can be prepared.
    public var missing: String? {
        guard let chosen else { return "Choose the type of encryption algorithms your app implements." }
        if chosen.exempt { return nil }
        if france.isEmpty { return "Choose whether your app is going to be available on the App Store in France." }
        return nil
    }
    /// Whether Save keeps a declaration at Apple; nil until the questions are answered.
    public var needsDeclaration: Bool? {
        guard missing == nil, let chosen else { return nil }
        return chosen.needsDeclaration(availableOnFrenchStore: france == "yes")
    }
    public var nextStep: String {
        if let missing { return missing }
        guard let chosen else { return "" }
        if chosen.exempt { return "This build then doesn't use non-exempt encryption. Save answers No for this build; no declaration is needed. " + chosen.documentation(availableOnFrenchStore: false) }
        if needsDeclaration == false { return "Apple keeps no declaration for standard encryption outside France, so Save answers No to non-exempt encryption for this build, as App Store Connect does. " + chosen.documentation(availableOnFrenchStore: false) }
        return "Save answers Yes for this build and attaches a declaration with these answers. " + chosen.documentation(availableOnFrenchStore: france == "yes")
    }
    /// The answers as saved locally per build, so they stay until Apple has them.
    public var json: JSONText { .object([("algorithms", .string(algorithms)), ("france", .string(france))]) }
    public init(json: JSONText) {
        if let value = json["algorithms"]?.text, EncryptionAlgorithms(rawValue: value) != nil { algorithms = value }
        if let value = json["france"]?.text, ["yes", "no"].contains(value) { france = value }
    }
    public var answers: EncryptionAnswers? {
        guard needsDeclaration == true, let chosen else { return nil }
        let written = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return chosen.answers(description: written.isEmpty ? chosen.description(availableOnFrenchStore: france == "yes") : written, availableOnFrenchStore: france == "yes")
    }
}

public struct EncryptionDeclaration: Identifiable, Equatable, Sendable {
    public let id, state, platform, description: String
    public init(id: String, state: String, platform: String, description: String) { self.id = id; self.state = state; self.platform = platform; self.description = description }
    public func fits(_ buildPlatform: String) -> Bool { TestFlightEncryption.declarationFits(platform, platform: buildPlatform) }
}

extension WorkspaceSession {
    static let declarationStates: Set<String> = ["CREATED", "IN_REVIEW", "APPROVED", "INVALID", "EXPIRED", "REJECTED"], activeDeclarationStates: Set<String> = ["CREATED", "IN_REVIEW", "APPROVED"]

    static func scopedDeclarations(_ resources: [AppStoreConnectClient.Resource], appId: String) throws -> [AppStoreConnectClient.Resource] {
        var ids = Set<String>()
        for item in resources {
            if Planner.resource(item)["relationships"]?["app"]?["data"] != nil {
                guard Apple.owned(item, "app", "apps", appId) else { throw PublishFailure.invalid("Apple returned encryption declarations outside the selected app.") }
            }
            guard item.type == "appEncryptionDeclarations", !item.id.isEmpty, ids.insert(item.id).inserted, item.attributes?["appEncryptionDeclarationState"].map({ declarationStates.contains($0.string ?? "") }) ?? true else {
                throw PublishFailure.invalid("Apple returned ambiguous encryption declarations for this app.")
            }
        }
        return resources
    }

    static let answerFields = ["appDescription", "containsProprietaryCryptography", "containsThirdPartyCryptography", "availableOnFrenchStore"]
    /// The four answers Apple keeps on a declaration, compared with the answers a review created it from.
    static func answersDigest(_ declaration: AppStoreConnectClient.Resource) -> String {
        JSONText.object(answerFields.map { key in
            switch declaration.attributes?[key] { case .string(let text)?: (key, .string(text)); case .bool(let flag)?: (key, .bool(flag)); default: (key, .null) }
        }).sha256
    }

    static func declarationsDigest(_ resources: [AppStoreConnectClient.Resource], appId: String) -> String {
        let snapshot = resources.sorted { $0.id.compare($1.id, locale: Locale(identifier: "en")) == .orderedAscending }.map { item -> JSONText in
            let attributes = Planner.resource(item)["attributes"] ?? .object([])
            return .object([("id", .string(item.id)), ("attributes", PricingModels.canonical(attributes))])
        }
        return JSONText.object([("appId", .string(appId)), ("snapshot", .array(snapshot))]).sha256
    }

    /// The app's encryption declarations. Apple lists them under the app; where that path is not available, its filtered
    /// list of all declarations gives the same records.
    static func declarationReads(_ appId: String, _ list: (String) async throws -> [AppStoreConnectClient.Resource]) async throws -> [AppStoreConnectClient.Resource] {
        do { return try await list("/v1/apps/\(appId)/appEncryptionDeclarations?limit=200") }
        catch AppStoreConnectClient.Failure.status(let code) where code == 404 || code == 410 { return try await list("/v1/appEncryptionDeclarations?filter%5Bapp%5D=\(appId)&limit=200") }
    }
    /// The declaration a build has, read as its relationship. A build without one has no linkage, which Apple can also answer with 404.
    static func declarationLink(_ buildId: String, _ get: (String) async throws -> [AppStoreConnectClient.Resource]) async throws -> [AppStoreConnectClient.Resource] {
        do { return try await get("/v1/builds/\(buildId)/relationships/appEncryptionDeclaration") }
        catch AppStoreConnectClient.Failure.status(404) { return [] }
    }

    /// The export compliance answers given for a build, kept locally until Apple records them so they never have to be given twice.
    public func encryptionAnswers(accountId: String, appId: String, buildId: String) throws -> EncryptionQuestionnaire? {
        try storeAccess { store in
            try store.document(namespace: "encryption_answers", key: "\(accountId):\(appId):\(buildId)").map { EncryptionQuestionnaire(json: try JSONText.parse($0.payload)) }
        }
    }
    /// Saves the build's answers; unstarted answers remove them.
    public func saveEncryptionAnswers(_ answers: EncryptionQuestionnaire, accountId: String, appId: String, buildId: String) throws {
        let key = "\(accountId):\(appId):\(buildId)"
        try storeAccess { store in
            try store.transaction { _ in [answers.started ? .put(namespace: "encryption_answers", key: key, json: answers.json.data) : .delete(namespace: "encryption_answers", key: key)] }
        }
    }

    public func encryptionDeclarations(appId: String, client: AppStoreConnectClient) async throws -> [EncryptionDeclaration] {
        try Self.scopedDeclarations(try await WorkspaceSession.declarationReads(appId) { try await client.list($0) }, appId: appId).map { item in
            EncryptionDeclaration(id: item.id, state: item.attributes?["appEncryptionDeclarationState"]?.string ?? "", platform: item.attributes?["platform"]?.string ?? "",
                                  description: item.attributes?["appDescription"]?.string ?? "")
        }
    }

    func planEncryptionDeclaration(_ planner: Planner) async throws -> String {
        let request = planner.request
        guard let answers = try request.encryptionDeclaration?.validated() else { throw PublishFailure.invalid("Complete the export compliance declaration before review.") }
        let current = try Self.scopedDeclarations(try await WorkspaceSession.declarationReads(request.appId) { try await planner.list($0) }, appId: request.appId)
        for item in current {
            let state = item.attributes?["appEncryptionDeclarationState"]?.string
            guard let state else { throw PublishFailure.invalid("Apple returned an incomplete encryption declaration. Check it under App Information → App Encryption Documentation in App Store Connect before creating another.") }
            if Self.activeDeclarationStates.contains(state) {
                guard let text = item.attributes?["appDescription"]?.string, !text.trimmingCharacters(in: .whitespaces).isEmpty,
                      ["containsProprietaryCryptography", "containsThirdPartyCryptography", "availableOnFrenchStore"].allSatisfy({ if case .bool? = item.attributes?[$0] { return true }; return false }) else {
                    throw PublishFailure.invalid("Apple returned an incomplete encryption declaration. Check it under App Information → App Encryption Documentation in App Store Connect before creating another.")
                }
            }
        }
        let matching = current.first { item in
            Self.activeDeclarationStates.contains(item.attributes?["appEncryptionDeclarationState"]?.string ?? "") && Self.answersDigest(item) == answers.json.sha256
        }
        var created: String?
        if matching == nil {
            // Apple refuses to create a declaration for standard encryption outside France; the build's answer alone covers it.
            guard answers.containsProprietaryCryptography || answers.containsThirdPartyCryptography && answers.availableOnFrenchStore else {
                throw PublishFailure.invalid("Apple keeps no declaration for standard encryption outside France. Save this on the build's Export Compliance questions instead; App Store Connect records it as the build's answer.")
            }
            created = planner.add(.api, method: "POST", path: [.string("appEncryptionDeclarations")], label: "Create app encryption declaration", detail: "Export compliance answers for this app",
                        before: "No active declaration with these exact answers", after: answers.summary,
                        body: .object([("data", .object([("type", .string("appEncryptionDeclarations")), ("attributes", answers.json), ("relationships", .object([("app", Apple.relationship("apps", .string(request.appId)))]))]))]),
                        guard: .object([("kind", .string("app-encryption-creation")), ("digest", .string(Self.declarationsDigest(current, appId: request.appId)))]))
        }
        if let buildId = request.buildId {
            // Answering for a build attaches the declaration to it in the same review, as App Store Connect does from the build's Manage link.
            guard let build = try await appBuild(appId: request.appId, buildId: buildId, client: planner.client, planner: planner), Self.processedUnexpired(build),
                  Self.acceptsDeclaration(build, planning: true) else { throw PublishFailure.invalid("Choose a processed, unexpired build that Apple records as using non-exempt encryption, or one without an answer yet.") }
            let platform = try await buildPlatform(build, client: planner.client, planner: planner), version = build.attributes?["version"]?.string ?? build.id
            if let matching, !TestFlightEncryption.declarationFits(matching.attributes?["platform"]?.string, platform: platform) {
                throw PublishFailure.invalid("A declaration with these answers already exists for another platform. Check it under App Information → App Encryption Documentation in App Store Connect.")
            }
            let linked = try TestFlightEncryption.observedDeclaration(try await WorkspaceSession.declarationLink(build.id) { try await planner.get($0) })
            try planEncryptionUse(build, planner: planner)
            if let matching, matching.id == linked { return "Export compliance declaration · build \(version)" }
            let target: JSONText = created.map(Apple.ref) ?? .string(matching?.id ?? "")
            planner.add(.api, method: "PATCH", path: [.string("builds"), .string(build.id)], label: "Attach declaration to build \(version)", detail: "Build \(version) · \(Releases.platformName(platform))",
                        before: linked.map { "Declaration \($0)" } ?? "No declaration assigned", after: created == nil ? "Declaration \(matching?.id ?? "")" : "The declaration created above",
                        body: .object([("data", .object([("type", .string("builds")), ("id", .string(build.id)), ("relationships", .object([("appEncryptionDeclaration", Apple.relationship("appEncryptionDeclarations", target))]))]))]),
                        guard: .object([("kind", .string("build-new-encryption-declaration")), ("digest", .string(TestFlightEncryption.declarationDigest(linked))), ("answers", .string(answers.json.sha256))]))
            planner.notes.append("Apple reviews the declaration. App Store Connect needs no documentation for industry standard encryption when the app is not on the App Store in France. Otherwise Apple asks for documents under App Information → App Encryption Documentation before it approves the declaration.")
            return "Export compliance declaration · build \(version)"
        }
        planner.notes.append("These answers describe your app's use of encryption. Check them against the shipped app and Apple's export compliance guidance before approval. Apple may require a document and a separate review before a declaration can be assigned to a build.")
        return "Create export compliance declaration"
    }
}

public struct StagedEncryptionDocument: Equatable, Sendable {
    public static let maximumBytes = 50_000_000
    public let fileName: String; public let size: Int; public let hash: String; public let revision: Int
}

extension WorkspaceSession {
    func encryptionDocumentKey(_ accountId: String, _ appId: String, _ declarationId: String) throws -> String {
        guard accountId.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil, appId.range(of: #"^\d+$"#, options: .regularExpression) != nil,
              declarationId.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil else { throw PublishFailure.invalid("Invalid encryption document selection.") }
        return "\(accountId):\(appId):\(declarationId)"
    }

    public func stagedEncryptionDocument(accountId: String, appId: String, declarationId: String) throws -> StagedEncryptionDocument? {
        let key = try encryptionDocumentKey(accountId, appId, declarationId)
        return try storeAccess { store in
            guard let document = try store.document(namespace: "encryption_document_drafts", key: key) else { return nil }
            let value = try JSONText.parse(document.payload)
            guard value["declarationId"]?.text == declarationId, let name = value["fileName"]?.text, let hash = value["hash"]?.text, case .number(let size)? = value["size"] else { throw PublishFailure.invalid("The staged encryption document is invalid. Choose the PDF again.") }
            return StagedEncryptionDocument(fileName: name, size: Int(size), hash: hash, revision: document.revision)
        }
    }

    /// Stages the PDF Apple asks for with a declaration; it is encrypted locally and sent only through a review.
    public func stageEncryptionDocument(accountId: String, appId: String, declarationId: String, expectedRevision: Int, fileName: String, data: Data) throws -> StagedEncryptionDocument {
        let key = try encryptionDocumentKey(accountId, appId, declarationId)
        guard data.count >= 5, data.count <= StagedEncryptionDocument.maximumBytes, data.prefix(5) == Data("%PDF-".utf8), fileName.range(of: #"^[^/\\\u0000-\u001f\u007f]{1,200}\.pdf$"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            throw PublishFailure.invalid("Choose a valid PDF up to 50 MB.")
        }
        let mutex = "encryption_doc_" + JSONText.string(key).rawSHA256.prefix(40)
        try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("\(mutex).mutex")) {
                let current = try store.document(namespace: "encryption_document_drafts", key: key)
                guard (current?.revision ?? 0) == expectedRevision else { throw PublishFailure.invalid("The encryption document changed in another window. Reload before saving.") }
                let saved = try media.write(data, limit: StagedEncryptionDocument.maximumBytes)
                let value = JSONText.object([("declarationId", .string(declarationId)), ("fileName", .string(fileName)), ("extension", .string("pdf")), ("size", .number(Double(saved.length))), ("hash", .string(saved.hash))])
                try store.transaction { now in
                    guard try now("encryption_document_drafts", key)?.revision == current?.revision else { throw PublishFailure.invalid("The encryption document changed in another window. Reload before saving.") }
                    return [.put(namespace: "encryption_document_drafts", key: key, json: value.data)]
                }
            }
        }
        return try stagedEncryptionDocument(accountId: accountId, appId: appId, declarationId: declarationId)!
    }

    static func documentOwnerDigest(_ declaration: AppStoreConnectClient.Resource) -> String {
        let answers = ["appDescription", "containsProprietaryCryptography", "containsThirdPartyCryptography", "availableOnFrenchStore"].map { key -> JSONText in
            switch declaration.attributes?[key] { case .string(let text)?: .string(text); case .bool(let flag)?: .bool(flag); default: .null }
        }
        return JSONText.object([("id", .string(declaration.id)), ("platform", declaration.attributes?["platform"]?.string.map { .string($0) } ?? .null), ("answers", .array(answers))]).sha256
    }

    func declarationDocument(_ declarationId: String, client: AppStoreConnectClient, planner: Planner? = nil) async throws -> AppStoreConnectClient.Resource? {
        let page: [AppStoreConnectClient.Resource]
        do { page = planner != nil ? try await planner!.get("/v1/appEncryptionDeclarations/\(declarationId)/appEncryptionDeclarationDocument") : try await client.get("/v1/appEncryptionDeclarations/\(declarationId)/appEncryptionDeclarationDocument") }
        catch AppStoreConnectClient.Failure.status(404) { return nil }
        guard page.count <= 1 else { throw PublishFailure.invalid("Apple returned multiple documents for one encryption declaration.") }
        guard let document = page.first else { return nil }
        guard document.type == "appEncryptionDeclarationDocuments", Apple.owner(document, "appEncryptionDeclaration").map({ $0 == ("appEncryptionDeclarations", declarationId) }) ?? true else {
            throw PublishFailure.invalid("Apple returned a document outside the selected encryption declaration.")
        }
        return document
    }

    func planEncryptionDocument(_ planner: Planner) async throws -> String {
        let request = planner.request
        let declarations = try Self.scopedDeclarations(try await WorkspaceSession.declarationReads(request.appId) { try await planner.list($0) }, appId: request.appId)
        guard let declaration = declarations.first(where: { $0.id == request.declarationId }), ["CREATED", "IN_REVIEW"].contains(declaration.attributes?["appEncryptionDeclarationState"]?.string ?? "") else {
            throw PublishFailure.invalid("Choose this app's encryption declaration before uploading its document.")
        }
        guard let staged = try stagedEncryptionDocument(accountId: request.accountId, appId: request.appId, declarationId: declaration.id), staged.revision == request.documentRevision else { throw PublishFailure.invalid("The staged encryption PDF changed. Reload before review.") }
        let asset = try describeAsset(revisionId: declaration.id, hash: staged.hash, storage: "export-document", ext: "pdf", fileName: staged.fileName, accountId: request.accountId, appId: request.appId)
        let checksum = asset["checksum"]?.text ?? ""
        let document = try await declarationDocument(declaration.id, client: planner.client, planner: planner)
        if let document {
            guard document.attributes?["fileName"]?.string == staged.fileName, document.attributes?["fileSize"] == .number(Double(staged.size)) else { throw PublishFailure.invalid("Apple already has a different document for this declaration. Check it under App Information → App Encryption Documentation in App Store Connect.") }
            if let existing = document.attributes?["sourceFileChecksum"]?.string, existing != checksum { throw PublishFailure.invalid("Apple's encryption document checksum differs from the staged PDF.") }
            switch Apple.delivery(document) {
            case "FAILED": throw PublishFailure.invalid("Apple could not process this encryption document. Check it under App Information → App Encryption Documentation in App Store Connect.")
            case "UPLOAD_COMPLETE", "COMPLETE":
                planner.notes.append("Apple has received this PDF. Wait for Apple's export compliance decision before assigning the declaration to a build.")
                return "Encryption document · \(staged.fileName)"
            default: break
            }
        } else if declaration.attributes?["appEncryptionDeclarationState"]?.string != "CREATED" { throw PublishFailure.invalid("Apple is already reviewing this declaration. A new document cannot be reserved now.") }
        let guardFields: [(String, JSONText)] = [("declarationId", .string(declaration.id)), ("digest", .string(Self.documentOwnerDigest(declaration))), ("fileName", .string(staged.fileName)), ("size", .number(Double(staged.size))), ("checksum", .string(checksum))]
        var documentId: JSONText = document.map { .string($0.id) } ?? .null, group = ""
        if document == nil {
            group = planner.add(.api, method: "POST", path: [.string("appEncryptionDeclarationDocuments")], label: "Reserve \(staged.fileName) at Apple", detail: "Create a document upload for the selected app encryption declaration.",
                                before: "No document at Apple", after: "\(staged.fileName) · \(String(format: "%.2f", Double(staged.size) / 1_000_000)) MB\nSHA-256 \(staged.hash)",
                                body: .object([("data", .object([("type", .string("appEncryptionDeclarationDocuments")), ("attributes", .object([("fileName", .string(staged.fileName)), ("fileSize", .number(Double(staged.size)))])),
                                                                  ("relationships", .object([("appEncryptionDeclaration", Apple.relationship("appEncryptionDeclarations", .string(declaration.id)))]))]))]),
                                guard: .object([("kind", .string("encryption-document-reservation"))] + guardFields))
            planner.steps[planner.steps.count - 1].group = group
            documentId = Apple.ref(group)
        }
        let upload = planner.add(.upload, path: [.string("appEncryptionDeclarationDocuments"), documentId], label: "Upload \(staged.fileName)", detail: "Send the reviewed encrypted local PDF to Apple's reserved upload URL. SHA-256 \(staged.hash).", asset: asset, group: group.isEmpty ? nil : group)
        if group.isEmpty { group = upload; planner.steps[planner.steps.count - 1].group = group }
        planner.add(.api, method: "PATCH", path: [.string("appEncryptionDeclarationDocuments"), documentId], label: "Complete \(staged.fileName)", detail: "Ask Apple to verify the uploaded PDF.",
                    body: .object([("data", .object([("type", .string("appEncryptionDeclarationDocuments")), ("id", documentId), ("attributes", .object([("uploaded", .bool(true)), ("sourceFileChecksum", .string(checksum))]))]))]),
                    guard: .object([("kind", .string("encryption-document-commit"))] + guardFields), group: group)
        planner.add(.verify, path: [.string("appEncryptionDeclarationDocuments"), documentId], label: "Verify \(staged.fileName)", detail: "Wait for Apple to finish processing the PDF.", group: group)
        planner.notes.append("This sends the selected PDF to Apple after one exact approval. Apple reviews export compliance separately; an uploaded document does not approve the declaration or attach it to a build.")
        return "Upload encryption document · \(staged.fileName)"
    }
}
