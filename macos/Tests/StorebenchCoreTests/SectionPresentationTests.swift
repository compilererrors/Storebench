import Foundation
import Testing
@testable import StorebenchCore

@Suite struct SectionPresentationTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func shortCopyUsesItsHeightAndLongCopyCannotMoveAdjacentStatusAndActions() {
        #expect(ComponentLayout.boundedTextHeight(measured: 17, maximum: 60) == 17)
        #expect(ComponentLayout.boundedTextHeight(measured: 600, maximum: 60) == 60)
        #expect(ComponentLayout.boundedTextHeight(measured: 17, maximum: 60, empty: true) == 0)
        for width in [0.0, 210, 390, 768, 1440] {
            let short = ComponentLayout.statusRow(width: width, headingHeight: 42, statusHeight: 30, actionHeight: 42, statusWidth: 124)
            let long = ComponentLayout.statusRow(width: width, headingHeight: 74, statusHeight: 30, actionHeight: 42, detailsHeight: 70, statusWidth: 124)
            #expect(short.status.minX == long.status.minX && short.action.minX == long.action.minX)
            for frame in [long.heading, long.status, long.action, long.details] {
                #expect(frame.minX >= 0 && frame.maxX <= width && frame.maxY <= long.height)
            }
            #expect(abs(Double(long.details.width) - width) < 0.0001)
        }
    }
    @Test func allStatusMeaningsRemainDistinctAndReadableInEveryAppearance() throws {
        let states: [SyncItem.State] = [.synced, .failed, .partial, .attention, .running, .pending, .unchecked, .waiting, .ready]
        #expect(Set(states.map { SyncStatusPresentation($0).label }).count == states.count)
        for choice in AppearanceChoice.allCases {
            for dark in [false, true] {
                for increased in [false, true] {
                    let palette = choice.palette(systemDark: dark, increasedContrast: increased)
                    for state in states {
                        let tone = SyncStatusPresentation(state).tone
                        let ink = try #require(palette[tone == .neutral ? "color-text" : "color-" + tone.rawValue])
                        let surface = try #require(palette[tone == .neutral ? "color-surface-subtle" : "color-" + tone.rawValue + "-surface"])
                        #expect(try AppearanceContrast.ratio(ink, surface) >= (increased || choice.highContrast ? 7 : 4.5))
                    }
                }
            }
        }
    }
}
