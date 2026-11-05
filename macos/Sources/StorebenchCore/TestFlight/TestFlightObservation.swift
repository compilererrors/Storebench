import Foundation

/// What the included Apple resources prove; absence, uncertainty and a known review stay distinct.
public enum TestFlightObservation {
    public typealias Resource = AppStoreConnectClient.Resource
    public enum ReviewState: String, Sendable, Equatable, Codable { case known, none, unknown }
    public enum ExportState: String, Sendable, Equatable, Codable {
        case unknown, unanswered, noNonexempt = "no-nonexempt", unassigned, reviewing, approved, invalid
        public var description: String {
            switch self {
            case .unknown: "Encryption declaration status unavailable"
            case .unanswered: "Missing Compliance"
            case .noNonexempt: "Non-exempt encryption: No"
            case .unassigned: "Encryption declaration needed"
            case .reviewing: "Encryption declaration pending approval"
            case .approved: "Encryption declaration approved"
            case .invalid: "Encryption declaration needs replacement"
            }
        }
    }
    public struct Review: Sendable { public let state: ReviewState; public let resource: Resource? }
    static func data(_ item: Resource, _ name: String) -> JSONValue? {
        guard case .object(let relation)? = item.relationships?[name] else { return nil }; return relation["data"]
    }
    static func truthy(_ value: JSONValue?) -> Bool {
        switch value { case nil, .null?: false; case .bool(let flag)?: flag; case .number(let value)?: value != 0 && !value.isNaN; case .string(let value)?: !value.isEmpty; default: true }
    }
    static func link(_ value: JSONValue?, type: String) -> String? {
        guard case .object(let fields)? = value, fields["type"]?.string == type, let id = fields["id"]?.string, !id.isEmpty else { return nil }; return id
    }
    static func owned(_ item: Resource, relation: String, type: String, id: String) -> Bool {
        TextSemantics.same(link(data(item, relation), type: type), id)
    }

