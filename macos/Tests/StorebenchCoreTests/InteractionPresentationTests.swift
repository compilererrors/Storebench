import Foundation
import Testing
@testable import StorebenchCore

@Suite struct InteractionPresentationTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func pointerBurstsPublishOnlyTheirLatestFrameAndFinalPosition() {
        var resize = TextSurfaceResizeSession()
        let ticket = resize.begin(height: 140)
        for sample in 1...1000 { resize.queue(translation: Double(sample) / 10, ticket: ticket) }
        #expect(resize.value == 140)
        #expect(resize.take(ticket: ticket) == 240)
        #expect(resize.take(ticket: ticket) == nil)
        resize.queue(translation: 120, ticket: ticket)
        #expect(resize.finish(translation: 123.3, ticket: ticket) == 263)
        #expect(resize.ticket == nil && resize.take(ticket: ticket) == nil)
    }
    @Test func returningToDisplayedHeightSkipsWorkAndCancelledCallbacksStayRetired() {
        var resize = TextSurfaceResizeSession()
        let old = resize.begin(height: 140)
        resize.queue(translation: 60, ticket: old)
        resize.queue(translation: 0.1, ticket: old)
        #expect(resize.take(ticket: old) == nil)
        resize.queue(translation: 60, ticket: old); resize.cancel()
        #expect(resize.take(ticket: old) == nil)
        let next = resize.begin(height: 300)
        resize.queue(translation: 500, ticket: old)
        #expect(resize.finish(translation: 500, ticket: old) == nil)
        resize.queue(translation: -20, ticket: next)
        #expect(resize.take(ticket: next) == 280)
    }
    @Test func absoluteTranslationDoesNotAccumulateAcrossMovingViewsAndFrames() {
        var resize = TextSurfaceResizeSession()
        let ticket = resize.begin(height: 140)
        for delta in [40.0, 80, 120, 60] {
            resize.queue(translation: delta, ticket: ticket)
            #expect(resize.take(ticket: ticket) == 140 + delta)
        }
        resize.queue(translation: .nan, ticket: ticket)
        #expect(resize.take(ticket: ticket) == nil)
        #expect(resize.finish(translation: -5000, ticket: ticket) == 70)
        let next = resize.begin(height: .infinity)
        #expect(resize.finish(translation: 5000, ticket: next) == 800)
    }
    @Test func textMeasurementsReuseOnlyTheirExactInputsAndPlacementConsumesOnce() {
        struct Key: Equatable { let text: String, width: Int, font: Int }
        var cache = LayoutMeasurementCache<Key, Int>(), measured = 0
        let first = Key(text: String(repeating: "Synthetic long text ", count: 1000), width: 300, font: 14)
        for _ in 0..<10_000 {
            #expect(cache.resolve(first) { measured += 1; return 180 } == 180)
        }
        #expect(measured == 1)
        let second = Key(text: first.text, width: 400, font: 14)
        #expect(cache.resolve(second) { measured += 1; return 140 } == 140)
        #expect(cache.consume(first) == nil && cache.consume(second) == nil)
        #expect(cache.resolve(second) { measured += 1; return 140 } == 140)
        #expect(cache.consume(second) == 140 && cache.consume(second) == nil)
        let changed = Key(text: "Changed synthetic text", width: 400, font: 16)
        #expect(cache.resolve(changed) { measured += 1; return 90 } == 90)
        cache.invalidate()
        #expect(cache.resolve(changed) { measured += 1; return 95 } == 95 && measured == 5)
    }
}
