import Foundation

/// Resolves only known release guidance, retaining the exact saved material and selected Apple version.
public struct ReleaseReadinessAction: Sendable {
    public enum Target: Sendable {
        case plan, language(String), information(String), reviewInformation(String?), publishing(PublishRequest)
        case build(id: String?, action: String?), external(URL)
    }
    public let scope: RecoveryGuidance.Scope, planToken: String, materialSignature: String, target: Target
    public init(snapshot: ReleaseReadinessSnapshot, stepId: String) throws {
        guard snapshot.plan.accountId == snapshot.scope.accountId, snapshot.plan.appId == snapshot.scope.appId,
              let step = snapshot.steps.first(where: { TextSemantics.same($0.id, stepId) }), let url = URLComponents(string: step.href) else { throw ReleaseReadiness.Failure.invalid }
        scope = snapshot.scope; planToken = snapshot.plan.token; materialSignature = snapshot.materialSignature
        if step.href == "https://appstoreconnect.apple.com/" { target = .external(URL(string: step.href)!); return }
        guard url.scheme == nil, url.host == nil, url.path.hasPrefix(scope.root + "/"), url.user == nil, url.password == nil else { throw ReleaseReadiness.Failure.invalid }
        var values: [String: String] = [:]
        for item in url.queryItems ?? [] { guard values[item.name] == nil, let value = item.value else { throw ReleaseReadiness.Failure.invalid }; values[item.name] = value }
        let route = String(url.path.dropFirst(scope.root.count))
        if route == "/release", values.isEmpty {
            if url.fragment == "release-version" { target = .plan; return }
            if let fragment = url.fragment, fragment.hasPrefix("release-locale-") {
                let locale = String(fragment.dropFirst("release-locale-".count))
                guard !locale.isEmpty, locale.utf16.count <= 256, !locale.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw ReleaseReadiness.Failure.invalid }
                target = .language(locale); return
            }
        }
        if route == "/testflight", values.isEmpty || Set(values.keys) == ["build"] {
            let id = values["build"]
            guard id == nil || AppOverviewMaterial.identifier(id!), url.fragment == nil || url.fragment == "selected-build" else { throw ReleaseReadiness.Failure.invalid }
            target = .build(id: id, action: nil); return
        }
        guard route == "/publish", url.fragment == nil, let raw = values["scope"], let change = PublishRequest.Scope(rawValue: raw) else { throw ReleaseReadiness.Failure.invalid }
        if change == .testflight {
            guard Set(values.keys) == ["scope", "testflightAction", "buildId"], let action = values["testflightAction"], ["set-encryption-use", "assign-encryption-declaration"].contains(action),
                  let build = values["buildId"], AppOverviewMaterial.identifier(build) else { throw ReleaseReadiness.Failure.invalid }
            target = .build(id: build, action: action); return
        }
        if [.release, .metadata].contains(change) {
            guard Set(values.keys) == ["scope", "draft"], values["draft"] == "1" else { throw ReleaseReadiness.Failure.invalid }
        } else { guard Set(values.keys) == ["scope"] else { throw ReleaseReadiness.Failure.invalid } }
        switch change {
        case .release: target = .publishing(.init(accountId: scope.accountId, appId: scope.appId, scope: .release))
        case .metadata: target = .publishing(.init(accountId: scope.accountId, appId: scope.appId, scope: .metadata, targetMode: "release-plan", revisionId: snapshot.plan.sourceRevisionId, versionId: snapshot.plan.baseVersionId))
        case .versionCopyright, .submit, .releaseVersion:
            target = .publishing(.init(accountId: scope.accountId, appId: scope.appId, scope: change, versionId: snapshot.targetVersionId))
        case .reviewInfo: target = .reviewInformation(snapshot.targetVersionId)
        case .appInformation: target = .information("categories")
        case .ageRating: target = .information("age-rating")
        case .accessibility: target = .information("accessibility")
        case .availability: target = .information("availability")
        case .exportCompliance, .exportDocument: target = .information("export-compliance")
        default: throw ReleaseReadiness.Failure.invalid
        }
    }
    public func allowed(current: RecoveryGuidance.Scope?, planToken: String?, materialSignature: String?, decision: EditorProtectionPolicy.Decision, discardConfirmed: Bool = false) -> Bool {
        guard current == scope, TextSemantics.same(planToken, self.planToken), TextSemantics.same(materialSignature, self.materialSignature) else { return false }
        return decision == .ready || decision == .confirmDiscard && discardConfirmed
    }
}
