import Foundation
import Testing
@testable import RawEngine

@Suite struct PresetTests {
    @Test func appliesItsGroupsAndLeavesTheRestAlone() {
        let preset = Preset(name: "Punchy", capturing: AdjustmentGroupTests.edited, groups: [.light, .color])
        var photo = Adjustments()
        photo.vignetting = 20
        photo.exposure = -1
        preset.apply(to: &photo)
        #expect(photo.exposure == 0.5 && photo.vibrance == 15)
        #expect(photo.vignetting == 20)
        #expect(photo.hsl.isNeutral)
    }

    /// A preset file must not leak settings of groups it does not carry.
    @Test func capturesOnlyTheChosenGroups() {
        let preset = Preset(name: "Light only", capturing: AdjustmentGroupTests.edited, groups: [.light])
        #expect(preset.adjustments.exposure == 0.5)
        #expect(preset.adjustments.hsl.isNeutral && preset.adjustments.vignetting == 0)
    }

    @Test func roundTripsThroughJSON() throws {
        let preset = Preset(name: "Teal & orange", capturing: AdjustmentGroupTests.edited, groups: [.grading, .curve])
        #expect(try Preset.decode(from: preset.encoded(), fallbackName: "ignored") == preset)
    }

    @Test func aBareAdjustmentsDocumentIsAPreset() throws {
        let json = Data(#"{"contrast": 20, "vibrance": 15}"#.utf8)
        let preset = try Preset.decode(from: json, fallbackName: "My look")
        #expect(preset.name == "My look")
        #expect(preset.groups == [.light, .color])
        #expect(preset.adjustments.contrast == 20)
    }

    /// A file passed around carries the name of the look, whatever the file is called.
    @Test func aBareDocumentMayStillSayWhatItIsCalled() throws {
        let json = Data(#"{"name": "Faded", "contrast": -10}"#.utf8)
        let preset = try Preset.decode(from: json, fallbackName: "from-a-friend")
        #expect(preset.name == "Faded" && preset.groups == [.light] && preset.adjustments.contrast == -10)
    }

    @Test func groupsAreInferredWhenLeftOut() throws {
        let json = Data(#"{"name": "Fade", "adjustments": {"curves": {"rgb": {"points": [{"x":0,"y":0.1},{"x":1,"y":1}]}}}}"#.utf8)
        let preset = try Preset.decode(from: json, fallbackName: "ignored")
        #expect(preset.name == "Fade" && preset.groups == [.curve])
    }
}

@Suite struct ExportPresetTests {
    let source = URL(fileURLWithPath: "/photos/R0007010.DNG")

    @Test func namesFilesFromItsTemplate() {
        var preset = ExportPreset(name: "Web")
        preset.fileNameTemplate = "{name}-web"
        #expect(preset.fileName(for: source) == "R0007010-web.jpg")
    }

    @Test func defaultsToTheNameOfTheSource() {
        #expect(ExportPreset(name: "Full").fileName(for: source) == "R0007010.jpg")
        #expect(ExportPreset(name: "Full").destination(for: source, in: URL(fileURLWithPath: "/out")).path == "/out/R0007010.jpg")
    }

    @Test func roundTripsThroughJSON() throws {
        var preset = ExportPreset(name: "Web 2048")
        preset.options.longEdge = 2048
        preset.options.quality = 0.85
        preset.options.colorSpace = .displayP3
        #expect(try ExportPreset.decode(from: preset.encoded(), fallbackName: "ignored") == preset)
    }

    @Test func builtInsCoverTheUsualNeeds() {
        let names = ExportPreset.builtIns.map(\.name)
        #expect(names.count >= 3 && Set(names).count == names.count)
        #expect(ExportPreset.builtIns.contains { $0.options.longEdge == nil })
    }
}

@Suite struct JSONFileStoreTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-store-\(UUID().uuidString)")

    private func makeStore(builtIns: [Preset] = []) -> JSONFileStore<Preset> {
        JSONFileStore(directory: directory, builtIns: builtIns)
    }

    @Test func savesAndListsItemsByName() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore()
        try store.save(Preset(name: "Zebra", capturing: Adjustments(), groups: [.light]))
        try store.save(Preset(name: "alpha", capturing: Adjustments(), groups: [.light]))
        #expect(store.all().map(\.name) == ["alpha", "Zebra"])
    }

    @Test func savingUnderTheSameNameReplaces() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore()
        try store.save(Preset(name: "Look", capturing: Adjustments(), groups: [.light]))
        try store.save(Preset(name: "Look", capturing: AdjustmentGroupTests.edited, groups: [.light]))
        #expect(store.all().count == 1)
        #expect(store.all().first?.adjustments.exposure == 0.5)
    }

    @Test func deletesUserItemsButNotBuiltIns() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let builtIn = Preset(name: "Built-in", capturing: Adjustments(), groups: [.light])
        let store = makeStore(builtIns: [builtIn])
        try store.save(Preset(name: "Mine", capturing: Adjustments(), groups: [.light]))
        try store.delete(named: "Mine")
        try store.delete(named: "Built-in")
        #expect(store.all().map(\.name) == ["Built-in"])
        #expect(store.isBuiltIn("Built-in") && !store.isBuiltIn("Mine"))
    }

    @Test func aUserItemShadowsABuiltInOfTheSameName() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(builtIns: [Preset(name: "Look", capturing: Adjustments(), groups: [.light])])
        try store.save(Preset(name: "Look", capturing: AdjustmentGroupTests.edited, groups: [.light]))
        #expect(store.all().count == 1)
        #expect(store.all().first?.adjustments.exposure == 0.5)
    }

    @Test func namesThatAreNotValidFileNamesStillWork() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore()
        try store.save(Preset(name: "B&W / high: contrast", capturing: Adjustments(), groups: [.light]))
        #expect(store.all().map(\.name) == ["B&W / high: contrast"])
    }

    @Test func unreadableFilesAreSkippedNotFatal() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore()
        try store.save(Preset(name: "Good", capturing: Adjustments(), groups: [.light]))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("broken.json"))
        #expect(store.all().map(\.name) == ["Good"])
    }

    @Test func aHandWrittenFileIsNamedAfterItself() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"contrast": 30}"#.utf8).write(to: directory.appendingPathComponent("Hand made.json"))
        #expect(store.all().map(\.name) == ["Hand made"])
    }
}

@Suite struct BuiltInPresetTests {
    @Test func builtInsAreWellFormed() {
        let names = Preset.builtIns.map(\.name)
        #expect(Set(names).count == names.count)
        for preset in Preset.builtIns {
            #expect(!preset.groups.isEmpty, "\(preset.name)")
            // A look must not reframe the picture it is applied to.
            #expect(!preset.groups.contains(.geometry), "\(preset.name)")
            var photo = Adjustments()
            preset.apply(to: &photo)
            #expect(photo != Adjustments(), "\(preset.name) changes nothing")
        }
    }

    @Test func builtInsSurviveTheirOwnFileFormat() throws {
        for preset in Preset.builtIns {
            #expect(try Preset.decode(from: preset.encoded(), fallbackName: "") == preset)
        }
    }
}
