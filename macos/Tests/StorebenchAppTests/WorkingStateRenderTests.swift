import AppKit
import StorebenchCore
import SwiftUI
import Testing
@testable import StorebenchApp

/// Loading, failure, missing-step and busy states replace unavailable controls. They render under every proposal,
/// keep fixed status tracks, and a busy lock keeps the normal colours that a disabled control loses.
@MainActor @Suite struct WorkingStateRenderTests {
    init() throws { _ = try TestIsolation.require() }

    private let measurements: [CGSize] = [CGSize(width: CGFloat.infinity, height: .infinity), .zero, CGSize(width: 1, height: 1),
                                          CGSize(width: 320, height: CGFloat.infinity), CGSize(width: CGFloat.infinity, height: 600), CGSize(width: 1440, height: 900)]
    private let placements: [ProposedViewSize] = [.unspecified, .zero, ProposedViewSize(width: 1, height: nil), ProposedViewSize(width: 320, height: nil), ProposedViewSize(width: 1440, height: 900)]

    private func capture<V: View>(_ name: String, _ view: V) {
        let host = NSHostingController(rootView: view)
        for size in measurements {
            let fitted = host.sizeThatFits(in: size)
            #expect(!fitted.width.isNaN && !fitted.height.isNaN, "\(name) measured \(fitted) for \(size)")
            #expect(!size.height.isFinite || fitted.height.isFinite, "\(name) measured \(fitted) for \(size)")
            #expect(!size.width.isFinite || fitted.width.isFinite || fitted.width == size.width, "\(name) measured \(fitted) for \(size)")
        }
        for proposal in placements {
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = proposal; renderer.scale = 1
            let image = renderer.cgImage
            if proposal.width == 320 { #expect(image != nil, "\(name) did not render at \(proposal)") }
        }
    }
    private func height<V: View>(_ view: V, width: CGFloat = 600) -> CGFloat {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: CGFloat.infinity)).height
    }
    /// Rendered RGBA pixels, drawn into a cleared bitmap of known layout so row padding never takes part in a comparison.
    /// Equal means the same size and at most a tiny share of pixels off by anti-aliasing; a disabled control differs everywhere.
    private struct Pixels: Equatable {
        let width: Int, height: Int, bytes: [UInt8]
        static func == (a: Pixels, b: Pixels) -> Bool {
            guard a.width == b.width, a.height == b.height, a.bytes.count == b.bytes.count else { return false }
            var differing = 0
            for index in stride(from: 0, to: a.bytes.count, by: 4) where (0..<4).contains(where: { abs(Int(a.bytes[index + $0]) - Int(b.bytes[index + $0])) > 8 }) { differing += 1 }
            return differing <= max(1, a.width * a.height / 1000)
        }
    }
    private func pixels<V: View>(_ view: V) -> Pixels? {
        let renderer = ImageRenderer(content: view.frame(width: 480).environment(\.colorScheme, .light))
        renderer.scale = 1
        guard let image = renderer.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.clear(rect); context.draw(image, in: rect)
        guard let data = context.data else { return nil }
        return Pixels(width: image.width, height: image.height, bytes: Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * 4 * image.height)))
    }

    private let long = String(repeating: "Synthetic status words ", count: 40)

    @Test func loadStatesRenderEveryPhase() {
        capture("loading", StorebenchLoadState(state: .loading("Reading builds…")) { Text("Content") })
        capture("long loading", StorebenchLoadState(state: .loading(long)) { Text("Content") })
        capture("failed", StorebenchLoadState(state: .failed("Synthetic failure", retry: {})) { Text("Content") })
        capture("long failure", StorebenchLoadState(state: .failed(long, retry: {})) { Text("Content") })
        capture("ready", StorebenchLoadState(state: .ready) { Text("Content") })
    }

    @Test func loadStatusKeepsFixedTracks() {
        let loading = height(StorebenchLoadState(state: .loading("Reading builds…")) { EmptyView() })
        let longLoading = height(StorebenchLoadState(state: .loading(long)) { EmptyView() })
        #expect(abs(loading - longLoading) < 1, "Loading measured \(loading) and \(longLoading)")
        #expect(loading >= StorebenchLoadPhase.statusHeight - 1, "Loading measured \(loading)")
        let failed = height(StorebenchLoadState(state: .failed("Synthetic failure", retry: {})) { EmptyView() })
        let longFailure = height(StorebenchLoadState(state: .failed(long, retry: {})) { EmptyView() })
        #expect(abs(failed - longFailure) < 1, "Failure measured \(failed) and \(longFailure)")
        #expect(failed >= StorebenchLoadPhase.statusHeight + CGFloat(StorebenchTheme.controlHeight), "Failure measured \(failed)")
        let narrow = height(StorebenchLoadState(state: .failed(long, retry: {})) { EmptyView() }, width: 240)
        #expect(abs(narrow - longFailure) < 1, "Narrow failure measured \(narrow)")
    }

    @Test func stepLinksNameTheMissingStep() {
        capture("step link", StorebenchStepLink(sentence: "Choose a build first.", phaseNumber: 3, phaseTitle: "Build"))
        capture("long step link", StorebenchStepLink(sentence: long, phaseNumber: 8, phaseTitle: "Synthetic Phase With A Long Title"))
        #expect(EnvironmentValues().releaseStepNavigation == nil)
    }

    @Test func busyButtonsKeepTheirFootprint() {
        let idle = StorebenchBusyButton(title: "Submit for Review", loadingTitle: "Submitting…", busy: false, variant: .primary) {}
        let busy = StorebenchBusyButton(title: "Submit for Review", loadingTitle: "Submitting…", busy: true, variant: .primary) {}
        capture("idle busy button", idle)
        capture("busy button", busy)
        capture("busy button in group", StorebenchActionGroup { busy; StorebenchBusyButton(title: "Cancel", loadingTitle: "Cancelling…", busy: false) {} })
        let size = CGSize(width: CGFloat.infinity, height: .infinity)
        #expect(NSHostingController(rootView: idle).sizeThatFits(in: size) == NSHostingController(rootView: busy).sizeThatFits(in: size))
    }

    @Test func workingInputsKeepTheirColours() {
        func choices() -> some View {
            StorebenchChoicePicker("Release", selection: .constant(1), options: [(1, "Manually"), (2, "Automatically")])
        }
        let normal = pixels(choices()), working = pixels(choices().storebenchWorking(true)), disabled = pixels(choices().disabled(true))
        #expect(normal != nil)
        #expect(normal == working, "A working choice must render with its normal colours")
        #expect(normal != disabled, "A disabled choice must still render as unavailable")
        let button = { Button("Synthetic") {}.buttonStyle(StorebenchButtonStyle()) }
        // A command whose operation runs is dimmed like an unavailable one, as in macOS; its busy label adds the spinner.
        #expect(pixels(button()) != pixels(button().storebenchWorking(true)))
        #expect(pixels(button().storebenchWorking(false)) == pixels(button()))
        capture("working fields", VStack {
            StorebenchTextField("Name", text: .constant("Synthetic"))
            StorebenchTextArea(title: "Notes", text: .constant("Synthetic"))
            StorebenchDateField("Date", selection: .constant(Date(timeIntervalSince1970: 0)))
            StorebenchCheckbox("Synthetic", isOn: .constant(true))
            choices()
        }.storebenchWorking(true))
    }
}
