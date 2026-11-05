import StorebenchCore
import SwiftUI
@preconcurrency import AVFoundation
@preconcurrency import AVKit

/// Only this reader's opaque local address is accepted. AVFoundation receives authenticated intervals.
private final class EncryptedMovieLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private final class Request: @unchecked Sendable {
        let token: UUID, value: AVAssetResourceLoadingRequest
        init(_ value: AVAssetResourceLoadingRequest, token: UUID) { self.value = value; self.token = token }
    }
    let reader: SavedMediaReader
    let queue = DispatchQueue(label: "app.storebench.media-reader")
    private var tasks: [ObjectIdentifier: (UUID, Task<Void, Never>)] = [:]
    private var tickets = MediaRequestTickets<ObjectIdentifier>()
    init(_ reader: SavedMediaReader) { self.reader = reader }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard reader.accepts(request.request.url) else {
            request.finishLoading(with: NSError(domain: "StorebenchMedia", code: 2, userInfo: [NSLocalizedDescriptionKey: "Only this saved video is available."]))
            return true
        }
        let key = ObjectIdentifier(request)
        tasks.removeValue(forKey: key)?.1.cancel()
        let owned = Request(request, token: tickets.begin(key))
        request.contentInformationRequest?.contentType = reader.contentType
        request.contentInformationRequest?.contentLength = Int64(reader.length)
        request.contentInformationRequest?.isByteRangeAccessSupported = true
        let task = Task { [self] in
            do {
                if let data = owned.value.dataRequest {
                    let end = try MediaReadPolicy.end(length: reader.length, offset: data.requestedOffset, requested: data.requestedLength, toEnd: data.requestsAllDataToEndOfResource)
                    var offset = max(data.requestedOffset, data.currentOffset)
                    while let range = try MediaReadPolicy.next(length: reader.length, current: offset, end: end) {
                        try Task.checkCancellation()
                        let bytes = try await reader.read(range)
                        guard await deliver(owned, key: key, data: bytes) else { return }
                        offset = Int64(range.upperBound)
                    }
                }
                finish(owned, key: key, error: nil)
            } catch { finish(owned, key: key, error: NSError(domain: "StorebenchMedia", code: 1, userInfo: [NSLocalizedDescriptionKey: "The saved video interval is unavailable."])) }
        }
        tasks[key] = (owned.token, task)
        return true
    }
    private func deliver(_ request: Request, key: ObjectIdentifier, data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard tickets.contains(key, token: request.token), !request.value.isCancelled else { continuation.resume(returning: false); return }
                request.value.dataRequest?.respond(with: data); continuation.resume(returning: true)
            }
        }
    }
    private func finish(_ request: Request, key: ObjectIdentifier, error: NSError?) {
        queue.async { [self] in
            guard tickets.finish(key, token: request.token) else { return }
            tasks.removeValue(forKey: key)
            guard !request.value.isCancelled else { return }
            if let error { request.value.finishLoading(with: error) } else { request.value.finishLoading() }
        }
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        tickets.cancel(ObjectIdentifier(request))
        tasks.removeValue(forKey: ObjectIdentifier(request))?.1.cancel()
    }
    func stop() {
        reader.close()
        queue.async { [self] in tickets.cancelAll(); tasks.values.forEach { $0.1.cancel() }; tasks.removeAll() }
    }
}

@MainActor private final class SavedMoviePlayback {
    let reader: SavedMediaReader, player: AVPlayer
    private let loader: EncryptedMovieLoader
    private var observation: NSKeyValueObservation?
    private var stopped = false
    init(_ reader: SavedMediaReader, onFailure: @escaping @MainActor () -> Void) {
        self.reader = reader; loader = EncryptedMovieLoader(reader)
        let asset = AVURLAsset(url: reader.address)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        observation = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in guard let self, !self.stopped else { return }; onFailure() }
        }
    }
    func seek(_ seconds: Double) {
        player.pause()
        player.seek(to: CMTime(seconds: MediaReadPolicy.poster(seconds, duration: reader.duration ?? 0), preferredTimescale: 100), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func stop() { stopped = true; observation?.invalidate(); observation = nil; player.pause(); player.replaceCurrentItem(with: nil); loader.stop() }
}

struct SavedPreviewPlayer: View {
    let scope: Editing, localizationId: String, type: String, item: PreviewSetDraft.Item, posterTime: Double, session: WorkspaceSession?
    var source: SavedMediaSource? = nil
    var canvasHeight: CGFloat? = nil
    var busyChanged: (Bool) -> Void = { _ in }
    @Environment(\.collectionVisible) private var visible
    @State private var playback: SavedMoviePlayback?
    @State private var loading = false
    @State private var saving = false
    @State private var status = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let playback { VideoPlayer(player: playback.player).aspectRatio(Double(item.width) / Double(item.height), contentMode: .fit).frame(maxWidth: 600, maxHeight: canvasHeight ?? 340).accessibilityLabel("Play \(item.fileName)") }
                else if loading { ProgressView("Opening saved video…").frame(height: canvasHeight ?? 100) }
                else if canvasHeight != nil { Text("Preview unavailable").font(.sbCaption).foregroundStyle(StorebenchTheme.muted).frame(maxWidth: .infinity) }
            }.frame(maxWidth: canvasHeight == nil ? nil : .infinity).frame(height: canvasHeight)
            HStack(spacing: 8) {
                if playback != nil { Button(saving ? "Downloading…" : "Download Original…") { Task { await download() } }.storebenchWorking(saving || loading) }
                if playback == nil && !loading { Button("Retry Playback") { Task { await load() } } }
            }.environment(\.naturalActions, canvasHeight != nil)
            StorebenchFeedback(text: status, height: 34)
        }
        .trackUnsavedChanges(false, busy: saving)
        .task(id: item.sha256) { await load() }
        .onChange(of: posterTime) { playback?.seek(posterTime) }
        .onChange(of: visible) { if !visible { playback?.player.pause() } }
        .onDisappear { playback?.stop(); playback = nil }
    }
    private func load() async {
        guard !loading, !saving, let session else { return }
        loading = true; status = ""; defer { loading = false }
        playback?.stop(); playback = nil
        var opened: SavedMediaReader?
        do {
            let reader = try await session.openSavedMedia(source ?? SavedMediaSource(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, itemId: item.id, kind: .preview(localizationId: localizationId, type: type)))
            opened = reader; try Task.checkCancellation()
            let value = SavedMoviePlayback(reader, onFailure: { status = "The saved video could not be played. Download the original to review it in a video editor." })
            playback = value; value.seek(posterTime)
        } catch is CancellationError { opened?.close() }
        catch { opened?.close(); status = "The saved video could not be opened. No video was fetched from Apple." }
    }
    private func download() async {
        guard !saving, let playback else { return }
        saving = true; busyChanged(true); defer { saving = false; busyChanged(false) }
        do { if try await MediaDownload.save(playback.reader) { status = "Original video downloaded." } }
        catch let failure as SavedMediaFailure { status = failure.message }
        catch let failure as SessionFailure { status = failure.message }
        catch { status = "The original could not be downloaded. The destination was not replaced." }
    }
}
