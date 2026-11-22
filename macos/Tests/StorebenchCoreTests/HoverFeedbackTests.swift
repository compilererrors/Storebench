import Foundation
import Testing
@testable import StorebenchCore

/// One hover look: a disclosure heading, a navigation row, a tab and a quiet command answer the pointer with the same fill,
/// visible on its background and readable in every appearance.
@Suite struct HoverFeedbackTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func quietCommandsAndOtherTargetsShareOneHoverFill() {
        #expect(ControlColors(.quiet, emphasized: true).background == HoverFeedback.fill(on: .surface, hovering: true))
        #expect(HoverFeedback.fill(on: .surface, hovering: false) == nil && HoverFeedback.fill(on: .page, hovering: false) == nil)
        #expect(HoverFeedback.border(hovering: true) != HoverFeedback.border(hovering: false))
    }

    @Test func everyStandardCommandAnswersThePointer() {
        for variant in [ControlColors.Variant.primary, .secondary, .danger] {
            let resting = HoverFeedback.command(variant, hovering: false), over = HoverFeedback.command(variant, hovering: true)
            #expect(resting.tint != over.tint || resting.border != over.border, "\(variant) looks the same under the pointer")
        }
        #expect(HoverFeedback.command(.secondary, hovering: true).border == HoverFeedback.border(hovering: true), "Bordered commands, menus and fields share one hover border")
    }

    @Test func areasAndCommandsShowThePointerWithTheSameBorder() {
        let cue = HoverFeedback.outline(on: .surface, hovering: true)
        #expect(cue == HoverFeedback.border(hovering: true) && cue == HoverFeedback.command(.secondary, hovering: true).border)
        #expect(HoverFeedback.outline(on: .surface, hovering: false) == nil && HoverFeedback.outline(on: .page, hovering: true) == nil)
    }

    @Test func everyHoverColourExistsInEveryAppearance() {
        var names: Set<String> = [HoverFeedback.border(hovering: true), HoverFeedback.border(hovering: false)]
        for ground in HoverFeedback.Ground.allCases { for hovering in [false, true] { for selected in [false, true] { if let fill = HoverFeedback.fill(on: ground, hovering: hovering, selected: selected) { names.insert(fill) } } } }
        for variant in ControlColors.Variant.allCases { for hovering in [false, true] {
            let look = HoverFeedback.command(variant, hovering: hovering); names.insert(look.tint); if let border = look.border { names.insert(border) }
        } }
        for theme in AppearanceChoice.allCases { for dark in [false, true] { for increased in [false, true] {
            let palette = theme.palette(systemDark: dark, increasedContrast: increased)
            for name in names { #expect(palette[name] != nil, "\(theme) has no \(name)") }
        } } }
    }

    @Test func theHoverFillIsVisibleAndItsTextReadableInEveryAppearance() throws {
        for theme in AppearanceChoice.allCases {
            for systemDark in [false, true] {
                for increased in [false, true] {
                    let palette = theme.palette(systemDark: systemDark, increasedContrast: increased)
                    let minimum = increased || theme.highContrast ? 7.0 : 4.5
                    for (ground, background) in [(HoverFeedback.Ground.surface, "color-surface"), (.page, "color-page")] {
                        let hover = try #require(HoverFeedback.fill(on: ground, hovering: true)), selected = try #require(HoverFeedback.fill(on: ground, hovering: false, selected: true))
                        let fill = try #require(palette[hover]), resting = try #require(palette[background]), chosen = try #require(palette[selected])
                        #expect(fill != resting, "\(theme) \(ground): the hover fill shows on its background")
                        #expect(chosen != fill, "\(theme) \(ground): a selected row looks different from a hovered one")
                        for ink in ["color-text", "color-accent-muted", "color-text-secondary"] {
                            #expect(try AppearanceContrast.ratio(try #require(palette[ink]), fill) >= minimum, "\(theme) \(ground) \(ink)")
                        }
                    }
                }
            }
        }
    }
}
