import Foundation
import Testing
@testable import StorebenchCore

@Suite struct TranslationFittingTests {
    init() throws { _ = try TestIsolation.require() }
    private static func result(_ texts: [String]) -> JSONText { .object([("translations", .array(texts.map(JSONText.string)))]) }
    private actor Probe {
        var requests: [AIRequest] = []
        func record(_ request: AIRequest) -> Int { requests.append(request); return requests.count }
    }

    @Test func initialPromptNamesEveryHardCharacterAndSharedByteLimit() throws {
        let fields = ["name", "subtitle", "description", "promotionalText", "whatsNew", "privacyPolicyText", "supportUrl", "keywords", "keywords"]
        let request = try AIRequest.translation(Array(repeating: "Synthetic copy", count: fields.count), source: "en-US", target: "sv", fields: fields)
        for (index, field) in fields.enumerated() where field != "keywords" {
            #expect(request.instructions.contains("Input \(index): \(field), hard maximum \(AIRequest.limit(field)) characters"))
        }
        #expect(request.instructions.contains("Keyword inputs 7, 8 share ONE maximum of 100 UTF-8 bytes"))
        #expect(request.instructions.contains("including one comma between terms"))
        #expect(request.instructions.contains("spaces, punctuation and line breaks"))
        #expect(request.instructions.contains("they are not token limits"))
    }

    @Test func anExpandingTranslationIsRewordedAtTheExactFieldBoundaryWithoutClipping() async throws {
        let request = try AIRequest.translation(["Synthetic description with {count} and https://example.test/help"], source: "en-US", target: "sv", fields: ["description"])
        let probe = Probe(), tooLong = String(repeating: "x", count: 4001), shortened = "Syntetisk beskrivning med {count} och https://example.test/help. Hela slutmeningen finns kvar."
        let value = try await TranslationFitting.generate(request) { input in
            if await probe.record(input) == 1 { return Self.result([tooLong]) }
            #expect(input.instructions.contains("uses 4001 characters; the hard limit is 4000"))
            return Self.result([shortened])
        }
        #expect(try AIRequest.translations(value, count: 1) == [shortened])
        #expect(await probe.requests.count == 2)
    }

    @Test func remoteModelGetsTheWholeListingAndOnlyTheOverflowingFieldIsReworded() async throws {
        let body = String(repeating: "Synthetic sentence with {count}. ", count: 100)
        let request = try AIRequest.translation([body, "Synthetic subtitle", "notes"], source: "en-US", target: "sv", fields: ["description", "subtitle", "keywords"])
        let probe = Probe(), tooLong = "Synthetic subtitle longer than thirty characters"
        let value = try await TranslationFitting.generate(request) { input in
            let count = await probe.record(input)
            if count == 1 {
                #expect(input == request, "The initial remote request must retain all fields and full context")
                return Self.result([body, tooLong, "anteckningar"])
            }
            let repair = try JSONText.parse(Data(input.input.utf8))
            #expect(repair["sourceTexts"] == .array([.string("Synthetic subtitle")]))
            #expect(repair["translations"] == .array([.string(tooLong)]))
            #expect(input.translationFields == ["subtitle"] && input.language == "sv")
            #expect(input.instructions.contains("do not truncate"))
            return Self.result(["Kort syntetisk text"])
        }
        #expect(try AIRequest.translations(value, count: 3) == [body, "Kort syntetisk text", "anteckningar"])
        #expect(await probe.requests.count == 2)
    }

    @Test func remoteKeywordRepairCountsCombinedUTF8BytesAndPreservesOtherFields() async throws {
        let request = try AIRequest.translation(["one", "two", "Synthetic description"], source: "en-US", target: "sv", fields: ["keywords", "keywords", "description"])
        #expect(request.instructions.contains("share ONE maximum of 100 UTF-8 bytes"))
        let probe = Probe(), initial = String(repeating: "å", count: 30)
        let value = try await TranslationFitting.generate(request) { input in
            let count = await probe.record(input)
            if count == 1 { return Self.result([initial, initial, "Syntetisk beskrivning"] ) }
            #expect(input.translationFields == ["keywords", "keywords"])
            #expect(input.instructions.contains("uses 121 UTF-8 bytes"))
            return Self.result([String(repeating: "å", count: 15), String(repeating: "ä", count: 30)])
        }
        #expect(try AIRequest.translations(value, count: 3) == [String(repeating: "å", count: 15), String(repeating: "ä", count: 30), "Syntetisk beskrivning"])
        #expect(await probe.requests.count == 2)
    }

