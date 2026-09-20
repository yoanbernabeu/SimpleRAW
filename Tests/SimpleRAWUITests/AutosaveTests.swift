import Foundation
import RawEngine
import TestSupport
import Testing
@testable import SimpleRAWUI

/// A store that takes its time, as a catalog busy with a backup does.
private final class SlowStore: AdjustmentsPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var written: [Double] = []
    let gate = DispatchSemaphore(value: 0)

    var contrasts: [Double] { lock.withLock { written } }

    func load(for photo: URL) throws -> Adjustments? { nil }

    func save(_ adjustments: Adjustments, for photo: URL) throws {
        gate.wait()
        lock.withLock { written.append(adjustments.contrast) }
    }
}

@MainActor
@Suite struct AutosaveTests {
    /// The autosave falls half a second after a gesture, often during the next one: it must
    /// not hold the main actor while the store writes.
    @Test func theAutosaveDoesNotWaitForTheStore() async {
        let store = SlowStore()
        let session = DevelopSession(sidecars: store)
        session.open(TestPhoto.url)
        session.adjustments.contrast = 10

        session.autosave()
        #expect(store.contrasts.isEmpty, "still writing, and the session did not wait")
        #expect(session.canUndo, "the edit became an undo step all the same")

        store.gate.signal()
        await session.autosaveSettled()
        #expect(store.contrasts == [10])
    }

    /// Leaving the photo waits for what is being written, and writes in order.
    @Test func flushingComesAfterAPendingAutosave() {
        let store = SlowStore()
        let session = DevelopSession(sidecars: store)
        session.open(TestPhoto.url)
        session.adjustments.contrast = 10
        session.autosave()
        session.adjustments.contrast = 20
        store.gate.signal()
        store.gate.signal()

        session.flush()
        #expect(store.contrasts == [10, 20])
    }

    @Test func nothingIsWrittenTwice() async {
        let store = SlowStore()
        let session = DevelopSession(sidecars: store)
        session.open(TestPhoto.url)
        session.adjustments.contrast = 10
        store.gate.signal()
        session.autosave()
        await session.autosaveSettled()

        session.autosave()
        session.flush()
        #expect(store.contrasts == [10])
    }
}
