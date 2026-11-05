import Foundation

public struct KeywordInputFailure: Error, Sendable, Equatable {
    public let field, message: String
    public init(field: String, message: String) { self.field = field; self.message = message }
}
