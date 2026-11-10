import Foundation
import Testing
@testable import StorebenchCore

extension AITests {
    @Test func perScreenshotInstructionsAndChosenColorsSurviveReorderingAndRecreation() async throws {
        let (session, root, _, _) = try await connected(); defer { try? FileManager.default.removeItem(at: root) }
        let f = try AIWorkflowFixture(), (draft, _, shots) = try await f.composer(session, provider: .openai)
        let briefs = ["Explain synthetic country pricing.", "Explain synthetic daily reports."]
        var palette = AICardPalette(); palette.fill = .solid; palette.color = "#224466"; palette.textColor = "#FFFFEE"
        // The same original can have two different messages. Source identity cannot rely on its hash alone.
        let input = draft.value.setting("screenshots", try JSONText.parse(JSONEncoder().encode([shots[0], shots[0]])))
            .setting("cardBriefs", .array(briefs.map(JSONText.string))).setting("cardPalette", palette.value)
        let saved = try await session.saveLocalEditorDraft(input, scope: f.scope, expected: draft.revision)
        let response = f.response(f.cards, provider: .openai)
        StubProtocol.handle("api.openai.com") { _ in (200, [:], response) }
        let proposal = try await session.proposeAICards(accountId: f.account, appId: f.app, expected: saved.revision)
        _ = try await session.saveProposedAICards(accountId: f.account, appId: f.app, set: proposal)
        #expect(proposal.cards.first?.title == "See Your Listing History")
        for card in proposal.cards {
            #expect(card.style.fill == .solid && card.style.color == palette.color && card.style.titleColor == palette.textColor)
            #expect(card.style.subtitleColor == palette.textColor)
        }
        let entry = try #require(try await session.aiHistory(accountId: f.account, appId: f.app).first)
        let job = try await session.aiHistoryJob(accountId: f.account, appId: f.app, id: entry.id)
        let sent = try JSONText.parse(Data(job.request.input.utf8))
        #expect(sent["cardInstructions"] == .array(briefs.enumerated().map { .object([("screenshotIndex", .number(Double($0.offset))), ("instructions", .string($0.element))]) }))
        #expect(sent["palette"] == palette.value && job.request.cardDraft?["cardBriefs"] == input["cardBriefs"])
        #expect(AppleLocalAI.executionSnapshot(job.request).input.contains(briefs[1]))
        for (card, expected) in zip(proposal.cards, briefs.reversed()) {
            let restored = try await session.aiCardSource(accountId: f.account, appId: f.app, set: proposal, cardID: card.id)
            #expect(try AICards.cardBriefs(in: restored, count: 1) == [expected] && restored["cardPalette"] == palette.value)
        }
        let exported = String(decoding: try JSONEncoder().encode(proposal), as: UTF8.self)
        #expect(!briefs.contains { exported.contains($0) })
    }
    @Test func requestHistoryRetainsEveryAttemptAndSurvivesReopening() async throws {
        let (session, root, writer, _) = try await connected(); defer { try? FileManager.default.removeItem(at: root) }
        let f = try AIWorkflowFixture(), (draft, _, _) = try await f.composer(session, provider: .openai)
        StubProtocol.handle("api.openai.com") { _ in (429, [:], Data()) }
        await #expect(throws: AIFailure.quota) { try await session.proposeAICards(accountId: f.account, appId: f.app, expected: draft.revision) }
        let first = try #require(try await session.aiHistory(accountId: f.account, appId: f.app).first)
        #expect(first.state == .failed && first.imageCount == 2)
        #expect(StubProtocol.requests("api.openai.com").count == 1)
        let failure = try await session.aiHistoryJob(accountId: f.account, appId: f.app, id: first.id)
        #expect(failure.failure == .quota && failure.startedAt != nil && failure.finishedAt != nil)
        let response = f.response(f.cards, provider: .openai)
        StubProtocol.handle("api.openai.com") { _ in (200, [:], response) }
        _ = try await session.proposeAICards(accountId: f.account, appId: f.app, expected: draft.revision)
        _ = try await session.proposeAICards(accountId: f.account, appId: f.app, expected: draft.revision)
        let rows = try await session.aiHistory(accountId: f.account, appId: f.app)
        #expect(rows.count == 2 && rows.first?.state == .complete && StubProtocol.requests("api.openai.com").count == 1)
        #expect(try await session.aiHistoryJob(accountId: f.account, appId: f.app, id: first.id).failure == .quota)
        let completed = try await session.aiHistoryJob(accountId: f.account, appId: f.app, id: rows[0].id)
        #expect(completed.request.cardDraft == draft.value && completed.execution?.instructions == completed.request.instructions)
        #expect(completed.execution?.input == completed.request.input && completed.result == f.cards)
        #expect(!String(decoding: try JSONEncoder().encode(rows), as: UTF8.self).contains("synthetic-ai-key"))
        await #expect(throws: RevisionHistoryFailure.invalid) { try await session.aiHistory(accountId: f.account, appId: "1999999999") }
        await #expect(throws: AIFailure.configuration) { try await session.aiHistoryJob(accountId: f.account, appId: f.app, id: "another-account:1000000001:attempt") }
        try await session.signOut()
        let reopened = try WorkspaceSession(workspace: Workspace(root: root), vault: writer.read())
        #expect(try await reopened.aiHistory(accountId: f.account, appId: f.app).map(\.id) == rows.map(\.id))
        #expect(try await reopened.aiHistoryJob(accountId: f.account, appId: f.app, id: rows[0].id).request.images == completed.request.images)
        try await reopened.signOut()
    }

