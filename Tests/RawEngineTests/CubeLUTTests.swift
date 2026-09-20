import CoreImage
import Foundation
import simd
import Testing
import TestSupport
@testable import RawEngine

/// The text of a `.cube` file whose entry for (r, g, b) is `color(r, g, b)`. Red varies fastest.
func cubeText(size: Int, title: String? = "Test", _ color: (Float, Float, Float) -> SIMD3<Float> = { SIMD3($0, $1, $2) }) -> String {
    var lines = ["# made for a test"]
    if let title { lines.append("TITLE \"\(title)\"") }
    lines.append("LUT_3D_SIZE \(size)")
    let scale = 1 / Float(size - 1)
    for b in 0..<size { for g in 0..<size { for r in 0..<size {
        let c = color(Float(r) * scale, Float(g) * scale, Float(b) * scale)
        lines.append("\(c.x) \(c.y) \(c.z)")
    } } }
    return lines.joined(separator: "\n") + "\n"
}

@Suite struct CubeLUTParsingTests {
    private func parse(_ text: String) throws -> CubeLUT { try CubeLUT(parsing: Data(text.utf8)) }

    @Test func readsSizeTitleAndEntries() throws {
        let lut = try parse(cubeText(size: 4, title: "Teal & orange"))
        #expect(lut.size == 4 && lut.title == "Teal & orange" && lut.entries.count == 64)
        // Red varies fastest: the second entry is one step of red.
        #expect(lut.entries[1] == SIMD3(1.0 / 3, 0, 0) && lut.entries[4] == SIMD3(0, 1.0 / 3, 0))
    }

    @Test func toleratesWhatEditorsWrite() throws {
        let text = "\u{FEFF}# comment\r\n\r\nTITLE \"x\"\r\nDOMAIN_MIN 0.0 0.0 0.0\r\nDOMAIN_MAX 1.0 1.0 1.0\r\nLUT_3D_SIZE 2\r\n"
            + (0..<8).map { _ in "0.5\t0.25   1e-1\r\n" }.joined()
        let lut = try parse(text)
        #expect(lut.size == 2 && lut.entries.allSatisfy { $0 == SIMD3(0.5, 0.25, 0.1) })
    }

    @Test(arguments: [1, 0, -4, 66, 1000, 100_000_000])
    func aSizeOutOfBoundsIsRefused(size: Int) {
        #expect(throws: CubeLUT.ParsingError.self) { try parse("LUT_3D_SIZE \(size)\n0 0 0\n") }
    }

    @Test func sizesFromTwoToSixtyFiveAreAccepted() throws {
        #expect(try parse(cubeText(size: 2)).size == 2)
        #expect(try parse(cubeText(size: 65)).entries.count == 65 * 65 * 65)
    }

    /// Exactly N³ entries: a file cut short or padded is not the LUT it claims to be.
    @Test func theNumberOfEntriesMustBeExact() {
        let good = cubeText(size: 3)
        #expect(throws: CubeLUT.ParsingError.wrongEntryCount(expected: 27, found: 26)) { try parse(good.split(separator: "\n").dropLast().joined(separator: "\n")) }
        #expect(throws: CubeLUT.ParsingError.wrongEntryCount(expected: 27, found: 28)) { try parse(good + "0 0 0\n") }
        #expect(throws: CubeLUT.ParsingError.self) { try parse("0 0 0\n0 0 0\n") }
    }

    @Test(arguments: ["nan 0 0", "0 inf 0", "0 0 -infinity", "0 0", "0 0 0 0", "a b c", "0x10 0 0", "1e400 0 0"])
    func anEntryThatIsNotThreeNumbersIsRefused(entry: String) {
        let text = "LUT_3D_SIZE 2\n" + Array(repeating: "0 0 0", count: 7).joined(separator: "\n") + "\n\(entry)\n"
        #expect(throws: CubeLUT.ParsingError.self) { try parse(text) }
    }

    @Test func valuesAreBroughtBackToTheDisplayRange() throws {
        let lut = try parse("LUT_3D_SIZE 2\n" + Array(repeating: "-3 0.5 1e30", count: 8).joined(separator: "\n"))
        #expect(lut.entries.allSatisfy { $0 == SIMD3(0, 0.5, 1) })
    }

    @Test(arguments: ["LUT_1D_SIZE 16", "DOMAIN_MIN -1 0 0", "DOMAIN_MAX 2 2 2", "LUT_3D_INPUT_RANGE 0 4", "LUT_3D_SIZE 2\nLUT_3D_SIZE 3", "SOMETHING_ELSE 1"])
    func whatTheEngineDoesNotSupportIsSaidNotGuessed(line: String) {
        #expect(throws: CubeLUT.ParsingError.self) { try parse(line + "\n" + cubeText(size: 2, title: nil)) }
    }

    @Test func aFileTooLargeIsRefusedBeforeBeingRead() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-lut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("huge.cube")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(CubeLUT.maximumFileSize) + 1)   // sparse: costs nothing
        try handle.close()
        #expect(throws: RawEngineError.fileTooLarge(file, limit: CubeLUT.maximumFileSize)) { try CubeLUT(contentsOf: file) }
        #expect(CubeLUT.maximumFileSize == 32 * 1024 * 1024)
    }
}

@Suite struct CubeLUTSamplingTests {
    @Test func theIdentityLeavesColorsAlone() throws {
        let lut = try CubeLUT(parsing: Data(cubeText(size: 5).utf8))
        for color in [SIMD3<Float>(0, 0, 0), SIMD3(1, 1, 1), SIMD3(0.2, 0.55, 0.9), SIMD3(0.125, 0.125, 0.125)] {
            #expect(simd_length(lut.sample(color) - color) < 1e-5)
        }
    }

