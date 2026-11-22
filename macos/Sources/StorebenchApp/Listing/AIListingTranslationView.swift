import StorebenchCore
import SwiftUI

/// Each language's latest translation step, updated from the translation tasks while they run.
@MainActor @Observable final class AITranslationBoard {
    var steps: [String: AITranslationStep] = [:]
    /// Fields of each language that left out closing sentences to fit their limit.
    var notes: [String: [String]] = [:]
    func record(_ step: AITranslationStep, for locale: String) {
        steps[locale] = step
        switch step.phase {
        case .leftOut, .keywordsLeftOut, .wordsLeftOut: notes[locale, default: []].append(step.text)
        case .translating, .shortening: break
        }
    }
}

struct AIListingTranslationView: View {
    let account: Account, appId: String, revisionId: String, version: Revision.Version, session: WorkspaceSession?
    /// The listing editor of Release step 2. Screenshots are translated only there, where each language's screenshots are edited.
    var model: VersionListingEditor? = nil
    var changed: () -> Void = {}
    @Environment(\.editorProtection) private var protection
    @Environment(\.confirmDestructive) private var confirm
    @State private var removing = false
    @State private var source = ""
    @State private var provider = AIProvider.apple.rawValue
    @State private var modelID = ""
    @State private var connections: [AIConnection] = []
    @State private var targets = Set<String>()
    @State private var translateText = true
    @State private var translateScreenshots = false
    @State private var cardSets: [WorkspaceSession.SavedMediaCardSet] = []
    /// Card sets written in other languages, by language, so the step can say which language to translate from.
    @State private var otherCardLanguages: [String: Int] = [:]
    @State private var chosenSets = Set<String>()
    @State private var replace = false
    @State private var working = false
    @State private var status = ""
    @State private var results: [String: String] = [:]
    @State private var screenshotResults: [String: String] = [:]
    @State private var screenshotWork: [String: String] = [:]
    @State private var outcomes: [String: LanguageTranslation.Completion] = [:]
    @State private var resultLocales: [String] = []
    @State private var failed = false
    @State private var board = AITranslationBoard()
    private var locales: [String] { version.localizations.map(\.locale) }
    private var targetOptions: [String] { StoreLocales.codes.filter { $0 != source } }
    private var screenshotsAvailable: Bool { model != nil && !cardSets.isEmpty }
    private var serviceReady: Bool { provider == AIProvider.apple.rawValue ? AppleLocalAI.available : connections.contains { $0.provider.rawValue == provider } }
    private var chosenWork: Bool { translateText || translateScreenshots && screenshotsAvailable && !chosenSets.isEmpty }
    private struct Prepared: Sendable { let locale: String, texts: [String]?, problem: String?; var skipped = false }

