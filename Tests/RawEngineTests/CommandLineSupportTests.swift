import CoreGraphics
import Foundation
import Testing
@testable import RawEngine

/// What a command line needs from the engine, written once and tested here: the CLI itself
/// only parses and prints.
@Suite struct SettingAssignmentTests {
    @Test func aSettingIsGivenByTheNameItHasInTheDocument() throws {
        var adjustments = Adjustments()
        try AdjustmentParameter.apply("clarity=20", to: &adjustments)
        try AdjustmentParameter.apply(" exposure = -0.5 ", to: &adjustments)
        try AdjustmentParameter.apply("sharpness=35", to: &adjustments)
        #expect(adjustments.clarity == 20 && adjustments.exposure == -0.5 && adjustments.sharpness == 35)
    }

    /// Every slider there is, and every one there will be: no list to keep up by hand.
    @Test(arguments: AdjustmentParameter.all)
    func everyParameterCanBeSet(parameter: AdjustmentParameter) throws {
        var adjustments = Adjustments()
        try AdjustmentParameter.apply("\(parameter.name)=\(parameter.range.upperBound)", to: &adjustments)
        #expect(parameter.value(in: adjustments) == parameter.range.upperBound)
    }

    @Test func anUnknownNameSaysWhichNamesExist() {
        var adjustments = Adjustments()
        #expect { try AdjustmentParameter.apply("clarty=20", to: &adjustments) } throws: { error in
            guard case RawEngineError.invalidSetting(let text, let reason) = error else { return false }
            return text == "clarty=20" && reason.contains("clarity") && reason.contains("vignetting")
        }
        #expect(adjustments == Adjustments())
    }

    /// Told, not clamped in silence: somebody typing clarity=400 made a mistake.
    @Test(arguments: ["clarity=400", "glow=-1", "exposure=11", "clarity=abc", "clarity=", "clarity", "=20", "clarity=nan", "clarity=inf"])
    func aValueThatMakesNoSenseIsRefused(assignment: String) {
        var adjustments = Adjustments()
        #expect(throws: RawEngineError.self) { try AdjustmentParameter.apply(assignment, to: &adjustments) }
        #expect(adjustments == Adjustments())
    }

    /// A script may ask for more than a slider offers, within what a document may hold.
    @Test func exposureGoesBeyondTheSliderUpToWhatADocumentHolds() throws {
        var adjustments = Adjustments()
        try AdjustmentParameter.apply("exposure=8", to: &adjustments)
        #expect(adjustments.exposure == 8)
    }
}

@Suite struct DisplayableTextTests {
    /// File names come from memory cards: control characters in one can rewrite what the
    /// terminal shows, or hide what the line really says.
    @Test func controlCharactersNeverReachTheTerminal() {
        #expect(FileName.displayable("R0001.DNG") == "R0001.DNG")
        #expect(FileName.displayable("Été 🏖.dng") == "Été 🏖.dng")
        #expect(FileName.displayable("a\u{1B}[2Jb\rc\nd\u{7}e\u{9B}f") == "a?[2Jb?c?d?e?f")
        #expect(FileName.displayable("photo\u{202E}gnd.exe") == "photo?gnd.exe")
        #expect(FileName.displayable("a\u{2028}b\u{2029}c") == "a?b?c")
    }
}

@Suite struct SafeFormattingTests {
    /// Values read from a file: a shutter speed of zero made `Int(1 / 0)`, which traps.
    @Test func numbersThatAreNotOnesDoNotCrash() {
        #expect(ExposureFormat.shutterSpeed(0) == "—")
        #expect(ExposureFormat.shutterSpeed(-1) == "—")
        #expect(ExposureFormat.shutterSpeed(.nan) == "—")
        #expect(ExposureFormat.shutterSpeed(.infinity) == "—")
        #expect(ExposureFormat.shutterSpeed(1e-320) == "—")
        #expect(ExposureFormat.shutterSpeed(1.0 / 250) == "1/250 s")
        #expect(ExposureFormat.shutterSpeed(2, locale: Locale(identifier: "en_US")) == "2 s")
    }

    @Test func dimensionsAndKelvinsDoNotCrashEither() {
        #expect(ExposureFormat.dimensions(CGSize(width: 6000, height: 4000)) == "6000 × 4000")
        #expect(ExposureFormat.dimensions(CGSize(width: 6000.4, height: 3999.6)) == "6000 × 4000")
        #expect(ExposureFormat.dimensions(CGSize(width: CGFloat.nan, height: 4000)) == "—")
        #expect(ExposureFormat.dimensions(CGSize(width: CGFloat.infinity, height: 4000)) == "—")
        #expect(ExposureFormat.dimensions(CGSize(width: 1e300, height: 4000)) == "—")
        #expect(ExposureFormat.kelvins(5204.7) == "5205 K")
        #expect(ExposureFormat.kelvins(.nan) == "—" && ExposureFormat.kelvins(.infinity) == "—")
    }
}

@Suite struct ResolvingPresetsTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-resolve-\(UUID().uuidString)")
    let builtIn = Preset(name: "Web", capturing: AdjustmentGroupTests.edited, groups: [.light])

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var store: JSONFileStore<Preset> { JSONFileStore(directory: directory.appendingPathComponent("store"), builtIns: [builtIn]) }

    /// A file called "Web" lying in the current folder must not be read in place of the look
    /// the user named.
    @Test func aNameIsANameEvenIfAFileIsCalledTheSame() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let decoy = directory.appendingPathComponent("Web")
        try Data(#"{"contrast": 99}"#.utf8).write(to: decoy)
        let previous = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(previous) }
        FileManager.default.changeCurrentDirectoryPath(directory.path)
        #expect(try store.resolve("Web") == builtIn)
        #expect(try store.resolve("web") == builtIn)
    }

    @Test func whatLooksLikeAPathIsAPath() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mine.json")
        try Data(#"{"contrast": 30}"#.utf8).write(to: file)
        #expect(try store.resolve(file.path).adjustments.contrast == 30)
        #expect(try store.resolve(file.path).name == "mine")
        // With a separator or the extension, never a name: a missing file is said to be missing.
        #expect(throws: (any Error).self) { try store.resolve(directory.appendingPathComponent("absent.json").path) }
        #expect(throws: (any Error).self) { try store.resolve("./Web") }
    }

    @Test func anUnknownNameListsWhatExists() {
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: RawEngineError.unknownPreset("Nope", available: ["Web"])) { try store.resolve("Nope") }
    }
}

@Suite struct AutoEntryPointTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-auto-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// One way in, so that the app and the command line analyze the same picture at the same
    /// scale and come to the same settings.
    @Test func autoForAPhotoIsAutoOnItsNeutralRenderingAtOneScale() throws {
        MemoryFuse.arm()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("sample.png")
        try HostileDocumentRenderingTests.writeSample(to: file)
        let source = try RawSource(url: file)

        let scale = AutoTone.analysisScale(for: source.info.imageSize)
        let expected = AutoTone.settings(for: try ToneAnalyzer().statistics(of: source.image(scaleFactor: scale)))
        #expect(try AutoTone.settings(for: source) == expected)
        // The picture is smaller than what is analyzed: taken as it is, never scaled up.
        #expect(scale == 1)
        #expect(AutoTone.analysisScale(for: CGSize(width: 6000, height: 4000)) == Float(AutoTone.analysisSide / 6000))
    }
}
