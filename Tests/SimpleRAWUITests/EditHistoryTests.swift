import Testing
@testable import SimpleRAWUI

@Suite struct EditHistoryTests {
    @Test func nothingToUndoAtFirst() {
        let history = EditHistory(0)
        #expect(!history.canUndo(from: 0))
        #expect(!history.canRedo(from: 0))
    }

    @Test func aChangeNotYetCommittedCanAlreadyBeUndone() {
        var history = EditHistory(0)
        #expect(history.canUndo(from: 1))
        #expect(history.undo(from: 1) == 0)
    }

    @Test func undoAndRedoWalkTheSteps() {
        var history = EditHistory(0)
        history.commit(1)
        history.commit(2)
        #expect(history.undo(from: 2) == 1)
        #expect(history.undo(from: 1) == 0)
        #expect(history.undo(from: 0) == nil)
        #expect(history.redo(from: 0) == 1)
        #expect(history.redo(from: 1) == 2)
        #expect(history.redo(from: 2) == nil)
    }

    @Test func committingTheSameStateIsNotAStep() {
        var history = EditHistory(0)
        history.commit(0)
        #expect(!history.canUndo(from: 0))
    }

    @Test func aNewEditForgetsWhatWasUndone() {
        var history = EditHistory(0)
        history.commit(1)
        _ = history.undo(from: 1)
        history.commit(5)
        #expect(!history.canRedo(from: 5))
        #expect(history.undo(from: 5) == 0)
    }

    /// Redoing over an edit made since would throw that edit away.
    @Test func redoIsOffWhileAnEditIsPending() {
        var history = EditHistory(0)
        history.commit(1)
        _ = history.undo(from: 1)
        #expect(!history.canRedo(from: 7))
        #expect(history.redo(from: 7) == nil)
    }

    @Test func theOldestStepsAreForgottenPastTheLimit() {
        var history = EditHistory(0, limit: 3)
        (1...5).forEach { history.commit($0) }
        #expect(history.undo(from: 5) == 4)
        #expect(history.undo(from: 4) == 3)
        // The way the document was opened is never forgotten: it stays the first step.
        #expect(history.undo(from: 3) == 0)
        #expect(history.undo(from: 0) == nil)
    }

    // MARK: - A timeline that can be read and walked

    @Test func stepsAreNamedAndTheCurrentOneIsKnown() {
        var history = EditHistory(0, label: "Opened")
        history.commit(1, label: "Exposure")
        history.commit(2, label: "Crop")
        #expect(history.steps.map(\.label) == ["Opened", "Exposure", "Crop"])
        #expect(history.cursor == 2)
        _ = history.undo(from: 2)
        #expect(history.cursor == 1 && history.steps.count == 3, "what was undone is still there to go back to")
    }

    @Test func anyStepCanBeJumpedTo() {
        var history = EditHistory(0, label: "Opened")
        (1...4).forEach { history.commit($0, label: "Step \($0)") }
        #expect(history.jump(to: 1, from: 4) == 1)
        #expect(history.cursor == 1 && history.canRedo(from: 1))
        #expect(history.jump(to: 4, from: 1) == 4)
        #expect(history.jump(to: 9, from: 4) == nil)
    }

    /// An edit not yet committed is not lost by a jump: it becomes a step first.
    @Test func jumpingKeepsAPendingEdit() {
        var history = EditHistory(0, label: "Opened")
        history.commit(1, label: "Exposure")
        #expect(history.jump(to: 0, from: 7, pendingLabel: "Contrast") == 0)
        #expect(history.steps.map(\.state) == [0, 1, 7])
    }

    @Test func editingAfterGoingBackDropsWhatFollowed() {
        var history = EditHistory(0, label: "Opened")
        (1...3).forEach { history.commit($0, label: "Step \($0)") }
        _ = history.jump(to: 1, from: 3)
        history.commit(9, label: "Another way")
        #expect(history.steps.map(\.state) == [0, 1, 9])
    }
}
