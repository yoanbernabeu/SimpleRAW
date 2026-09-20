import CoreImage
import Foundation
import RawEngine
import TestSupport
import Testing
@testable import SimpleRAWUI

/// A session wired to throwaway folders, so that tests never write next to the samples.
@MainActor
struct Sandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-session-\(UUID().uuidString)")

    func makeSession() -> DevelopSession {
        DevelopSession(
            presets: JSONFileStore(directory: root.appendingPathComponent("presets"), builtIns: Preset.builtIns),
            exportPresets: JSONFileStore(directory: root.appendingPathComponent("export"), builtIns: ExportPreset.builtIns),
            sidecars: SidecarStore(directory: root.appendingPathComponent("sidecars"))
        )
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
@Suite
struct PersistenceTests {
    let sandbox = Sandbox()

    @Test func editsComeBackTheNextTimeThePhotoIsOpened() throws {
        defer { sandbox.cleanUp() }
        let first = sandbox.makeSession()
        first.open(TestPhoto.all[0])
        first.adjustments.contrast = 25
        first.flush()

        let second = sandbox.makeSession()
        second.open(TestPhoto.all[0])
        #expect(second.adjustments.contrast == 25)
        #expect(second.errorMessage == nil)
    }

    @Test func openingAnotherPhotoSavesTheCurrentOne() {
        defer { sandbox.cleanUp() }
        let session = sandbox.makeSession()
        session.open(TestPhoto.all[0])
        session.adjustments.shadows = 40
        session.open(TestPhoto.all[1])
        #expect(session.adjustments == Adjustments())
        session.open(TestPhoto.all[0])
        #expect(session.adjustments.shadows == 40)
    }

    @Test func lookingAtAPhotoWritesNothing() {
        defer { sandbox.cleanUp() }
        let session = sandbox.makeSession()
        session.open(TestPhoto.all[0])
        session.flush()
        let sidecars = (try? FileManager.default.contentsOfDirectory(atPath: sandbox.root.appendingPathComponent("sidecars").path)) ?? []
        #expect(sidecars.isEmpty)
    }

    @Test func aDamagedSidecarIsReportedAndLeftAlone() throws {
        defer { sandbox.cleanUp() }
        let folder = sandbox.root.appendingPathComponent("sidecars")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sidecar = SidecarStore(directory: folder).sidecarURL(for: TestPhoto.all[0])
        try Data("garbage".utf8).write(to: sidecar)

        let session = sandbox.makeSession()
        session.open(TestPhoto.all[0])
        #expect(session.errorMessage != nil)
        #expect(session.info != nil)
        session.flush()
        #expect(try Data(contentsOf: sidecar) == Data("garbage".utf8))
    }
}

@MainActor
@Suite
struct DamagedSidecarEditTests {
    /// The case the first test missed: the photo is edited after its sidecar failed to load.
    /// The autosave then writes, and used to write over the file it could not read.
    @Test func editingAPhotoWhoseSidecarCouldNotBeReadKeepsThatSidecar() throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        let sample = TestPhoto.url
        let folder = sandbox.root.appendingPathComponent("sidecars")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("somebody's work".utf8).write(to: SidecarStore(directory: folder).sidecarURL(for: sample))

        let session = sandbox.makeSession()
        session.open(sample)
        session.adjustments.contrast = 15
        session.flush()

        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let kept = try #require(files.first { $0.contains(".unreadable") })
        #expect(try String(contentsOf: folder.appendingPathComponent(kept), encoding: .utf8) == "somebody's work")
        #expect(try SidecarStore(directory: folder).load(for: sample)?.contrast == 15)
    }
}

@MainActor
@Suite
struct PresetSessionTests {
    let sandbox = Sandbox()

    @Test func listsBuiltInLooks() {
        defer { sandbox.cleanUp() }
        #expect(sandbox.makeSession().presets.map(\.name).contains("Camera match"))
    }

