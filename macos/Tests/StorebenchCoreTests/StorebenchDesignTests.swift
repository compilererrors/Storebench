import CoreGraphics
import Foundation
import Testing
@testable import StorebenchCore

@Suite struct StorebenchDesignTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func everySharedWebIconDecodesIntoContainedNativeVectorGeometry() throws {
        let design = StorebenchDesign.shared
        #expect(design.icons.count == 45)
        #expect(design.icons["keyboard"]?.isEmpty == false)
        for (name, primitives) in design.icons {
            #expect(!primitives.isEmpty)
            for primitive in primitives {
                let path = try primitive.path(), bounds = path.boundingBoxOfPath
                #expect(!path.isEmpty, "Icon: \(name)")
                #expect(bounds.minX >= -1 && bounds.minY >= -1 && bounds.maxX <= 25 && bounds.maxY <= 25, "Icon: \(name)")
            }
        }
        // Controls follow the macOS large control size; commands share one width and only long labels widen up to the maximum.
        #expect(design.number("control-height") == 32)
        #expect(design.number("action-min-width") == 160 && design.number("action-max-width") == 220)
        #expect(design.number("workspace-toolbar-height") == 64)
        #expect(design.number("action-width") == 192)
        #expect(design.number("panel-radius") == 12)
        #expect(design.number("action-gap") == design.number("space-3"))
        #expect(design.sections.count == AppNavigation.Section.allCases.count)
        for section in design.sections {
            #expect(AppNavigation.Section(key: section.key)?.rawValue == section.label)
            #expect(design.icons[section.icon] != nil)
        }
        for section in AppNavigation.Section.allCases { #expect(design.icons[section.designIcon] != nil) }
        for pane in SettingsNavigation.Pane.allCases { #expect(design.icons[pane.icon] != nil) }
        for data in [design.brandIcon, design.brandMark, design.wordmark] {
            #expect(Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        }
    }

    @Test func relativeCommandsRepeatedCoordinatesAndClosedPathsRetainTheirEndpoints() throws {
        let primitive = StorebenchDesign.Primitive(tag: "path", attributes: ["d": "M2 3h4v5l-4 0z M10 12 14 16 18 12"])
        let path = try primitive.path()
        #expect(path.currentPoint == CGPoint(x: 18, y: 12))
        #expect(path.boundingBoxOfPath == CGRect(x: 2, y: 3, width: 16, height: 13))
        #expect(throws: StorebenchDesign.Failure.invalidIcon) { try StorebenchDesign.Primitive(tag: "path", attributes: ["d": "M2"]).path() }
        #expect(throws: StorebenchDesign.Failure.invalidIcon) { try StorebenchDesign.Primitive(tag: "path", attributes: ["d": "M2 3 R4 5"]).path() }
    }

    @Test func circularArcsKeepBothEndpointsAndCorrectSweeps() throws {
        let upper = try StorebenchDesign.Primitive(tag: "path", attributes: ["d": "M2 12A10 10 0 0 1 22 12"]).path()
        let lower = try StorebenchDesign.Primitive(tag: "path", attributes: ["d": "M2 12a10 10 0 0 0 20 0"]).path()
        #expect(upper.currentPoint == CGPoint(x: 22, y: 12) && lower.currentPoint == upper.currentPoint)
        #expect(abs(upper.boundingBoxOfPath.minY - 2) < 0.001)
        #expect(abs(upper.boundingBoxOfPath.maxY - 12) < 0.001)
        #expect(abs(lower.boundingBoxOfPath.minY - 12) < 0.001)
        #expect(abs(lower.boundingBoxOfPath.maxY - 22) < 0.001)
        #expect(throws: StorebenchDesign.Failure.invalidIcon) { try StorebenchDesign.Primitive(tag: "path", attributes: ["d": "M2 12A10 10 0 2 1 22 12"]).path() }
    }

    @Test func nativeContrastResolvesStrongerAppearanceAndRetainsTextAndControlBudgets() throws {
        let design = StorebenchDesign.shared
        func luminance(_ name: String, _ increased: Bool) throws -> Double {
            let hex = String(design.colorToken(name, increasedContrast: increased).dropFirst())
            let expanded = hex.count == 3 ? hex.map { "\($0)\($0)" }.joined() : hex
            let rgb = try #require(UInt32(expanded, radix: 16))
            return zip([16, 8, 0], [0.2126, 0.7152, 0.0722]).reduce(0) { sum, pair in
                let channel = Double((rgb >> pair.0) & 255) / 255
                return sum + pair.1 * (channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4))
            }
        }
        for increased in [false, true] {
            for (foreground, background, minimum) in [
                ("color-on-accent", "color-accent", 4.5), ("color-on-accent", "color-accent-strong", 4.5),
                ("color-accent-muted", "color-surface-accent-strong", 4.5), ("color-text-muted", "color-page", 4.5),
                ("color-text-subtle", "color-surface-sunken", 4.5), ("color-nav-muted", "color-nav-active", 4.5),
                ("color-border-control", "color-surface-sunken", 3.0), ("color-border-accent", "color-surface-accent-strong", 3.0),
                ("color-focus", "color-surface", 3.0), ("color-nav-focus", "color-nav-active", 3.0)
            ] {
                let a = try luminance(foreground, increased), b = try luminance(background, increased)
                #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= minimum, "\(foreground) on \(background)")
            }
            #expect(design.colorToken("color-text", increasedContrast: increased) == design.tokens["color-text"])
        }
        for name in ["color-border", "color-border-strong", "color-border-control", "color-border-accent"] {
            #expect(design.colorToken(name, increasedContrast: true) == design.tokens[name + "-high"])
            #expect(design.colorToken(name, increasedContrast: true) != design.colorToken(name))
        }
    }
}
