import Foundation

/// Native translation starts with complete fields; only a context error can split a field.
struct LocalTranslationPlan: Sendable {
    struct Fragment: Sendable {
        let text, separator: String
        let maximum: Int
    }
    struct Segment: Sendable {
        let field: String?
        let prefix: String
        let fragments: [Fragment]
    }
    let segments: [Segment]
    let instructions: String

    init(_ request: AIRequest) throws {
        guard request.purpose == "translation", case .array(let values) = try JSONText.parse(Data(request.input.utf8)), !values.isEmpty else { throw AIFailure.configuration }
        let texts = try values.map { value -> String in
            guard let text = value.text, !TextSemantics.trim(text).isEmpty, text.utf16.count <= TextDrafts.storedLimit else { throw AIFailure.configuration }
            return text
        }
        if let fields = request.translationFields, fields.count != texts.count { throw AIFailure.configuration }
        let groups = try TranslationBudget.groups(request, count: texts.count)
        if let keywords = groups.first(where: { $0.field == "keywords" }), keywords.indices.count * 2 - 1 > keywords.maximum { throw AIFailure.translationLength }
        segments = try texts.indices.map { index in
            let field = request.translationFields?[index], prefix = String(texts[index].prefix(while: \.isWhitespace))
            // The validated field fits the storage limit, so its first attempt is one complete input.
            let chunks = try Self.chunks(String(texts[index].dropFirst(prefix.count)), maximum: TextDrafts.storedLimit)
            let maximum = field.map(AIRequest.limit) ?? TextDrafts.storedLimit
            let group = groups.first { $0.indices.contains(index) }
            let separators = chunks.reduce(Self.used(prefix, field: field)) { $0 + Self.used($1.separator, field: field) }
            let available = max(1, maximum - separators - (field == "keywords" ? (group?.indices.count ?? 1) - 1 : 0))
            let weight = field == "keywords" ? max(1, group?.indices.reduce(0) { $0 + Self.used(texts[$1], field: field) } ?? 1)
                : max(1, chunks.reduce(0) { $0 + Self.used($1.text, field: field) })
            // These are wording guides, not per-fragment quotas. Only the complete field must fit.
            return Segment(field: field, prefix: prefix, fragments: chunks.map {
                .init(text: $0.text, separator: $0.separator, maximum: max(1, min(max(32, Self.used($0.text, field: field) * 2), available * Self.used($0.text, field: field) / weight * 95 / 100)))
            })
        }
        instructions = String(request.instructions.split(separator: "\n", maxSplits: 1).first ?? "").replacingOccurrences(of: "Return JSON only.", with: "")
            + "\nTranslate only the supplied text field or explicitly requested part. Return its translation in the native text property. Do not add explanations or combine inputs."
    }

    static func used(_ text: String, field: String?) -> Int { TranslationBudget.used(text, field: field) }
    static func chunks(_ text: String, maximum: Int) throws -> [(text: String, separator: String)] {
        let characters = Array(text)
        var start = 0, result: [(String, String)] = []
        while start < characters.count {
            var end = start, count = 0
            while end < characters.count, count + String(characters[end]).utf16.count <= maximum { count += String(characters[end]).utf16.count; end += 1 }
            guard end > start else { throw AIFailure.tooLarge }
            if end < characters.count, let space = (start..<end).last(where: { characters[$0].isWhitespace }), space > start { end = space }
            while end > start, characters[end - 1].isWhitespace { end -= 1 }
            var separator = end
            while separator < characters.count, characters[separator].isWhitespace { separator += 1 }
            result.append((String(characters[start..<end]), String(characters[end..<separator])))
            start = separator
        }
        return result
    }
}