    @Test func legacyHistoryIsIndexedOnceAndRetainedWhenTheSameRequestRetries() async throws {
        let (session, root, _, _) = try await connected(); defer { try? FileManager.default.removeItem(at: root) }
        let f = try AIWorkflowFixture()
        let request = try AIRequest.translation(["Synthetic old input"], source: "en-US", target: "sv")
        StubProtocol.handle("api.openai.com") { _ in (429, [:], Data()) }
        await #expect(throws: AIFailure.quota) { try await session.runAIJob(accountId: f.account, appId: f.app, provider: .openai, request: request) }
        var job = try #require(try await session.aiJobs(accountId: f.account, appId: f.app).first)
        job.attemptID = nil; job.execution = nil; job.startedAt = nil; job.finishedAt = nil
        try await session.storeAccess { store in
            let keys = try store.keys(namespace: "ai_history")
            try store.transaction { _ in
                [.put(namespace: "ai_jobs", key: job.id, json: try JSONEncoder().encode(job))] + keys.flatMap { [.delete(namespace: "ai_history", key: $0), .delete(namespace: "ai_history_index", key: $0)] }
            }
        }
        let first = try await session.aiHistory(accountId: f.account, appId: f.app)
        #expect(first.count == 1 && first[0].state == .failed)
        #expect(try await session.aiHistory(accountId: f.account, appId: f.app).map(\.id) == first.map(\.id))
        let restored = try await session.aiHistoryJob(accountId: f.account, appId: f.app, id: first[0].id)
        #expect(restored.execution == nil && restored.request == request && restored.failure == .quota)
        let response = JSONText.object([("status", .string("completed")), ("output", .array([.object([("type", .string("message")), ("content", .array([.object([("type", .string("output_text")), ("text", .string("{\"translations\":[\"Synthetic result\"]}"))])]))])]))]).data
        StubProtocol.handle("api.openai.com") { _ in (200, [:], response) }
        _ = try await session.runAIJob(accountId: f.account, appId: f.app, provider: .openai, request: request)
        #expect(try await session.aiHistory(accountId: f.account, appId: f.app).count == 2)
        #expect(try await session.aiHistoryJob(accountId: f.account, appId: f.app, id: first[0].id).failure == .quota)

    }

