import Foundation

/// One explicit declaration linkage; a missing relationship is different from an unconfirmed response.
public enum TestFlightEncryption {
    public static func observedDeclaration(_ resources: [AppStoreConnectClient.Resource]) throws -> String? {
        guard resources.count <= 1, resources.allSatisfy({ $0.type == "appEncryptionDeclarations" && $0.id.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil }) else { throw PublishFailure.invalid("Apple did not confirm this build's encryption declaration.") }
        return resources.first?.id
    }
    public static func declarationDigest(_ id: String?) -> String { Apple.sha(id.map { "id:\($0)" } ?? "none") }
    /// Apple no longer sets a platform on new declarations. One without a platform applies to every platform of the app.
    public static func declarationFits(_ declared: String?, platform: String) -> Bool {
        guard let declared = declared.map(TextSemantics.trim), !declared.isEmpty else { return true }
        return TextSemantics.same(declared, platform)
    }
}

/// One build's export compliance at Apple, read together so the Release step can name the one next step.
public struct BuildExportCompliance: Equatable, Sendable {
    public enum Next: Equatable, Sendable { case done, waiting, choose, create }
    public let currentId: String?, declarations: [EncryptionDeclaration], platform: String
    public init(currentId: String?, declarations: [EncryptionDeclaration], platform: String) { self.currentId = currentId; self.declarations = declarations; self.platform = platform }
    public var current: EncryptionDeclaration? { declarations.first { $0.id == currentId } }
    public var approved: [EncryptionDeclaration] { declarations.filter { $0.state == "APPROVED" && $0.fits(platform) } }
    public var next: Next {
        if let current, current.fits(platform) {
            if current.state == "APPROVED" { return .done }
            if ["CREATED", "IN_REVIEW"].contains(current.state) { return .waiting }
        }
        return approved.contains { $0.id != currentId } ? .choose : .create
    }
}

extension WorkspaceSession {
    public func buildEncryptionDeclaration(appId: String, buildId: String, client: AppStoreConnectClient) async throws -> String? {
        try requireFeedbackScope(appId: appId, client: client)
        guard try await appBuild(appId: appId, buildId: buildId, client: client) != nil else { throw PublishFailure.invalid("Choose a build belonging to this app.") }
        let id = try TestFlightEncryption.observedDeclaration(try await WorkspaceSession.declarationLink(buildId) { try await client.get($0) })
        try requireFeedbackScope(appId: appId, client: client)
        return id
    }

    /// The build's linked declaration and the app's declarations. A refresh elsewhere that cancels these reads reads them again instead of reporting a failure.
    public func buildExportCompliance(appId: String, buildId: String, platform: String, client: AppStoreConnectClient) async throws -> BuildExportCompliance {
        try await AppStoreReadCache.rereadingAfterInvalidation {
            let current = try await self.buildEncryptionDeclaration(appId: appId, buildId: buildId, client: client)
            let declarations = try await self.encryptionDeclarations(appId: appId, client: client)
            return BuildExportCompliance(currentId: current, declarations: declarations, platform: platform)
        }
    }

    func buildPlatform(_ build: AppStoreConnectClient.Resource, client: AppStoreConnectClient, planner: Planner? = nil) async throws -> String {
        guard let version = Apple.owner(build, "preReleaseVersion"), version.type == "preReleaseVersions", version.id.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil else { throw PublishFailure.invalid("Apple did not confirm this build's platform.") }
        let versions = planner != nil ? try await planner!.get("/v1/preReleaseVersions/\(version.id)") : try await client.get("/v1/preReleaseVersions/\(version.id)")
        guard versions.count == 1, versions[0].type == "preReleaseVersions", versions[0].id == version.id, let platform = versions[0].attributes?["platform"]?.string, !platform.isEmpty else { throw PublishFailure.invalid("Apple did not confirm this build's platform.") }
        return platform
    }

