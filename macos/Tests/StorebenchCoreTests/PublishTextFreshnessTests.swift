import Foundation
import Testing
@testable import StorebenchCore

/// A version draft from an Apple import must never put older text back at App Store Connect.
@Suite struct PublishTextFreshnessTests {
    init() throws { _ = try TestIsolation.require() }

    func locale(_ id: String, _ fields: [String: String]) -> AppStoreConnectClient.Resource {
        AppStoreConnectClient.Resource(type: "appStoreVersionLocalizations", id: id, attributes: fields.mapValues { .string($0) }, relationships: nil)
    }
    func value(_ fields: [(String, String)], _ name: String) -> String? { fields.first { $0.0 == name }?.1 }

    @Test func textNeverEditedHereIsTakenFromAppleAsItIsNow() {
        let imported = [("locale", "en-US"), ("description", "Older description"), ("keywords", "one,two"), ("promotionalText", "Synthetic promotion"), ("whatsNew", "")]
        // A new version: Apple copied its current listing into it and left Promotional Text empty. The import is older than that listing.
        let base = locale("base", ["locale": "en-US", "description": "Newer description", "keywords": "one,two", "promotionalText": "Synthetic promotion"])
        let target = locale("target", ["locale": "en-US", "description": "Newer description", "keywords": "one,two", "promotionalText": ""])
        let fresh = WorkspaceSession.currentText(imported, base: base, target: target, kept: nil)
        #expect(value(fresh.fields, "description") == "Newer description", "The older saved description must never be sent")
        #expect(value(fresh.fields, "promotionalText") == "Synthetic promotion", "What Apple left empty is filled with its own current text")
        #expect(value(fresh.fields, "locale") == "en-US" && fresh.left == ["description"])
        // The same version: nothing unedited differs from Apple, so nothing unedited is sent.
        let same = WorkspaceSession.currentText(imported, base: target, target: target, kept: nil)
        #expect(value(same.fields, "description") == "Newer description" && value(same.fields, "promotionalText") == "" && Set(same.left) == ["description", "promotionalText"])
    }

    @Test func withoutTheContinuedVersionSavedTextFillsOnlyWhatAppleLeftEmpty() {
        let imported = [("description", "Older description"), ("promotionalText", "Synthetic promotion")]
        let target = locale("target", ["description": "Newer description", "promotionalText": ""])
        let fresh = WorkspaceSession.currentText(imported, base: nil, target: target, kept: nil)
        #expect(value(fresh.fields, "description") == "Newer description" && value(fresh.fields, "promotionalText") == "Synthetic promotion" && fresh.left == ["description"])
        // A language Apple does not have on the version yet is added with this Mac's text.
        let added = WorkspaceSession.currentText(imported, base: nil, target: nil, kept: nil)
        #expect(value(added.fields, "description") == "Older description" && added.left.isEmpty)
    }

    @Test func keepMineSendsThisMacsTextOnlyOverTheAppleTextItWasChosenAgainst() {
        let imported = [("description", "Mine")], target = locale("target", ["description": "Apple's"])
        let kept = JSONText.object([("description", .string(JSONText.string("Apple's").rawSHA256))])
        #expect(value(WorkspaceSession.currentText(imported, base: target, target: target, kept: kept).fields, "description") == "Mine")
        // Apple changed again after the choice: the choice no longer applies.
        let changed = locale("target", ["description": "Apple's again"])
        let later = WorkspaceSession.currentText(imported, base: changed, target: changed, kept: kept)
        #expect(value(later.fields, "description") == "Apple's again" && later.left == ["description"])
    }

    @Test func aDraftValueThatOnlyRepeatsTheImportIsNotAnEdit() {
        let imported = [("description", "Older description"), ("keywords", "one,two"), ("whatsNew", "")]
        let drafted = [("description", "Older description"), ("keywords", "one,two,three"), ("whatsNew", "Synthetic notes")]
        let apple = locale("target", ["description": "Newer description", "keywords": "one,two"])
        let edited = WorkspaceSession.editedText(drafted, imported: imported, kept: nil, apple: apple)
        #expect(edited.map(\.0) == ["keywords", "whatsNew"], "Only what was typed here is sent")
        let kept = JSONText.object([("description", .string(JSONText.string("Newer description").rawSHA256))])
        #expect(WorkspaceSession.editedText(drafted, imported: imported, kept: kept, apple: apple).map(\.0) == ["description", "keywords", "whatsNew"])
        // Text taken from App Store Connect differs from the import and equals Apple, so it is kept in the draft and changes nothing.
        let adopted = WorkspaceSession.editedText([("description", "Newer description")], imported: imported, kept: nil, apple: apple)
        #expect(adopted.map(\.1) == ["Newer description"])
    }
}