    @Test func healthyRemoteListingNeedsExactlyOneRequest() async throws {
        let request = try AIRequest.translation(["Synthetic source"], source: "en-US", target: "sv", fields: ["description"]), probe = Probe()
        let value = try await TranslationFitting.generate(request) { input in
            _ = await probe.record(input); return Self.result(["Syntetisk text"])
        }
        #expect(value == Self.result(["Syntetisk text"]))
        #expect(await probe.requests.count == 1)
    }

    @Test func cardUTF16LimitsDoNotShortenHealthyListingUnicode() async throws {
        let request = try AIRequest.translation(["Synthetic body", "Synthetic title"], source: "en-US", target: "sv", fields: ["description", "card-title"])
        let emoji = String(repeating: "🙂", count: MediaCards.titleLimit / 2 + 1), probe = Probe()
        let value = try await TranslationFitting.generate(request) { input in
            if await probe.record(input) == 1 { return Self.result([emoji, emoji]) }
            #expect(input.translationFields == ["card-title"])
            #expect(input.instructions.contains("UTF-16 code units"))
            return Self.result(["Syntetisk titel"])
        }
        #expect(try AIRequest.translations(value, count: 2) == [emoji, "Syntetisk titel"])
    }

    @Test func repairIsBoundedAndNamesTheSpecificLimitWithoutExposingText() async throws {
        let request = try AIRequest.translation(["Synthetic subtitle"], source: "en-US", target: "sv", fields: ["subtitle"]), probe = Probe()
        do {
            _ = try await TranslationFitting.generate(request) { input in
                _ = await probe.record(input); return Self.result([String(repeating: "z", count: 31)])
            }
            Issue.record("An oversized translation cannot become a result")
        } catch let failure as TranslationLengthFailure {
            #expect(failure.field == "Subtitle" && failure.used == 31 && failure.maximum == 30)
            #expect(AIFailure.message(failure).contains("Subtitle still uses 31 of 30 characters"))
            #expect(!AIFailure.message(failure).contains("Synthetic"))
        }
        #expect(await probe.requests.count == 4)
    }

    @Test func malformedRepairIsRetriedWithoutReplacingValidFields() async throws {
        let request = try AIRequest.translation(["Synthetic subtitle", "Synthetic body"], source: "en-US", target: "sv", fields: ["subtitle", "description"]), probe = Probe()
        let value = try await TranslationFitting.generate(request) { input in
            switch await probe.record(input) {
            case 1: Self.result([String(repeating: "x", count: 31), "Beskrivning"])
            case 2: Self.result([])
            default: Self.result(["Kort text"])
            }
        }
        #expect(try AIRequest.translations(value, count: 2) == ["Kort text", "Beskrivning"])
        #expect(await probe.requests.count == 3)
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func emptyKeywordRepairsCannotSilentlyRemoveATerm(_ empty: String) async throws {
        let request = try AIRequest.translation(["one", "two"], source: "en-US", target: "sv", fields: ["keywords", "keywords"]), probe = Probe()
        let long = String(repeating: "å", count: 30)
        let value = try await TranslationFitting.generate(request) { input in
            switch await probe.record(input) {
            case 1: Self.result([long, long])
            case 2: Self.result([long, empty])
            default: Self.result(["syntetisk", "anteckning"])
            }
        }
        #expect(try AIRequest.translations(value, count: 2) == ["syntetisk", "anteckning"])
        #expect(await probe.requests.count == 3)
    }

    @Test(arguments: [AIFailure.quota, .credentials, .changed, .unavailable])
    func providerFailuresDuringRepairAreNeverRetriedOrChangedToLengthErrors(_ failure: AIFailure) async throws {
        let request = try AIRequest.translation(["Synthetic subtitle"], source: "en-US", target: "sv", fields: ["subtitle"]), probe = Probe()
        await #expect(throws: failure) {
            try await TranslationFitting.generate(request) { input in
                if await probe.record(input) == 1 { return Self.result([String(repeating: "x", count: 31)]) }
                throw failure
            }
        }
        #expect(await probe.requests.count == 2)
    }

    @Test func cancellationDuringRepairStopsImmediately() async throws {
        let request = try AIRequest.translation(["Synthetic subtitle"], source: "en-US", target: "sv", fields: ["subtitle"]), probe = Probe()
        await #expect(throws: CancellationError.self) {
            try await TranslationFitting.generate(request) { input in
                if await probe.record(input) == 1 { return Self.result([String(repeating: "x", count: 31)]) }
                throw CancellationError()
            }
        }
        #expect(await probe.requests.count == 2)
    }
}
