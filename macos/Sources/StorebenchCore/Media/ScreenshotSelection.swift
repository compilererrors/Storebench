import Foundation

/// A local, unsaved selection retains its immutable originals and adjustments between editing sessions.
public struct ScreenshotSelection: Sendable {
    public struct Item: Identifiable, Sendable {
        public let id: String, originalName: String, original: Data
        public fileprivate(set) var name: String, data: Data, edits: ScreenshotEdits?
        public init(name: String, data: Data) {
            id = UUID().uuidString; originalName = name; original = data; self.name = name; self.data = data
        }
    }
    public private(set) var items: [Item]
    public private(set) var revision = UUID().uuidString
    public init(_ files: [SelectedFiles.File]) { items = files.map { Item(name: $0.name, data: $0.data) } }
    public init(items: [Item]) { self.items = items }
    @discardableResult public mutating func reorder(_ order: [String], expectedRevision: String) -> Bool {
        let ids = items.map(\.id)
        guard revision == expectedRevision, order.count == ids.count, Set(order).count == order.count, Set(order) == Set(ids) else { return false }
        guard order != ids else { return true }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        items = order.compactMap { byID[$0] }; revision = UUID().uuidString; return true
    }
    public mutating func move(_ id: String, by offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }), items.indices.contains(index + offset) else { return }
        items.swapAt(index, index + offset)
        revision = UUID().uuidString
    }
    @discardableResult public mutating func move(_ id: String, to target: String) -> Bool {
        guard let from = items.firstIndex(where: { $0.id == id }), let to = items.firstIndex(where: { $0.id == target }), from != to else { return false }
        let item = items.remove(at: from); items.insert(item, at: to); revision = UUID().uuidString; return true
    }
    public mutating func remove(_ id: String) { items.removeAll { $0.id == id }; revision = UUID().uuidString }
    public mutating func restore(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].data = items[index].original; items[index].name = items[index].originalName; items[index].edits = nil
        revision = UUID().uuidString
    }
    public mutating func apply(_ id: String, data: Data, edits: ScreenshotEdits) throws {
        guard let index = items.firstIndex(where: { $0.id == id }), ScreenshotEditing.valid(edits) else { throw ScreenshotEditFailure.edits }
        guard let image = try? ScreenshotSpecs.validate(data) else { throw ScreenshotEditFailure.image }
        guard image.width == edits.width, image.height == edits.height, image.contentType == "image/jpeg" else { throw ScreenshotEditFailure.image }
        let name = ScreenshotSpecs.fileName(items[index].originalName, contentType: "image/jpeg")
        items[index].name = String(name.dropLast(4)) + "-edited.jpg"
        items[index].data = data; items[index].edits = edits
        revision = UUID().uuidString
    }
    /// Replaces images that carry an alpha channel with opaque copies on white; Restore Original brings the file back.
    public mutating func removeTransparency() -> Int {
        var count = 0
        for index in items.indices {
            if let flat = try? ScreenshotRenderer.opaque(items[index].data) { items[index].data = flat; count += 1 }
        }
        if count > 0 { revision = UUID().uuidString }
        return count
    }
    public func problem(platform: String, displayType: String? = nil) -> String? {
        guard !items.isEmpty, items.count <= ScreenshotSpecs.maximum else { return "Choose between 1 and 10 screenshots." }
        guard items.allSatisfy({ !$0.data.isEmpty && $0.data.count <= ScreenshotSpecs.maximumBytes }) else { return "Each screenshot must be no larger than 20 MB. Choose Fix Images to reduce its size." }
        guard items.reduce(0, { $0 + $1.data.count }) <= ScreenshotSpecs.maximumBatchBytes else { return "Choose up to 50 MB of images at a time. The selection is kept." }
        for item in items {
            do {
                let image = try ScreenshotSpecs.validate(item.data)
                guard displayType.map({ ScreenshotSpecs.fits($0, width: image.width, height: image.height) }) ?? (ScreenshotSpecs.type(platform: platform, width: image.width, height: image.height) != nil) else {
                    return "This image is not an App Store screenshot size. Choose Fix Images to crop or resize it."
                }
            } catch let failure as ScreenshotFailure { return failure.message + " Choose Fix Images to correct it." }
            catch { return "Choose a valid PNG or JPEG before adding." }
        }
        return nil
    }
}
