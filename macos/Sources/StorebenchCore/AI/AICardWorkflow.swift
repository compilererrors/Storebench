import Foundation

extension WorkspaceSession {
    /// Generates from the exact saved composer revision. New originals belong to that scoped draft,
    /// even before they have been used in a saved card set. The proposal remains unsaved until the editor accepts it.
    public func proposeAICards(accountId: String, appId: String, expected: Int) async throws -> MediaCardSet {
        try requireHistoryScope(accountId: accountId, appId: appId)
        let scope = LocalEditorDraft.Scope(accountId: accountId, appId: appId, editor: "ai-cards", resource: "composer")
        guard let saved = try localEditorDraft(scope), saved.revision == expected else { throw AIFailure.changed }
        let value = saved.value
        guard let name = value["name"]?.text, !TextSemantics.trim(name).isEmpty, MediaCards.validText(name, MediaCards.nameLimit), !name.contains("\n"),
              let brief = value["brief"]?.text, !TextSemantics.trim(brief).isEmpty, brief.utf16.count <= 2000, TextSemantics.validControlText(brief),
              let language = value["language"]?.text, StoreLocales.codes.contains(language),
              let provider = value["provider"]?.text.flatMap(AIProvider.init(rawValue:)),
              let target = MediaCards.targets.first(where: { $0.id == value["target"]?.text }),
              let payload = value["screenshots"], let shots = try? JSONDecoder().decode([MediaCard.Screenshot].self, from: payload.data),
              (1...10).contains(shots.count), shots.allSatisfy({ $0.hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }) else { throw AIFailure.configuration }
        let customInstructions = try AICards.customInstructions(in: value)
        _ = try AICards.cardBriefs(in: value, count: shots.count)
        let palette = try AICardPalette.read(value["cardPalette"])
        if provider == .apple, !AppleLocalAI.available { throw AIFailure.localUnavailable }
        let model: String?
        if let chosen = value["model"] {
            guard let text = chosen.text, text.isEmpty || (provider != .apple && AIConnection.validModel(text)) else { throw AIFailure.configuration }
            model = text.isEmpty ? nil : text
        } else { model = nil }
        var images: [AIImage] = []
        for shot in shots {
            try Task.checkCancellation()
            let bytes = try media.read(shot.hash)
            let info = try ScreenshotEditing.inspect(bytes)
            guard info.width == shot.width, info.height == shot.height else { throw AIFailure.changed }
            images.append(try await AICards.image(bytes, recognizeText: provider == .apple, textLimit: min(1800, 6000 / shots.count)))
        }
        let directions = try AICardDirection.selected(in: value)
        let variationID = value["variationID"]?.text
        if let variationID { guard UUID(uuidString: variationID) != nil else { throw AIFailure.configuration } }
        let request = try AICards.request(brief: brief, language: language, target: target, images: images, directions: directions, cardDraft: value, variationID: variationID, customInstructions: customInstructions)
        let result = try await runAIJob(accountId: accountId, appId: appId, provider: provider, request: request, model: model)
        try Task.checkCancellation()
        guard try localEditorDraft(scope) == saved else { throw AIFailure.changed }
        let set = try AICards.cardSet(result, screenshots: shots, name: name, language: language, target: target, directions: directions, variationID: variationID, palette: palette)
        let proposals = try AICards.checked(result, count: shots.count)
        let source = value.setting("cardSourceIndices", .object(zip(set.cards, proposals).map { ($0.0.id, $0.1["screenshotIndex"] ?? .null) }))
        try storeAccess { store in
            try store.transaction { current in
                let key = accountId + ":" + appId + ":" + set.id
                guard try current("ai_card_sources", key) == nil else { return [] }
                return [.put(namespace: "ai_card_sources", key: key, json: source.data)]
            }
        }
        return set
    }

