import AppKit
import StorebenchCore
import SwiftUI
import UniformTypeIdentifiers

/// Create Media turns screenshots into App Store cards. Card sets save on this Mac shortly after each change;
/// finished cards become local Asset Library originals. Nothing here contacts Apple.
struct CreateMediaView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    var selectAIScreenshots: @MainActor (Int) async throws -> [SelectedFiles.File] = MediaFileSelection.screenshots
    var availableTranslationTargets: @MainActor (String, [String]) async -> [String] = ListingTranslation.translatableTargets
    @State private var creationMode: String?
    @State private var aiComposerId = UUID()
    @State private var aiInitialSource: JSONText?
    @State private var saved: [WorkspaceSession.SavedMediaCardSet] = []
    @State private var history: MediaCardHistory?
    @State private var savedSet: MediaCardSet?
    @State private var revision = 0
    @State private var selectedId = ""
    @State private var loading = true
    @State private var working = false
    @State private var saving = false
    @State private var stale = false
    @State private var status = ""
    @State private var statusError = false
    @State private var creating = false
    @State private var newName = ""
    @State private var newTarget = MediaCards.defaultTarget.id
    @State private var images = MediaCardImages()
    /// Font files used by the open set's cards, by content hash.
    @State private var fonts: [String: Data] = [:]
    @State private var mediaReadId = UUID()
    @State private var mediaRead: Task<Void, Never>?
    @State private var loads: [String: UUID] = [:]
    @State private var preview: ScreenshotPreview?
    @State private var previewIssue = ""
    @State private var dragStart: MediaCard?
    @State private var translateTo = ""
    @State private var translationService = ""
    @State private var translationModel = ""
    @State private var aiConnections: [AIConnection] = []
    @State private var translationTargets: [String] = []
    @State private var translation: ListingTranslationRequest?
    @FocusState private var canvasFocused: Bool
    @Environment(\.workspaceHeight) private var viewportHeight
    @Environment(\.confirmDestructive) private var confirm
    @Environment(\.editorProtection) private var protection
    @Environment(\.openReleaseStep) private var openReleaseStep

    private var opened: MediaCardSet? { history?.set }
    private var dirty: Bool { history != nil && history?.set != savedSet }
    private var index: Int? { opened?.cards.firstIndex { $0.id == selectedId } ?? (opened?.cards.isEmpty == false ? 0 : nil) }
    private var current: MediaCard? { index.flatMap { opened?.cards[$0] } }
    private var busy: Bool { working || loading }

    var body: some View {
        ScrollViewReader { scroll in
        VStack(alignment: .leading, spacing: 20) {
            Card(title: "Create Media", subtitle: "Choose how to start your App Store cards.") {
                StorebenchActionGroup {
                    Button("Create Cards") { chooseMode("manual") }
                    Button("Create AI Cards") { chooseMode("ai") }
                        .storebenchControlID("media.ai")
                        .help("Let AI propose editable cards from screenshots and a short brief")
                }
            }
            if creationMode == "ai" {
                let composerId = aiComposerId
                AICardsCreator(account: account, app: app, session: session, selectScreenshots: selectAIScreenshots, initialSource: aiInitialSource) { value in
                    saved.removeAll { $0.set.id == value.set.id }; saved.insert(value, at: 0)
                    guard creationMode == "ai", aiComposerId == composerId else { return }
                    show(value); creationMode = "manual"
                }.id("ai-composer")
            }
            if creationMode == "manual" {
            if !loading { stepsCard }
            setsCard
            if let set = opened, let current, let index {
                cardsCard(set)
                editorCard(set, card: current, index: index).id("card-editor")
                saveCard(set)
                translateCard(set)
            }
            }
        }
        .onChange(of: creationMode) { scroll.scrollTo(creationMode == "ai" ? "ai-composer" : "card-editor", anchor: .top) }
        .task { await load() }
        .task(id: textLanguage) {
            let source = textLanguage, found = await availableTranslationTargets(source, StoreLocales.codes)
            guard !Task.isCancelled, source == textLanguage else { return }
            translationTargets = found
            if translationService.isEmpty, !found.contains(translateTo) { translateTo = found.first ?? "" }
        }
        .listingTranslation(translation) { request, translate in await translateSet(request, translate) } finished: { translation = nil }
        .task(id: history?.set) {
            // Each change is saved on this Mac shortly after editing pauses.
            guard dirty, !stale else { return }
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            _ = await save()
        }
        // The preview loads its selected screenshot at full size; other cards draw from small decodes.
        .task(id: MediaCardPreviewRequest(card: current, width: opened?.width ?? 0, height: opened?.height ?? 0,
                                        screenshotLoaded: current?.screenshot.map { images.full($0.hash) != nil } ?? false,
                                        fontLoaded: current.map { font($0) != nil } ?? false)) { await renderPreview() }
        .onDisappear { mediaRead?.cancel(); mediaReadId = UUID() }
        .trackUnsavedChanges(dirty, busy: busy || saving, onSave: { await save() })
        }
    }

    private func chooseMode(_ mode: String, source: JSONText? = nil) {
        guard creationMode != mode else { return }
        let choose: @MainActor @Sendable () -> Void = { creationMode = mode; if mode == "ai" { aiInitialSource = source; aiComposerId = UUID() } }
        if let protection { protection.requestLeaving(choose) }
        else { Task { if dirty { guard await save() else { return } }; choose() } }
    }

    // MARK: Steps

    /// Where the open card set stands: each step with a check once done, and the next one in plain words.
    private var stepsCard: some View {
        let steps = CreateMediaFlow.steps(opened)
        return Card(title: "Create Media steps", subtitle: "\(steps.filter(\.done).count) of \(steps.count - 1) complete. Work from the top; each step shows what it still needs.", help: "media") {
            ForEach(steps) { step in
                StorebenchSetupStep(number: step.number, title: step.title, detail: step.needed.first ?? step.detail, done: step.done) {
                    if step.id == .release, let openReleaseStep {
                        StorebenchActionGroup {
                            Button("Open Release Step 2") { openReleaseStep(ReleaseWizard.phase(containing: "local:") ?? "listing") }.buttonStyle(StorebenchButtonStyle(step.current ? .primary : .secondary))
                                .help("Open Release step 2, Text and Screenshots, where screenshots are chosen from Asset Library")
                        }
                    }
                }
            }
        }
    }

    // MARK: Card sets

    private var setsCard: some View {
        Card(title: "Create Media", subtitle: "Make App Store screenshot cards from your app's screenshots: a background, a screenshot and short text. Card sets are saved on this Mac as you edit. Nothing is uploaded to Apple.", help: "media") {
            if loading { ProgressView("Opening card sets…") }
            else {
                if !saved.isEmpty, !creating {
                    StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 260) {
                        StorebenchPicker("Card Set", selection: Binding(get: { opened?.id ?? "" }, set: { id in Task { await open(id) } })) {
                            selectionOptions(saved) { SelectionOption($0.set.name, value: $0.set.id) }
                        }
                        StorebenchTextField("Card Set Name · \(opened?.name.utf16.count ?? 0)/\(MediaCards.nameLimit)", text: Binding(get: { opened?.name ?? "" }, set: { value in
                            change("name", set: { $0.name = limited(value, MediaCards.nameLimit, lines: false) })
                        }))
                    }
                    if let set = opened { Text("\(StoreLocales.displayTypeName(set.displayType)) · \(set.width) × \(set.height) px · \(set.cards.count) of \(MediaCards.maximumCards) cards").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
                    StorebenchActionGroup {
                        Button("New Card Set") { newName = ""; creating = true }
                        if opened != nil { Button("Delete Card Set", role: .destructive) {
                            guard confirm(.deleteCreatedMedia, title: "Delete this card set?", message: "Delete \(opened?.name ?? "this card set") from this Mac. Cards already saved to Asset Library stay there.", action: "Delete Card Set") else { return }
                            Task { await deleteSet() }
                        } }
                    }.storebenchWorking(busy)
                } else { newSetForm }
            }
            StorebenchFeedback(text: status, height: 48, error: statusError)
            if stale { StorebenchActionGroup { Button("Reload Card Set") { Task { await reload() } } } }
        }
    }

    private var newSetForm: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.gap) {
            Text(saved.isEmpty ? "Start with a card set: one App Store display size with up to 10 cards." : "A new card set has its own display size and cards.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 260) {
                StorebenchTextField("Card Set Name · \(newName.utf16.count)/\(MediaCards.nameLimit)", text: Binding(get: { newName }, set: { newName = limited($0, MediaCards.nameLimit, lines: false) }), placeholder: "Launch screenshots")
                StorebenchPicker("Display Size", selection: $newTarget) { selectionOptions(MediaCards.targets) { SelectionOption($0.label, value: $0.id) } }
            }
            Text("Cards are created at the exact pixel size Apple accepts. Use your largest iPhone or iPad size; the App Store scales it for smaller displays.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
            StorebenchActionGroup {
                Button("Create Card Set") { Task { await createSet() } }.buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(MediaCards.trimmed(newName).isEmpty)
                if !saved.isEmpty { Button("Cancel", role: .cancel) { creating = false } }
            }.storebenchWorking(busy)
        }
    }

    // MARK: Cards in the set

    private func cardsCard(_ set: MediaCardSet) -> some View {
        Card(title: "Cards", subtitle: "Thumbnails are about the size of an App Store search result. The first three cards are seen most; check that their titles are readable here.") {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: StorebenchTheme.space(3)) {
                    ForEach(Array(set.cards.enumerated()), id: \.element.id) { position, card in
                        Button { select(card.id) } label: {
                            VStack(spacing: StorebenchTheme.space(1)) {
                                MediaCardThumbnail(card: card, width: set.width, height: set.height, screenshot: card.screenshot.flatMap { images.thumbnail($0.hash) }, font: font(card))
                                    .frame(height: 150)
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(card.id == current?.id ? StorebenchTheme.accent : StorebenchTheme.border, lineWidth: card.id == current?.id ? 3 : 1))
                                Text("\(position + 1)").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                            }
                        }.buttonStyle(StorebenchPressStyle()).help("Edit card \(position + 1)").accessibilityLabel("Edit card \(position + 1)")
                    }
                }.padding(StorebenchTheme.space(1))
            }
            StorebenchActionGroup {
                Button("Add Card") { let after = current?.id; operate("add") { selectedId = try $0.addCard(after: after).id } }
                Button("Duplicate") { if let id = current?.id { operate("duplicate") { selectedId = try $0.duplicateCard(id).id } } }.help("Duplicate the selected card")
                Button("Move Earlier") { if let id = current?.id { operate("move") { $0.moveCard(id, by: -1) } } }
                    .storebenchWorking((index ?? 0) == 0).help((index ?? 0) == 0 ? "The selected card is already first" : "Move the selected card one place earlier")
                Button("Move Later") { if let id = current?.id { operate("move") { $0.moveCard(id, by: 1) } } }
                    .storebenchWorking(index.map { $0 >= set.cards.count - 1 } ?? true).help(index.map { $0 >= set.cards.count - 1 } ?? true ? "The selected card is already last" : "Move the selected card one place later")
                Button("Delete Card", role: .destructive) {
                    if confirm(.deleteCreatedMedia, title: "Delete the selected card?", message: "Undo restores it until you leave this card set.", action: "Delete Card") { deleteCard() }
                }.storebenchWorking(set.cards.count <= 1).help(set.cards.count <= 1 ? "A card set keeps at least one card" : "Delete the selected card. Undo restores it.")
                Button("Undo") { undo() }.keyboardShortcut("z", modifiers: .command).storebenchWorking(history?.canUndo != true).help(history?.canUndo == true ? "Undo the last change in this card set" : "Nothing to undo")
                Button("Redo") { redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).storebenchWorking(history?.canRedo != true).help(history?.canRedo == true ? "Redo the last undone change" : "Nothing to redo")
            }.storebenchWorking(busy)
        }
    }

    // MARK: Editing one card

    private func editorCard(_ set: MediaCardSet, card: MediaCard, index: Int) -> some View {
        // The settings scroll on their own beside the preview, so the card stays in view while it changes.
        let height = min(760, max(480, viewportHeight - 220))
        return Card(title: "Card \(index + 1)", subtitle: "Changes appear in the preview and are saved on this Mac. Undo and Redo cover every change in this set. Scroll the settings to keep the preview in view.") {
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 320) {
                VStack(alignment: .leading, spacing: StorebenchTheme.gap) {
                    canvas(set, card: card).aspectRatio(Double(set.width) / Double(set.height), contentMode: .fit).frame(maxHeight: height - 220).padding(8)
                        .background(StorebenchTheme.nav, in: RoundedRectangle(cornerRadius: 12))
                    StorebenchActionGroup {
                        Button("Re-create Card") { recreate(set, card: card) }.storebenchControlID("media.recreate-card")
                            .help("Open this card's brief and screenshot in Create AI Cards. Adjust the directions, then generate a new variant; the current card stays saved.")
                        Button("Create AI Cards") { chooseMode("ai") }.storebenchControlID("media.return-ai")
                            .help("Return to the saved AI composer to create another card set")
                    }.storebenchWorking(busy || saving)
                    StorebenchTextSlot(text: previewIssue, height: 48, font: .sbCallout, color: StorebenchTheme.color("color-danger"), live: true)
                    StorebenchTextSlot(text: "Drag the screenshot to move the crop after zooming in. Arrow keys move it, + and − zoom, Delete removes the card.", height: 48, font: .sbCaption, color: StorebenchTheme.muted)
                }
                ScrollView(.vertical) { controls(card).padding(.trailing, StorebenchTheme.space(3)) }.frame(height: height)
            }
        }
    }

    private func recreate(_ set: MediaCardSet, card: MediaCard) {
        guard !busy, !saving, let session else { return }
        Task {
            do {
                let source = try await session.aiCardSource(accountId: account.id, appId: app.id, set: set, cardID: card.id)
                guard opened == set else { return }
                chooseMode("ai", source: source)
            } catch { status = AIFailure.message(error); statusError = true }
        }
    }

    private func canvas(_ set: MediaCardSet, card: MediaCard) -> some View {
        GeometryReader { bounds in
            let ratio = min(bounds.size.width / Double(set.width), bounds.size.height / Double(set.height))
            ZStack {
                if let preview { Image(decorative: preview.image, scale: 1).resizable().interpolation(.high) }
                else { Rectangle().fill(StorebenchTheme.color("color-surface-sunken")); ProgressView() }
            }
            .frame(width: Double(set.width) * ratio, height: Double(set.height) * ratio)
            .contentShape(Rectangle()).focusable(!busy, interactions: .edit).focused($canvasFocused)
            .accessibilityLabel("Card preview")
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                guard !busy else { return }
                canvasFocused = true
                if dragStart == nil { dragStart = card }
                guard let start = dragStart else { return }
                let moved = MediaCards.drag(start, width: set.width, height: set.height, startX: gesture.startLocation.x / ratio, startY: gesture.startLocation.y / ratio,
                                            deltaX: gesture.translation.width / ratio, deltaY: gesture.translation.height / ratio)
                change("crop") { $0 = moved }
            }.onEnded { _ in dragStart = nil })
            .onKeyPress { press in
                guard !busy, press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
                let step = press.modifiers.contains(.shift) ? 0.1 : 0.01
                switch press.key {
                case .delete, .deleteForward: deleteCard(); return .handled
                case .leftArrow: change("crop") { $0.x = min(1, $0.x + step) }
                case .rightArrow: change("crop") { $0.x = max(0, $0.x - step) }
                case .upArrow: change("crop") { $0.y = min(1, $0.y + step) }
                case .downArrow: change("crop") { $0.y = max(0, $0.y - step) }
                case "+", "=": change("zoom") { $0.zoom = min(4, $0.zoom + 0.1) }
                case "-": change("zoom") { $0.zoom = max(1, $0.zoom - 0.1) }
                default: return .ignored
                }
                return .handled
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func controls(_ card: MediaCard) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            StorebenchChoicePicker("Card Type", selection: field(\.layout, "layout"), options: MediaCard.Layout.allCases.map { ($0, $0.label) })
            if card.layout.usesScreenshot { screenshotControls(card) }
            textControls(card)
            backgroundControls(card)
            StorebenchActionGroup {
                Button("Apply Style to All Cards") { if let id = current?.id { operate("style") { $0.applyStyle(from: id) }; status = "This card's colors, text style and screenshot frame now apply to every card in the set."; statusError = false } }
                    .help("Copy this card's background, text style and screenshot frame to every card. Text and screenshots stay.")
            }
        }.storebenchWorking(busy).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func screenshotControls(_ card: MediaCard) -> some View {
        DisclosureGroup("Screenshot") {
            VStack(alignment: .leading, spacing: 10) {
                StorebenchTextSlot(text: card.screenshot.map { "\($0.name) · \($0.width) × \($0.height) px" } ?? "No screenshot chosen.", height: 34, font: .sbCallout, color: card.screenshot == nil ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted)
                StorebenchActionGroup {
                    Button(card.screenshot == nil ? "Choose Screenshot" : "Replace Screenshot") { chooseScreenshot() }
                    if card.screenshot != nil { Button("Remove Screenshot", role: .destructive) { change("screenshot") { $0.screenshot = nil; $0.zoom = 1; $0.x = 0.5; $0.y = 0.5 } } }
                }
                StorebenchSliderField(title: "Zoom", value: field(\.zoom, "zoom"), range: 1...4, step: 0.01, percentage: true)
                StorebenchSliderField(title: "Screenshot width", value: style(\.screenshotWidth, "screenshotWidth"), range: 0.4...1, step: 0.01, percentage: true)
                StorebenchTextSlot(text: opened.map { MediaCards.placement(card, width: $0.width, height: $0.height).limited } == true
                                   ? "The screenshot is as tall as its space allows, so a larger width does not make it bigger. Lower Space for text or the margin to give it more room." : "",
                                   height: 34, font: .sbCaption, color: StorebenchTheme.muted, live: true)
                StorebenchSliderField(title: "Corner radius (%)", value: style(\.cornerRadius, "cornerRadius"), range: 0...20, step: 0.5)
                StorebenchSliderField(title: "Border width (%)", value: style(\.borderWidth, "borderWidth"), range: 0...6, step: 0.1)
                StorebenchColorField("Border Color", selection: color(\.borderColor, "borderColor"))
                StorebenchToggle("Shadow", isOn: style(\.shadow, "shadow"))
                StorebenchActionGroup { Button("Recenter Crop") { change("crop") { $0.zoom = 1; $0.x = 0.5; $0.y = 0.5 } } }
            }.padding(.top, 8)
        }
    }

    private func textControls(_ card: MediaCard) -> some View {
        DisclosureGroup("Text and Text Colors") {
            VStack(alignment: .leading, spacing: 10) {
                StorebenchTextField("Title · \(card.title.utf16.count)/\(MediaCards.titleLimit)", text: text(\.title, MediaCards.titleLimit, lines: false), placeholder: "Plan your week in seconds")
                StorebenchTextField("Subtitle · \(card.subtitle.utf16.count)/\(MediaCards.subtitleLimit)", text: text(\.subtitle, MediaCards.subtitleLimit, lines: false))
                Text("Body Text · \(card.body.utf16.count)/\(MediaCards.bodyLimit)")
                StorebenchTextArea(text: text(\.body, MediaCards.bodyLimit, lines: true), height: StorebenchTheme.textarea(rows: 3)).accessibilityLabel("Body text")
                Text("Short text reads best: about 4 to 8 words in the title. Long text is reduced until it fits; if it still does not fit, the preview says so.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                typefaceControls(card)
                StorebenchChoicePicker("Alignment", selection: style(\.alignment, "alignment"), options: MediaCardStyle.Alignment.allCases.map { ($0, $0.label) })
                StorebenchSliderField(title: "Text size", value: style(\.textSize, "textSize"), range: 0.6...1.5, step: 0.01, percentage: true)
                StorebenchTextSlot(text: textSizeNote(card), height: 34, font: .sbCaption, color: StorebenchTheme.muted, live: true)
                if card.layout.usesScreenshot { StorebenchSliderField(title: "Space for text", value: style(\.textSpace, "textSpace"), range: 0.12...0.5, step: 0.01, percentage: true) }
                StorebenchMetricGrid(maximumColumns: 3, minimumWidth: 140) {
                    StorebenchColorField("Title Color", selection: color(\.titleColor, "titleColor"))
                    StorebenchColorField("Subtitle Color", selection: color(\.subtitleColor, "subtitleColor"))
                    StorebenchColorField("Body Color", selection: color(\.bodyColor, "bodyColor"))
                }
            }.padding(.top, 8)
        }
    }

    /// The typeface choice, with the installed family or the font file when one of those is chosen.
    @ViewBuilder private func typefaceControls(_ card: MediaCard) -> some View {
        StorebenchChoicePicker("Typeface", selection: Binding(get: { card.style.typeface }, set: { value in
            if value == .file && card.style.fontFile == nil { chooseFont(); return }
            change("typeface") { $0.style.typeface = value; if value == .installed && $0.style.fontFamily == nil { $0.style.fontFamily = MediaCardRenderer.installedFamilies.first { $0 == "Avenir Next" } ?? MediaCardRenderer.installedFamilies.first } }
        }), options: MediaCardStyle.Typeface.allCases.map { ($0, $0.label) })
        if card.style.typeface == .installed {
            StorebenchSearchPicker("Font Family", selection: Binding(get: { card.style.fontFamily ?? "" }, set: { value in change("fontFamily") { $0.style.fontFamily = value } }),
                                   hint: "Fonts installed on this Mac. A card set opened on another Mac needs the same font.") {
                MediaCardRenderer.installedFamilies.map { SelectionOption($0, value: $0) }
            }
        }
        if card.style.typeface == .file || card.style.fontFile != nil {
            StorebenchTextSlot(text: card.style.fontFile.map { "\($0.family) · \($0.name)" } ?? "No font file chosen.", height: 34, font: .sbCallout, color: StorebenchTheme.muted)
            StorebenchActionGroup {
                Button(card.style.fontFile == nil ? "Choose Font File…" : "Replace Font File…") { chooseFont() }
                    .help("Add a TrueType or OpenType font file. It is saved encrypted on this Mac with the card set.")
            }
        }
    }
    /// Says when Space for text makes the text smaller than the chosen size.
    private func textSizeNote(_ card: MediaCard) -> String {
        guard let set = opened, [card.title, card.subtitle, card.body].contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return "" }
        guard let share = MediaCardRenderer.textShare(card, width: set.width, height: set.height, font: font(card)) else { return "" }
        guard share < 0.995 else { return "" }
        return "Shown at \(Int((share * card.style.textSize * 100).rounded())) % so the text fits its space. Raise Space for text or shorten the text to show it larger."
    }

    private func backgroundControls(_ card: MediaCard) -> some View {
        DisclosureGroup("Background and Colors") {
            VStack(alignment: .leading, spacing: 10) {
                StorebenchChoicePicker("Fill", selection: style(\.fill, "fill"), options: MediaCardStyle.Fill.allCases.map { ($0, $0.label) })
                StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 140) {
                    StorebenchColorField(card.style.fill == .gradient ? "Start Color" : "Color", selection: color(\.color, "color"))
                    if card.style.fill == .gradient { StorebenchColorField("End Color", selection: color(\.secondColor, "secondColor")) }
                }
                if let suggestions = suggestions(card), !suggestions.isEmpty {
                    Text("Colors from the screenshot").font(.sbCallout.weight(.semibold))
                    StorebenchActionGroup {
                        ForEach(suggestions, id: \.self) { hex in
                            Button { change("color") { $0.style.color = hex; if $0.style.fill == .gradient { $0.style.secondColor = Self.shade(hex) } } } label: {
                                RoundedRectangle(cornerRadius: 4).fill(Self.swatch(hex)).frame(width: 28, height: 18)
                            }.help("Use \(hex) as the background").accessibilityLabel("Use background color \(hex)")
                        }
                    }
                }
                if card.style.fill == .gradient { StorebenchSliderField(title: "Gradient angle (°)", value: style(\.angle, "angle"), range: 0...360, step: 1) }
                StorebenchSliderField(title: "Margin (%)", value: style(\.margin, "margin"), range: 0...15, step: 0.5)
            }.padding(.top, 8)
        }
    }

    // MARK: Saving cards

    private func saveCard(_ set: MediaCardSet) -> some View {
        Card(title: "Use the Cards", subtitle: "Each card is an opaque \(set.width) × \(set.height) px PNG, the size Apple accepts for \(StoreLocales.displayTypeName(set.displayType)). Saving to Asset Library keeps them on this Mac. Then add them in Release step 2, Text and Screenshots, which uploads them after you approve.") {
            Text(set.cards.count == 1 ? "Save All creates 1 PNG file." : "Save All creates \(set.cards.count) PNG files, one per card, in card order.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
            StorebenchActionGroup {
                StorebenchBusyButton(title: "Save Draft", loadingTitle: "Saving…", busy: saving, variant: .primary) { Task { _ = await save() } }
                    .storebenchWorking(!dirty || stale)
                Button("Save All to Asset Library") { Task { await saveToLibrary(all: true) } }.buttonStyle(StorebenchButtonStyle(.primary))
                    .storebenchControlID("media.save-library")
                Button("Save This Card") { Task { await saveToLibrary(all: false) } }.help("Save the selected card to Asset Library")
                Button("Export PNG") { Task { await exportPNG() } }.help("Save the selected card as a PNG file on this Mac")
            }.storebenchWorking(busy)
            if let openReleaseStep {
                Button("Open Apple Sync") {
                    Task {
                        if await saveToLibrary(all: true) { openReleaseStep("listing") }
                    }
                }.help("Save the cards to Asset Library, then choose their language and version in Release before Sync to Apple")
                    .storebenchWorking(busy || saving || stale)
            }
        }
    }

    // MARK: Other languages

    /// The language the open set's text is written in. Sets made before a language was chosen are treated as American English.
    private var textLanguage: String { opened?.language ?? "en-US" }

    private func translateCard(_ set: MediaCardSet) -> some View {
        Card(title: "Other Languages", subtitle: "Make a translated copy using Apple Translation or your chosen AI service. The copy keeps the same background, layout and screenshots. Replace screenshots that show another language.", help: "media") {
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 260) {
                StorebenchPicker("Card Text Language", selection: Binding(get: { textLanguage }, set: { value in change("language", set: { $0.language = value }) })) {
                    selectionOptions(StoreLocales.codes) { SelectionOption(StoreLocales.name($0), value: $0) }
                }
                StorebenchPicker("Translate To", selection: $translateTo) {
                    selectionOptions(translationService.isEmpty ? translationTargets : StoreLocales.codes.filter { $0 != textLanguage }) { SelectionOption(StoreLocales.name($0), value: $0) }
                }
            }
            AIServicePicker(session: session, selection: $translationService, modelID: $translationModel, includesTranslation: true, loaded: { aiConnections = $0 })
                .onChange(of: translationService) {
                    let options = translationService.isEmpty ? translationTargets : StoreLocales.codes.filter { $0 != textLanguage }
                    if !options.contains(translateTo) { translateTo = options.first ?? "" }
                }
            Text(translationService.isEmpty && translationTargets.isEmpty ? "This Mac cannot translate \(StoreLocales.name(textLanguage)). Translation needs macOS 15 or later and a language Apple’s translation supports."
                 : translationService.isEmpty ? "macOS asks before downloading a missing translation language. The original card set is kept."
                 : "AI translates the card text. The original card set is kept; review the translated copy before using it.")
                .font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            StorebenchActionGroup {
                Button(translation == nil ? "Translate Card Set" : "Translating…") {
                    guard !translateTo.isEmpty else { return }
                    Task {
                        if dirty, !(await save()) { return }
                        let request = ListingTranslationRequest(source: textLanguage, target: translateTo)
                        let selectedModel = translationModel.isEmpty ? nil : translationModel
                        if let provider = AIProvider(rawValue: translationService), let session {
                            await translateSet(request) { texts in
                                try await session.translateWithAI(accountId: account.id, appId: app.id, provider: provider, texts: texts, source: request.source, target: request.target, fields: MediaCardTranslation.translationFields(set), model: selectedModel)
                            }
                        } else { translation = request }
                    }
                }.help("Create a translated copy of this card set").storebenchWorking(translateTo.isEmpty || MediaCardTranslation.segments(set).isEmpty || translation != nil || (translationService == AIProvider.apple.rawValue && !AppleLocalAI.available) || (!translationService.isEmpty && translationService != AIProvider.apple.rawValue && !aiConnections.contains { $0.provider.rawValue == translationService }))
            }.storebenchWorking(busy || stale)
        }
    }

    /// Creates the translated set as a new saved set and opens it. The open set is left unchanged.
    private func translateSet(_ request: ListingTranslationRequest, _ translate: TextTranslator) async {
        guard let session, let source = opened, request.source == textLanguage, !busy, !stale else { return }
        working = true; defer { working = false }
        do {
            let texts = MediaCardTranslation.segments(source)
            let translated: [String]
            do { translated = try await translate(texts) } catch let error as AIFailure { throw error } catch { throw MediaCardFailure.translation }
            let copy = try MediaCardTranslation.translated(source, to: request.target, translations: translated)
            guard opened == source, savedSet == source else { status = "This card set changed while it was being translated. Translate it again."; statusError = true; return }
            let next = try await session.saveMediaCardSet(accountId: account.id, appId: app.id, set: copy, expected: 0)
            saved = try await session.mediaCardSets(accountId: account.id, appId: app.id)
            show(.init(revision: next, set: copy))
            status = "\(copy.name) created. Read each card’s text and replace screenshots that show another language, then save the cards to Asset Library."; statusError = false
        } catch let failure as MediaCardFailure { status = failure.message; statusError = true }
        catch let failure as AIFailure { status = failure.message; statusError = true }
        catch { status = "The translated card set could not be saved. This card set is unchanged."; statusError = true }
    }

    // MARK: Bindings

    private func change(_ key: String, _ body: (inout MediaCard) -> Void) {
        guard !stale, let index else { return }
        history?.change(key, now: ProcessInfo.processInfo.systemUptime) { body(&$0.cards[index]) }
    }
    /// Applies a finished file load to the card it was chosen for. Returns the card's position, or nil when it no longer applies.
    private func finish(_ load: MediaCardLoad, _ key: String, _ body: (inout MediaCard) -> Void) -> Int? {
        guard !stale, let position = load.position(in: opened, newest: loads) else { return nil }
        loads[load.key] = nil
        history?.change(key, now: ProcessInfo.processInfo.systemUptime) { body(&$0.cards[position]) }
        return position
    }
    private func start(_ kind: MediaCardLoad.Kind) -> MediaCardLoad? {
        guard let set = opened, let card = current else { return nil }
        let load = MediaCardLoad(setId: set.id, cardId: card.id, kind: kind); loads[load.key] = load.ticket; return load
    }
    private func change(_ key: String, set body: (inout MediaCardSet) -> Void) {
        guard !stale else { return }
        history?.change(key, now: ProcessInfo.processInfo.systemUptime, body)
    }
    private func operate(_ key: String, _ body: (inout MediaCardSet) throws -> Void) {
        guard !stale, !busy else { return }
        // Card operations are separate undo steps even when repeated quickly.
        do { try history?.change(key + ":" + UUID().uuidString, now: ProcessInfo.processInfo.systemUptime, body) }
        catch { status = (error as? MediaCardFailure)?.message ?? MediaCardFailure.invalid.message; statusError = true }
    }
    private func field<Value>(_ key: WritableKeyPath<MediaCard, Value>, _ name: String) -> Binding<Value> {
        Binding(get: { current![keyPath: key] }, set: { value in change(name) { $0[keyPath: key] = value } })
    }
    private func style<Value>(_ key: WritableKeyPath<MediaCardStyle, Value>, _ name: String) -> Binding<Value> {
        let path: WritableKeyPath<MediaCard, MediaCardStyle> = \.style
        return field(path.appending(path: key), name)
    }
    private func text(_ key: WritableKeyPath<MediaCard, String>, _ maximum: Int, lines: Bool) -> Binding<String> {
        Binding(get: { current![keyPath: key] }, set: { value in change(String(describing: key)) { $0[keyPath: key] = limited(value, maximum, lines: lines) } })
    }
    private func limited(_ value: String, _ maximum: Int, lines: Bool) -> String {
        var result = "", length = 0
        for character in value where lines || !character.isNewline {
            let size = String(character).utf16.count; if length + size > maximum { break }; result.append(character); length += size
        }
        return result
    }
    private func color(_ key: WritableKeyPath<MediaCardStyle, String>, _ name: String) -> Binding<Color> {
        Binding(get: { Self.swatch(current!.style[keyPath: key]) }, set: { value in
            guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02x%02x%02x", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
            change(name) { $0.style[keyPath: key] = hex }
        })
    }
    static func swatch(_ hex: String) -> Color {
        let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
    /// A darker partner for a gradient that starts with `hex`.
    static func shade(_ hex: String) -> String {
        let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return String(format: "#%02x%02x%02x", Int(Double((rgb >> 16) & 255) * 0.62), Int(Double((rgb >> 8) & 255) * 0.62), Int(Double(rgb & 255) * 0.62))
    }
    private func suggestions(_ card: MediaCard) -> [String]? {
        card.screenshot.flatMap { images.thumbnail($0.hash) }.map { MediaCardColors.suggestions($0) }
    }

    // MARK: Actions

    private func select(_ id: String) { selectedId = id; previewIssue = "" }
    private func undo() { guard !busy, !stale else { return }; history?.undo(); keepSelection() }
    private func redo() { guard !busy, !stale else { return }; history?.redo(); keepSelection() }
    private func keepSelection() { if let set = opened, !set.cards.contains(where: { $0.id == selectedId }) { selectedId = set.cards.first?.id ?? "" } }
    private func deleteCard() {
        guard let id = current?.id else { return }
        operate("delete") { if let next = $0.removeCard(id) { selectedId = next } }
    }

    private func load() async {
        defer { loading = false }
        guard let session else { return }
        do {
            saved = try await session.mediaCardSets(accountId: account.id, appId: app.id)
            if let first = saved.first { show(first) } else { creating = true }
        } catch { status = "Card sets could not be opened. Your saved files are unchanged."; statusError = true }
    }
    private func show(_ value: WorkspaceSession.SavedMediaCardSet) {
        mediaRead?.cancel(); mediaReadId = UUID()
        if value.set.id != opened?.id { images.removeAll(); fonts.removeAll() }
        history = MediaCardHistory(value.set); savedSet = value.set; revision = value.revision; stale = false
        selectedId = value.set.cards.first?.id ?? ""; preview = nil; previewIssue = ""
        let ticket = mediaReadId
        mediaRead = Task { await loadScreenshots(value.set, ticket: ticket) }
    }
    private func open(_ id: String) async {
        guard id != opened?.id, !busy else { return }
        if dirty, !(await save()) { return }
        if let value = saved.first(where: { $0.set.id == id }) { show(value); status = ""; statusError = false }
    }
    private func reload() async {
        guard let session, let id = opened?.id else { return }
        do {
            saved = try await session.mediaCardSets(accountId: account.id, appId: app.id)
            if let value = saved.first(where: { $0.set.id == id }) ?? saved.first { show(value); status = "Card set reloaded."; statusError = false }
            else {
                mediaRead?.cancel(); mediaReadId = UUID(); images.removeAll(); fonts.removeAll()
                history = nil; savedSet = nil; creating = true; status = MediaCardFailure.missing.message; statusError = true
            }
        } catch { status = "The card set could not be reloaded."; statusError = true }
    }
    private func createSet() async {
        guard let session, !busy, let target = MediaCards.targets.first(where: { $0.id == newTarget }), !MediaCards.trimmed(newName).isEmpty else { return }
        if dirty, !(await save()) { return }
        working = true; defer { working = false }
        let created = MediaCardSet(name: MediaCards.trimmed(newName), target: target)
        do {
            let next = try await session.saveMediaCardSet(accountId: account.id, appId: app.id, set: created, expected: 0)
            saved = try await session.mediaCardSets(accountId: account.id, appId: app.id)
            show(.init(revision: next, set: created)); creating = false
            status = "Card set created. Choose a screenshot and add a title to the first card."; statusError = false
        } catch { status = (error as? MediaCardFailure)?.message ?? "The card set could not be created."; statusError = true }
    }
    private func deleteSet() async {
        guard let session, let set = opened, !busy else { return }
        working = true; defer { working = false }
        do {
            // Unsaved edits belong to the set being deleted; the saved revision is what is removed.
            try await session.deleteMediaCardSet(accountId: account.id, appId: app.id, id: set.id, expected: revision)
            saved = try await session.mediaCardSets(accountId: account.id, appId: app.id)
            history = nil; savedSet = nil
            if let first = saved.first { show(first) } else {
                mediaRead?.cancel(); mediaReadId = UUID(); images.removeAll(); fonts.removeAll(); creating = true
            }
            status = "Card set deleted from this Mac."; statusError = false
        } catch let failure as MediaCardFailure { stale = failure == .stale; status = failure.message; statusError = true }
        catch { status = "The card set could not be deleted."; statusError = true }
    }

    /// Saves the current set onto the loaded revision. A newer save from another window stops editing until reload.
    @discardableResult private func save() async -> Bool {
        guard let session, let value = history?.set, value != savedSet, !stale else { return !stale }
        guard !saving else { return false }
        saving = true; defer { saving = false }
        do {
            revision = try await session.saveMediaCardSet(accountId: account.id, appId: app.id, set: value, expected: revision)
            savedSet = value
            if let position = saved.firstIndex(where: { $0.set.id == value.id }) { saved[position] = .init(revision: revision, set: value) }
            return true
        } catch let failure as MediaCardFailure {
            stale = failure == .stale || failure == .missing; status = failure.message; statusError = true; return false
        } catch { status = "Changes could not be saved on this Mac. They stay here; try again before leaving."; statusError = true; return false }
    }

    /// Reads the open set's screenshots as small decodes for the thumbnails, the selected card's first, then its font files.
    /// Full-size decodes are made only for the selected card and for exports.
    private func loadScreenshots(_ set: MediaCardSet, ticket: UUID) async {
        guard let session else { return }
        @MainActor func currentRead() -> Bool { !Task.isCancelled && mediaReadId == ticket && opened?.id == set.id }
        let shots = set.cards.compactMap(\.screenshot), first = current?.screenshot?.hash
        for shot in shots.sorted(by: { ($0.hash == first ? 0 : 1) < ($1.hash == first ? 0 : 1) }) where images.thumbnail(shot.hash) == nil {
            guard currentRead() else { return }
            do {
                let bytes = try await session.mediaCardScreenshot(accountId: account.id, appId: app.id, hash: shot.hash)
                let image = try await ScreenshotRenderer.loadAsync(bytes, maximumEdge: MediaCardImages.thumbnailEdge)
                guard currentRead() else { return }
                images.keepThumbnail(image, shot.hash)
            } catch is CancellationError { return } catch {
                guard currentRead() else { return }
                previewIssue = "A saved screenshot could not be opened. Choose it again on the cards that show an empty frame."
            }
        }
        for file in set.cards.compactMap(\.style.fontFile) where fonts[file.hash] == nil {
            guard currentRead() else { return }
            do {
                let bytes = try await session.mediaCardFont(accountId: account.id, appId: app.id, hash: file.hash)
                guard currentRead() else { return }
                fonts[file.hash] = bytes
            } catch is CancellationError { return } catch {
                guard currentRead() else { return }
                previewIssue = MediaCardFailure.font.message
            }
        }
    }
    /// The full-size screenshot of a card, decoded when it is not kept; nil when it cannot be read.
    @discardableResult private func loadFull(_ card: MediaCard?) async -> DecodedScreenshot? {
        guard let shot = card?.screenshot, let session else { return nil }
        if let kept = images.full(shot.hash) { images.touch(shot.hash); return kept }
        do {
            let image = try await ScreenshotRenderer.loadAsync(try await session.mediaCardScreenshot(accountId: account.id, appId: app.id, hash: shot.hash))
            images.keepFull(image, shot.hash); return image
        } catch is CancellationError { return nil } catch { previewIssue = "A saved screenshot could not be opened. Choose it again on the cards that show an empty frame."; return nil }
    }
    /// The font file a card draws with, once it is read.
    private func font(_ card: MediaCard) -> Data? { card.style.typeface == .file ? card.style.fontFile.flatMap { fonts[$0.hash] } : nil }

    private func chooseFont() {
        guard !busy, let session else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.font]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let load = start(.font) else { return }
        working = true
        Task {
            defer { working = false }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 <= WorkspaceSession.maximumFontBytes }) ?? false else { throw MediaCardFailure.font }
                let bytes = try Data(contentsOf: url)
                let file = try await session.stageMediaCardFont(accountId: account.id, appId: app.id, bytes: bytes, name: url.lastPathComponent)
                fonts[file.hash] = bytes
                guard let position = finish(load, "typeface", { $0.style.typeface = .file; $0.style.fontFile = file }) else {
                    if loads[load.key] == load.ticket { loads[load.key] = nil; status = "\(file.family) was not used because its card was removed or another card set was opened."; statusError = true }
                    return
                }
                status = "\(file.family) is used on card \(position + 1). Apply Style to All Cards uses it on every card."; statusError = false
            } catch {
                guard loads[load.key] == load.ticket else { return }; loads[load.key] = nil
                status = "The font could not be added. Choose a TrueType or OpenType font file up to 20 MB."; statusError = true
            }
        }
    }

    private func chooseScreenshot() {
        guard !busy, let session else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let load = start(.screenshot) else { return }
        working = true
        Task {
            defer { working = false }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard size.isRegularFile == true, (size.fileSize ?? 0) <= ScreenshotEditing.maximumSourceBytes else { throw ScreenshotEditFailure.bytes }
                let bytes = try Data(contentsOf: url)
                let shot = try await session.stageMediaCardScreenshot(accountId: account.id, appId: app.id, bytes: bytes, name: url.lastPathComponent)
                let image = try await ScreenshotRenderer.loadAsync(bytes)
                images.keepFull(image, shot.hash)
                images.keepThumbnail(try await ScreenshotRenderer.loadAsync(bytes, maximumEdge: MediaCardImages.thumbnailEdge), shot.hash)
                guard let position = finish(load, "screenshot", { $0.screenshot = shot; $0.zoom = $0.layout == .focus ? 1.6 : 1; $0.x = 0.5; $0.y = 0.5 }) else {
                    if loads[load.key] == load.ticket { loads[load.key] = nil; status = "The screenshot was not added because its card was removed or another card set was opened."; statusError = true }
                    return
                }
                status = "Screenshot added to card \(position + 1)."; statusError = false
            } catch {
                guard loads[load.key] == load.ticket else { return }; loads[load.key] = nil
                status = (error as? ScreenshotEditFailure)?.message ?? "The screenshot could not be added. Choose a PNG or JPEG up to 80 MB."; statusError = true
            }
        }
    }

    private func renderPreview() async {
        guard let set = opened, let card = current else { return }
        guard card.style.typeface != .file || font(card) != nil else { return }
        // The decoded screenshot goes to the renderer directly, so one an export let go, or one too large to keep, still draws.
        var screenshot: DecodedScreenshot?
        if card.layout.usesScreenshot, let shot = card.screenshot {
            if let kept = images.full(shot.hash) { screenshot = kept } else { screenshot = await loadFull(card) }
            guard screenshot != nil else { return }
        }
        do {
            let image = try await MediaCardRenderer.previewAsync(card, width: set.width, height: set.height, screenshot: screenshot, font: font(card))
            try Task.checkCancellation()
            preview = image; previewIssue = ""
        } catch is CancellationError {} catch { previewIssue = (error as? MediaCardFailure)?.message ?? MediaCardFailure.render.message }
    }

    private func exportCards(_ cards: [(Int, MediaCard)], in set: MediaCardSet) async throws -> [(Int, Data)] {
        var result: [(Int, Data)] = []
        for (position, card) in cards {
            // Each card's full-size screenshot is decoded as it is exported; the budget lets earlier ones go.
            let screenshot = card.layout.usesScreenshot ? await loadFull(card) : nil
            do { result.append((position, try await MediaCardRenderer.exportAsync(card, width: set.width, height: set.height, screenshot: screenshot, font: font(card)))) }
            catch let failure as MediaCardFailure { throw CardExportFailure(position: position, failure: failure) }
        }
        return result
    }

    @discardableResult private func saveToLibrary(all: Bool) async -> Bool {
        guard let session, let set = opened, let index, !busy else { return false }
        guard await save() else { return false }
        working = true; defer { working = false }
        let chosen = all ? Array(set.cards.enumerated()) : [(index, set.cards[index])]
        do {
            // Every card is rendered and checked first, and all of them are saved in one transaction, so a set is never added halfway.
            let files = try await exportCards(chosen, in: set)
            let images = files.map { position, data in
                WorkspaceSession.CreatedLibraryImage(sourceId: set.cards[position].id, bytes: data, fileName: MediaCards.fileName(set: set, index: position), referenceName: "\(MediaCards.trimmed(set.name)) \(position + 1)")
            }
            let saved = try await session.stageCreatedLibraryImages(accountId: account.id, appId: app.id, setId: set.id, images: images)
            // The marker records the exported cards, so edits made while saving still show as unsaved.
            if all { let exported = set.cards; change("library", set: { if $0.id == set.id { $0.savedCards = exported } }) }
            let kept = saved.files.count - saved.added
            status = (files.count == 1 ? "1 card" : "\(files.count) cards") + " saved to Asset Library on this Mac"
                + (kept == 0 ? "" : kept == files.count ? ", already there unchanged" : ", \(kept) already there unchanged") + ". Next, add them in Release step 2, Text and Screenshots."
            statusError = false
            return true
        } catch let failure as CardExportFailure {
            selectedId = set.cards[failure.position].id
            status = "Card \(failure.position + 1): \(failure.failure.message) Nothing was saved."; statusError = true
            return false
        } catch { status = (error as? PublishFailure)?.message ?? "The cards could not be saved to Asset Library."; statusError = true; return false }
    }

    private func exportPNG() async {
        guard let set = opened, let index, !busy else { return }
        working = true; defer { working = false }
        do {
            guard let data = try await exportCards([(index, set.cards[index])], in: set).first?.1 else { return }
            let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = MediaCards.fileName(set: set, index: index)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try data.write(to: url, options: .atomic)
            status = "Card \(index + 1) exported as a PNG."; statusError = false
        } catch let failure as CardExportFailure { status = "Card \(failure.position + 1): \(failure.failure.message)"; statusError = true }
        catch { status = "The PNG could not be saved."; statusError = true }
    }
}

