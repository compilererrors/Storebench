import Testing
@testable import StorebenchCore

@Suite struct SelectionOptionsTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func conditionalAndGeneratedOptionsKeepLabelsValuesAndAvailabilityTogether() {
        let options = makeOptions(includePlaceholder: true, values: [3, 1, 2])
        #expect(options.map(\.value) == [0, 3, -3, 1, -1, 2, -2])
        #expect(SelectionOption.title(for: -1, in: options) == "Synthetic reverse 1")
        #expect(options.first { $0.value == -1 }?.isEnabled == false)
        #expect(options.first { $0.value == -1 }?.detail == "Synthetic option detail")
        #expect(options.first { $0.value == 1 }?.isEnabled == true)
        #expect(makeOptions(includePlaceholder: false, values: []).isEmpty)
    }

    @Test func missingOrRemovedSelectionsNeverFallBackToAnotherOption() {
        let selected = 2
        let options = makeOptions(includePlaceholder: true, values: [1, 2])
        #expect(SelectionOption.title(for: selected, in: options) == "Synthetic forward 2")
        #expect(SelectionOption.title(for: selected, in: makeOptions(includePlaceholder: true, values: [1])) == nil)
        #expect(SelectionOption.title(for: selected, in: []) == nil)
    }

    @Test func fullUnicodeLabelsAndTypedEmptyValuesRemainAvailable() {
        let longTitle = String(repeating: "Synthetic language å漢字 · ", count: 200)
        let options: [SelectionOption<String?>] = [SelectionOption("Choose a language", value: nil), SelectionOption(longTitle, value: "synthetic-language")]
        #expect(SelectionOption.title(for: nil, in: options) == "Choose a language")
        #expect(SelectionOption.title(for: "synthetic-language", in: options) == longTitle)
        #expect(SelectionOption.title(for: "SYNTHETIC-LANGUAGE", in: options) == nil)
        let flags = selectionOptions([false, true]) { SelectionOption($0 ? "Enabled" : "Disabled", value: $0) }
        #expect(flags.map(\.value) == [false, true])
    }

    @Test func openMenuSnapshotsCannotSelectRemovedDisabledRelabelledOrAmbiguousValues() {
        let captured = SelectionOption("Synthetic option", value: 10).help("Synthetic detail")
        #expect(SelectionOption.resolve(captured, in: [captured]) == 10)
        #expect(SelectionOption.resolve(captured, in: []) == nil)
        #expect(SelectionOption.resolve(captured, in: [captured.disabled(true)]) == nil)
        #expect(SelectionOption.resolve(captured, in: [SelectionOption("Another synthetic option", value: 10)]) == nil)
        #expect(SelectionOption.resolve(captured, in: [captured, captured]) == nil)
        #expect(SelectionOption.resolve(captured.disabled(true), in: [captured]) == nil)
        let empty: SelectionOption<String?> = SelectionOption("All synthetic choices", value: nil)
        let value = SelectionOption.resolve(empty, in: [empty])
        #expect(value != nil)
        #expect(value! == nil)
    }

    @SelectionOptionsBuilder<Int> private func makeOptions(includePlaceholder: Bool, values: [Int]) -> [SelectionOption<Int>] {
        if includePlaceholder { SelectionOption("Choose a synthetic option", value: 0) }
        selectionOptions(values) { value in
            SelectionOption("Synthetic forward \(value)", value: value)
            SelectionOption("Synthetic reverse \(value)", value: -value).disabled(true).help("Synthetic option detail")
        }
    }
}
