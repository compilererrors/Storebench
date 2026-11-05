import Foundation
import Testing
@testable import StorebenchCore

@Suite struct ReleaseMaterialTests {
    init() throws { _ = try TestIsolation.require() }
    private func cases() throws -> [JSONText] {
        let fixture = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/release-readiness.json")))
        guard case .array(let values)? = fixture["material"] else { throw ReleaseMaterial.Failure.invalid }
        return values
    }
    @Test func savedTextMediaCountsAndRequiredFieldsMatchThePrimaryReleaseChecks() throws {
        let values = try cases(); #expect(values.count > 110)
        for item in values {
            let source = try #require(item["source"]), draft = try #require(item["draft"]), version = try #require(item["versionId"]?.text)
            let actual = try ReleaseMaterial.languages(source: source, draft: draft, versionId: version, requireWhatsNew: item["requireWhatsNew"] == .bool(true))
            #expect(JSONText.array(actual.map(\.json)) == item["expected"], "Synthetic release material: \(item["name"]?.text ?? "unknown")")
        }
    }
    @Test func foreignOrMalformedDraftsNeverProduceAReadinessResult() throws {
        let item = try #require(try cases().first), source = try #require(item["source"]), draft = try #require(item["draft"])
        #expect(throws: ReleaseMaterial.Failure.invalid) { try ReleaseMaterial.languages(source: source, draft: draft.setting("revisionId", .string("synthetic-foreign")), versionId: "version-1") }
        #expect(throws: ReleaseMaterial.Failure.invalid) { try ReleaseMaterial.languages(source: source, draft: draft, versionId: "synthetic-unavailable") }
        #expect(throws: DraftFailure.invalid) { try ReleaseMaterial.languages(source: source, draft: draft.setting("texts", .array([])), versionId: "version-1") }
        for key in ["screenshotLayouts", "uploads", "previewUploads", "previewLayouts"] {
            #expect(throws: ReleaseMaterial.Failure.invalid) { try ReleaseMaterial.languages(source: source, draft: draft.setting(key, .array([])), versionId: "version-1") }
        }
        let malformed = JSONText.object([("preview-synthetic", .object([("id", .string("preview-synthetic")), ("duration", .number(.nan)), ("width", .number(.infinity)), ("height", .number(1))]))])
        #expect(throws: ReleaseMaterial.Failure.invalid) { try ReleaseMaterial.languages(source: source, draft: draft.setting("previewUploads", malformed), versionId: "version-1") }
    }
}
