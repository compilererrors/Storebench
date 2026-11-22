import Foundation
import Testing
@testable import StorebenchCore

/// An import keeps a version a newer one replaced from the previous import, since it can no longer change at Apple, so starting
/// a release only reads the versions that still can. Anything else, or a version whose screenshots are gone, is read again.
@Suite(.serialized) struct ImportReuseTests {
    init() throws { _ = try TestIsolation.require() }

    private func version(_ state: String) -> AppStoreConnectClient.Resource {
        .init(type: "appStoreVersions", id: "synthetic-version", attributes: ["appVersionState": .string(state), "appStoreState": .string(state)], relationships: nil)
    }
    private let previous: [String: JSONText] = ["synthetic-version": .object([
        ("id", .string("synthetic-version")),
        ("fields", .object([("appVersionState", .string("REPLACED_WITH_NEW_VERSION")), ("appStoreState", .string("REPLACED_WITH_NEW_VERSION"))])),
        ("localizations", .array([.object([("id", .string("synthetic-en")), ("screenshotSets", .array([.object([("screenshots", .array([.object([("sha256", .string("synthetic-hash"))])]))])]))])]))])]

    @Test func aReplacedVersionIsKeptWhileItsScreenshotsAreSaved() {
        let kept = WorkspaceSession.frozenCopy(of: version("REPLACED_WITH_NEW_VERSION"), in: previous, mediaSaved: { _ in true })
        #expect(kept?.version == previous["synthetic-version"] && kept?.hashes == ["synthetic-hash"])
        #expect(WorkspaceSession.frozenCopy(of: version("REPLACED_WITH_NEW_VERSION"), in: previous, mediaSaved: { _ in false }) == nil, "A missing screenshot is read again")
    }

    @Test func aVersionThatCanStillChangeIsAlwaysReadAgain() {
        for state in ["READY_FOR_DISTRIBUTION", "PREPARE_FOR_SUBMISSION", "IN_REVIEW"] {
            #expect(WorkspaceSession.frozenCopy(of: version(state), in: previous, mediaSaved: { _ in true }) == nil, "\(state) is read again")
        }
        #expect(WorkspaceSession.frozenCopy(of: version("REPLACED_WITH_NEW_VERSION"), in: [:], mediaSaved: { _ in true }) == nil, "A version not imported before is read")
    }
}