    var body: some View {
        Card(title: "Translate Languages with AI", subtitle: "Fill other languages from one saved language. Results stay drafts on this Mac until you sync them.") {
            StorebenchCardSection(title: "1. From and To") {
                // Both languages are fields side by side; the languages to fill are always in view, never folded away.
                StorebenchFormGrid {
                    StorebenchPicker("From", selection: $source) { SelectionOption("Choose a Language", value: ""); selectionOptions(locales) { SelectionOption(StoreLocales.name($0), value: $0) } }
                        .onChange(of: source) { targets.remove(source); if targets.isEmpty { targets = TranslationTargets.initial(source: source, inVersion: locales, all: StoreLocales.codes) } }
                    StorebenchMultiSelect(title: "Into", dialogTitle: "Choose Languages",
                                          dialogSubtitle: "The languages to fill from \(source.isEmpty ? "the source language" : StoreLocales.name(source)).",
                                          selection: $targets, options: targetOptions, name: StoreLocales.name,
                                          note: { locales.contains($0) ? "In Version" : "" }, presets: presets,
                                          summary: TranslationTargets.summary(targets), controlID: "ai-languages.targets", optionPrefix: "ai-languages.target.")
                }.environment(\.fieldHintHeight, 0)
            }
            StorebenchCardSection(title: "2. What to Translate") {
                VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
                    HStack(spacing: StorebenchTheme.space(6)) {
                        StorebenchToggle("Text", isOn: $translateText).storebenchControlID("ai-languages.text")
                        StorebenchToggle("Screenshots", isOn: $translateScreenshots).storebenchControlID("ai-languages.screenshots").storebenchWorking(!screenshotsAvailable)
                    }
                    StorebenchTextSlot(text: whatHint, height: 32, font: .sbCaption, color: StorebenchTheme.muted)
                }
                if translateScreenshots && screenshotsAvailable {
                    Text("Card Sets From Create Media").font(.sbCallout.weight(.semibold))
                    StorebenchOptionGrid(maximumColumns: 1) {
                        ForEach(cardSets, id: \.set.id) { saved in
                            StorebenchToggle(Self.setLabel(saved.set), isOn: Binding(get: { chosenSets.contains(saved.set.id) }, set: { if $0 { chosenSets.insert(saved.set.id) } else { chosenSets.remove(saved.set.id) } }))
                                .storebenchControlID("ai-languages.card-set." + saved.set.id)
                        }
                    }
                }
            }
            StorebenchCardSection(title: "3. How") {
                AIServicePicker(session: session, selection: $provider, modelID: $modelID, loaded: { connections = $0 })
                VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
                    StorebenchToggle(translateScreenshots && screenshotsAvailable ? "Replace Existing Text and Screenshots" : "Replace Existing Text", isOn: $replace)
                    StorebenchTextSlot(text: howHint, height: 32, font: .sbCaption, color: StorebenchTheme.muted)
                }
            }
            if !resultLocales.isEmpty { resultList }
            // The run's status sits beside its command, so an empty status takes no room of its own.
            VStack(spacing: StorebenchTheme.space(3)) {
                StorebenchDivider()
                StorebenchActionRow {
                    StorebenchFeedback(text: status, height: 36, error: failed).storebenchControlID("ai-languages.status")
                } actions: {
                    StorebenchBusyButton(title: "Translate Languages", loadingTitle: "Translating…", busy: working, variant: .primary) { Task { await populate() } }
                        .storebenchControlID("ai-languages.populate")
                        .storebenchWorking(source.isEmpty || targets.isEmpty || !chosenWork || !serviceReady || model?.busy == true || model?.workflow.shown.ready == false)
                        .help(targets.isEmpty ? "Choose at least one language in Into" : !chosenWork ? "Choose Text, Screenshots or both" : "Translate into \(targets.count) \(targets.count == 1 ? "language" : "languages")")
                }
            }.layoutValue(key: StorebenchCardFooterKey.self, value: true)
        }.storebenchWorking(working || session == nil)
            .task {
                if source.isEmpty { source = locales.first ?? "" }
                // The version's own languages are chosen from the start, so Translate Languages can run at once.
                if targets.isEmpty { targets = TranslationTargets.initial(source: source, inVersion: locales, all: StoreLocales.codes) }
                if let preferences = try? await session?.aiSetupPreferences() { provider = preferences.defaultProvider.rawValue }
            }
            .task(id: source) {
                guard model != nil, let session, !source.isEmpty else { cardSets = []; return }
                cardSets = (try? await session.cardSets(accountId: account.id, appId: appId, writtenIn: source)) ?? []
                otherCardLanguages = ((try? await session.cardSetLanguages(accountId: account.id, appId: appId)) ?? [:]).filter { $0.key != source }
                chosenSets = Set(cardSets.map(\.set.id))
                if cardSets.isEmpty { translateScreenshots = false }
            }
    }

    /// Each language's outcome in one row: a bar while it runs, then what was saved and anything left out.
    private var resultList: some View {
        StorebenchCardSection(title: "Results", accessory: addedLanguages.count > 1 && !working ? AnyView(
            Button("Remove Added Languages", role: .destructive) { removeLanguages(addedLanguages) }
                .help("Remove every language this translation added on this Mac, after one confirmation")
                .storebenchWorking(removing || model?.busy == true).storebenchControlID("ai-languages.remove-added")) : nil) {
            StorebenchStatusList {
                ForEach(Array(resultLocales.enumerated()), id: \.element) { index, locale in
                    VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
                        Text(StoreLocales.name(locale)).font(.sbHeadline)
                        if working, results[locale] == nil, translateText {
                            // A bar while this language is translated; languages after it wait their turn for the model.
                            if let step = board.steps[locale] { StorebenchProgressStatus(message: step.text, value: step.fraction, height: 36) }
                            else { StorebenchProgressStatus(message: provider == AIProvider.apple.rawValue ? "Waiting for the on-device model…" : "Waiting…", value: 0, height: 36) }
                        } else if let work = screenshotWork[locale] {
                            StorebenchProgressStatus(message: work, height: 36)
                        } else {
                            StorebenchTextSlot(text: resultText(locale), height: 54, font: .sbCallout,
                                               color: outcomes[locale] == .failed ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted, live: true)
                            removal(locale)
                        }
                        if index < resultLocales.count - 1 { StorebenchDivider().padding(.top, StorebenchTheme.space(2)) }
                    }.padding(.vertical, StorebenchTheme.space(1))
                }
            }
        }
    }
    /// Languages this run added that are only on this Mac, so they can be taken out again at once.
    private var addedLanguages: [String] { resultLocales.filter { model?.localOnlyLocalization($0) != nil } }
    /// Removing what a run made: a language only on this Mac, or the screenshots placed in it.
    @ViewBuilder private func removal(_ locale: String) -> some View {
        if let model, !working {
            let local = model.localOnlyLocalization(locale) != nil
            let placed = screenshotResults[locale]?.hasPrefix("Screenshots placed") == true
            if local || placed {
                StorebenchActionGroup {
                    if placed, let media = model.languages.first(where: { $0.locale == locale })?.media.first {
                        Button("Remove Screenshots", role: .destructive) { removeScreenshots(locale, media) }
                            .help("Remove the translated screenshots from \(StoreLocales.name(locale)) on this Mac. The cards stay in Asset Library.")
                            .storebenchControlID("ai-languages.remove-screenshots." + locale)
                    }
                    if local {
                        Button("Remove Language", role: .destructive) { removeLanguages([locale]) }
                            .help("Remove \(StoreLocales.name(locale)) from this version on this Mac. It is not in App Store Connect yet.")
                            .storebenchControlID("ai-languages.remove." + locale)
                    }
                }.storebenchWorking(removing || model.busy)
            }
        }
    }
    private func removeScreenshots(_ locale: String, _ media: MediaListingEditor) {
        let name = StoreLocales.name(locale)
        guard confirm(.removeLanguage, title: "Remove the screenshots from \(name)?",
                      message: "Every screenshot in \(name) is taken out of this version on this Mac. The translated cards stay in Asset Library, and nothing changes in App Store Connect.",
                      action: "Remove Screenshots") else { return }
        media.removeAllScreenshots()
        screenshotResults[locale] = "Screenshots removed on this Mac."
    }
    /// Removes languages only on this Mac, after one confirmation for all of them.
    private func removeLanguages(_ locales: [String]) {
        guard let model, !locales.isEmpty, !removing else { return }
        let names = locales.map(StoreLocales.name)
        let title = locales.count == 1 ? "Remove \(names[0]) from this version?" : "Remove \(locales.count) added languages from this version?"
        guard confirm(.removeLanguage, title: title,
                      message: (locales.count == 1 ? names[0] + " was" : names.joined(separator: ", ") + " were") + " added on this Mac and " + (locales.count == 1 ? "is" : "are")
                        + " not in App Store Connect. Their text, screenshot and preview choices on this Mac are removed. Cards stay in Asset Library.",
                      action: locales.count == 1 ? "Remove Language" : "Remove \(locales.count) Languages") else { return }
        removing = true
        Task {
            defer { removing = false }
            var removed: [String] = []
            for locale in locales where await model.removeLanguage(locale) { removed.append(locale) }
            resultLocales.removeAll { removed.contains($0) }
            for locale in removed { results[locale] = nil; screenshotResults[locale] = nil; outcomes[locale] = nil }
            status = removed.count == locales.count ? (removed.count == 1 ? "\(StoreLocales.name(removed[0])) removed on this Mac." : "\(removed.count) languages removed on this Mac.")
                : "\(removed.count) of \(locales.count) languages removed. " + model.status
            failed = removed.count < locales.count
            changed()
        }
    }
    private func resultText(_ locale: String) -> String {
        let notes = outcomes[locale] == .saved ? board.notes[locale] ?? [] : []
        let parts = [results[locale]] + notes.map(Optional.some) + [screenshotResults[locale]]
        let text = parts.compactMap { $0 }.joined(separator: " ")
        return text.isEmpty ? "Ready to translate." : text
    }
    private var whatHint: String {
        if model == nil { return "Text is translated here. Screenshots are translated in Release, step 2, Text and Screenshots." }
        if cardSets.isEmpty, let other = otherCardLanguages.max(by: { $0.value < $1.value }) {
            return "Your screenshot cards are written in \(StoreLocales.name(other.key)). Choose \(StoreLocales.name(other.key)) in From to translate them."
        }
        if cardSets.isEmpty { return "No screenshot cards yet. Make cards in Create Media; their text can then be translated into each language here." }
        if !translateScreenshots { return "\(cardSets.count == 1 ? "1 card set" : "\(cardSets.count) card sets") from Create Media can be translated, rendered and placed in each language's screenshots." }
        return "Each chosen card set is translated, rendered as new PNGs, saved to Asset Library and placed in the matching display size."
    }
    private var howHint: String {
        let fill = replace ? "Translated text replaces existing text; names and links are kept." : "Only empty text fields are filled; existing text, names and links are kept."
        let screens = translateScreenshots && screenshotsAvailable ? (replace ? " Translated cards replace a size's screenshots." : " Cards fill only sizes without screenshots.") : ""
        return fill + screens + " Text is fitted to App Store limits; nothing is cut mid-word or mid-sentence."
    }
    /// Quick choices in the language dialog.
    private var presets: [StorebenchMultiSelect.Preset] {
        let own = Set(locales).subtracting([source]).intersection(targetOptions)
        let markets = Set(TranslationTargets.topMarkets.filter { $0 != source && StoreLocales.codes.contains($0) })
        return (own.isEmpty ? [] : [StorebenchMultiSelect.Preset(title: "Languages in This Version", help: "The version's other languages", values: own)])
            + [.init(title: "Top Markets", help: "The ten largest App Store languages: " + TranslationTargets.topMarkets.map(StoreLocales.name).joined(separator: ", "), values: markets),
               .init(title: "All", help: "Every other App Store language", values: Set(targetOptions))]
    }
    /// A card set by its name, how many screenshot cards it makes and for which display.
    static func setLabel(_ set: MediaCardSet) -> String {
        "\(MediaCards.trimmed(set.name)) · \(set.cards.count == 1 ? "1 screenshot card" : "\(set.cards.count) screenshot cards") · \(StoreLocales.displayTypeName(set.displayType))"
    }
    private func populate() async {
        guard !working, model?.active != false, model?.workflow.ready != false, let session, let service = AIProvider(rawValue: provider), !targets.isEmpty, chosenWork else { return }
        working = true; defer { working = false; screenshotWork = [:] }
        let selected = targets.sorted(), sourceLocale = source, replaceText = replace
        let sets = translateScreenshots && screenshotsAvailable ? cardSets.map(\.set).filter { chosenSets.contains($0.id) } : []
        let selectedModel = modelID.isEmpty ? nil : modelID
        let accountId = account.id, appId = appId, revisionId = revisionId, versionId = version.id
        if let protection, !(await protection.saveAllDrafts()) { status = "Save or compare pending edits before translating."; failed = true; return }
        results = [:]; screenshotResults = [:]; outcomes = [:]; resultLocales = selected; failed = false; board.steps = [:]; board.notes = [:]
        let board = board
        status = "Translating \(selected.count) \(selected.count == 1 ? "language" : "languages"). Completed results are saved on this Mac."
        guard translateText else {
            for locale in selected { await translateCards(sets, locale: locale, service: service, model: selectedModel, replace: replaceText) }
            status = screenshotSummary(selected); return
        }
        do {
            let request = try await session.translationRequest(accountId: accountId, appId: appId, revisionId: revisionId, versionId: versionId, sourceLocale: sourceLocale)
            guard !request.segments.isEmpty else { status = "The source language has no saved text to translate. Save its text first."; return }
            let baselines = try await session.aiTranslationTargets(accountId: accountId, appId: appId, revisionId: revisionId, versionId: versionId, locales: selected)
            await withTaskGroup(of: Prepared.self) { group in
                for locale in selected {
                    let baseline = baselines[locale]
                    group.addTask {
                        do {
                            let texts = try await AITranslationProgress.$report.withValue({ step in Task { @MainActor in board.record(step, for: locale) } }) {
                                try await session.translatedListingSegments(accountId: accountId, appId: appId, provider: service, source: request, locale: locale, target: baseline, replace: replaceText, model: selectedModel)
                            }
                            guard let texts else { return Prepared(locale: locale, texts: nil, problem: "No empty text fields to fill.", skipped: true) }
                            return Prepared(locale: locale, texts: texts, problem: nil)
                        } catch { return Prepared(locale: locale, texts: nil, problem: AIFailure.message(error)) }
                    }
                }
                var completed = 0
                for await value in group {
                    completed += 1
                    outcomes[value.locale] = await apply(value, source: request, baseline: baselines[value.locale], replace: replaceText)
                    // Cards follow the text, so a language the text just added already has its screenshots.
                    if !sets.isEmpty, outcomes[value.locale] != .failed { await translateCards(sets, locale: value.locale, service: service, model: selectedModel, replace: replaceText) }
                    failed = outcomes.values.contains(.failed)
                    status = "\(completed) of \(selected.count) languages checked. Completed results are saved on this Mac."
                }
            }
            status = LanguageTranslation.summary(Array(outcomes.values)) + (sets.isEmpty ? "" : " " + screenshotSummary(selected))
        } catch { status = AIFailure.message(error); failed = true }
    }
    /// Translates each chosen card set for one language and places its cards in that language's screenshots.
    private func translateCards(_ sets: [MediaCardSet], locale: String, service: AIProvider, model selectedModel: String?, replace: Bool) async {
        guard let session, !sets.isEmpty else { return }
        guard let media = await mediaEditor(locale) else {
            screenshotResults[locale] = "Screenshots: add \(StoreLocales.name(locale)) first, or include Text to add it."; failed = true; return
        }
        let accountId = account.id, appId = appId
        var placed: [String] = [], problems: [String] = []
        for (index, set) in sets.enumerated() {
            screenshotWork[locale] = "Translating screenshots: \(MediaCards.trimmed(set.name)) (\(index + 1) of \(sets.count))…"
            do {
                let cards = try await session.translateCardSet(accountId: accountId, appId: appId, sourceId: set.id, target: locale) { texts, fields in
                    try await session.translateWithAI(accountId: accountId, appId: appId, provider: service, texts: texts, source: set.language ?? "en-US", target: locale, fields: fields, model: selectedModel)
                }
                if let problem = await media.placeTranslatedCards(cards.files, replacing: replace) { problems.append(problem) }
                else { placed.append("\(StoreLocales.displayTypeName(set.displayType)): \(cards.files.count == 1 ? "1 card" : "\(cards.files.count) cards")") }
            } catch let failure as MediaCardLanguageFailure { problems.append(failure.message) }
            catch let failure as MediaCardFailure { problems.append("\(MediaCards.trimmed(set.name)): \(failure.message)") }
            catch { problems.append("\(MediaCards.trimmed(set.name)): \(AIFailure.message(error))") }
        }
        screenshotWork[locale] = nil
        if !problems.isEmpty { failed = true }
        screenshotResults[locale] = ([placed.isEmpty ? nil : "Screenshots placed for " + placed.joined(separator: ", ") + "."] + problems.map(Optional.some)).compactMap { $0 }.joined(separator: " ")
        if !placed.isEmpty { changed() }
    }
    /// The language's media editor once it has read its screenshots, waiting briefly for a language the text just added.
    private func mediaEditor(_ locale: String) async -> MediaListingEditor? {
        for _ in 0..<100 {
            if let media = model?.languages.first(where: { $0.locale == locale })?.media.first, !media.loading { return media }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
    private func screenshotSummary(_ locales: [String]) -> String {
        let done = locales.filter { screenshotResults[$0]?.hasPrefix("Screenshots placed") == true }.count
        return done == locales.count ? "Translated screenshots placed in \(done == 1 ? "1 language" : "\(done) languages")." : "Translated screenshots placed in \(done) of \(locales.count) languages; see each result."
    }
    private func apply(_ value: Prepared, source: LanguageTranslation.Request, baseline: [LanguageDrafts.Section]?, replace: Bool) async -> LanguageTranslation.Completion {
        guard model?.active != false, let session else { return .failed }
        guard let texts = value.texts else { results[value.locale] = value.problem; return value.skipped ? .skipped : .failed }
        do {
            let translation = try source.translation(texts)
            if let baseline {
                try await session.applyAITranslation(accountId: account.id, appId: appId, revisionId: revisionId, versionId: version.id, source: source, translation: translation, target: baseline, replace: replace)
                if let language = model?.languages.first(where: { $0.locale == value.locale }) { await language.text.load(afterReuse: true) }
            } else if let model {
                let added = await model.addLanguage(value.locale, copyFrom: source.sourceLocale, translate: { current in
                    guard current == source.segments else { throw LanguageFailure.sourceChanged }; return texts
                })
                guard added else { results[value.locale] = model.status; return .failed }
            } else {
                _ = try await session.addLanguage(accountId: account.id, appId: appId, revisionId: revisionId, versionId: version.id, locale: value.locale, copyFrom: source.sourceLocale, translation: translation)
            }
            results[value.locale] = "Draft saved. View Changes before syncing to Apple."; changed(); return .saved
        } catch { results[value.locale] = (error as? LanguageFailure)?.message ?? (error as? DraftFailure)?.message ?? AIFailure.message(error); return .failed }
    }

}
