import StorebenchCore
import SwiftUI

/// A single zoom tool shared by image inspection and crop editing.
struct StorebenchZoomControl: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0.05...8
    var step: Double? = nil
    var fitted = false
    var fit: (() -> Void)? = nil
    var identifier = "media.zoom"

    private var percentage: String { value.formatted(.percent.precision(.fractionLength(0))) }
    private var slider: Binding<Double> {
        Binding(get: { log2(max(range.lowerBound, value)) }, set: { value = min(range.upperBound, max(range.lowerBound, pow(2, $0))) })
    }
    private func change(_ direction: Double) {
        let next = step.map { value + direction * $0 } ?? value * pow(1.25, direction)
        value = min(range.upperBound, max(range.lowerBound, next))
    }
    private var choices: [SelectionOption<String>] {
        let presets = [0.25, 0.5, 1, 1.25, 1.5, 2, 3, 4, 8].filter { range.contains($0) }
        var options: [SelectionOption<String>] = []
        if fit != nil { options.append(SelectionOption(fitted ? "Fit · " + percentage : "Fit Image", value: "fit")) }
        if !presets.contains(value), !fitted { options.append(SelectionOption(percentage, value: String(value))) }
        options += presets.map { SelectionOption($0.formatted(.percent.precision(.fractionLength(0))), value: String($0)) }
        return options
    }
    var body: some View {
        HStack(spacing: StorebenchTheme.space(2)) {
            HStack(spacing: 0) {
                StorebenchIconButton(title: "Zoom Out", icon: "minus") { change(-1) }
                    .storebenchControlID(identifier + ".out").disabled(value <= range.lowerBound)
                StorebenchIconButton(title: "Zoom In", icon: "plus") { change(1) }
                    .storebenchControlID(identifier + ".in").disabled(value >= range.upperBound)
            }
            .background(StorebenchTheme.color("color-surface-subtle"), in: RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
            StorebenchSlider(value: slider, in: log2(range.lowerBound)...log2(range.upperBound))
                .frame(minWidth: 44, maxWidth: 120).accessibilityLabel("Zoom")
                .accessibilityValue(percentage).storebenchControlID(identifier + ".slider")
            StorebenchNativePicker(title: "Zoom Level", selection: Binding(get: { fitted ? "fit" : String(value) }, set: { choice in
                if choice == "fit" { fit?() }
                else if let zoom = Double(choice), range.contains(zoom) { value = zoom }
            }), options: choices)
            .frame(width: 108)
            .help("Zoom: " + percentage + ". Choose a magnification" + (fit == nil ? "." : " or fit the entire image."))
            .accessibilityLabel("Zoom Level").accessibilityValue((fitted ? "Fit Image, " : "") + percentage)
            .storebenchControlID(identifier + ".level")
        }
        .environment(\.naturalActions, true)
        .accessibilityElement(children: .contain).accessibilityLabel("Image Zoom")
    }
}

struct StorebenchCropControls: View {
    @Binding var zoom: Double
    var identifier = "media.crop"
    let recenter: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
            HStack(spacing: StorebenchTheme.space(2)) {
                Text("Crop and Zoom").font(.sbCallout.weight(.semibold))
                Spacer(minLength: 0)
                StorebenchIconButton(title: "Recenter Crop", icon: "center", action: recenter)
                    .storebenchControlID(identifier + ".recenter")
            }
            StorebenchZoomControl(value: $zoom, range: 1...4, step: 0.1, identifier: identifier + ".zoom")
        }
    }
}

/// Groups stay intact when a narrower image sheet needs two rows.
struct StorebenchMediaToolbar<Navigation: View, Zoom: View, Actions: View>: View {
    @ViewBuilder let navigation: () -> Navigation
    @ViewBuilder let zoom: () -> Zoom
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: StorebenchTheme.space(4)) {
                navigation().fixedSize()
                Spacer(minLength: 0)
                zoom().frame(width: 300)
                Spacer(minLength: 0)
                actions().fixedSize()
            }.fixedSize(horizontal: true, vertical: false)
            VStack(spacing: StorebenchTheme.space(2)) {
                HStack(spacing: StorebenchTheme.space(2)) { navigation(); Spacer(minLength: 0); actions() }
                zoom().frame(maxWidth: 320)
            }
        }.frame(maxWidth: .infinity)
    }
}
