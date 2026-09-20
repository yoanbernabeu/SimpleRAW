/// One line of the history list: a step of the photo's development, and what it was.
public struct HistoryStep: Identifiable, Equatable, Sendable {
    /// Its place in the history, oldest first.
    public let id: Int
    public let label: String
}
