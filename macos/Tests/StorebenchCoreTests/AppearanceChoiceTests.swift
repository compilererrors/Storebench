import Testing
@testable import StorebenchCore

@Suite struct AppearanceChoiceTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func everyThemeRetainsItsContrastContractInBothSystemAppearances() throws {
        let design = StorebenchDesign.shared
        for choice in AppearanceChoice.allCases {
            for dark in [false, true] {
                for increased in [false, true] {
                    let palette = choice.palette(systemDark: dark, increasedContrast: increased)
                    #expect(AppearanceContrast.valid(palette, pairs: increased || choice.highContrast ? design.increasedContrastPairs : design.contrastPairs))
                }
            }
        }
    }
    @Test func systemThemeFollowsAppearanceWhileExplicitChoicesRemainStable() {
        #expect(AppearanceChoice.system.palette(systemDark: false, increasedContrast: false) == AppearanceChoice.light.palette(systemDark: true, increasedContrast: false))
        #expect(AppearanceChoice.system.palette(systemDark: true, increasedContrast: false) == AppearanceChoice.dark.palette(systemDark: false, increasedContrast: false))
        for choice in AppearanceChoice.allCases where choice != .system {
            #expect(choice.palette(systemDark: false, increasedContrast: false) == choice.palette(systemDark: true, increasedContrast: false))
            #expect(!choice.title.isEmpty && !choice.detail.isEmpty)
        }
        #expect(AppearanceChoice.system.scheme == nil)
        #expect(AppearanceChoice.dark.scheme == "dark")
    }
    @Test func invalidPreferencesAndInvalidOrMissingColorsCannotEnterPresentation() throws {
        #expect(AppearanceChoice(stored: nil) == .light)
        #expect(AppearanceChoice(stored: "obsolete") == .light)
        for choice in AppearanceChoice.allCases { #expect(AppearanceChoice(stored: choice.rawValue) == choice) }
        #expect(try AppearanceContrast.ratio("#fff", "#000") == 21)
        for invalid in ["", "#fff8", "#gggggg", "transparent"] {
            #expect(throws: AppearanceContrast.Failure.invalidColor) { try AppearanceContrast.ratio(invalid, "#fff") }
        }
        #expect(!AppearanceContrast.valid([:], pairs: StorebenchDesign.shared.contrastPairs))
        var damaged = AppearanceChoice.light.palette(systemDark: false, increasedContrast: false)
        damaged["color-text"] = damaged["color-surface"]
        #expect(!AppearanceContrast.valid(damaged, pairs: StorebenchDesign.shared.contrastPairs))
    }

    @Test func nativeControlsKeepTheirActualForegroundAndSurfaceReadableInEveryState() throws {
        for theme in AppearanceChoice.allCases {
            for systemDark in [false, true] {
                for increased in [false, true] {
                    let palette = theme.palette(systemDark: systemDark, increasedContrast: increased)
                    let minimum = increased || theme.highContrast ? 7.0 : 4.5
                    for variant in ControlColors.Variant.allCases {
                        for enabled in [false, true] {
                            for busy in [false, true] {
                                for emphasized in [false, true] {
                                    for settings in [false, true] {
                                        let colors = ControlColors(variant, enabled: enabled, busy: busy, emphasized: emphasized, settings: settings)
                                        let ink = try #require(palette[colors.foreground]), surface = try #require(palette[colors.background])
                                        #expect(try AppearanceContrast.ratio(ink, surface) >= minimum)
                                        if variant != .primary || !enabled && !busy {
                                            let border = try #require(palette[colors.border])
                                            #expect(try AppearanceContrast.ratio(border, surface) >= 3)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