    @Test func explicitCardVariantsKeepEarlierSetsAndRestoreTheirExactBrief() async throws {
        let (session, root, _, _) = try await connected(); defer { try? FileManager.default.removeItem(at: root) }
        let f = try AIWorkflowFixture(), (draft, _, shots) = try await f.composer(session, provider: .openai)
        let response = f.response(f.cards, provider: .openai)
        StubProtocol.handle("api.openai.com") { _ in (200, [:], response) }
        let firstInput = draft.value.setting("variationID", .string(UUID().uuidString.lowercased())).setting("directions", .array([.string("modern"), .string("featureSpecific")]))
        let firstDraft = try await session.saveLocalEditorDraft(firstInput, scope: f.scope, expected: draft.revision)
        let first = try await session.proposeAICards(accountId: f.account, appId: f.app, expected: firstDraft.revision)
        let saved = try await session.saveProposedAICards(accountId: f.account, appId: f.app, set: first)
        let source = try await session.aiCardSource(accountId: f.account, appId: f.app, set: first, cardID: first.cards[0].id)
        #expect(source["previousCard"]?["title"] == .string(first.cards[0].title))
        #expect(source["brief"] == firstInput["brief"] && source["directions"] == firstInput["directions"] && source["variationID"] == .null)
        #expect(try JSONDecoder().decode([MediaCard.Screenshot].self, from: #require(source["screenshots"]).data) == [shots[1]])
        let nextInput = firstInput.setting("variationID", .string(UUID().uuidString.lowercased()))
        let secondDraft = try await session.saveLocalEditorDraft(nextInput, scope: f.scope, expected: firstDraft.revision)
        let second = try await session.proposeAICards(accountId: f.account, appId: f.app, expected: secondDraft.revision)
        _ = try await session.saveProposedAICards(accountId: f.account, appId: f.app, set: second)
        #expect(second.id != first.id && second.cards.map(\.title) == first.cards.map(\.title))
        #expect(StubProtocol.requests("api.openai.com").count == 2)
        #expect(try await session.mediaCardSets(accountId: f.account, appId: f.app).first { $0.set.id == first.id } == saved)
        #expect(try await session.aiHistory(accountId: f.account, appId: f.app).count == 2)
        let exported = String(decoding: try JSONEncoder().encode(second), as: UTF8.self)
        #expect(!exported.contains("brief") && !exported.contains("directions") && !exported.contains("variationID"))
    }
    @Test func customPromptIsPersistedInHistoryAndRestoredForRecreation() async throws {
        let (session, root, writer, _) = try await connected(); defer { try? FileManager.default.removeItem(at: root) }
        let f = try AIWorkflowFixture(), (draft, _, _) = try await f.composer(session, provider: .openai)
        let custom = "Use an understated synthetic poster style with specific, confident headlines."
        let value = draft.value.setting("customInstructions", .string(custom))
        let saved = try await session.saveLocalEditorDraft(value, scope: f.scope, expected: draft.revision)
        let response = f.response(f.cards, provider: .openai)
        StubProtocol.handle("api.openai.com") { request in
            do {
                let body = try JSONText.parse(StubProtocol.body(request))
                #expect(body["instructions"]?.text?.hasPrefix(custom) == true)
                #expect(body["instructions"]?.text?.contains(AICardDirection.modern.instruction) == true)
            } catch { Issue.record("The submitted request must contain the custom prompt") }
            return (200, [:], response)
        }
        let proposal = try await session.proposeAICards(accountId: f.account, appId: f.app, expected: saved.revision)
        _ = try await session.saveProposedAICards(accountId: f.account, appId: f.app, set: proposal)
        let entry = try #require(try await session.aiHistory(accountId: f.account, appId: f.app).first)
        let job = try await session.aiHistoryJob(accountId: f.account, appId: f.app, id: entry.id)
        #expect(job.request.cardDraft?["customInstructions"] == .string(custom) && job.execution?.instructions.hasPrefix(custom) == true)
        try await session.signOut()
        let reopened = try WorkspaceSession(workspace: Workspace(root: root), vault: writer.read())
        let source = try await reopened.aiCardSource(accountId: f.account, appId: f.app, set: proposal, cardID: proposal.cards[0].id)
        #expect(source["customInstructions"] == .string(custom) && source["brief"] == value["brief"])
        #expect(try await reopened.localEditorDraft(f.scope)?.value["customInstructions"] == .string(custom))
        try await reopened.signOut()
    }

}

