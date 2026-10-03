public struct EvaluationError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    /// Set when the error comes from a name that is not bound anywhere, so
    /// `??` can fall back instead of failing.
    public var undefinedName: String?

    public init(_ message: String, undefinedName: String? = nil) {
        self.message = message
        self.undefinedName = undefinedName
    }

    public var description: String { message }
}
