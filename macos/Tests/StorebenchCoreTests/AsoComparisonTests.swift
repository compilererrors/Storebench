import Foundation
import Testing
@testable import StorebenchCore

@Suite struct AsoComparisonTests {
    init() throws { _ = try TestIsolation.require() }
    func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/aso-comparison.json"))) }
    func items(_ value: JSONText?) throws -> [JSONText] { guard case .array(let values)? = value else { throw AsoOutcome.Failure.malformed }; return values }
    func integer(_ value: JSONText?) throws -> Int { guard case .number(let number)? = value, number.isFinite, number.rounded() == number else { throw AsoOutcome.Failure.malformed }; return Int(number) }
    func snapshots(_ value: JSONText) throws -> [AsoSnapshot] { try JSONDecoder().decode([AsoSnapshot].self, from: value["snapshots"]!.data) }
    func reports(_ value: JSONText) throws -> ([AnalyticsPeriod], [SalesPresentation.Period]) {
        let decoder = JSONDecoder(), analytics = try decoder.decode([AnalyticsPeriod].self, from: value["analytics"]!.data)
        let records = try decoder.decode([SalesRecord].self, from: value["records"]!.data)
        return (analytics, try records.flatMap { try SalesPresentation.prepare([$0], accountId: "synthetic-account", appId: "1000000001") })
    }
    @Test func literalChangesWhitespaceAndCreationProvenanceMatchPrimarySnapshotsAndJournalBases() throws {
        let histories = try items(fixture()["histories"]); #expect(histories.count >= 20)
        for vector in histories {
            let revisions = try JSONDecoder().decode([Revision].self, from: vector["revisions"]!.data), generated = AsoComparison.snapshots(revisions)
            let journal = try WorkspaceSession.journalEvents(accountId: "synthetic-account", appId: "1000000001", revisions: revisions, drafts: [], plan: nil, reviews: [])
            #expect(JSONText.array(AsoComparison.statisticsEvents(journal, snapshots: generated).map { .string($0.id) }).data == vector["statisticsEvents"]?.data)

            #expect(JSONText.array(generated.map(\.json)).data == vector["snapshots"]?.data, "Synthetic history: \(vector["id"]!.text!)")
            if revisions.count > 1 {
                let changes = ASO.diff(ASO.entries(revisions[1]), ASO.entries(revisions[0]))
                let json = JSONText.array(changes.map { .object([("section", .string($0.section)), ("field", .string($0.field)), ("before", .string($0.before)), ("after", .string($0.after))]) })
                #expect(json.data == vector["diff"]?.data)
            }
            let events = try WorkspaceSession.journalEvents(accountId: "synthetic-account", appId: "1000000001", revisions: revisions, drafts: [], plan: nil, reviews: [])
            let json = JSONText.array(events.map { .object([("id", .string($0.id)), ("basis", .string($0.basis)), ("changes", .array($0.changes.map(\.json)))]) })
            #expect(json.data == vector["events"]?.data, "Synthetic journal: \(vector["id"]!.text!)")
        }
    }
    @Test func pairSelectionFullValuesFieldOrderingAndBaselinesMatchPrimary() throws {
        let input = try fixture(), histories = try items(input["histories"]), vectors = try items(input["fieldVectors"])
        #expect(vectors.count >= 80)
        for vector in vectors {
            let history = try #require(histories.first { $0["id"] == vector["history"] }), saved = try snapshots(history), pair = AsoComparison.initialPair(saved)
            let left = saved.first { $0.id == pair.leftId }, right = saved.first { $0.id == pair.rightId }, primary = vector["primary"]!.text!
            #expect(pair.json.data == vector["pair"]?.data)
            #expect(JSONText.array(AsoComparison.fields(left, right, primary: primary).map(\.json)).data == vector["fields"]?.data)
            #expect(JSONText.array(AsoComparison.fields(nil, right, primary: primary).map(\.json)).data == vector["baseline"]?.data)
            if let left, let right { #expect(JSONText.bool(AsoComparison.sameState(left, right)) == vector["same"]) }
            for choice in try items(vector["choices"]) { #expect(AsoComparison.choose(pair, side: choice["side"]!.text!, id: choice["id"]!.text!).json.data == choice["pair"]?.data) }
        }
    }
    @Test func completeAndMissingWindowsReportPrecedenceAndGraphGapsMatchPrimary() throws {
        let input = try fixture(), histories = try items(input["histories"]), ordinary = try #require(histories.first { $0["id"] == .string("ordinary") }), saved = try snapshots(ordinary), selections = try items(input["selections"])
        #expect(selections.count >= 200)
        for vector in selections {
            let (analytics, sales) = try reports(vector), days = try integer(vector["days"])
            let initialDays = try integer(vector["initialDays"]), paths = try integer(vector["paths"]), isolated = try integer(vector["isolated"])
            let activity = AsoComparison.activity(leftDate: vector["leftDate"]!.text!, rightDate: vector["rightDate"]!.text!, days: days, analytics: analytics, sales: sales)
            #expect(JSONText.array(activity.map(\.json)).data == vector["activity"]?.data, "Synthetic windows: \(vector["id"]!.text!) / \(days)")
            #expect(AsoComparison.initialDays(saved.first, saved.last, analytics: analytics, sales: sales) == initialDays)
            #expect(AsoComparison.graphMetric(analytics: analytics, sales: sales) == vector["graphMetric"]?.text)
            let points = AsoOutcome.metrics.map { AsoComparison.points($0.key, analytics: analytics, sales: sales) }
            let json = JSONText.array(points.map { .array($0.map { .object([("date", .string($0.date)), ("value", .number($0.value))]) }) })
            #expect(json.data == vector["points"]?.data)
            let runs = AsoComparison.runs(points[1])
            #expect(runs.filter { $0.count >= 2 }.count == paths)
            #expect(runs.filter { $0.count == 1 }.count == isolated)
        }
    }
    @Test func exactWordAndListChangesPreserveUnicodeAndStoredWhitespaceRules() throws {
        for vector in try items(fixture()["textVectors"]) {
            let before = vector["before"]!.text!, after = vector["after"]!.text!, segments = AsoProgress.wordDiff(before, after), list = AsoProgress.listChange(before, after)
            #expect(JSONText.array(segments.map { .object([("kind", .string($0.kind.rawValue)), ("text", .string($0.text))]) }).data == vector["segments"]?.data)
            #expect(JSONText.object([("added", .array(list.added.map(JSONText.string))), ("removed", .array(list.removed.map(JSONText.string)))]).data == vector["list"]?.data)
        }
    }
}