struct AICardDirectionTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func optionalCardGuidanceAcceptsOldDraftsAndRejectsInvalidSources() throws {
        #expect(try AICards.cardBriefs(in: .object([]), count: 2) == ["", ""])
        #expect(try AICards.cardBriefs(in: .object([("cardBriefs", .array([.string(""), .string("Synthetic reports")]))]), count: 2) == ["", "Synthetic reports"])
        for value in [JSONText.array([]), .array([.number(1)]), .array([.string(String(repeating: "a", count: 601))]), .array([.string("Synthetic\u{0000}text")])] {
            #expect(throws: AIFailure.configuration) { try AICards.cardBriefs(in: .object([("cardBriefs", value)]), count: 1) }
        }
        #expect(try AICardPalette.read(nil) == nil)
        #expect(throws: AIFailure.configuration) { try AICardPalette.read(AICardPalette().value.setting("color", .string("invalid"))) }
        let request = AIRequest(purpose: "cards", instructions: "Synthetic", input: "{}", schema: .null, images: [AIImage(data: Data([1]))], cardDraft: .object([("cardBriefs", .array([]))]))
        #expect(throws: AIFailure.configuration) { try request.validate() }
    }
    @Test func nativeAndRemotePromptsUseTheSameSelectedDirectionsAndPreserveImageContext() throws {
        let image = AIImage(data: Data([1]), text: "Synthetic pricing chart")
        let request = try AICards.request(brief: "Explain the visible synthetic chart.", language: "en-US", target: MediaCards.defaultTarget, images: [image], directions: [.modern, .featureSpecific])
        let native = AppleLocalAI.executionSnapshot(request)
        #expect(native.instructions.contains(AICardDirection.modern.instruction) && request.instructions.contains(AICardDirection.modern.instruction))
        #expect(!native.instructions.contains(AICardDirection.exploreStyle.instruction) && !request.instructions.contains(AICardDirection.exploreStyle.instruction))
        #expect(native.input.contains(image.text) && native.input.contains(request.input))
        #expect(!AppleLocalAI.allowsCropping(request))
        let cropped = try AICards.request(brief: "Synthetic chart", language: "en-US", target: MediaCards.defaultTarget, images: [image], directions: [.allowCropping])
        #expect(AppleLocalAI.allowsCropping(cropped))
        #expect(throws: AIFailure.configuration) { try AICardDirection.selected(in: .object([("directions", .array([.string("unknown")]))])) }
    }
    @Test func customPromptReachesRemoteAndNativeModelsWithoutReplacingSelectedDirections() throws {
        let custom = "Use a crisp editorial style and explain the visible synthetic pricing chart.", directions: [AICardDirection] = [.modern, .featureSpecific]
        let request = try AICards.request(brief: "A synthetic chart.", language: "sv", target: MediaCards.defaultTarget, images: [AIImage(data: Data([1]), text: "Synthetic chart")], directions: directions, customInstructions: custom)
        try request.validate()
        let native = AppleLocalAI.executionSnapshot(request)
        for text in [request.instructions, native.instructions] {
            #expect(text.hasPrefix(custom) && !text.contains(AICards.defaultInstructions))
            #expect(text.contains(AICardDirection.modern.instruction) && text.contains(AICardDirection.featureSpecific.instruction))
            #expect(text.contains("plain text in sv") && text.contains("60 characters"))
        }
        #expect(request.cardDraft?["customInstructions"] == .string(custom))
        #expect(native.instructions.contains("RGB object") && request.instructions.contains("#RRGGBB"))
        #expect(request.schema["properties"]?["cards"] != nil)
        let reset = try AICards.request(brief: "A synthetic chart.", language: "sv", target: MediaCards.defaultTarget, images: request.images, directions: directions)
        #expect(reset.instructions.hasPrefix(AICards.defaultInstructions) && reset.instructions.contains(AICardDirection.modern.instruction))
    }
    @Test func invalidCustomPromptsFailBeforeDispatch() throws {
        for value in [" \n", String(repeating: "x", count: AICards.customInstructionsLimit + 1), "Synthetic\u{0000}instructions"] {
            #expect(throws: AIFailure.configuration) {
                try AICards.request(brief: "Synthetic chart", language: "en-US", target: MediaCards.defaultTarget, images: [AIImage(data: Data([1]))], customInstructions: value)
            }
            let request = AIRequest(purpose: "cards", instructions: "Synthetic", input: "{}", schema: .null, cardDraft: .object([("customInstructions", .string(value))]))
            #expect(throws: AIFailure.configuration) { try request.validate() }
        }
        #expect(throws: AIFailure.configuration) { try AICards.customInstructions(in: .object([("customInstructions", .number(1))])) }
        #expect(try AICards.customInstructions(in: .object([("customInstructions", .null)])) == nil)
    }
    @Test func screenshotTextKeepsTheMainFeatureWhenNavigationWouldFillTheBudget() {
        let navigation = Array(repeating: (text: "Synthetic navigation item", bounds: CGRect(x: 0.02, y: 0.5, width: 0.12, height: 0.015)), count: 50)
        let content = [(text: "Compare country prices", bounds: CGRect(x: 0.28, y: 0.8, width: 0.4, height: 0.02)),
                       (text: "Synthetic pricing chart details", bounds: CGRect(x: 0.28, y: 0.6, width: 0.4, height: 0.02))]
        let context = AICards.screenshotText(navigation + content, limit: 600)
        #expect(context.hasPrefix("Compare country prices\nSynthetic pricing chart details"))
        #expect(context.contains("Synthetic navigation item") && context.count <= 600)
        let fullWidthTitle = (text: "Synthetic full-width heading", bounds: CGRect(x: 0.02, y: 0.9, width: 0.8, height: 0.02))
        #expect(AICards.screenshotText(navigation + [fullWidthTitle], limit: 100).hasPrefix(fullWidthTitle.text))
    }
    @Test func generatedLandscapeCardsShowMoreOriginalPixelsWithSmallerCornerLoss() throws {
        let fixture = try AIWorkflowFixture()
        let target = try #require(MediaCards.targets.first { $0.width == 2880 && $0.height == 1800 })
        let shots = (0..<2).map { MediaCard.Screenshot(hash: String(repeating: $0 == 0 ? "a" : "b", count: 64), name: "Synthetic Screen", width: 3200, height: 2014) }
        guard case .array(let rows)? = fixture.cards["cards"] else { throw AIFailure.response }
        let response = JSONText.object([("cards", .array(rows.map { $0.setting("layout", .string("focus")) }))])
        let generated = try AICards.cardSet(response, screenshots: shots, name: "Synthetic Cards", language: "en-US", target: target)
        for card in generated.cards {
            var previous = card; previous.layout = .textAbove; previous.style = .init()
            let before = try #require(MediaCards.placement(previous, width: target.width, height: target.height).screen)
            let placement = MediaCards.placement(card, width: target.width, height: target.height), screen = try #require(placement.screen)
            #expect(card.layout == .textAbove && screen.width > before.width * 1.15)
            #expect(abs(screen.width / screen.height - 3200.0 / 2014) < 0.001 && placement.radius < screen.width * 0.02)
            #expect(screen.left >= 0 && screen.top >= 0 && screen.left + screen.width <= Double(target.width) && screen.top + screen.height <= Double(target.height))
        }
        #expect(try AICards.cardSet(response, screenshots: shots, name: "Synthetic Cropping", language: "en-US", target: target, directions: [.allowCropping]).cards.allSatisfy { $0.layout == .focus })
    }
}
