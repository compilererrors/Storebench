import Foundation
import Testing
@testable import StorebenchCore

@Suite struct ApplicationAboutTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func aboutWorksWithoutWorkspaceOrSupportConfiguration() {
        let about = ApplicationAbout(info: [:])
        #expect(about.name == "Storebench")
        #expect(about.version == nil && about.build == nil && about.contact == nil)
        #expect(!ApplicationAbout.summary.isEmpty)
    }

    @Test func displayNameAndIndependentVersionBuildComeFromPublicBundleFields() {
        let about = ApplicationAbout(info: ["CFBundleDisplayName": " Synthetic App ", "CFBundleName": "Synthetic Executable", "CFBundleShortVersionString": "2.3.4", "CFBundleVersion": "42"])
        #expect(about.name == "Synthetic App" && about.version == "2.3.4" && about.build == "42")
        #expect(ApplicationAbout(info: ["CFBundleVersion": "9"]).build == "9")
        #expect(ApplicationAbout(info: ["CFBundleName": "Synthetic App"]).name == "Synthetic App")
    }

    @Test func blankOversizedAndControlCharacterMetadataFallsBackIndependently() {
        let about = ApplicationAbout(info: ["CFBundleDisplayName": " \n ", "CFBundleName": "Synthetic App", "CFBundleVersion": "4\n2", "CFBundleShortVersionString": String(repeating: "v", count: 201)])
        #expect(about.name == "Synthetic App" && about.version == nil && about.build == nil)
    }

    @Test func supportUsesValidatedPublicMetadataAndIsOptional() {
        let info = ["CFBundleShortVersionString": "2.3.4", "StorebenchSupportWebsite": "https://example.invalid", "StorebenchSupportURL": "https://example.invalid/support#support"]
        #expect(ApplicationAbout(info: info).contact?.support == URL(string: "https://example.invalid/support#support"))
        var invalid = info; invalid["StorebenchSupportWebsite"] = "file:///synthetic"
        #expect(ApplicationAbout(info: invalid).contact == nil)
        #expect(ApplicationAbout(info: invalid).version == "2.3.4")
    }

    @Test func restoredSettingsPaneKeepsAValidSelectedDestination() {
        #expect(SettingsNavigation.Pane.restored("security") == .security)
        #expect(SettingsNavigation.Pane.restored("unknown") == .general)
        #expect(SettingsNavigation.Pane.restored("") == .general)
        #expect(Set(SettingsNavigation.Pane.allCases.map(\.icon)).count == SettingsNavigation.Pane.allCases.count)
        #expect(SettingsNavigation.Pane.allCases.allSatisfy { !$0.title.isEmpty })
    }
}