    /// Between nodes, a straight blend of the eight around: what makes 5 nodes enough for a
    /// smooth look, and lets a LUT of 65 be resampled.
    @Test func interpolatesBetweenNodes() throws {
        let lut = try CubeLUT(parsing: Data(cubeText(size: 3) { r, g, b in SIMD3(r * r, g, 1 - b) }.utf8))
        #expect(simd_length(lut.sample(SIMD3(0.5, 0.5, 0.5)) - SIMD3(0.25, 0.5, 0.5)) < 1e-5)
        #expect(simd_length(lut.sample(SIMD3(0.25, 1, 0)) - SIMD3(0.125, 1, 1)) < 1e-5)
        // Out of range colors are read at the edge of the cube.
        #expect(lut.sample(SIMD3(-1, 2, 0.5)) == lut.sample(SIMD3(0, 1, 0.5)))
    }

    @Test func theAmountFadesTheLookIn() throws {
        let lut = try CubeLUT(parsing: Data(cubeText(size: 3) { _, _, _ in SIMD3(1, 0, 0) }.utf8))
        let gray = SIMD3<Float>(0.4, 0.4, 0.4)
        #expect(lut.sample(gray, amount: 0) == gray && lut.sample(gray, amount: 1) == SIMD3(1, 0, 0))
        #expect(simd_length(lut.sample(gray, amount: 0.5) - SIMD3(0.7, 0.2, 0.2)) < 1e-5)
    }
}

@Suite struct LUTLibraryAndStageTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-luts-\(UUID().uuidString)")
    let probe = PixelProbe()

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Swaps red and blue: easy to tell on a swatch.
        try Data(cubeText(size: 9) { r, g, b in SIMD3(b, g, r) }.utf8).write(to: folder.appendingPathComponent("Swap.cube"))
        try Data("not a LUT".utf8).write(to: folder.appendingPathComponent("Broken.cube"))
        try Data(cubeText(size: 2).utf8).write(to: folder.appendingPathComponent("notes.txt"))
    }

    @Test func listsTheLUTsOfItsFolderAndFindsThemByName() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LUTLibrary(directory: folder)
        #expect(library.names() == ["Broken", "Swap"])
        #expect(try library.lut(named: "Swap").size == 9)
        #expect(throws: CubeLUT.ParsingError.self) { try library.lut(named: "Broken") }
        #expect(throws: RawEngineError.unknownLUT("Missing")) { try library.lut(named: "Missing") }
        #expect(LUTLibrary(directory: folder.appendingPathComponent("nowhere")).names().isEmpty)
    }

    /// The name comes from a settings document: it never leads out of the folder.
    @Test(arguments: ["../Swap", "/etc/passwd", "..", "a/../../Swap", ""])
    func aNameCannotLeaveTheFolder(name: String) throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let inside = folder.appendingPathComponent("inside")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try LUTLibrary(directory: inside).lut(named: name) }
        #expect(FileName.isContained(LUTLibrary(directory: inside).url(for: name), in: inside))
    }

    private func develop(_ swatch: CIImage, _ setting: LUTSetting?) throws -> PixelProbe.Pixel {
        var adjustments = Adjustments()
        adjustments.lut = setting
        return try probe.average(of: LUTStage(library: LUTLibrary(directory: folder)).apply(adjustments, to: swatch))
    }

    @Test func theStageAppliesTheLookAndItsAmount() throws {
        MemoryFuse.arm()
        defer { try? FileManager.default.removeItem(at: folder) }
        let warm = PixelProbe.swatch(r: 0.6, g: 0.3, b: 0.05)
        let full = try develop(warm, LUTSetting(name: "Swap"))
        #expect(abs(full.r - 0.05) < 0.02 && abs(full.b - 0.6) < 0.03 && abs(full.g - 0.3) < 0.02)
        let half = try develop(warm, LUTSetting(name: "Swap", amount: 50))
        #expect(half.r < 0.6 - 0.1 && half.r > 0.05 + 0.1 && half.b > 0.05 + 0.1)
    }

    @Test func noLUTNoAmountOrAMissingFileLeaveThePictureAlone() throws {
        MemoryFuse.arm()
        defer { try? FileManager.default.removeItem(at: folder) }
        let warm = PixelProbe.swatch(r: 0.6, g: 0.3, b: 0.05)
        let stage = LUTStage(library: LUTLibrary(directory: folder))
        var adjustments = Adjustments()
        #expect(stage.apply(adjustments, to: warm) === warm)
        for setting in [LUTSetting(name: "Swap", amount: 0), LUTSetting(name: "Missing"), LUTSetting(name: "Broken")] {
            adjustments.lut = setting
            #expect(stage.apply(adjustments, to: warm) === warm, "\(setting)")
        }
    }

    @Test func theDocumentNamesTheLUTAndDoesNotCarryIt() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        var adjustments = Adjustments()
        adjustments.lut = LUTSetting(name: "Swap", amount: 60)
        let json = try adjustments.jsonData()
        #expect(json.count < 4000)
        #expect(try JSONDecoder().decode(Adjustments.self, from: json) == adjustments)
        let partial = try JSONDecoder().decode(Adjustments.self, from: Data(#"{"lut": {"name": "Swap"}}"#.utf8))
        #expect(partial.lut == LUTSetting(name: "Swap", amount: 100))
        let hostile = try JSONDecoder().decode(Adjustments.self, from: Data(#"{"lut": {"name": "x", "amount": 1e308}}"#.utf8))
        #expect(hostile.lut?.amount == 100)
        #expect(DevelopPipeline.standard.stages.contains { $0 is LUTStage })
    }
}