extension AppleLocalAI {
    /// The supplied responder is the only model boundary; isolated tests use synthetic responses.
    static func translate(_ request: AIRequest, respond: @Sendable (_ instructions: String, _ text: String) async throws -> String) async throws -> JSONText {
        let plan = try LocalTranslationPlan(request)
        let groups = try TranslationBudget.groups(request, count: plan.segments.count)
        var parts: [[String]] = []
        for segment in plan.segments {
            var translated: [String] = []
            for fragment in segment.fragments {
                let unit = TranslationBudget(field: segment.field, indices: [], maximum: fragment.maximum).unit
                let maximum = segment.field.map(AIRequest.limit) ?? TextDrafts.storedLimit
                let instruction = plan.instructions + "\nThe complete \(segment.field ?? "text field") has a hard maximum of \(maximum) \(unit)."
                    + (segment.field == "keywords" ? " All keyword terms share that maximum, including comma separators." : "")
                    + " Aim for at most \(fragment.maximum) \(unit) for this fragment."
                    + (segment.field == "keywords" ? " Translate one keyword term; do not add commas." : "")
                let value = try await localFragment(fragment.text, instructions: instruction, respond: respond)
                guard !value.isEmpty, TextSemantics.validControlText(value), segment.field != "keywords" || !value.contains(",") else { throw AIFailure.response }
                translated.append(value)
            }
            parts.append(translated)
        }
        func assemble(_ parts: [[String]]) -> [String] {
            plan.segments.indices.map { index in
                plan.segments[index].prefix + zip(parts[index], plan.segments[index].fragments).map { $0.0 + $0.1.separator }.joined()
            }
        }
        var translations = assemble(parts)
        for round in 0..<TranslationFitting.repairRounds {
            let overflowing = groups.filter { $0.used(translations) > $0.maximum }
            if overflowing.isEmpty { break }
            for group in overflowing {
                // Larger fragments can give their spare room to the rest of the field or keyword list.
                let candidates = group.indices.flatMap { segment in parts[segment].indices.map { (segment, $0) } }
                    .sorted { TranslationBudget.used(parts[$0.0][$0.1], field: group.field) > TranslationBudget.used(parts[$1.0][$1.1], field: group.field) }
                for (segment, fragment) in candidates {
                    let observed = group.used(translations)
                    if observed <= group.maximum { break }
                    let current = parts[segment][fragment], used = TranslationBudget.used(current, field: group.field)
                    let target = max(1, used - max(1, min(observed - group.maximum + round, max(1, used / 3))))
                    let instruction = "Rewrite this translated fragment in \(request.language ?? "the same language"). \(TranslationFitting.preservation) Return only its rewritten text in the native text property."
                        + "\nThe complete \(group.title) uses \(observed) of \(group.maximum) \(group.unit). This fragment uses \(used); aim for at most \(target) \(group.unit)."
                        + (group.field == "keywords" ? " Keep this one keyword term separate; do not add commas." : "")
                    let value: String
                    do { value = try await localFragment(current, instructions: instruction, respond: respond) }
                    catch AIFailure.response { continue }
                    guard !value.isEmpty, TextSemantics.validControlText(value), group.field != "keywords" || !value.contains(",") else { continue }
                    if TranslationBudget.used(value, field: group.field) < used {
                        parts[segment][fragment] = value; translations = assemble(parts)
                    }
                }
            }
        }
        try Task.checkCancellation()
        if let group = groups.first(where: { $0.used(translations) > $0.maximum }) { throw group.failure(translations) }
        let result = JSONText.object([("translations", .array(translations.map(JSONText.string)))])
        try request.validateTranslations(result, count: translations.count)
        return result
    }

    /// A fresh native session can retry a smaller source only when the local context window is exceeded.
    private static func localFragment(_ text: String, instructions: String, depth: Int = 0,
                                      respond: @Sendable (String, String) async throws -> String) async throws -> String {
        try Task.checkCancellation()
        do {
            let result = try await respond(instructions, text)
            try Task.checkCancellation()
            return TextSemantics.trim(result)
        } catch AIFailure.tooLarge {
            guard depth < 3, text.utf16.count > 128 else { throw AIFailure.tooLarge }
            let prefix = String(text.prefix(while: \.isWhitespace))
            let chunks = try LocalTranslationPlan.chunks(String(text.dropFirst(prefix.count)), maximum: text.utf16.count / 2)
            guard chunks.count > 1 else { throw AIFailure.tooLarge }
            var result = prefix
            for chunk in chunks {
                result += try await localFragment(chunk.text, instructions: instructions, depth: depth + 1, respond: respond) + chunk.separator
            }
            return result
        }
    }
}
