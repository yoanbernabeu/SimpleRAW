/// The history of a document: a timeline of named steps, with a cursor on the current one.
/// Undo and redo move the cursor; so does a jump to any step, from a list.
///
/// The document changes dozens of times during one gesture; the history only hears about it
/// when the gesture settles (`commit`). Until then the change is pending: it can be undone
/// already, and it rules out redoing, which would throw it away.
struct EditHistory<State: Equatable> {
    struct Step: Equatable {
        let state: State
        let label: String
    }

    /// Oldest first. The first one is the document as it was opened.
    private(set) var steps: [Step]
    /// Index of the step the document is at.
    private(set) var cursor = 0
    private let limit: Int

    init(_ initial: State, label: String = "Opened", limit: Int = 100) {
        steps = [Step(state: initial, label: label)]
        self.limit = limit
    }

    /// Takes a history up where it was left: what a store kept of an earlier session.
    init?(steps: [Step], cursor: Int, limit: Int = 100) {
        guard steps.indices.contains(cursor) else { return nil }
        (self.steps, self.cursor, self.limit) = (steps, cursor, limit)
    }

    /// The state the next step starts from.
    var committed: State { steps[cursor].state }

    func canUndo(from current: State) -> Bool { cursor > 0 || current != committed }
    func canRedo(from current: State) -> Bool { cursor < steps.count - 1 && current == committed }

    /// Turns whatever changed since the last step into one step. What had been undone is
    /// dropped: the document went another way.
    mutating func commit(_ current: State, label: String = "Edit") {
        guard current != committed else { return }
        steps.removeSubrange((cursor + 1)...)
        steps.append(Step(state: current, label: label))
        // The oldest steps go first; "Opened" keeps its place at the head of the list.
        if steps.count > limit + 1 { steps.remove(at: 1) }
        cursor = steps.count - 1
    }

    /// The state to go back to, or `nil` at the beginning.
    mutating func undo(from current: State, pendingLabel: String = "Edit") -> State? {
        commit(current, label: pendingLabel)
        return cursor > 0 ? jump(to: cursor - 1, from: committed) : nil
    }

    mutating func redo(from current: State) -> State? {
        canRedo(from: current) ? jump(to: cursor + 1, from: current) : nil
    }

    /// Goes to any step. An edit still pending becomes a step first, so that it is not lost;
    /// as it drops what followed the cursor, `index` is then read in the new list.
    mutating func jump(to index: Int, from current: State, pendingLabel: String = "Edit") -> State? {
        commit(current, label: pendingLabel)
        guard steps.indices.contains(index) else { return nil }
        cursor = index
        return committed
    }
}
