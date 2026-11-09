import AppKit
import StorebenchCore
import SwiftUI

struct ScreenshotImageEditor: View {
    let item: ScreenshotSelection.Item, platform: String, displayType: String?
    var customTargets: [ScreenshotEditing.Target]? = nil
    var outputPNG = false
    let apply: (Data, ScreenshotEdits) throws -> Void, close: () -> Void
    @State private var source: DecodedScreenshot?
    @State private var edits: ScreenshotEdits?
    @State private var preview: ScreenshotPreview?
    @State private var renderedEdits: ScreenshotEdits?
    @State private var dragStart: ScreenshotEdits?
    @State private var working = false
    @State private var loading = true
    @State private var status = ""
    @FocusState private var focused: Bool
    @Environment(\.workspaceHeight) private var viewportHeight
    private var targets: [ScreenshotEditing.Target] {
        var seen: Set<String> = []
        return (customTargets ?? ScreenshotEditing.targets(platform: platform, displayType: displayType)).filter { seen.insert("\($0.width)x\($0.height)").inserted }
    }
    private func initial(_ source: DecodedScreenshot) throws -> ScreenshotEdits {
        guard let customTargets else { return try ScreenshotEditing.initial(platform: platform, width: source.width, height: source.height, displayType: displayType) }
        guard let target = customTargets.first(where: { $0.width == source.width && $0.height == source.height }) ?? customTargets.first else { throw ScreenshotEditFailure.targets }
        return ScreenshotEdits(width: target.width, height: target.height)
    }
    var body: some View {
        StorebenchDialog(title: customTargets == nil ? "Edit Screenshot" : "Edit Library Image", wide: true, height: 780, busy: working, close: close) {
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 300) {
                VStack(alignment: .leading, spacing: 12) {
                    StorebenchTextSlot(text: item.originalName, height: 34, font: .sbCallout)
                    previewPane.padding(16).frame(height: min(440, viewportHeight * 0.48))
                        .background(StorebenchTheme.nav, in: RoundedRectangle(cornerRadius: 12))
                    StorebenchTextSlot(text: "Drag the image to crop. Arrow keys move it; + and − zoom. Proportions stay locked.", height: 48, font: .sbCallout, color: StorebenchTheme.muted)
                    if let source, let edits {
                        Text("Original: \(source.width) × \(source.height) px\nOutput: \(edits.width) × \(edits.height) px")
                            .font(.sbCaption).foregroundStyle(StorebenchTheme.muted).frame(height: 40, alignment: .topLeading)
                    }
                }
                if edits != nil { controls }
            }
        } actions: {
            StorebenchFeedback(text: status.isEmpty ? (loading ? "Opening image…" : renderedEdits != edits ? "Rendering preview…" : "Edits create an opaque \(outputPNG ? "PNG" : "JPEG"). Your original is kept for further edits.") : status, height: 48)
            StorebenchActionGroup(alignment: .trailing) {
                Button("Cancel", role: .cancel) { if !working { close() } }.storebenchWorking(working).keyboardShortcut(.cancelAction)
                if working || source != nil && edits != nil && status.isEmpty {
                    Button { Task { await export() } } label: { StorebenchBusyLabel("Apply Changes", loading: "Applying…", busy: working) }
                        .buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(working || loading || renderedEdits != edits)
                }
            }
        }
        .interactiveDismissDisabled(true)
        .trackUnsavedChanges(edits != nil, busy: working || loading)
        .task {
            defer { loading = false }
            do {
                let decoded = try await ScreenshotRenderer.loadAsync(item.original)
                let initial = try item.edits ?? initial(decoded)
                try Task.checkCancellation(); source = decoded; edits = initial
            } catch is CancellationError {} catch let failure as ScreenshotEditFailure { status = failure.message } catch { status = ScreenshotEditFailure.image.message }
        }
    }

    @ViewBuilder private var previewPane: some View {
        if let source, let value = edits {
            GeometryReader { bounds in
                let ratio = min(bounds.size.width / Double(value.width), bounds.size.height / Double(value.height))
                ZStack {
                    if let preview, renderedEdits == value { Image(decorative: preview.image, scale: 1).resizable().interpolation(.high) }
                    else { Rectangle().fill(StorebenchTheme.color("color-surface-sunken")); ProgressView().accessibilityLabel("Rendering Screenshot Preview") }
                }
                .frame(width: Double(value.width) * ratio, height: Double(value.height) * ratio)
                .contentShape(Rectangle()).focusable(!working, interactions: .edit).focused($focused)
                .accessibilityLabel("Edited screenshot preview")
                .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                    guard !working else { return }
                    focused = true
                    if dragStart == nil { dragStart = value }
                    guard let start = dragStart else { return }
                    edits = ScreenshotEditing.drag(width: source.width, height: source.height, edits: start,
                        startX: gesture.startLocation.x / ratio, startY: gesture.startLocation.y / ratio,
                        deltaX: gesture.translation.width / ratio, deltaY: gesture.translation.height / ratio)
                    status = ""
                }.onEnded { _ in dragStart = nil })
                .onKeyPress { press in
                    guard !working, press.modifiers.subtracting(.shift).isEmpty, var next = edits else { return .ignored }
                    let step = press.modifiers.contains(.shift) ? 0.1 : 0.01
                    switch press.key {
                    case .leftArrow: next.x = min(1, next.x + step)
                    case .rightArrow: next.x = max(0, next.x - step)
                    case .upArrow: next.y = min(1, next.y + step)
                    case .downArrow: next.y = max(0, next.y - step)
                    case "+", "=": next.zoom = min(4, next.zoom + 0.1)
                    case "-": next.zoom = max(1, next.zoom - 0.1)
                    default: return .ignored
                    }
                    edits = next; status = ""; return .handled
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .task(id: value) {
                renderedEdits = nil; preview = nil; status = ""
                do { let result = try await ScreenshotRenderer.previewAsync(source, edits: value); try Task.checkCancellation(); preview = result; renderedEdits = value }
                catch is CancellationError {} catch let failure as ScreenshotEditFailure { status = failure.message } catch { status = ScreenshotEditFailure.render.message }
            }
        } else { Rectangle().fill(StorebenchTheme.color("color-surface-sunken")).overlay { if loading { ProgressView().accessibilityLabel("Reading Original Screenshot") } } }
    }

    private func edit<Value>(_ key: WritableKeyPath<ScreenshotEdits, Value>) -> Binding<Value> {
        Binding(get: { edits![keyPath: key] }, set: { edits?[keyPath: key] = $0; status = "" })
    }
    private func card<Value>(_ key: WritableKeyPath<ScreenshotCard, Value>) -> Binding<Value> {
        Binding(get: { edits!.card[keyPath: key] }, set: { edits?.card[keyPath: key] = $0; status = "" })
    }
    private func text(_ key: WritableKeyPath<ScreenshotCard, String>, maximum: Int) -> Binding<String> {
        Binding(get: { edits!.card[keyPath: key] }, set: { value in
            var result = "", length = 0
            for character in value { let size = String(character).utf16.count; if length + size > maximum { break }; result.append(character); length += size }
            edits?.card[keyPath: key] = result; status = ""
        })
    }
    private func color(_ key: WritableKeyPath<ScreenshotCard, String>) -> Binding<Color> {
        Binding(get: {
            let rgb = UInt32(edits!.card[keyPath: key].dropFirst(), radix: 16) ?? 0
            return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
        }, set: { value in
            guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
            edits?.card[keyPath: key] = String(format: "#%02x%02x%02x", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
            status = ""
        })
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            StorebenchPicker("Output Size", selection: Binding(get: { "\(edits!.width)x\(edits!.height)" }, set: { value in
                guard let target = targets.first(where: { "\($0.width)x\($0.height)" == value }) else { return }
                edits?.width = target.width; edits?.height = target.height; status = ""
            })) { selectionOptions(targets) { target in SelectionOption(target.label, value: "\(target.width)x\(target.height)") } }
            Text("Different proportions crop the edges. The image is never stretched.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
            StorebenchSliderField(title: "Zoom", value: edit(\.zoom), range: 1...4, step: 0.01, percentage: true)
            StorebenchActionGroup(alignment: .trailing) {
                if edits!.zoom > 1 { Button("Zoom Out") { edits?.zoom = max(1, edits!.zoom - 0.1) } }
                if edits!.zoom < 4 { Button("Zoom In") { edits?.zoom = min(4, edits!.zoom + 0.1) } }
                Button("Recenter") { edits?.zoom = 1; edits?.x = 0.5; edits?.y = 0.5 }
            }
            HStack {
                Button("Rotate 90°") { edits?.rotation = (edits!.rotation + 90) % 360; edits?.x = 0.5; edits?.y = 0.5 }
                StorebenchToggle("Flip Horizontally", isOn: edit(\.flip))
            }
            Button("Reset") { if let source { edits = try? initial(source) } }
            DisclosureGroup("Make Image a Card") { cardControls }
            DisclosureGroup("Fine-tune Position and File Size") {
                VStack(alignment: .leading, spacing: 8) {
                    StorebenchSliderField(title: "Horizontal crop position", value: edit(\.x), range: 0...1, step: 0.01, percentage: true)
                    StorebenchSliderField(title: "Vertical crop position", value: edit(\.y), range: 0...1, step: 0.01, percentage: true)
                    StorebenchSliderField(title: "JPEG quality", value: edit(\.quality), range: 0.5...1, step: 0.01, percentage: true)
                    Text("Lower quality reduces file size. The resulting size appears after applying.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                }.padding(.top, 8)
            }
        }.storebenchWorking(working).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var cardControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            StorebenchToggle("Enable Image Card", isOn: card(\.enabled))
            if edits!.card.enabled {
                StorebenchSliderField(title: "Frame width (%)", value: card(\.frame), range: 0...20, step: 0.5)
                StorebenchColorField("Frame Color", selection: color(\.color), supportsOpacity: false)
                StorebenchPicker("Text Placement", selection: card(\.placement)) { SelectionOption("Above Image", value: ScreenshotCard.Placement.above); SelectionOption("Below Image", value: ScreenshotCard.Placement.below) }
                Text("Card Title · \(edits!.card.title.utf16.count)/120")
                StorebenchTextArea(text: text(\.title, maximum: 120), height: StorebenchTheme.textarea(rows: 2)).accessibilityLabel("Card title")
                StorebenchColorField("Title Color", selection: color(\.titleColor), supportsOpacity: false)
                Text("Card Text · \(edits!.card.body.utf16.count)/500")
                StorebenchTextArea(text: text(\.body, maximum: 500), height: StorebenchTheme.textarea(rows: 3)).accessibilityLabel("Card text")
                StorebenchColorField("Text Color", selection: color(\.bodyColor), supportsOpacity: false)
                Text("Text wraps automatically. Explicit line breaks are kept.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
            }
        }
    }
    private func export() async {
        guard !working, let source, let edits, renderedEdits == edits, status.isEmpty else { return }
        working = true; defer { working = false }
        do { let data = try await ScreenshotRenderer.exportAsync(source, edits: edits, png: outputPNG); try Task.checkCancellation(); try apply(data, edits); close() }
        catch is CancellationError {} catch let failure as ScreenshotEditFailure { status = failure.message } catch { status = ScreenshotEditFailure.render.message }
    }
}
