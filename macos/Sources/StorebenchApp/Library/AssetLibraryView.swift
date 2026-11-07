import AppKit
import StorebenchCore
import SwiftUI
import UniformTypeIdentifiers

struct AssetLibraryView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    let openReview: (PublishReview) -> Bool
    @State private var snapshot: AssetLibrary.Snapshot?
    @State private var files: [AssetLibrary.File] = []
    @State private var fresh = false
    @State private var working = false
    @State private var status = ""
    @State private var issueCode: String?
    @State private var observations: [AssetLibraryVersions.Observation] = []
    @State private var selectedId = ""
    @State private var referenceName = ""
    @State private var timeCode = ""
    @State private var selectedIDs: Set<String> = []
    @State private var category: AssetLibrary.Category = .creative
    @State private var localName = ""
    @State private var localTime = "00:00:05:00"
    @State private var surface: AssetLibrary.Surface = .versions
    @State private var targets: [AssetLibrary.Target] = []
    @State private var targetId = ""
    @State private var slotId = ""
    @State private var placements: [AssetLibrary.Placement] = []
    @State private var orderEditor: AssetLibraryOrderEditor?
    @State private var orderReadTicket = UUID()
    @State private var orderLoading = false
    @State private var group = ""
    @State private var targetFresh = false
    @State private var platform = "MAC_OS"
    @State private var submissionId = ""
    @State private var reviewChoices: [PublishingWorkspace.Choice] = []
    @State private var prepared: PublishReview?
    @State private var preview: DecodedScreenshot?
    @State private var previewIssue = ""
    @State private var uses: [AssetLibrary.Placement]?
    private struct ImageEdit: Identifiable { let id = UUID(), file: AssetLibrary.File, item: ScreenshotSelection.Item, targets: [ScreenshotEditing.Target] }
    @State private var editingImage: ImageEdit?
    @State private var playingFile: AssetLibrary.File?
    @State private var playbackBusy = false
    /// A chosen file that could not be saved on this Mac. It stays under On This Mac until it is added or discarded.
    private struct PendingFile: Identifiable { let id = UUID(), url: URL, category: AssetLibrary.Category, name: String, timeCode: String?; var reason = "" }
    @State private var notAdded: [PendingFile] = []
    @Environment(\.editorProtection) private var protection
    @Environment(\.confirmDestructive) private var confirm
    @Environment(\.navigationPresentation) private var history
    @State private var restoring: Choices?
    private struct Choices: Equatable { var selectedId: String; var surface: AssetLibrary.Surface; var targetId, group: String }
    private struct Read: Codable { let snapshot: AssetLibrary.Snapshot, files: [AssetLibrary.File], observations: [AssetLibraryVersions.Observation] }
    private var readKey: String { "asset-library/\(account.id)/\(app.id)" }
    /// Back returns to the open asset and placement destination. The destination and its placements are read again before they can be changed.
    private var choiceValue: Binding<Choices> {
        Binding(get: { restoring ?? Choices(selectedId: selectedId, surface: surface, targetId: targetId, group: group) }, set: { value in
            restoring = value; selectedId = value.selectedId; surface = value.surface
            if let asset = snapshot?.assets.first(where: { $0.id == value.selectedId }) { referenceName = asset.referenceName; timeCode = asset.value["attributes"]?["previewFrameTimeCode"]?.text ?? "" }
        })
    }
    private var selected: AssetLibrary.Asset? { snapshot?.assets.first { $0.id == selectedId } }
    private var target: AssetLibrary.Target? { targets.first { $0.id == targetId } }
    private var slots: [AssetLibrary.Slot] {
        guard let target, let selected, let spec = selected.specId else { return [] }
        return snapshot?.catalog.slots(surface: surface, platform: target.platform.isEmpty ? nil : target.platform, category: selected.category, specId: spec) ?? []
    }
    private var assetEdited: Bool { selected.map { referenceName != $0.referenceName || timeCode != ($0.value["attributes"]?["previewFrameTimeCode"]?.text ?? "") } == true }
    private var operationBusy: Bool { working || orderLoading || orderEditor?.busy == true }
    private var groupPlacements: [AssetLibrary.Placement] { placements.filter { $0.group == group } }
    private var rows: [AssetLibraryTable.Row] { AssetLibraryTable.rows(snapshot?.assets ?? [], catalog: snapshot?.catalog, observations: observations) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card(title: "Asset Library", subtitle: "Upload originals once, reuse them across languages and App Store surfaces, and follow processing and review. Apple changes open a concrete review in App Store changes.", help: "media") {
                StorebenchActionGroup {
                    StorebenchReadButton("Refresh") { await refresh(fresh: true) }.storebenchWorking(working)
                    if let snapshot { Text("\(snapshot.assets.count) assets at Apple · \(files.count) saved local files").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
                }
                if !fresh && !working { Text(snapshot == nil ? "Apple's library has not been read. Saved local files remain available." : "The displayed Apple library could not be refreshed. Read it again before preparing changes.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
                StorebenchFeedback(text: status, height: 56)
                RecoveryActions(code: issueCode)
                if let prepared { Button("Open Review") { _ = openReview(prepared) }.help("Open Prepared Review").accessibilityLabel("Open Prepared Review").storebenchWorking(working) }
            }
            localFilesCard
            DisclosureGroup("Creative assets for header and search") {
                Text("Choose Creative Assets for images or videos used in the product page header or search results. Upload the original, submit it for App Review, then place the approved asset in the matching language and destination.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                Text("Header images: 3840 × 1646 px. Search images: 3:2, from 1920 × 1280 to 3840 × 2560 px. A 5244 × 2950 PNG can serve both placements. Images must have no alpha channel. Videos have separate requirements; check the current Apple specification before upload.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                StorebenchTextLink("Apple creative asset specifications", destination: URL(string: "https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications")!)
                StorebenchTextLink("Apple placement guidelines and templates", destination: URL(string: "https://developer.apple.com/app-store/product-page/")!)
            }
            libraryCard
            if let selected { selectedCard(selected) }
            placementsCard
            submissionCard
            specificationsCard
        }
        .task { showRemembered(); await refresh(); await applyRestoring() }
        .historyValue("asset-library", choiceValue)
        .trackUnsavedChanges(assetEdited && prepared == nil || orderEditor?.dirty == true || !notAdded.isEmpty, busy: operationBusy)
        .onChange(of: referenceName) { prepared = nil }
        .onChange(of: timeCode) { prepared = nil }
        .onChange(of: orderEditor?.order) { prepared = nil }
        .onDisappear { orderReadTicket = UUID(); orderLoading = false; orderEditor?.retire() }
        .onChange(of: localName) { prepared = nil }
        .task(id: selectedId) { await loadPreview() }
        .sheet(item: $editingImage) { edit in
            ScreenshotImageEditor(item: edit.item, platform: "MAC_OS", displayType: nil, customTargets: edit.targets, outputPNG: true, apply: { data, _ in
                working = true
                Task {
                    defer { working = false }; guard let session else { return }
                    do { _ = try await session.stageEditedLibraryImage(accountId: account.id, appId: app.id, sourceId: edit.file.id, bytes: data); files = try await session.assetLibraryFiles(accountId: account.id, appId: app.id); status = "Edited PNG saved locally. Your original is kept. Review Upload to send it to Apple." }
                    catch { problem(error, fallback: "The edited image could not be saved.") }
                }
            }, close: { editingImage = nil })
        }
        .sheet(item: $playingFile) { file in
            StorebenchDialog(title: file.fileName, wide: true, height: 620, busy: playbackBusy, close: { if !playbackBusy { playingFile = nil } }) {
                SavedPreviewPlayer(scope: .init(accountId: account.id, appId: app.id, revisionId: file.id, local: true), localizationId: "", type: "", item: .init(id: file.id, fileName: file.fileName, sha256: file.hash, ext: file.ext, width: file.width, height: file.height, duration: file.duration ?? 0), posterTime: 0, session: session,
                    source: .init(accountId: account.id, appId: app.id, revisionId: file.id, itemId: file.id, kind: .assetLibrary), busyChanged: { playbackBusy = $0 })
            } actions: { EmptyView() }
                .interactiveDismissDisabled(playbackBusy)
        }
    }
    private var localFilesCard: some View {
        Card(title: "On This Mac", subtitle: "Added files are checked and saved on this Mac right away, in encrypted storage. Nothing is uploaded to Apple until you review and approve it.") {
            StorebenchMetricGrid(maximumColumns: 3, minimumWidth: 200) {
                StorebenchPicker("Category", selection: $category) { selectionOptions(AssetLibrary.Category.allCases) { SelectionOption($0.label, value: $0) } }
                StorebenchTextField("Reference name for the next file (optional)", text: $localName)
                StorebenchTextField("Video preview frame · HH:MM:SS:FF", text: $localTime)
            }.storebenchWorking(working)
            StorebenchFileDropZone(title: "Drop images or videos here", detail: "PNG, JPEG, MP4, M4V or MOV · added files are saved on this Mac right away. Review Upload sends a file to Apple after approval.", disabled: operationBusy || session == nil, choose: chooseFiles, drop: importFiles)
            ForEach(notAdded) { file in
                StorebenchNotSavedRow(title: file.url.lastPathComponent + " not added", reason: file.reason, next: "Try Again",
                                      retry: { if !operationBusy { add([file]) } }, discard: { notAdded.removeAll { $0.id == file.id } })
            }.storebenchWorking(operationBusy)
            VStack(alignment: .leading, spacing: 0) {
                StorebenchCollection(items: files, title: { $0.referenceName.isEmpty ? $0.fileName : $0.referenceName }, subtitle: { "Local " + $0.kind.rawValue + " · " + $0.category.label }, maximumColumns: 4, cardSurface: false, initialOpeningLimit: -1,
                                     empty: "No local originals yet. Drop images or videos above, or choose Choose Files…") { file in
                    StorebenchAssetCard(title: file.referenceName.isEmpty ? file.fileName : file.referenceName + "\n" + file.fileName,
                        metadata: "\(file.width) × \(file.height) px · \(file.size / 1024) KiB · \(file.category.label)", status: file.kind == .image ? "Local image" : "Local video") {
                        if file.kind == .image {
                            LocalLibraryThumbnail(accountId: account.id, appId: app.id, file: file, session: session).accessibilityLabel(file.fileName)
                        } else {
                            Button { playbackBusy = false; playingFile = file } label: {
                                VStack(spacing: StorebenchTheme.space(3)) {
                                    StorebenchIcon(name: "play", size: 32)
                                    Text("Play video").font(.sbHeadline)
                                    if let duration = file.duration { Text(duration.formatted(.number.precision(.fractionLength(1))) + " seconds").font(.sbCaption) }
                                }.frame(maxWidth: .infinity).frame(height: StorebenchTheme.measure("assetPreviewHeight") - 2 * StorebenchTheme.measure("assetPreviewPadding"))
                                    .foregroundStyle(StorebenchTheme.color("color-accent-muted")).contentShape(Rectangle())
                                    .overlay(StorebenchControlOutline(border: .clear))
                            }.buttonStyle(StorebenchPressStyle()).help("Play " + file.fileName).accessibilityLabel("Play " + file.fileName)
                                .storebenchWorking(working || session == nil)
                        }
                    } actions: {
                        VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
                            StorebenchTextSlot(text: snapshot.map { $0.catalog.matching(file).isEmpty ? "No matching Apple specification. Check Specifications below." : "Matches \($0.catalog.matching(file).count) current Apple specifications." } ?? "Read Apple's specifications to check compatibility.", height: 40, font: .sbCaption, color: StorebenchTheme.muted)
                            if fresh && snapshot?.catalog.matching(file).isEmpty == false {
                                Button("Review Upload") { var change = AssetLibrary.Change(action: .upload); change.fileId = file.id; change.kind = file.kind; Task { await prepare(change) } }.help("Review Upload or Resume").accessibilityLabel("Review Upload or Resume")
                                    .buttonStyle(StorebenchButtonStyle(.primary, stretch: true)).storebenchWorking(working)
                            }
                            StorebenchMenu("More actions", icon: "settings") {
                                Button("Export Original") { Task { await export(file) } }.storebenchWorking(working)
                                if file.kind == .image { if fresh && snapshot?.catalog.editingTargets(category: file.category).isEmpty == false { Button("Edit Image") { Task { await edit(file) } }.storebenchWorking(working) } }
                                else { Button("Play Video") { playbackBusy = false; playingFile = file }.storebenchWorking(working || session == nil) }
                                Button("Remove Local File", role: .destructive) {
                                    if confirm(.removeLocalFile, title: "Remove this local file from Asset Library?", message: "Remove \(file.fileName) from this app's local library. Any uploaded Apple asset remains available.", action: "Remove Local File") { remove(file) }
                                }.storebenchWorking(working)
                            }.environment(\.naturalActions, true).frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }
    private var libraryCard: some View {
        AssetLibraryAssetsCard(account: account, appId: app.id, session: session, rows: rows, fresh: fresh, working: working, read: snapshot != nil,
            selectedIDs: $selectedIDs, open: select, selectionChanged: { prepared = nil })
    }
    private func selectedCard(_ asset: AssetLibrary.Asset) -> some View {
        Card(title: "Selected asset", subtitle: asset.fileName) {
            if let preview { Image(decorative: preview.image, scale: 1).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: .infinity, maxHeight: 280).accessibilityLabel(asset.name) }
            StorebenchTextSlot(text: previewIssue, height: 34, font: .sbCaption, color: StorebenchTheme.muted, live: true)
            StorebenchStateLabel(code: asset.state)
            if let modified = AppStoreNames.date(asset.modified) { Text("Modified " + modified).font(.sbCaption).foregroundStyle(StorebenchTheme.muted) }
            StorebenchTextSlot(text: asset.details, height: asset.details.isEmpty ? 24 : 80, font: .sbCallout, color: StorebenchTheme.muted)
            StorebenchTextField("Reference name", text: $referenceName).storebenchWorking(working)
            if asset.kind == .video { StorebenchTextField("Preview frame · HH:MM:SS:FF", text: $timeCode).storebenchWorking(working) }
            StorebenchActionGroup {
                if fresh {
                    Button("Review Rename") { manage(asset, action: .rename) }.storebenchWorking(!(referenceName != asset.referenceName))
                    if asset.kind == .video {
                        let frame = Self.frameUnavailable(asset, timeCode: timeCode)
                        Button("Review Frame") { manage(asset, action: .poster) }.storebenchWorking(frame != nil).help(frame ?? "Review Preview Frame").accessibilityLabel("Review Preview Frame")
                    }
                    Button("Show Where It's Used") { Task { await readUsage(asset) } }
                    // Archive and Restore are one command that follows the asset's state.
                    let archived = asset.state == "ARCHIVED"
                    Button(archived ? "Review Restore" : "Review Archive") { manage(asset, action: archived ? .restore : .archive) }
                        .storebenchWorking(!archived && asset.state != "APPROVED")
                        .help(archived ? "Review restoring this asset" : asset.state == "APPROVED" ? "Review archiving this asset" : "Only an approved asset can be archived")
                    Button("Review Delete") { manage(asset, action: .delete) }.storebenchWorking(asset.state != "PREPARE_FOR_SUBMISSION")
                        .help(asset.state == "PREPARE_FOR_SUBMISSION" ? "Review deleting this asset" : "Only an asset in Prepare for Submission can be deleted; archive it instead")
                }
            }.storebenchWorking(working)
            StorebenchTextSlot(text: !fresh && assetEdited ? "Not sent for review yet. Choose Refresh above, then review this change." : "", height: 34, font: .sbCallout, color: StorebenchTheme.color("color-danger"), live: true)
            if let uses {
                Text(uses.isEmpty ? "This asset has no placements." : "Used by \(uses.count) placements. Remove a placement from its destination before deleting the asset.").font(.sbCallout)
                ForEach(uses) { use in StorebenchTextSlot(text: "\(AppStoreNames.placementType(use.type)) · \(use.group) · \(AppStoreNames.state(use.state))", height: 34, font: .sbCaption, color: StorebenchTheme.muted) }
            }
        }
    }
    /// Why a video's preview frame cannot be reviewed now; nil when it can.
    private static func frameUnavailable(_ asset: AssetLibrary.Asset, timeCode: String) -> String? {
        if asset.state == "APPROVED" { return "Apple has approved this preview, so its frame can no longer change" }
        if !asset.ready { return "Apple is still processing this preview" }
        if timeCode.isEmpty { return "Enter the preview frame time code first" }
        return nil
    }
    private var placementsCard: some View {
        Card(title: "Where It's Used", subtitle: "Where this app's Asset Library files appear. A version's screenshots and app previews are added and ordered in one place: Release, step 2. Custom product pages, in-app events and product page optimizations are set here.") {
            StorebenchPicker("Surface", selection: Binding(get: { surface }, set: { value in guard !operationBusy, protection?.allowLeaving() != false else { return }; orderEditor?.retire(); orderEditor = nil; surface = value; targets = []; targetId = ""; placements = []; group = ""; targetFresh = false; prepared = nil })) {
                selectionOptions(AssetLibrary.Surface.allCases) { SelectionOption($0.label, value: $0) }
            }.storebenchWorking(working)
            StorebenchPicker("Destination", selection: Binding(get: { targetId }, set: { value in guard !operationBusy, protection?.allowLeaving() != false else { return }; orderEditor?.retire(); orderEditor = nil; targetId = value; targetFresh = false; placements = []; group = ""; prepared = nil; Task { await readPlacements() } })) {
                SelectionOption("Choose a destination", value: ""); selectionOptions(targets) { SelectionOption("\($0.name) · \(AppStoreNames.state($0.state))", value: $0.id) }
            }.storebenchWorking(working)
            if let target {
                Text(target.editable ? "Editable destination · current placements below." : target.liveCreative ? "Live version · approved creative assets can be placed or removed after Publish approval. Screenshots and previews need an editable version." : "This destination is not editable. Choose another destination to change placements.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                Button("Refresh Placements") { Task { await readPlacements(fresh: true) } }.storebenchWorking(working)
            }
            StorebenchPicker("Compatible placement for selected asset", selection: $slotId) {
                SelectionOption("Choose a placement", value: ""); selectionOptions(slots) { SelectionOption("\($0.label) · maximum \($0.limit)", value: $0.id) }
            }.storebenchWorking(working)
            StorebenchCollection(items: placements, title: { placement in snapshot?.assets.first { $0.id == placement.assetId }?.name ?? placement.assetId }, subtitle: { $0.type + " · " + $0.group },
                                 empty: target == nil ? "Choose a destination to see what is used there. Show Destinations lists the ones you can change." : "No placements in this destination yet. Select an asset and a compatible placement, then choose Review Placement.") { placement in
                StorebenchStatusRow(title: snapshot?.assets.first { $0.id == placement.assetId }?.name ?? placement.assetId, detail: "\(placement.type) · \(placement.group)", status: { Text(AppStoreNames.state(placement.state)).font(.sbCaption) }, action: {
                    if fresh && targetFresh && surface != .versions && canRemove(placement) { Button("Review Removal") { var change = AssetLibrary.Change(action: .removePlacement); change.surface = surface; change.targetId = targetId; change.placementId = placement.id; Task { await prepare(change) } }.storebenchWorking(working) }
                }, details: {})
            }
            if surface == .versions {
                StorebenchStepLink(sentence: "Add and order this version's screenshots and app previews in Release, step 2. Its Save adds them to App Previews and Screenshots.", phaseNumber: 2, phaseTitle: "Text and Screenshots")
            } else if surface != .events { orderingControls }
            if fresh {
                StorebenchFormFooter {
                    Button("Show Destinations") { Task { await readTargets() } }
                    if targetFresh && canPlaceSelected && surface != .versions {
                        Button("Review Placement") {
                            guard let asset = selected, let target, let slot = slots.first(where: { $0.id == slotId }) else { return }
                            var change = AssetLibrary.Change(action: .place); change.assetId = asset.id; change.kind = asset.kind; change.surface = surface; change.targetId = target.id; change.placementType = slot.type; change.placementGroup = slot.group
                            Task { await prepare(change) }
                        }
                    }
                }.storebenchWorking(working)
            }
        }.storebenchWorking(operationBusy)
    }
    private var canPlaceSelected: Bool {
        guard let target, let selected, selected.ready, let slot = slots.first(where: { $0.id == slotId }) else { return false }
        return target.allowsPlacement(selected, slot: slot)
    }
    private func canRemove(_ placement: AssetLibrary.Placement) -> Bool {
        guard let target else { return false }
        return target.editable || target.liveCreative && snapshot?.assets.first(where: { $0.id == placement.assetId })?.category == AssetLibrary.Category.creative.rawValue
    }
    private var orderingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            StorebenchPicker("Order placement group", selection: Binding(get: { group }, set: { value in guard !operationBusy, protection?.allowLeaving() != false else { return }; group = value; orderEditor?.retire(); orderEditor = nil; Task { await loadOrder() }; prepared = nil })) {
                SelectionOption("Choose a group", value: ""); selectionOptions(Array(Set(placements.map(\.group))).sorted()) { SelectionOption($0, value: $0) }
            }.storebenchWorking(working)
            if let orderEditor {
                AssetLibraryOrderView(editor: orderEditor, account: account, appId: app.id, placements: groupPlacements, assets: snapshot?.assets ?? [], session: session,
                    editable: !working && target?.editable == true, fresh: fresh && targetFresh, prepare: prepare)
            } else if !group.isEmpty && targetFresh { Button(orderLoading ? "Reading…" : "Read Local Order") { Task { await loadOrder() } }.storebenchWorking(operationBusy) }
        }
    }
    private var submissionCard: some View {
        Card(title: "App Review", subtitle: "Submit selected library assets independently after this platform has an approved app version. Assets for a first version travel with that version's submission. Creative Assets must be suitable for ages 4+.") {
            Text("\(selectedIDs.count) assets selected").font(.sbHeadline)
            StorebenchPicker("Review platform", selection: $platform) { SelectionOption("macOS", value: "MAC_OS"); SelectionOption("iOS", value: "IOS"); SelectionOption("tvOS", value: "TV_OS"); SelectionOption("visionOS", value: "VISION_OS") }.storebenchWorking(working)
            StorebenchPicker("Submission", selection: $submissionId) { SelectionOption("Create a new submission", value: ""); selectionOptions(reviewChoices) { SelectionOption($0.name, value: $0.id) } }.storebenchWorking(working)
            if fresh {
                StorebenchFormFooter {
                    Button("Read Submissions") { Task { await readSubmissions() } }.help("Read Draft Submissions").accessibilityLabel("Read Draft Submissions")
                    if !selectedIDs.isEmpty {
                        Button("Review Selection") {
                            let selected = snapshot?.assets.filter { selectedIDs.contains($0.id) } ?? []
                            guard let kind = selected.first?.kind else { return }
                            var change = AssetLibrary.Change(action: .submit); change.kind = kind; change.assetIds = selected.map(\.id).sorted(); change.platform = platform; change.submissionId = submissionId.isEmpty ? nil : submissionId
                            Task { await prepare(change) }
                        }.help("Review Selected Assets for App Review").accessibilityLabel("Review Selected Assets for App Review")
                    }
                }.storebenchWorking(working)
            }
        }.onChange(of: platform) { reviewChoices = []; submissionId = ""; prepared = nil }
    }
    private var specificationsCard: some View {
        Card(title: "Specifications", subtitle: "Dimensions, formats, placement groups and limits are read from Apple each time the library is refreshed.") {
            DisclosureGroup("Show current image and video requirements") {
                StorebenchCollection(items: snapshot?.catalog.specs ?? [], title: { $0.id }, subtitle: { $0.kind.rawValue.capitalized },
                                     empty: "Apple's specifications have not been read yet. Choose Refresh above.") { spec in
                    VStack(alignment: .leading, spacing: 4) { StorebenchTextSlot(text: spec.description, height: 56, font: .sbCallout); Text(spec.id).font(.sbCaption).foregroundStyle(StorebenchTheme.muted) }.padding(.vertical, 8)
                }
            }.disclosureGroupStyle(StorebenchDisclosureStyle())
        }
    }
    private func loadOrder() async {
        guard !operationBusy, !group.isEmpty, targetFresh, let session else { return }
        let ticket = UUID(); orderReadTicket = ticket
        orderLoading = true; defer { if orderReadTicket == ticket { orderLoading = false } }
        do {
            let scope = try AssetLibrary.OrderScope(accountId: account.id, appId: app.id, surface: surface, targetId: targetId, group: group)
            let saved = try await session.assetLibraryOrder(scope)
            try Task.checkCancellation()
            guard orderReadTicket == ticket, scope.targetId == targetId, scope.group == group, scope.surface == surface else { return }
            let next = try AssetLibraryOrderEditor(scope: scope, placements: groupPlacements, saved: saved)
            orderEditor?.retire(); orderEditor = next
        } catch {
            guard orderReadTicket == ticket else { return }
            orderEditor = nil; problem(error, fallback: "The local order could not be read. Retry before editing or uploading.")
        }
    }
    private func select(_ asset: AssetLibrary.Asset) {
        guard !operationBusy, protection?.allowLeaving() != false else { return }
        selectedId = asset.id; referenceName = asset.referenceName; timeCode = asset.value["attributes"]?["previewFrameTimeCode"]?.text ?? ""; slotId = ""; uses = nil; prepared = nil
    }
    private func refresh(fresh force: Bool = false) async {
        await ScreenReads.reading(fresh: force) {
            guard !operationBusy, protection?.allowLeaving() != false, let session else { return }
            working = true; defer { working = false }; fresh = false; targetFresh = false
            do { files = try await session.assetLibraryFiles(accountId: account.id, appId: app.id) } catch { status = "Saved local files could not be read." }
            do {
                let next = try await session.assetLibrary(account: account, appId: app.id, client: session.readClient(for: account)); try Task.checkCancellation()
                snapshot = next; fresh = true; selectedIDs.formIntersection(Set(next.assets.filter(AssetLibraryAssetsCard.reviewable).map(\.id)))
                if let asset = next.assets.first(where: { $0.id == selectedId }) { referenceName = asset.referenceName; timeCode = asset.value["attributes"]?["previewFrameTimeCode"]?.text ?? "" } else { selectedId = "" }
                prepared = nil; issueCode = nil; status = "Asset Library and current specifications read."
                await readVersionHistory(session)
                history?.rememberRead(Read(snapshot: next, files: files, observations: observations), readKey)
            } catch is CancellationError {} catch { problem(error, fallback: "Asset Library could not be read. Check your account and API role.") }
        }
    }
    /// The library last read shows at once; Apple changes stay unavailable until the read that follows confirms it.
    private func showRemembered() {
        guard snapshot == nil, let read = history?.rememberedRead(readKey, as: Read.self) else { return }
        snapshot = read.snapshot; observations = read.observations; if files.isEmpty { files = read.files }
        if let asset = read.snapshot.assets.first(where: { $0.id == selectedId }) { referenceName = asset.referenceName; timeCode = asset.value["attributes"]?["previewFrameTimeCode"]?.text ?? "" }
    }
    private func applyRestoring() async {
        guard let choice = restoring else { return }
        restoring = nil
        guard fresh, !choice.targetId.isEmpty else { return }
        surface = choice.surface
        await readTargets()
        guard targets.contains(where: { $0.id == choice.targetId }) else { return }
        targetId = choice.targetId; await readPlacements()
        if !choice.group.isEmpty, targetFresh, placements.contains(where: { $0.group == choice.group }) { group = choice.group; await loadOrder() }
    }
    /// Saved imports plus Apple's current versions, read now, date the Live Version column. A failed current read leaves only saved history.
    private func readVersionHistory(_ session: WorkspaceSession) async {
        var next = AssetLibraryVersions.observations((try? await session.revisions(accountId: account.id, appId: app.id)) ?? [])
        do {
            let current = try await session.currentAppVersions(account: account, appId: app.id, client: session.readClient(for: account))
            next.append(AssetLibraryVersions.observation(current: current, at: Date()))
        } catch is CancellationError { return } catch { status = "Asset Library read. Apple's current versions could not be read, so Live Version uses saved imports only." }
        observations = next
    }
    private func chooseFiles() {
        guard !operationBusy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .mpeg4Movie, .quickTimeMovie, UTType("com.apple.m4v-video") ?? .movie]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        _ = importFiles(panel.urls)
    }
    /// Chosen files are saved on this Mac right away. A file that cannot be saved stays listed in red with its reason.
    @discardableResult private func importFiles(_ urls: [URL]) -> Bool {
        guard !operationBusy, session != nil, !urls.isEmpty, urls.count <= 50, urls.allSatisfy(\.isFileURL), Set(urls).count == urls.count else { return false }
        add(urls.map { url in
            PendingFile(url: url, category: category, name: urls.count == 1 ? localName : url.deletingPathExtension().lastPathComponent,
                        timeCode: ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased()) ? localTime : nil)
        })
        return true
    }
    private func add(_ pending: [PendingFile]) {
        guard !operationBusy, session != nil else { return }
        working = true
        Task {
            guard let session else { working = false; return }; defer { working = false }
            var failed: [PendingFile] = []
            for var file in pending {
                let scoped = file.url.startAccessingSecurityScopedResource(); defer { if scoped { file.url.stopAccessingSecurityScopedResource() } }
                do { _ = try await session.stageAssetLibraryFile(accountId: account.id, appId: app.id, url: file.url, category: file.category, name: file.name, timeCode: file.timeCode) }
                catch { file.reason = (error as? PublishFailure)?.message ?? (error as? PreviewFailure)?.message ?? "This file could not be saved on this Mac. Check that it is a PNG, JPEG, MP4, M4V or MOV file, then try again."; failed.append(file) }
            }
            let tried = Set(pending.map(\.url))
            notAdded = notAdded.filter { !tried.contains($0.url) } + failed
            files = (try? await session.assetLibraryFiles(accountId: account.id, appId: app.id)) ?? files
            let saved = pending.count - failed.count
            if failed.isEmpty { localName = ""; status = (saved == 1 ? "1 file" : "\(saved) files") + " added and saved on this Mac. Choose Review Upload on a file to send it to Apple." }
            else { status = (saved == 0 ? "Not added. " : "\(saved) of \(pending.count) files added and saved on this Mac. ") + "Try again or discard the files marked in red under On This Mac." }
        }
    }
    private func remove(_ file: AssetLibrary.File) {
        guard !working else { return }
        Task { guard let session else { return }; working = true; defer { working = false }
            do { try await session.removeAssetLibraryFile(accountId: account.id, appId: app.id, id: file.id); files = try await session.assetLibraryFiles(accountId: account.id, appId: app.id); status = "Local file removed. Apple's library is unchanged." }
            catch { problem(error, fallback: "The local file could not be removed.") }
        }
    }
    private func export(_ file: AssetLibrary.File) async {
        guard !working, let session else { return }; working = true; defer { working = false }
        do {
            let reader = try await session.openSavedMedia(.init(accountId: account.id, appId: app.id, revisionId: file.id, itemId: file.id, kind: .assetLibrary)); defer { reader.close() }
            if try await MediaDownload.save(reader) { status = "Original exported." }
        } catch { problem(error, fallback: "The original could not be exported.") }
    }
    private func edit(_ file: AssetLibrary.File) async {
        guard !working, let session, let targets = snapshot?.catalog.editingTargets(category: file.category), !targets.isEmpty else { return }
        working = true; defer { working = false }
        do {
            let reader = try await session.openSavedMedia(.init(accountId: account.id, appId: app.id, revisionId: file.id, itemId: file.id, kind: .assetLibrary)); defer { reader.close() }
            let bytes = try await reader.imageBytes(); try Task.checkCancellation()
            editingImage = .init(file: file, item: .init(name: file.fileName, data: bytes), targets: targets)
        } catch { problem(error, fallback: "The original image could not be opened for editing.") }
    }
    private func prepare(_ change: AssetLibrary.Change) async {
        guard !operationBusy, fresh, let session else { return }; working = true; defer { working = false }
        do {
            var request = PublishRequest(accountId: account.id, appId: app.id, scope: .assetLibrary); request.assetLibraryChange = change
            let review = try await session.preparePublishing(account: account, request: request, client: session.client(for: account)); try Task.checkCancellation()
            prepared = review; status = review.steps.isEmpty ? review.notes.joined(separator: " ") : "Exact changes saved for review. Open Review to approve them in App Store changes."
            issueCode = nil
        } catch is CancellationError {} catch { problem(error, fallback: "The Asset Library review could not be prepared.") }
    }
    private func manage(_ asset: AssetLibrary.Asset, action: AssetLibrary.Action) { var change = AssetLibrary.Change(action: action); change.assetId = asset.id; change.kind = asset.kind; if action == .rename { change.name = referenceName }; if action == .poster { change.timeCode = timeCode }; Task { await prepare(change) } }
    private func readTargets() async {
        guard !operationBusy, fresh, protection?.allowLeaving() != false, let session else { return }; working = true; defer { working = false }; targetFresh = false
        do { targets = try await session.assetLibraryTargets(account: account, appId: app.id, surface: surface, client: session.readClient(for: account)); status = targets.isEmpty ? "No destinations on this surface." : "Current destinations read."; issueCode = nil }
        catch { targets = []; problem(error, fallback: "Placement destinations could not be read.") }
    }
    private func readPlacements(fresh force: Bool = false) async {
        await ScreenReads.reading(fresh: force) {
            guard !operationBusy, fresh, protection?.allowLeaving() != false, let session, let target else { return }; working = true; defer { working = false }; targetFresh = false
            do { placements = try await session.assetLibraryPlacements(account: account, appId: app.id, target: target, client: session.readClient(for: account)); targetFresh = true; status = "Current placements read in display order."; issueCode = nil; working = false; await loadOrder() }
            catch { problem(error, fallback: "Placement status is unknown. Refresh before changing it.") }
        }
    }
    private func readUsage(_ asset: AssetLibrary.Asset) async {
        guard !working, let session else { return }; working = true; defer { working = false }; uses = nil
        do { uses = try await session.assetLibraryUses(account: account, appId: app.id, asset: asset, client: session.readClient(for: account)); issueCode = nil }
        catch { problem(error, fallback: "Asset usage could not be read.") }
    }
    private func readSubmissions() async {
        guard !working, fresh, let session else { return }; working = true; defer { working = false }
        do {
            reviewChoices = try await session.assetLibraryReviewChoices(account: account, appId: app.id, platform: platform, client: session.readClient(for: account)); status = "Draft submissions read. Their existing items are included in the concrete Publish review."
        } catch { reviewChoices = []; submissionId = ""; problem(error, fallback: "Draft submissions could not be read.") }
    }
    private func loadPreview() async {
        preview = nil; previewIssue = ""; guard let selected, let session else { return }
        do { let bytes = try await session.assetLibraryThumbnail(account: account, appId: app.id, asset: selected, client: session.client(for: account)); let decoded = try await ScreenshotRenderer.loadAsync(bytes); try Task.checkCancellation(); guard selectedId == selected.id else { return }; preview = decoded }
        catch is CancellationError {} catch { guard selectedId == selected.id else { return }; previewIssue = "A processed preview is not available. The asset status remains visible." }
    }
    private func problem(_ error: Error, fallback: String) { status = (error as? PublishFailure)?.message ?? (error as? PreviewFailure)?.message ?? fallback; issueCode = RecoveryIssue.apple(error) }
}
