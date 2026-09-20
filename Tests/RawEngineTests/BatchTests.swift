import CoreImage
import Foundation
import Testing
import TestSupport
@testable import RawEngine

@Suite struct PresetResolutionTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-resolve-\(UUID().uuidString)")

    @Test func findsAPresetByNameWhateverTheCase() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONFileStore<Preset>(directory: directory)
        try store.save(Preset(name: "Punchy", capturing: Adjustments(), groups: [.light]))
        #expect(try store.resolve("punchy").name == "Punchy")
    }

    @Test func aPathToAFileWinsOverNames() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("look.json")
        try Data(#"{"contrast": 20}"#.utf8).write(to: file)
        let preset = try JSONFileStore<Preset>(directory: directory.appendingPathComponent("empty")).resolve(file.path)
        #expect(preset.name == "look" && preset.adjustments.contrast == 20)
    }

    @Test func anUnknownNameIsAnErrorThatListsWhatExists() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONFileStore<Preset>(directory: directory)
        try store.save(Preset(name: "Punchy", capturing: Adjustments(), groups: [.light]))
        #expect(throws: RawEngineError.unknownPreset("nope", available: ["Punchy"])) {
            try store.resolve("nope")
        }
    }
}

@Suite(.enabled(if: Sample.all.count >= 2, "Needs two DNGs in Samples/"))
struct BatchJobTests {
    let output = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-batch-\(UUID().uuidString)")

    @Test func developsEveryFileAndSurvivesABadOne() throws {
        defer { try? FileManager.default.removeItem(at: output) }
        var export = ExportPreset(name: "Tiny")
        export.options.longEdge = 320
        export.fileNameTemplate = "{name}-tiny"
        var look = Adjustments()
        look.saturation = -100
        let job = BatchJob(
            preset: Preset(name: "Mono", capturing: look, groups: [.color]),
            exportPreset: export,
            outputDirectory: output
        )
        let bogus = URL(fileURLWithPath: "/nonexistent/photo.dng")
        let files = [Sample.all[0], bogus, Sample.all[1]]

        var reported: [URL] = []
        let outcomes = job.run(on: files) { reported.append($0.source) }

        #expect(reported == files)
        #expect(outcomes.map { $0.isSuccess } == [true, false, true])

        let first = try #require(outcomes[0].destination)
        #expect(first.lastPathComponent == Sample.all[0].deletingPathExtension().lastPathComponent + "-tiny.jpg")
        let image = try #require(CIImage(contentsOf: first))
        #expect(max(image.extent.width, image.extent.height) == 320)
        #expect(try PixelProbe().average(of: image).chroma < 0.02)
    }

    /// Edits made in the app are part of the picture: a batch starts from them, and the look
    /// only replaces the groups it carries.
    @Test func startsFromTheSavedEditsOfEachPhoto() throws {
        defer { try? FileManager.default.removeItem(at: output) }
        let sidecars = SidecarStore(directory: output.appendingPathComponent("sidecars"))
        var edits = Adjustments()
        edits.saturation = -100
        try sidecars.save(edits, for: Sample.all[0])

        var export = ExportPreset(name: "Tiny")
        export.options.longEdge = 320
        var look = Adjustments()
        look.contrast = 20
        let job = BatchJob(
            preset: Preset(name: "Contrast", capturing: look, groups: [.light]),
            exportPreset: export,
            outputDirectory: output,
            sidecars: sidecars
        )
        let outcomes = job.run(on: [Sample.all[0], Sample.all[1]])

        let editedFile = try #require(outcomes[0].destination)
        let untouchedFile = try #require(outcomes[1].destination)
        let edited = try #require(CIImage(contentsOf: editedFile))
        let untouched = try #require(CIImage(contentsOf: untouchedFile))
        #expect(try PixelProbe().average(of: edited).chroma < 0.02)
        #expect(try PixelProbe().average(of: untouched).chroma > 0.02)
    }
}
