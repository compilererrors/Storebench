import StorebenchCore
import SwiftUI

struct AIListingTranslationView: View {
    let account: Account, appId: String, revisionId: String, version: Revision.Version, session: WorkspaceSession?
    var model: VersionListingEditor? = nil
    var changed: () -> Void = {}
    @Environment(\.editorProtection) private var protection
    @State private var source = ""
    @State private var provider = AIProvider.apple.rawValue
    @State private var modelID = ""
    @State private var connections: [AIConnection] = []
    @State private var targets = Set<String>()
    @State private var replace = false
    @State private var working = false
    @State private var status = ""
    @State private var results: [String: String] = [:]
    private var locales: [String] { version.localizations.map(\.locale) }
    private struct Prepared: Sendable { let locale: String, texts: [String]?, problem: String? }
    var body: some View {
        Card(title: "Translate Languages with AI", subtitle: "Choose one saved source language and the languages to populate. Results are local drafts; Sync to Apple sends them after review.") {
            StorebenchPicker("Source Language", selection: $source) { SelectionOption("Choose a Language", value: ""); selectionOptions(locales) { SelectionOption(StoreLocales.name($0), value: $0) } }
                .onChange(of: source) { targets.remove(source) }
            AIServicePicker(session: session, selection: $provider, modelID: $modelID, loaded: { connections = $0 })
            DisclosureGroup("Target Languages · \(targets.count) Selected") {
                ForEach(StoreLocales.codes.filter { $0 != source }, id: \.self) { locale in
                    StorebenchToggle(StoreLocales.name(locale), isOn: Binding(get: { targets.contains(locale) }, set: { if $0 { targets.insert(locale) } else { targets.remove(locale) } }))
                        .storebenchControlID("ai-languages.target." + locale)
                }
            }
            .storebenchControlID("ai-languages.targets")
            StorebenchToggle("Replace Existing Text", isOn: $replace)
            Text(replace ? "Selected languages' translated text fields will be replaced. Names and links are preserved." : "Only empty text fields are filled. Existing text, names and links are preserved.")
                .font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            StorebenchTextSlot(text: status, height: 54, font: .sbCallout, color: StorebenchTheme.muted, live: true)
            DisclosureGroup("Language Results · \(targets.count) Selected") {
                ForEach(targets.sorted(), id: \.self) { locale in
                    StorebenchCardSection(title: StoreLocales.name(locale)) {
                        StorebenchTextSlot(text: results[locale] ?? (working ? "Waiting…" : "Ready to translate."), height: 54, font: .sbCallout, color: StorebenchTheme.muted, live: true)
                    }
                }
            }
            StorebenchFormFooter {
                Button(working ? "Translating…" : "Populate Languages") { Task { await populate() } }
                    .buttonStyle(StorebenchButtonStyle(.primary)).storebenchControlID("ai-languages.populate")
                    .storebenchWorking(source.isEmpty || targets.isEmpty || (provider == AIProvider.apple.rawValue ? !AppleLocalAI.available : !connections.contains { $0.provider.rawValue == provider }) || model?.busy == true || model?.workflow.ready == false)
            }
        }.storebenchWorking(working || session == nil)
            .task {
                if source.isEmpty { source = locales.first ?? "" }
                if let preferences = try? await session?.aiSetupPreferences() { provider = preferences.defaultProvider.rawValue }
            }
    }
    private func populate() async {
        guard !working, model?.active != false, model?.workflow.ready != false, let session, let service = AIProvider(rawValue: provider), !targets.isEmpty else { return }
        let selected = targets.sorted(), sourceLocale = source, replaceText = replace
        let selectedModel = modelID.isEmpty ? nil : modelID
        let accountId = account.id, appId = appId, revisionId = revisionId, versionId = version.id
        if let protection, !(await protection.saveAllDrafts()) { status = "Save or compare pending edits before translating."; return }
        working = true; results = [:]; status = "Translating \(selected.count) languages. Completed results are saved on this Mac."; defer { working = false }
        do {
            let request = try await session.translationRequest(accountId: accountId, appId: appId, revisionId: revisionId, versionId: versionId, sourceLocale: sourceLocale)
            guard !request.segments.isEmpty else { status = "The source language has no saved text to translate. Save its text first."; return }
            var baselines: [String: [LanguageDrafts.Section]] = [:]
            for locale in selected where locales.contains(locale) {
                baselines[locale] = try await session.aiTranslationTarget(accountId: accountId, appId: appId, revisionId: revisionId, versionId: versionId, locale: locale)
            }
            await withTaskGroup(of: Prepared.self) { group in
                for locale in selected {
                    let baseline = baselines[locale]
                    group.addTask {
                        do {
                            let texts = try await session.translatedListingSegments(accountId: accountId, appId: appId, provider: service, source: request, locale: locale, target: baseline, replace: replaceText, model: selectedModel)
                            guard let texts else { return Prepared(locale: locale, texts: nil, problem: "No empty text fields to fill.") }
                            return Prepared(locale: locale, texts: texts, problem: nil)
                        } catch { return Prepared(locale: locale, texts: nil, problem: AIFailure.message(error)) }
                    }
                }
                var completed = 0
                for await value in group {
                    completed += 1
                    await apply(value, source: request, baseline: baselines[value.locale], replace: replaceText)
                    status = "\(completed) of \(selected.count) languages checked. Completed results are saved on this Mac."
                }
            }
            status = "Translation finished. Results remain local until you sync. Failed languages can be retried; completed AI results are reused."
        } catch { status = AIFailure.message(error) }
    }
    private func apply(_ value: Prepared, source: LanguageTranslation.Request, baseline: [LanguageDrafts.Section]?, replace: Bool) async {
        guard model?.active != false, let session else { return }
        guard let texts = value.texts else { results[value.locale] = value.problem; return }
        do {
            let translation = try source.translation(texts)
            if let baseline {
                try await session.applyAITranslation(accountId: account.id, appId: appId, revisionId: revisionId, versionId: version.id, source: source, translation: translation, target: baseline, replace: replace)
                if let language = model?.languages.first(where: { $0.locale == value.locale }) { await language.text.load(afterReuse: true) }
            } else if let model {
                let added = await model.addLanguage(value.locale, copyFrom: source.sourceLocale, translate: { current in
                    guard current == source.segments else { throw LanguageFailure.sourceChanged }; return texts
                })
                guard added else { results[value.locale] = model.status; return }
            } else {
                _ = try await session.addLanguage(accountId: account.id, appId: appId, revisionId: revisionId, versionId: version.id, locale: value.locale, copyFrom: source.sourceLocale, translation: translation)
            }
            results[value.locale] = "Draft saved. Review the text, then sync to Apple."; changed()
        } catch { results[value.locale] = (error as? LanguageFailure)?.message ?? (error as? DraftFailure)?.message ?? AIFailure.message(error) }
    }

}
