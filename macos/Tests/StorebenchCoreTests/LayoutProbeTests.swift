import Foundation
import Testing
@testable import StorebenchCore

/// SwiftUI probes a view's largest size with an infinite proposal, for example inside menus, popovers and
/// `ViewThatFits`. Every layout track must return finite geometry for such probes instead of trapping.
@Suite struct LayoutProbeTests {
    init() throws { _ = try TestIsolation.require() }

    private let probes: [Double] = [.infinity, -.infinity, .nan, .greatestFiniteMagnitude, -1, 0, 1, 640]

    @Test func usableWidthIsAlwaysFiniteAndNotNegative() {
        for probe in probes {
            let width = ComponentLayout.usableWidth(probe)
            #expect(width.isFinite && width >= 0, "Probe \(probe)")
        }
        #expect(ComponentLayout.usableWidth(nil) == 640)
        #expect(ComponentLayout.usableWidth(.infinity, fallback: 360) == 360)
        #expect(ComponentLayout.usableWidth(.infinity, fallback: .infinity) == 640)
    }

    @Test func actionGridsAcceptEveryProbe() {
        for probe in probes {
            for count in [0, 1, 2, 5] {
                let grid = ComponentLayout.actionGrid(width: probe, heights: Array(repeating: 42, count: count))
                #expect(grid.frames.count == count, "Probe \(probe) with \(count) commands")
                #expect(grid.height.isFinite)
            }
        }
    }

    @Test func columnsAndGridsAcceptEveryProbe() {
        for probe in probes {
            for minimum in [0.0, 190, .infinity, .nan] {
                let columns = ComponentLayout.columns(width: probe, count: 6, maximum: 4, minimumWidth: minimum, spacing: 16)
                #expect((1...4).contains(columns), "Probe \(probe), minimum \(minimum)")
            }
            let grid = ComponentLayout.grid(width: probe, heights: [10, 20, 30])
            #expect((1...3).contains(grid.columns))
            let collection = ComponentLayout.collectionGrid(width: probe, heights: [10, nil, 30], maximum: 3)
            #expect(collection.frames.count == 3)
        }
    }
}
