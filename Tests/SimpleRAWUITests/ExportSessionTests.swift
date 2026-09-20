import Foundation
import RawEngine
import TestSupport
import Testing
@testable import SimpleRAWUI

/// Exporting is set up in the app, not in a JSON file written by hand: a preset is the
/// starting point, everything about it can be changed before the file is written, and what
/// was set up can be kept as a preset of its own.
@MainActor
@Suite struct ExportSessionTests {
    let sandbox = Sandbox()

    private func session() -> DevelopSession {
        let session = sandbox.makeSession()
        session.open(TestPhoto.url)
        return session
    }

    private func full(_ session: DevelopSession) throws -> ExportPreset {
        try #require(session.exportPresets.first { $0.name == "Full size" })
    }

    @Test func settingUpAnExportStartsFromAPreset() throws {
        defer { sandbox.cleanUp() }
        let session = session()
        #expect(session.exportDraft == nil, "nothing is being set up until it is asked for")

        session.beginExport(with: try #require(session.exportPresets.first { $0.name == "Web 2048" }))
        let draft = try #require(session.exportDraft)
        #expect(draft.options.longEdge == 2048 && draft.options.metadata == .withoutLocation)
        #expect(session.exportFileName?.hasSuffix("-web.jpg") == true)

        session.cancelExport()
        #expect(session.exportDraft == nil)
    }

    /// The file name follows what is being set up, so that it is never a .jpg holding a TIFF.
    @Test func theProposedNameFollowsTheFormatAndTheTemplate() throws {
        defer { sandbox.cleanUp() }
        let session = session()
        session.beginExport(with: try full(session))
        session.exportDraft?.options.format = .tiff16
        session.exportDraft?.fileNameTemplate = "{name}-print"
        #expect(session.exportFileName?.hasSuffix("-print.tif") == true)
    }

    @Test func whatWasSetUpCanBeKeptAsAPreset() throws {
        defer { sandbox.cleanUp() }
        let session = session()
        session.beginExport(with: try full(session))
        session.exportDraft?.options.longEdge = 1600
        session.exportDraft?.options.metadata = .copyrightOnly
        session.exportDraft?.options.author = "Yoan"
        session.saveExportPreset(named: "  Instagram  ")

        let saved = try #require(session.exportPresets.first { $0.name == "Instagram" })
        #expect(saved.options.longEdge == 1600 && saved.options.metadata == .copyrightOnly && saved.options.author == "Yoan")
        #expect(session.exportDraft?.name == "Instagram", "the sheet stays open, on what was just saved")

        // Read back from the folder by a session of its own: it is a file, not a memory.
        let next = sandbox.makeSession()
        #expect(next.exportPresets.contains { $0.name == "Instagram" && $0.options.longEdge == 1600 })
    }

    @Test func aBlankNameKeepsNothing() throws {
        defer { sandbox.cleanUp() }
        let session = session()
        session.beginExport(with: try full(session))
        session.saveExportPreset(named: "   ")
        #expect(session.exportPresets.map(\.name) == ExportPreset.builtIns.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    /// A preset that ships with the app is not deleted; one made here is.
    @Test func onlyPresetsOfYourOwnAreDeleted() throws {
        defer { sandbox.cleanUp() }
        let session = session()
        #expect(!session.canDeleteExportPreset(try full(session)))

        session.beginExport(with: try full(session))
        session.saveExportPreset(named: "Instagram")
        let mine = try #require(session.exportPresets.first { $0.name == "Instagram" })
        #expect(session.canDeleteExportPreset(mine))

        session.deleteExportPreset(mine)
        #expect(!session.exportPresets.contains { $0.name == "Instagram" })
    }

    /// Settings that make no file — a long edge of 3 px, a quality of 0 — never reach a
    /// preset: a size that means nothing is full size, and the quality stops at the lowest
    /// one that still is a picture.
    @Test func whatIsKeptIsWhatTheEngineAccepts() throws {
        defer { sandbox.cleanUp() }
        let session = session()
        session.beginExport(with: try full(session))
        session.exportDraft?.options.longEdge = 3
        session.exportDraft?.options.quality = 0
        session.saveExportPreset(named: "Odd")

        let saved = try #require(session.exportPresets.first { $0.name == "Odd" })
        #expect(saved.options.longEdge == nil && saved.options.quality == 0.05)
    }
}