    /// Restores the original brief without adding private prompt data to exported card configurations.
    public func aiCardSource(accountId: String, appId: String, set: MediaCardSet, cardID: String? = nil) throws -> JSONText {
        try requireHistoryScope(accountId: accountId, appId: appId)
        var source = try storeAccess { try $0.document(namespace: "ai_card_sources", key: accountId + ":" + appId + ":" + set.id).map { try JSONText.parse($0.payload) } }
        if source == nil, let target = MediaCards.targets.first(where: { $0.type == set.displayType && $0.width == set.width && $0.height == set.height }) {
            // Legacy jobs retain the original request and source order, even before source links existed.
            for entry in try aiHistory(accountId: accountId, appId: appId) where entry.purpose == "cards" && entry.state == .complete {
                let job = try aiHistoryJob(accountId: accountId, appId: appId, id: entry.id)
                guard let result = job.result, let cards = try? AICards.checked(result, count: set.cards.count) else { continue }
                var originals = Array<MediaCard.Screenshot?>(repeating: nil, count: set.cards.count)
                for (proposal, card) in zip(cards, set.cards) {
                    if case .number(let index)? = proposal["screenshotIndex"] { originals[Int(index)] = card.screenshot }
                }
                let shots = originals.compactMap { $0 }
                guard shots.count == set.cards.count,
                      let candidate = try? AICards.cardSet(result, screenshots: shots, name: set.name, language: set.language ?? "en-US", target: target), candidate.id == set.id,
                      let input = try? JSONText.parse(Data(job.request.input.utf8)) else { continue }
                source = try job.request.cardDraft ?? .object([("name", .string(set.name)), ("brief", input["brief"] ?? .string("")), ("language", .string(set.language ?? "en-US")),
                    ("target", .string(target.id)), ("provider", .string(job.connection.provider.rawValue)), ("model", .string(job.connection.provider == .apple ? "" : job.connection.model)),
                    ("screenshots", try JSONText.parse(JSONEncoder().encode(shots)))])
                break
            }
        }
        let selected = cardID.flatMap { id in set.cards.first { $0.id == id } }
        if source == nil {
            let shots = (selected.map { [$0] } ?? set.cards).compactMap(\.screenshot)
            source = .object([("name", .string(String(set.name.prefix(65)) + " Variant")), ("brief", .string((selected.map { [$0] } ?? set.cards).map { $0.title + ". " + $0.subtitle }.joined(separator: "\n"))),
                ("language", .string(set.language ?? "en-US")), ("target", .string(MediaCards.targets.first { $0.type == set.displayType && $0.width == set.width && $0.height == set.height }?.id ?? MediaCards.defaultTarget.id)), ("provider", .string(try aiSetupPreferences().defaultProvider.rawValue)),
                ("screenshots", try JSONText.parse(JSONEncoder().encode(shots))), ("sourceNote", .string("Original AI instructions are unavailable. This draft starts from the selected card's text and screenshot."))])
        } else if let selected, let shot = selected.screenshot {
            var selectedBrief = ""
            if let current = source, let payload = current["screenshots"], let originals = try? JSONDecoder().decode([MediaCard.Screenshot].self, from: payload.data) {
                let exact: Int? = if case .number(let raw)? = current["cardSourceIndices"]?[selected.id] { Int(exactly: raw) } else { nil }
                let index = exact.flatMap { originals.indices.contains($0) && originals[$0] == shot ? $0 : nil } ?? originals.firstIndex(of: shot)
                if let index, let briefs = try? AICards.cardBriefs(in: current, count: originals.count) {
                    // Filter by the original source index, rather than the model's reordered result position.
                    selectedBrief = briefs[index]
                }
            }
            source = source?.setting("cardBriefs", .array([.string(selectedBrief)]))
                .setting("screenshots", try JSONText.parse(JSONEncoder().encode([shot])))
        }
        if let selected {
            source = source?.setting("previousCard", .object([("title", .string(selected.title)), ("subtitle", .string(selected.subtitle)),
                ("layout", .string(selected.layout.rawValue)), ("backgroundColor", .string(selected.style.color)), ("secondColor", .string(selected.style.secondColor))]))
        }
        return (source ?? .null).setting("variationID", .null)
    }

    /// Reopening the same result preserves any edits already saved to its deterministic card-set ID.
    public func saveProposedAICards(accountId: String, appId: String, set: MediaCardSet) throws -> SavedMediaCardSet {
        if let existing = try mediaCardSets(accountId: accountId, appId: appId).first(where: { $0.set.id == set.id }) { return existing }
        do { return .init(revision: try saveMediaCardSet(accountId: accountId, appId: appId, set: set, expected: 0), set: set) }
        catch MediaCardFailure.stale {
            guard let existing = try mediaCardSets(accountId: accountId, appId: appId).first(where: { $0.set.id == set.id }) else { throw MediaCardFailure.stale }
            return existing
        }
    }
}