    func approvedBuildDeclaration(build: AppStoreConnectClient.Resource, declarationId: String, appId: String, client: AppStoreConnectClient, planner: Planner? = nil) async throws -> AppStoreConnectClient.Resource {
        // While planning, a build without an answer is answered Yes earlier in the same review; applying checks Apple's answer again.
        guard Self.processedUnexpired(build), Self.acceptsDeclaration(build, planning: planner != nil) else { throw PublishFailure.invalid("Choose a processed, unexpired build marked as using non-exempt encryption at Apple.") }
        let values = planner != nil ? try await WorkspaceSession.declarationReads(appId) { try await planner!.list($0) } : try await WorkspaceSession.declarationReads(appId) { try await client.list($0) }
        guard let declaration = try Self.scopedDeclarations(values, appId: appId).first(where: { $0.id == declarationId && $0.attributes?["appEncryptionDeclarationState"]?.string == "APPROVED" }) else { throw PublishFailure.invalid("Choose an Apple-approved encryption declaration belonging to this app and build.") }
        let platform = try await buildPlatform(build, client: client, planner: planner)
        guard TestFlightEncryption.declarationFits(declaration.attributes?["platform"]?.string, platform: platform) else { throw PublishFailure.invalid("The approved declaration must match this build's platform.") }
        return declaration
    }
    static func acceptsDeclaration(_ build: AppStoreConnectClient.Resource, planning: Bool) -> Bool {
        let answer = build.attributes?["usesNonExemptEncryption"]
        return answer == .bool(true) || (planning && (answer == nil || answer == .null))
    }
    /// App Store Connect answers Yes for a build without an answer when its encryption needs a declaration, before it attaches one.
    func planEncryptionUse(_ build: AppStoreConnectClient.Resource, planner: Planner) throws {
        let old = build.attributes?["usesNonExemptEncryption"]
        guard old != .bool(true) else { return }
        guard old != .bool(false) else { throw PublishFailure.invalid("Apple records that this build doesn't use non-exempt encryption, so it takes no declaration.") }
        let version = build.attributes?["version"]?.string ?? build.id
        planner.add(.api, method: "PATCH", path: [.string("builds"), .string(build.id)], label: "Set build encryption use", detail: "Build \(version) · Export compliance classification", before: "No answer at Apple",
                    after: "Uses non-exempt encryption: Yes", body: .object([("data", .object([("type", .string("builds")), ("id", .string(build.id)), ("attributes", .object([("usesNonExemptEncryption", .bool(true))]))]))]),
                    guard: .object([("kind", .string("build-encryption-use")), ("digest", .string(try Self.encryptionUseDigest(old)))]))
    }
    func planBuildDeclaration(_ planner: Planner) async throws -> String {
        let request = planner.request
        guard let build = try await appBuild(appId: request.appId, buildId: request.buildId, client: planner.client, planner: planner), let id = request.declarationId else { throw PublishFailure.invalid("Choose a build and an approved encryption declaration belonging to this app.") }
        let declaration = try await approvedBuildDeclaration(build: build, declarationId: id, appId: request.appId, client: planner.client, planner: planner)
        let current = try TestFlightEncryption.observedDeclaration(try await WorkspaceSession.declarationLink(build.id) { try await planner.get($0) }), version = build.attributes?["version"]?.string ?? build.id
        try planEncryptionUse(build, planner: planner)
        if current != declaration.id {
            planner.add(.api, method: "PATCH", path: [.string("builds"), .string(build.id)], label: "Assign approved encryption declaration", detail: "Build \(version) · \(declaration.attributes?["appDescription"]?.string ?? declaration.id)",
                        before: current.map { "Declaration \($0)" } ?? "No declaration assigned", after: "Approved declaration \(declaration.id)",
                        body: .object([("data", .object([("type", .string("builds")), ("id", .string(build.id)), ("relationships", .object([("appEncryptionDeclaration", Apple.relationship("appEncryptionDeclarations", .string(declaration.id)))]))]))]),
                        guard: .object([("kind", .string("build-encryption-declaration")), ("digest", .string(TestFlightEncryption.declarationDigest(current)))]))
        }
        planner.notes.append("Use an approved declaration only when it accurately describes this build's encryption. Apple may require further export compliance steps.")
        return "Assign encryption declaration · build \(version)"
    }
    func verifyBuildDeclaration(method: String, parts: [String], data: JSONText?, guardValue: JSONText?, appId: String, client: AppStoreConnectClient) async throws {
        let kind = guardValue?["kind"]?.text ?? ""
        guard method == "PATCH", parts.count == 2, parts[0] == "builds", data?["type"]?.text == "builds", data?["id"]?.text == parts[1], case .object(let fields)? = data,
              fields.count == 3, Set(fields.map(\.0)) == ["type", "id", "relationships"], case .object(let relationships)? = data?["relationships"], relationships.count == 1, relationships[0].0 == "appEncryptionDeclaration",
              let id = data?["relationships"]?["appEncryptionDeclaration"]?["data"]?["id"]?.text,
              data?["relationships"]?["appEncryptionDeclaration"] == Apple.relationship("appEncryptionDeclarations", .string(id)), ["build-encryption-declaration", "build-new-encryption-declaration"].contains(kind),
              let build = try await appBuild(appId: appId, buildId: parts[1], client: client) else { throw PublishFailure.write("Unsupported TestFlight encryption declaration change.") }
        let current = try TestFlightEncryption.observedDeclaration(try await WorkspaceSession.declarationLink(build.id) { try await client.get($0) })
        guard TestFlightEncryption.declarationDigest(current) == guardValue?["digest"]?.text else { throw PublishFailure.write("The build encryption declaration changed after review.") }
        if kind == "build-encryption-declaration" { _ = try await approvedBuildDeclaration(build: build, declarationId: id, appId: appId, client: client); return }
        _ = try await reviewedNewDeclaration(build: build, declarationId: id, answersDigest: guardValue?["answers"]?.text ?? "", appId: appId, client: client)
    }

    /// The declaration created or matched in the same review: it belongs to this app, carries the reviewed answers and is not withdrawn. Apple decides its approval.
    func reviewedNewDeclaration(build: AppStoreConnectClient.Resource, declarationId: String, answersDigest: String, appId: String, client: AppStoreConnectClient) async throws -> AppStoreConnectClient.Resource {
        guard Self.processedUnexpired(build), build.attributes?["usesNonExemptEncryption"] == .bool(true) else { throw PublishFailure.write("The build no longer uses non-exempt encryption at Apple. Prepare a new review.") }
        let declarations = try Self.scopedDeclarations(try await WorkspaceSession.declarationReads(appId) { try await client.list($0) }, appId: appId)
        guard let declaration = declarations.first(where: { $0.id == declarationId }), Self.activeDeclarationStates.contains(declaration.attributes?["appEncryptionDeclarationState"]?.string ?? ""),
              Self.answersDigest(declaration) == answersDigest else { throw PublishFailure.write("The new encryption declaration does not match the reviewed answers. Prepare a new review.") }
        guard TestFlightEncryption.declarationFits(declaration.attributes?["platform"]?.string, platform: try await buildPlatform(build, client: client)) else { throw PublishFailure.write("The new encryption declaration does not apply to this build's platform.") }
        return declaration
    }
}
