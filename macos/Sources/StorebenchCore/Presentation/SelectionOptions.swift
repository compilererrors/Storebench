import Foundation

/// A selection's visible label and value are kept together, independently of native view rendering.
public struct SelectionOption<Value: Hashable>: Identifiable, Equatable {
    public let title: String, value: Value
    public var isEnabled: Bool
    public var detail: String? = nil
    public var id: Value { value }
    public init(_ title: String, value: Value, isEnabled: Bool = true) { self.title = title; self.value = value; self.isEnabled = isEnabled }
    public func disabled(_ disabled: Bool) -> Self { var copy = self; copy.isEnabled = !disabled; return copy }
    public func help(_ detail: String) -> Self { var copy = self; copy.detail = detail; return copy }
    public static func title(for value: Value, in options: [Self]) -> String? { options.first { $0.value == value }?.title }
    /// A native menu may still show its opening snapshot after the available choices change.
    public static func resolve(_ captured: Self, in options: [Self]) -> Value? {
        guard captured.isEnabled, Set(options.map(\.value)).count == options.count,
              options.first(where: { $0.value == captured.value }) == captured else { return nil }
        return .some(captured.value)
    }
}
extension SelectionOption: Sendable where Value: Sendable {}

@resultBuilder public enum SelectionOptionsBuilder<Value: Hashable> {
    public static func buildExpression(_ option: SelectionOption<Value>) -> [SelectionOption<Value>] { [option] }
    public static func buildExpression(_ options: [SelectionOption<Value>]) -> [SelectionOption<Value>] { options }
    public static func buildBlock(_ groups: [SelectionOption<Value>]...) -> [SelectionOption<Value>] { groups.flatMap { $0 } }
    public static func buildOptional(_ group: [SelectionOption<Value>]?) -> [SelectionOption<Value>] { group ?? [] }
    public static func buildEither(first: [SelectionOption<Value>]) -> [SelectionOption<Value>] { first }
    public static func buildEither(second: [SelectionOption<Value>]) -> [SelectionOption<Value>] { second }
    public static func buildArray(_ groups: [[SelectionOption<Value>]]) -> [SelectionOption<Value>] { groups.flatMap { $0 } }
}

public func selectionOptions<Data: Sequence, Value: Hashable>(_ data: Data, @SelectionOptionsBuilder<Value> content: (Data.Element) -> [SelectionOption<Value>]) -> [SelectionOption<Value>] {
    data.flatMap(content)
}
