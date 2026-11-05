import Foundation
import Testing
@testable import StorebenchCore

@Suite struct ReleaseReadinessActionTests {
    init() throws { _ = try TestIsolation.require() }
    private func snapshot(_ input: JSONText) throws -> ReleaseReadinessSnapshot {
        let scope = try RecoveryGuidance.Scope(accountId: "synthetic-account", appId: "1000000001")
        let plan = try #require(ReleasePlan(.object([("accountId", .string(scope.accountId)), ("appId", .string(scope.appId)),
            ("sourceRevisionId", .string("00000000-0000-4000-8000-000000000002")), ("baseVersionId", .string("synthetic-base")), ("platform", .string("IOS")),
            ("targetVersion", .string("2.0")), ("releaseType", .string("MANUAL")), ("updatedAt", .string("2026-01-01T00:00:00.000Z"))])))
        return .init(scope: scope, plan: plan, steps: try ReleaseReadiness.steps(input, scope: scope), materialSignature: "synthetic-saved-material", targetVersionId: "synthetic-version", targetState: nil)
    }
    private func cases() throws -> [JSONText] {
        let value = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/release-readiness.json")))
        guard case .array(let cases)? = value["cases"] else { throw ReleaseReadiness.Failure.invalid }; return cases
    }
    @Test func everyPrimaryNextActionKeepsTheExactScopeMaterialAndAppleTarget() throws {
        for item in try cases() {
            let snapshot = try snapshot(#require(item["input"]))
            for step in snapshot.steps {
                let action = try ReleaseReadinessAction(snapshot: snapshot, stepId: step.id)
                #expect(action.scope == snapshot.scope && action.planToken == snapshot.plan.token && action.materialSignature == snapshot.materialSignature)
                switch action.target {
                case .publishing(let request):
                    #expect(request.accountId == snapshot.scope.accountId && request.appId == snapshot.scope.appId)
                    if request.scope == .metadata { #expect(request.revisionId == snapshot.plan.sourceRevisionId && request.versionId == snapshot.plan.baseVersionId && request.targetMode == "release-plan") }
                    if [.submit, .versionCopyright, .releaseVersion].contains(request.scope) { #expect(request.versionId == snapshot.targetVersionId) }
                case .language(let locale): #expect(step.href.hasSuffix("#" + ReleaseReadiness.languageAnchor(locale)))
                case .build(let id, let choice): #expect(id == nil || id!.range(of: #"\A[A-Za-z0-9_-]{1,256}\z"#, options: .regularExpression) != nil); #expect(choice == nil || ["set-encryption-use", "assign-encryption-declaration"].contains(choice!))
                case .external(let url): #expect(url.absoluteString == "https://appstoreconnect.apple.com/")
                default: break
                }
            }
        }
    }
    @Test func busyForeignAndChangedMaterialCannotNavigateAfterTheDiscardDialog() throws {
        let value = try snapshot(#require(try cases().first?["input"])), action = try ReleaseReadinessAction(snapshot: value, stepId: "version")
        func allowed(_ current: RecoveryGuidance.Scope? = nil, token: String? = nil, material: String? = nil, decision: EditorProtectionPolicy.Decision = .ready, discard: Bool = false) -> Bool {
            action.allowed(current: current ?? value.scope, planToken: token ?? value.plan.token, materialSignature: material ?? value.materialSignature, decision: decision, discardConfirmed: discard)
        }
        #expect(allowed()); #expect(!allowed(decision: .wait)); #expect(!allowed(decision: .confirmDiscard)); #expect(allowed(decision: .confirmDiscard, discard: true))
        #expect(!allowed(try RecoveryGuidance.Scope(accountId: "synthetic-other", appId: "1000000001"), discard: true))
        #expect(!allowed(token: "synthetic-new-plan", discard: true)); #expect(!allowed(material: "synthetic-new-draft", discard: true))
        #expect(throws: ReleaseReadiness.Failure.invalid) { try ReleaseReadinessAction(snapshot: value, stepId: "synthetic-unknown-row") }
    }
}