    public struct Index: Sendable {
        let reviewsByID, reviewsByBuild, detailsByID, versionsByID: [Data: [Resource]]
        public init(included: [Resource]) {
            var reviews: [Data: [Resource]] = [:], reverse: [Data: [Resource]] = [:], details: [Data: [Resource]] = [:], versions: [Data: [Resource]] = [:]
            for item in included {
                switch item.type {
                case "betaAppReviewSubmissions":
                    reviews[Data(item.id.utf8), default: []].append(item)
                    if let id = link(data(item, "build"), type: "builds") { reverse[Data(id.utf8), default: []].append(item) }
                case "buildBetaDetails": details[Data(item.id.utf8), default: []].append(item)
                case "preReleaseVersions": versions[Data(item.id.utf8), default: []].append(item)
                default: break
                }
            }
            reviewsByID = reviews; reviewsByBuild = reverse; detailsByID = details; versionsByID = versions
        }
        public func review(_ build: Resource) -> Review {
            let unknown = Review(state: .unknown, resource: nil)
            guard build.type == "builds" else { return unknown }
            let target = data(build, "betaAppReviewSubmission"), reverse = reviewsByBuild[Data(build.id.utf8)] ?? []
            if target == .null { return reverse.isEmpty ? Review(state: .none, resource: nil) : unknown }
            if truthy(target), link(target, type: "betaAppReviewSubmissions") == nil { return unknown }
            let candidates = truthy(target) ? reviewsByID[Data(link(target, type: "betaAppReviewSubmissions")!.utf8)] ?? [] : reverse
            guard candidates.count == 1, let candidate = candidates.first, reverse.allSatisfy({ TextSemantics.same($0.id, candidate.id) }) else { return unknown }
            if truthy(data(candidate, "build")), !owned(candidate, relation: "build", type: "builds", id: build.id) { return unknown }
            guard ["WAITING_FOR_REVIEW", "IN_REVIEW", "REJECTED", "APPROVED"].contains(candidate.attributes?["betaReviewState"]?.string ?? "") else { return unknown }
            return Review(state: .known, resource: candidate)
        }
        public func detail(_ build: Resource) -> Resource? {
            guard build.type == "builds", let id = link(data(build, "buildBetaDetail"), type: "buildBetaDetails"),
                  let candidates = detailsByID[Data(id.utf8)], candidates.count == 1 else { return nil }
            let detail = candidates[0]
            if truthy(data(detail, "build")), !owned(detail, relation: "build", type: "builds", id: build.id) { return nil }
            return detail
        }
        func version(_ build: Resource) -> Resource? {
            guard let id = link(data(build, "preReleaseVersion"), type: "preReleaseVersions"), let versions = versionsByID[Data(id.utf8)], versions.count == 1 else { return nil }; return versions[0]
        }
    }
    public static func listedExportCompliance(build: Resource, versions: [Resource], declarations: [Resource]?, appId: String) throws -> ExportState {
        let index = Index(included: versions)
        return try exportCompliance(build: build, version: index.version(build), declarations: declarations, appId: appId)
    }
    static func exportCompliance(build: Resource, version: Resource?, declarations: [Resource]?, appId: String, declarationIndex: [Data: Resource]? = nil) throws -> ExportState {
        guard build.type == "builds", build.id.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil, owned(build, relation: "app", type: "apps", id: appId) else {
            throw PublishFailure.invalid("Apple returned an unrelated build for export compliance.")
        }
        switch build.attributes?["usesNonExemptEncryption"] {
        case .bool(false)?: return .noNonexempt
        case .null?: return .unanswered
        case .bool(true)?: break
        default: return .unknown
        }
        guard let linked = data(build, "appEncryptionDeclaration") else { return .unknown }
        if linked == .null { return .unassigned }
        guard let id = link(linked, type: "appEncryptionDeclarations"), id != "unknown", id.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil,
              let platform = version?.attributes?["platform"]?.string, !platform.isEmpty, let declarations else { return .unknown }
        let selected: Resource?
        if let declarationIndex { selected = declarationIndex[Data(id.utf8)] }
        else { selected = try WorkspaceSession.scopedDeclarations(declarations, appId: appId).first(where: { TextSemantics.same($0.id, id) }) }
        guard let declaration = selected, let state = declaration.attributes?["appEncryptionDeclarationState"]?.string else { return .unknown }
        guard TestFlightEncryption.declarationFits(declaration.attributes?["platform"]?.string, platform: platform) else { return .invalid }
        switch state { case "APPROVED": return .approved; case "CREATED", "IN_REVIEW": return .reviewing; default: return .invalid }
    }
    public static func models(appId: String, builds: [Resource], included: [Resource], declarations: [Resource]?) throws -> [TestFlightBuild] {
        guard builds.allSatisfy({ $0.type == "builds" && !TextSemantics.trim($0.id).isEmpty && owned($0, relation: "app", type: "apps", id: appId) }), Set(builds.map { Data($0.id.utf8) }).count == builds.count else {
            throw PublishFailure.invalid("Apple returned unexpected TestFlight builds.")
        }
        let index = Index(included: included)
        let observations = builds.map { index.review($0) }
        let activeVersions = Set(zip(builds, observations).compactMap { build, review -> Data? in
            guard ["WAITING_FOR_REVIEW", "IN_REVIEW"].contains(review.resource?.attributes?["betaReviewState"]?.string ?? ""), let id = link(data(build, "preReleaseVersion"), type: "preReleaseVersions") else { return nil }; return Data(id.utf8)
        })
        let checkedDeclarations = declarations.flatMap { try? WorkspaceSession.scopedDeclarations($0, appId: appId) }
        let declarationIndex = checkedDeclarations.map { Dictionary(uniqueKeysWithValues: $0.map { (Data($0.id.utf8), $0) }) }
        return zip(builds, observations).map { build, observation in
            let version = index.version(build), detail = index.detail(build), releaseID = link(data(build, "preReleaseVersion"), type: "preReleaseVersions")
            func flag(_ value: JSONValue?) -> Bool? { if case .bool(let flag)? = value { return flag }; return nil }
            var model = TestFlightBuild(id: build.id, version: build.attributes?["version"]?.string ?? build.id, platform: version?.attributes?["platform"]?.string ?? "", appVersion: version?.attributes?["version"]?.string ?? "",
                                       processingState: build.attributes?["processingState"]?.string ?? "", uploadedDate: build.attributes?["uploadedDate"]?.string ?? "", expirationDate: build.attributes?["expirationDate"]?.string ?? "",
                                       audience: build.attributes?["buildAudienceType"]?.string ?? "", expired: flag(build.attributes?["expired"]), usesNonExemptEncryption: flag(build.attributes?["usesNonExemptEncryption"]),
                                       externalState: detail?.attributes?["externalBuildState"]?.string, internalState: detail?.attributes?["internalBuildState"]?.string, betaReviewState: observation.resource?.attributes?["betaReviewState"]?.string,
                                       autoNotifyEnabled: flag(detail?.attributes?["autoNotifyEnabled"]))
            model.reviewObservation = observation.state; model.preReleaseVersionId = releaseID
            model.otherBuildInBetaReview = observation.state != .known && releaseID.map { activeVersions.contains(Data($0.utf8)) } == true
            model.exportState = (try? exportCompliance(build: build, version: version, declarations: checkedDeclarations, appId: appId, declarationIndex: declarationIndex)) ?? .unknown
            model.betaDetailConfirmed = detail != nil
            return model
        }.sorted { $0.uploadedDate > $1.uploadedDate }
    }
}
