import AppKit
import SwiftUI

struct StorebenchSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 0.01
    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 0.01) {
        _value = value; self.range = range; self.step = step
    }
    var body: some View {
        Slider(value: $value, in: range, step: step)
            .tint(StorebenchTheme.accent)
            .frame(minWidth: 0, maxWidth: .infinity).frame(height: StorebenchTheme.controlHeight)
            .accessibilityValue(value.formatted(.number.precision(.fractionLength(0...2))))
    }
}

/// Exact values and a native slider share one bounded editor and update the preview together.
struct StorebenchSliderField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 0.01
    var percentage = false
    private var bounded: Binding<Double> {
        Binding(get: { value }, set: { next in
            guard next.isFinite else { return }
            value = min(range.upperBound, max(range.lowerBound, next))
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
            HStack(spacing: StorebenchTheme.space(3)) {
                StorebenchTextSlot(text: title, height: StorebenchTheme.controlHeight, font: .sbCallout.weight(.semibold), centered: true)
                if percentage {
                    StorebenchTextField(title, value: bounded, format: .percent.precision(.fractionLength(0...1))).labelsHidden().frame(width: 100)
                } else {
                    StorebenchTextField(title, value: bounded, format: .number.precision(.fractionLength(0...2))).labelsHidden().frame(width: 100)
                }
            }
            StorebenchSlider(value: bounded, in: range, step: step).accessibilityLabel(title)
                .accessibilityValue(percentage ? value.formatted(.percent.precision(.fractionLength(0...1))) : value.formatted(.number.precision(.fractionLength(0...2))))
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

struct StorebenchColorField: View {
    let title: String
    @Binding var selection: Color
    let supportsOpacity: Bool
    @Environment(\.isEnabled) private var enabled
    init(_ title: String, selection: Binding<Color>, supportsOpacity: Bool = false) { self.title = title; _selection = selection; self.supportsOpacity = supportsOpacity }
    init(_ title: String, hex: Binding<String>) {
        self.title = title; supportsOpacity = false
        _selection = Binding(get: {
            let rgb = UInt32(hex.wrappedValue.dropFirst(), radix: 16) ?? 0
            return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
        }, set: { value in
            guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
            hex.wrappedValue = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        })
    }
    var body: some View {
        StorebenchFormField(label: title) {
            ColorPicker(title, selection: $selection, supportsOpacity: supportsOpacity).labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 11)
                .frame(height: StorebenchTheme.controlHeight)
                .background(enabled ? StorebenchTheme.surface : StorebenchTheme.color("color-surface-sunken"), in: RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
                .overlay(StorebenchControlOutline())
                .accessibilityLabel(title)
        }
    }
}
