import Testing
@testable import StorebenchCore

@Suite struct CollectionPresentationTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func recordsStartCollapsedOnEveryPageUntilTheUserOpensThem() {
        let ids = Array(0..<23)
        for initial in [CollectionPresentation<Int>(), CollectionPresentation<Int>(openingLimit: 99)] {
            var state = initial
            #expect(state.openingLimit == 0)
            for page in 1...3 {
                state.choosePage(page)
                let visible = state.page(ids)
                #expect(visible.ids.allSatisfy { !state.expanded($0, on: visible) })
            }
            state.choosePage(1)
            state.setExpanded(0, true)
            #expect(state.expanded(0, on: state.page(ids)))
            state.choosePage(2)
            #expect(state.page(ids).ids.allSatisfy { !state.expanded($0, on: state.page(ids)) })
            state.choosePage(1)
            #expect(state.expanded(0, on: state.page(ids)))
        }
    }

    @Test func emptyAndOutOfRangePagesRemainValid() {
        var state = CollectionPresentation<Int>()
        state.choosePage(Int.max)
        #expect(state.page([]).number == 1)
        #expect(state.page([]).count == 1)
        #expect(state.page([]).summary == "No results")
        let page = state.page(Array(0..<23))
        #expect(page.number == 3 && page.count == 3)
        #expect(page.ids == [20, 21, 22])
        #expect(page.summary == "21–23 of 23")
        state.choosePage(Int.min)
        #expect(state.page(Array(0..<23)).number == 1)
    }

    @Test func pageWideExpansionNeverChangesAnotherPage() {
        let ids = Array(0..<31)
        var state = CollectionPresentation<Int>(pageSize: 5, openingLimit: 0)
        let first = state.page(ids)
        state.setPageExpanded(first, true)
        state.choosePage(2)
        let second = state.page(ids)
        #expect(second.ids.allSatisfy { !state.expanded($0, on: second) })
        state.setExpanded(7, true)
        state.setPageExpanded(second, false)
        #expect(first.ids.allSatisfy { state.expanded($0, on: first) })
        #expect(second.ids.allSatisfy { !state.expanded($0, on: second) })
        #expect(!state.expanded(0, on: second))
    }

    @Test(arguments: [0, 1, 3, 5, -1]) func openingDefaultsAndIndividualOverrides(_ limit: Int) {
        let ids = Array(0..<25)
        var state = CollectionPresentation<Int>()
        let first = state.page(ids)
        state.chooseOpeningLimit(limit, on: first)
        #expect(first.ids.filter { state.expanded($0, on: first) }.count == (limit == -1 ? 10 : limit))
        state.choosePage(2)
        let second = state.page(ids)
        #expect(second.ids.filter { state.expanded($0, on: second) }.count == (limit == -1 ? 10 : limit))
        state.setExpanded(19, true)
        state.choosePage(1); state.choosePage(2)
        #expect(state.expanded(19, on: state.page(ids)))
    }

    @Test func resizingAndSortingRetainStableRecordDecisions() {
        let ids = Array(0..<30)
        var state = CollectionPresentation<Int>(openingLimit: 0)
        state.setExpanded(17, true); state.choosePage(3)
        state.chooseSize(20)
        #expect(state.requestedPage == 1 && state.pageSize == 20)
        #expect(state.expanded(17, on: state.page(ids)))
        state.reveal(17, in: Array(ids.reversed()))
        #expect(state.expanded(17, on: state.page(Array(ids.reversed()))))
        state.chooseSize(0); state.chooseSize(Int.max)
        #expect(state.pageSize == 20)
    }

    @Test func newOpeningDefaultOnlyChangesCurrentPage() {
        var state = CollectionPresentation<Int>(pageSize: 5)
        let ids = Array(0..<13), first = state.page(ids)
        state.setExpanded(3, true); state.choosePage(2)
        let second = state.page(ids)
        state.chooseOpeningLimit(0, on: second)
        #expect(state.expanded(3, on: first))
        #expect(second.ids.allSatisfy { !state.expanded($0, on: second) })
        state.chooseOpeningLimit(99, on: second)
        #expect(state.openingLimit == 0)
    }

    @Test func removedRecordsAndFocusedDestinationsAreScoped() {
        var state = CollectionPresentation<String>(pageSize: 5, openingLimit: 0)
        let ids = (0..<21).map { "synthetic-language-\($0)" }
        state.reveal(ids[19], in: ids)
        #expect(state.requestedPage == 4)
        #expect(state.expanded(ids[19], on: state.page(ids)))
        state.reveal("missing", in: ids)
        #expect(state.requestedPage == 4)
        state.reconcile(Array(ids.prefix(2)))
        #expect(state.requestedPage == 1)
        #expect(!state.expanded(ids[19], on: state.page(ids)))
    }

    @Test(arguments: [390.0, 768, 1440]) func expandingOverviewKeepsTheAppCardsAfterTheLeadingDivider(_ width: Double) {
        let card = ComponentLayout.workflowCard(width: width)
        let workflows = ComponentLayout.grid(width: width, heights: Array(repeating: card.height, count: 3), maximum: 3, minimumWidth: 260, spacing: 12, workflow: true)
        for details in [0.0, 240, 1200] {
            let heights = [1.0, workflows.height, details]
            let expanded = ComponentLayout.collectionGrid(width: width, heights: heights.map(Optional.some), maximum: 1, minimumWidth: 1, spacing: 0)
            #expect(expanded.frames.count == 3)
            #expect(expanded.frames[0].height == 1)
            #expect(expanded.frames[1].minY == 1 && expanded.frames[1].height == workflows.height)
            #expect(expanded.frames[2].minY == 1 + workflows.height && expanded.frames[2].height == details)
            #expect(expanded.height == 1 + workflows.height + details)
            for _ in 0..<10 {
                let collapsed = ComponentLayout.collectionGrid(width: width, heights: heights.map { _ in nil }, maximum: 1, minimumWidth: 1, spacing: 0)
                #expect(collapsed.height == 0 && collapsed.frames.allSatisfy { $0 == .zero })
                let reopened = ComponentLayout.collectionGrid(width: width, heights: heights.map(Optional.some), maximum: 1, minimumWidth: 1, spacing: 0)
                #expect(reopened.frames == expanded.frames && reopened.height == expanded.height)
            }
            #expect(expanded.frames.allSatisfy { $0.minX >= 0 && $0.maxX <= width && $0.maxY <= expanded.height })
        }
    }

    @Test(arguments: [0.0, 180, 390, 768, 1380]) func hiddenRetainedEditorsConsumeNoGridSpace(_ width: Double) {
        let heights: [Double?] = [nil, 160, nil, 200, 80, nil, 190]
        let layout = ComponentLayout.collectionGrid(width: width, heights: heights, maximum: 3)
        let base = ComponentLayout.grid(width: width, heights: heights.compactMap { $0 }, maximum: 3, minimumWidth: 260)
        #expect(layout.height == base.height)
        #expect(layout.frames.count == heights.count)
        for (index, frame) in layout.frames.enumerated() {
            if heights[index] == nil { #expect(frame == .zero) }
            else {
                #expect(Double(frame.minX) >= 0)
                #expect(Double(frame.maxX) <= width + 0.001)
                #expect(Double(frame.maxY) <= layout.height + 0.001)
                #expect(Double(frame.height) == heights[index])
            }
        }
        #expect(ComponentLayout.collectionGrid(width: width, heights: [nil, nil]).height == 0)
    }
}
