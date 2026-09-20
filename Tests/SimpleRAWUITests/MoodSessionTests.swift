import Foundation
import RawEngine
import TestSupport
import Testing
@testable import SimpleRAWUI

/// Moods are `.cube` files someone put in a folder: the panel lists what is there, and
/// picking one is an edit like any other.
@MainActor
@Suite struct MoodSessionTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-moods-\(UUID().uuidString)")
    let session: DevelopSession

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["Teal", "Faded"] {
            try Data("LUT_3D_SIZE 2\n\(Array(repeating: "0 0 0", count: 8).joined(separator: "\n"))\n".utf8)
                .write(to: folder.appendingPathComponent("\(name).cube"))
        }
        session = DevelopSession(luts: LUTLibrary(directory: folder))
        session.open(TestPhoto.url)
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    @Test func listsTheLUTsOfTheFolderWhenAsked() {
        defer { cleanUp() }
        session.reloadMoodNames()
        #expect(session.moodNames == ["Faded", "Teal"])
        #expect(session.adjustments.lut == nil && session.moodAmount == 100)
    }

    /// A file dropped into the folder while the app runs shows up on the next look.
    @Test func aFileAddedLaterShowsUp() throws {
        defer { cleanUp() }
        session.reloadMoodNames()
        try Data("LUT_3D_SIZE 2\n\(Array(repeating: "1 1 1", count: 8).joined(separator: "\n"))\n".utf8)
            .write(to: folder.appendingPathComponent("Warm.cube"))
        session.reloadMoodNames()
        #expect(session.moodNames == ["Faded", "Teal", "Warm"])
    }

    @Test func pickingAMoodIsOneUndoStepAndKeepsTheAmount() {
        defer { cleanUp() }
        session.setMood("Teal")
        #expect(session.adjustments.lut == LUTSetting(name: "Teal", amount: 100))

        session.setMoodAmount(60)
        session.commitEdit()
        session.setMood("Faded")
        #expect(session.adjustments.lut == LUTSetting(name: "Faded", amount: 60), "trying several at the same amount")

        session.undo()
        #expect(session.adjustments.lut?.name == "Teal")
    }

    @Test func noMoodTakesTheSettingAway() {
        defer { cleanUp() }
        session.setMood("Teal")
        session.setMood(nil)
        #expect(session.adjustments.lut == nil && !session.hasChanges)
    }

    /// The amount is dragged like any slider: one step when it settles, and it never leaves
    /// the picture wearing a mood at nothing.
    @Test func theAmountIsDraggedAndUndoesAtOnce() {
        defer { cleanUp() }
        session.setMood("Teal")
        session.commitEdit()
        for amount in [90.0, 70, 50, 40] { session.setMoodAmount(amount) }
        session.commitEdit()
        #expect(session.adjustments.lut?.amount == 40)

        session.undo()
        #expect(session.adjustments.lut?.amount == 100)

        // Down to nothing: the mood is still the one picked, waiting to be brought back.
        session.setMoodAmount(0)
        #expect(session.adjustments.lut == LUTSetting(name: "Teal", amount: 0))
        #expect(session.moodAmount == 0)
    }

    @Test func settingTheAmountWithoutAMoodDoesNothing() {
        defer { cleanUp() }
        session.setMoodAmount(50)
        #expect(session.adjustments.lut == nil)
    }
}
