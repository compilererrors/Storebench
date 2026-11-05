import Foundation

/// Paging and disclosure affect presentation only; the caller retains records and editor ownership.
public struct CollectionPresentation<ID: Hashable> {
    public static var pageSizes: [Int] { [5, 10, 20, 50] }
    public static var openingLimits: [Int] { [0, 1, 3, 5, -1] }
    public private(set) var requestedPage = 1
    public private(set) var pageSize = 10
    public private(set) var openingLimit = 0
    var overrides: [ID: Bool] = [:]

    public init(pageSize: Int = 10, openingLimit: Int = 0) {
        self.pageSize = Self.pageSizes.contains(pageSize) ? pageSize : 10
        self.openingLimit = Self.openingLimits.contains(openingLimit) ? openingLimit : 0
    }
    public struct Page {
        public let number, count, total: Int
        public let range: Range<Int>
        public let ids: [ID]
        public var summary: String { total == 0 ? "No results" : "\(range.lowerBound + 1)–\(range.upperBound) of \(total)" }
    }
    public func page(_ ids: [ID]) -> Page {
        let count = max(1, ids.count / pageSize + (ids.count % pageSize == 0 ? 0 : 1))
        let number = min(max(1, requestedPage), count), start = min(ids.count, (number - 1) * pageSize)
        let range = start..<min(ids.count, start + min(pageSize, ids.count - start))
        return Page(number: number, count: count, total: ids.count, range: range, ids: Array(ids[range]))
    }
    public func expanded(_ id: ID, on page: Page) -> Bool {
        guard let index = page.ids.firstIndex(of: id) else { return false }
        return overrides[id] ?? (openingLimit == -1 || index < openingLimit)
    }
    public mutating func choosePage(_ number: Int) { requestedPage = max(1, number) }
    public mutating func resetPage() { requestedPage = 1 }
    public mutating func chooseSize(_ size: Int) {
        guard Self.pageSizes.contains(size) else { return }
        pageSize = size; requestedPage = 1
    }
    public mutating func chooseOpeningLimit(_ limit: Int, on page: Page) {
        guard Self.openingLimits.contains(limit) else { return }
        openingLimit = limit
        for (index, id) in page.ids.enumerated() { overrides[id] = limit == -1 || index < limit }
    }
    public mutating func setExpanded(_ id: ID, _ value: Bool) { overrides[id] = value }
    public mutating func setPageExpanded(_ page: Page, _ value: Bool) {
        for id in page.ids { overrides[id] = value }
    }
    public mutating func reveal(_ id: ID, in ids: [ID]) {
        guard let index = ids.firstIndex(of: id) else { return }
        requestedPage = index / pageSize + 1; overrides[id] = true
    }
    public mutating func reconcile(_ ids: [ID]) {
        let available = Set(ids); overrides = overrides.filter { available.contains($0.key) }
        requestedPage = page(ids).number
    }
}

extension CollectionPresentation: Equatable {}

extension ComponentLayout {
    public struct CollectionGrid {
        public let frames: [CGRect], height: Double
    }
    /// Hidden retained editors reserve no rows or gaps and keep their original view identity.
    public static func collectionGrid(width: Double, heights: [Double?], maximum: Int = 1, minimumWidth: Double = 260, spacing: Double = 16) -> CollectionGrid {
        let visible = heights.compactMap { $0 }, grid = grid(width: usableWidth(width), heights: visible, maximum: maximum, minimumWidth: minimumWidth, spacing: spacing)
        var index = 0
        let frames = heights.map { height -> CGRect in
            guard let height else { return .zero }
            let row = index / grid.columns, column = index % grid.columns; index += 1
            return CGRect(x: Double(column) * (grid.cellWidth + spacing), y: grid.rowOffsets[row], width: grid.cellWidth, height: max(0, height))
        }
        return CollectionGrid(frames: frames, height: grid.height)
    }
}