private struct CardExportFailure: Error { let position: Int; let failure: MediaCardFailure }

/// Image and font availability change independently, including on a Text Only card without a screenshot.
struct MediaCardPreviewRequest: Equatable {
    let card: MediaCard?, width: Int, height: Int
    let screenshotReady, fontReady: Bool
    var ready: Bool { screenshotReady && fontReady }
    init(card: MediaCard?, width: Int, height: Int, screenshotLoaded: Bool, fontLoaded: Bool) {
        self.card = card; self.width = width; self.height = height
        screenshotReady = card?.layout.usesScreenshot != true || card?.screenshot == nil || screenshotLoaded
        fontReady = card?.style.typeface != .file || fontLoaded
    }
}

/// A small rendering of one card, about the size it appears in App Store search results.
private struct MediaCardThumbnail: View {
    let card: MediaCard, width: Int, height: Int
    let screenshot: DecodedScreenshot?
    let font: Data?
    @State private var image: ScreenshotPreview?
    var body: some View {
        let request = MediaCardPreviewRequest(card: card, width: width, height: height, screenshotLoaded: screenshot != nil, fontLoaded: font != nil)
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(StorebenchTheme.color("color-surface-sunken"))
            if let image { Image(decorative: image.image, scale: 1).resizable().clipShape(RoundedRectangle(cornerRadius: 6)) }
        }
        .aspectRatio(Double(width) / Double(height), contentMode: .fit)
        .accessibilityHidden(true)
        .task(id: request) {
            guard request.ready else { image = nil; return }
            if let result = try? await MediaCardRenderer.previewAsync(card, width: width, height: height, screenshot: screenshot, font: font, edge: 360), !Task.isCancelled { image = result }
        }
    }
}
