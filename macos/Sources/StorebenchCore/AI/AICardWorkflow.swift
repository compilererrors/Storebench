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
            images.append(try await AICards.image(bytes, recognizeText: provider == .apple))
        }
        let request = try AICards.request(brief: brief, language: language, target: target, images: images)
        let result = try await runAIJob(accountId: accountId, appId: appId, provider: provider, request: request, model: model)
        try Task.checkCancellation()
        guard try localEditorDraft(scope) == saved else { throw AIFailure.changed }
        return try AICards.cardSet(result, screenshots: shots, name: name, language: language, target: target)
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
