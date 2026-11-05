import AppKit
import StorebenchCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor enum MediaDownload {
    static func save(_ reader: SavedMediaReader) async throws -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(reader.contentType) ?? .data]; panel.nameFieldStringValue = reader.fileName
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try await reader.export(to: url); return true
    }
}

struct ScreenshotGalleryRequest: Identifiable {
    let id = UUID()
    let items: [ScreenshotSetDraft.Item], initialId: String
    var archivedSources: [SavedMediaSource]? = nil
}

struct SavedScreenshotGallery: View {
    let request: ScreenshotGalleryRequest, scope: Editing, setId: String, session: WorkspaceSession
    let close: () -> Void
    @State private var index = 0
    @State private var reader: SavedMediaReader?
    @State private var image: DecodedScreenshot?
    @State private var zoom: Double?
    @State private var fittedScale = 1.0
    @State private var loading = false
    @State private var saving = false
    @State private var status = ""
    @FocusState private var focused: Bool
    private var selected: ScreenshotSetDraft.Item? { request.items.indices.contains(index) ? request.items[index] : nil }
    var body: some View {
        StorebenchDialog(title: selected?.fileName ?? "Screenshot", wide: true, height: 760, scrollBody: false, media: true,
            subtitle: "\(index + 1) of \(request.items.count)\(image.map { " · \($0.width) × \($0.height) px" } ?? "")", busy: saving, close: close) {
            GeometryReader { bounds in
                if let image {
                    let scale = MediaViewport.scale(imageWidth: Double(image.width), imageHeight: Double(image.height), width: bounds.size.width, height: bounds.size.height, zoom: zoom)
                    ScrollView([.horizontal, .vertical]) {
                        Image(decorative: image.image, scale: 1).resizable().interpolation(.high)
                            .frame(width: Double(image.width) * scale, height: Double(image.height) * scale)
                            .frame(minWidth: bounds.size.width, minHeight: bounds.size.height, alignment: .center)
                            .onTapGesture(count: 2) { zoom = zoom == nil ? 1 : nil }
                            .accessibilityLabel(selected?.fileName ?? "Screenshot")
                            .accessibilityAction(named: Text("Fit image")) { zoom = nil }
                    }.scrollIndicators(.visible).defaultScrollAnchor(.center).id(selected?.id)
                        .onChange(of: scale, initial: true) { if zoom == nil { fittedScale = scale } }

                } else if loading { ProgressView("Reading saved image…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(StorebenchTheme.color("color-surface-subtle"))
        } actions: {
            StorebenchActionGroup(alignment: .leading) {
                if request.items.count >= 2 {
                    Button { move(-1) } label: { StorebenchIcon(name: "previous") }
                        .buttonStyle(StorebenchButtonStyle(.quiet, size: .icon)).help("Previous screenshot").accessibilityLabel("Previous screenshot").storebenchWorking(saving)
                }
                Text("\(index + 1) / \(request.items.count)").font(.sbCaption).monospacedDigit().frame(minWidth: 52)
                if request.items.count >= 2 {
                    Button { move(1) } label: { StorebenchIcon(name: "next") }
                        .buttonStyle(StorebenchButtonStyle(.quiet, size: .icon)).help("Next screenshot").accessibilityLabel("Next screenshot").storebenchWorking(saving)
                }
                if image != nil {
                    Button("Fit") { zoom = nil }.help("Fit the entire image in the viewer")
                    Button("100%") { zoom = 1 }.help("View original pixel size")
                    Button { adjustZoom(1 / 1.25) } label: { StorebenchIcon(name: "down") }.buttonStyle(StorebenchButtonStyle(.quiet, size: .icon)).help("Zoom out").accessibilityLabel("Zoom out")
                    Text("\(Int((zoom ?? fittedScale) * 100))%").font(.sbCaption).monospacedDigit().frame(minWidth: 48).accessibilityLabel("Zoom percentage")
                    Button { adjustZoom(1.25) } label: { StorebenchIcon(name: "plus") }.buttonStyle(StorebenchButtonStyle(.quiet, size: .icon)).help("Zoom in").accessibilityLabel("Zoom in")
                }
                if reader != nil && !loading {
                    Button { Task { await download() } } label: { StorebenchBusyLabel("Download Original…", loading: "Downloading…", busy: saving) }
                        .storebenchWorking(saving)
                }
            }
            StorebenchFeedback(text: status.isEmpty ? "Double-click to switch between Fit and 100%. Scroll to inspect an enlarged image." : status, height: 26)

        }
        .focusable().focused($focused)
        .onKeyPress { press in
            guard !saving, press.modifiers.isEmpty else { return .ignored }
            switch press.key {
            case .leftArrow: move(-1)
            case .rightArrow: move(1)
            default: return .ignored
            }
            return .handled
        }
        .interactiveDismissDisabled(saving)
        .trackUnsavedChanges(false, busy: saving)
        .onAppear { index = request.items.firstIndex(where: { $0.id == request.initialId }) ?? 0; focused = true }
        .task(id: selected?.id) { await load() }
        .onDisappear { reader?.close() }
    }
    private func adjustZoom(_ factor: Double) {
        zoom = min(8, max(0.05, (zoom ?? fittedScale) * factor))
    }
    private func move(_ amount: Int) {
        guard !saving, !request.items.isEmpty else { return }
        reader?.close(); reader = nil; image = nil; zoom = nil
        index = (index + amount + request.items.count) % request.items.count
    }
    private func load() async {
        guard let item = selected else { return }
        reader?.close(); reader = nil; image = nil; status = ""; loading = true
        defer { if selected?.id == item.id { loading = false } }
        var opened: SavedMediaReader?
        do {
            let source: SavedMediaSource
            if let sources = request.archivedSources {
                guard sources.count == request.items.count, sources.indices.contains(index) else { throw SavedMediaFailure.changed }
                source = sources[index]
            } else { source = SavedMediaSource(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, itemId: item.id, kind: .screenshot(setId: setId)) }
            let value = try await session.openSavedMedia(source)
            opened = value
            let data = try await value.imageBytes(), decoded = try await ScreenshotRenderer.loadAsync(data)
            try Task.checkCancellation(); guard selected?.id == item.id else { value.close(); return }
            reader = value; image = decoded
        } catch is CancellationError { opened?.close() }
        catch { opened?.close(); if selected?.id == item.id { status = "This saved image could not be read. It has not been fetched from Apple." } }
    }
    private func download() async {
        guard !saving, let reader else { return }
        saving = true; defer { saving = false }
        do { if try await MediaDownload.save(reader) { status = "Original image downloaded." } }
        catch let failure as SavedMediaFailure { status = failure.message }
        catch let failure as SessionFailure { status = failure.message }
        catch { status = "The image could not be downloaded. The destination was not replaced." }
    }
}

struct ArchivedScreenshotThumbnail: View {
    let shot: LibraryChooser.Shot, session: WorkspaceSession?
    var row: ConnectedApps.Row? = nil
    var imageHeight: CGFloat = 180
    var caption: String? = nil
    @State private var image: ScreenshotPreview?
    @Environment(\.collectionVisible) private var visible
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius).fill(StorebenchTheme.color("color-surface-sunken"))
                if let image { Image(decorative: image.image, scale: 1).resizable().aspectRatio(contentMode: .fit) }
                else if failed { Text("Not saved").font(.sbCaption) } else { ProgressView().controlSize(.small) }
            }.padding(8).frame(height: imageHeight).background(StorebenchTheme.color("color-surface-sunken"))
            StorebenchDivider()
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(caption ?? "Screenshot").font(.sbCaption.weight(.semibold))
                    Spacer(minLength: 0)
                    StorebenchIcon(name: "resize", size: 14)
                }
                Text(shot.fileName).font(.sbCaption).foregroundStyle(StorebenchTheme.muted).lineLimit(2).frame(height: 34, alignment: .topLeading).help(shot.fileName)
            }.padding(10)
        }.background(StorebenchTheme.surface, in: RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
            .clipShape(RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius).strokeBorder(StorebenchTheme.color("color-border-control")))
            .task(id: visible ? shot.source : nil) {
            image = nil; failed = false
            guard visible else { return }
            guard let session else { failed = true; return }
            var reader: SavedMediaReader?
            defer { reader?.close() }
            do {
                if let row { try await session.validateConnectedApp(row) }
                let opened = try await session.openSavedMedia(shot.source); reader = opened
                let bytes = try await opened.imageBytes(), decoded = try await ScreenshotRenderer.thumbnailAsync(bytes, maximumEdge: 640)
                try Task.checkCancellation(); if let row { try await session.validateConnectedApp(row) }
                image = decoded; failed = false
            } catch is CancellationError { } catch { failed = true }
        }
    }
}