    @Test func applyingALookChangesOnlyItsGroups() throws {
        defer { sandbox.cleanUp() }
        let session = sandbox.makeSession()
        session.open(TestPhoto.url)
        session.adjustments.vignetting = 30
        session.apply(try #require(session.presets.first { $0.name == "Camera match" }))
        #expect(session.adjustments.exposure == 0.4)
        #expect(session.adjustments.vignetting == 30)
    }

    @Test func theCurrentLookCanBeSavedAndDeleted() throws {
        defer { sandbox.cleanUp() }
        let session = sandbox.makeSession()
        session.open(TestPhoto.url)
        session.adjustments.contrast = 33
        session.savePreset(named: "Mine", groups: [.light])
        let saved = try #require(session.presets.first { $0.name == "Mine" })
        #expect(saved.adjustments.contrast == 33 && saved.groups == [.light])
        #expect(session.canDelete(saved))

        session.deletePreset(saved)
        #expect(!session.presets.contains { $0.name == "Mine" })
        #expect(!session.canDelete(try #require(session.presets.first { $0.name == "Camera match" })))
    }

    /// Looks are passed around as files: one dropped into the folder under any file name is
    /// still yours to delete, even when it carries the name of a look that ships with the app.
    @Test func aLookDroppedInByHandIsYoursToDelete() throws {
        defer { sandbox.cleanUp() }
        let folder = sandbox.root.appendingPathComponent("presets")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"name": "Camera match", "groups": ["light"], "adjustments": {"contrast": 12}}"#.utf8)
            .write(to: folder.appendingPathComponent("from-a-friend.json"))

        let session = sandbox.makeSession()
        let replaced = try #require(session.presets.first { $0.name == "Camera match" })
        #expect(replaced.adjustments.contrast == 12, "the file replaces the built-in of that name")
        #expect(session.canDelete(replaced))

        session.deletePreset(replaced)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("from-a-friend.json").path))
        // The built-in comes back, and is not deletable.
        let builtIn = try #require(session.presets.first { $0.name == "Camera match" })
        #expect(builtIn.adjustments.contrast != 12 && !session.canDelete(builtIn))
    }

    /// A look is not silently written over: saving under a name that is taken asks first.
    /// Whatever the case of the name — "Fade" and "fade" are one file.
    @Test func savingOverALookAsksFirst() throws {
        defer { sandbox.cleanUp() }
        let session = sandbox.makeSession()
        session.open(TestPhoto.url)
        session.adjustments.contrast = 33
        session.savePreset(named: "Mine", groups: [.light])

        session.adjustments.contrast = 10
        #expect(session.lookToOverwrite(named: " mine ") == "Mine", "the name that is taken, as it is written")
        #expect(session.lookToOverwrite(named: "Other") == nil)
        // A built-in is a name that is taken too: saving over it hides it behind a file.
        #expect(session.lookToOverwrite(named: "Camera match") == "Camera match")

        // Until it is confirmed, nothing is written.
        #expect(session.presets.first { $0.name == "Mine" }?.adjustments.contrast == 33)
        session.savePreset(named: "Mine", groups: [.light], overwriting: true)
        #expect(session.presets.first { $0.name == "Mine" }?.adjustments.contrast == 10)
        #expect(session.presets.filter { $0.name == "Mine" }.count == 1)
    }

    @Test func anEmptyNameIsRefused() throws {
        defer { sandbox.cleanUp() }
        let session = sandbox.makeSession()
        session.open(TestPhoto.url)
        let before = session.presets.count
        session.savePreset(named: "   ", groups: [.light])
        #expect(session.presets.count == before)
    }
}

@MainActor
@Suite
struct CopyPasteTests {
    let sandbox = Sandbox()

    @Test func settingsTravelFromOnePhotoToAnother() {
        defer { sandbox.cleanUp() }
        let session = sandbox.makeSession()
        #expect(!session.canPaste)
        session.open(TestPhoto.all[0])
        session.adjustments.contrast = 20
        session.adjustments.geometry.straighten = 3
        session.copyAdjustments(groups: AdjustmentGroup.defaultSelection)

        session.open(TestPhoto.all[1])
        session.adjustments.vignetting = 15
        #expect(session.canPaste)
        session.pasteAdjustments()
        #expect(session.adjustments.contrast == 20)
        // Geometry was not part of the copy; optics was, and the source had none.
        #expect(session.adjustments.geometry.straighten == 0)
        #expect(session.adjustments.vignetting == 0)
    }
}

@MainActor
@Suite
struct ExportPresetSessionTests {
    let sandbox = Sandbox()

    @Test func exportsWithAPresetUnderItsFileName() async throws {
        defer { sandbox.cleanUp() }
        let session = sandbox.makeSession()
        let sample = TestPhoto.url
        session.open(sample)
        let preset = try #require(session.exportPresets.first { $0.name == "Small 1080" })
        #expect(session.suggestedFileName(for: preset) == sample.deletingPathExtension().lastPathComponent + "-small.jpg")

        let destination = sandbox.root.appendingPathComponent("out.jpg")
        try FileManager.default.createDirectory(at: sandbox.root, withIntermediateDirectories: true)
        try await session.export(to: destination, options: preset.options)
        let image = try #require(CIImage(contentsOf: destination))
        #expect(max(image.extent.width, image.extent.height) == 1080)
    }
}
