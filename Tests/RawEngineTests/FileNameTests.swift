import Foundation
import Testing
@testable import RawEngine

@Suite struct FileNameTests {
    @Test func aPlainNameIsLeftAlone() {
        #expect(FileName.sanitized("R0007010-web", fallback: "x") == "R0007010-web")
        #expect(FileName.sanitized("Été à la plage 🏖", fallback: "x") == "Été à la plage 🏖")
    }

    @Test func separatorsAndControlCharactersAreReplaced() {
        #expect(FileName.sanitized("a/b:c", fallback: "x") == "a-b-c")
        #expect(FileName.sanitized("a\u{0}b\nc\u{7F}d\u{85}e\u{1B}[2J", fallback: "x") == "a-b-c-d-e-[2J")
    }

    /// A slash followed by a combining mark is one `Character`, which is not "/": compared by
    /// character it stayed in the name, and the file system saw a separator.
    @Test func aSeparatorHiddenInAGraphemeClusterIsStillReplaced() {
        let sanitized = FileName.sanitized("a/\u{0301}b", fallback: "x")
        #expect(!sanitized.unicodeScalars.contains("/"))
        // Scalar by scalar: the dash and the mark that follows it are one `Character`.
        #expect(Array(sanitized.unicodeScalars) == ["a", "-", "\u{0301}", "b"])
    }

    @Test func leadingDotsGo() {
        #expect(FileName.sanitized(".hidden", fallback: "x") == "hidden")
        #expect(FileName.sanitized("...name.v2", fallback: "x") == "name.v2")
    }

    @Test(arguments: ["", ".", "..", "   ", "/", "../..", "\u{0}"])
    func whatIsNoNameAtAllFallsBack(name: String) {
        let sanitized = FileName.sanitized(name, fallback: "R0001")
        #expect(!sanitized.isEmpty && sanitized != "." && sanitized != "..")
        #expect(!sanitized.unicodeScalars.contains("/"))
        if name.unicodeScalars.allSatisfy({ " ./\u{0}".unicodeScalars.contains($0) }) && !name.contains("/") {
            #expect(sanitized == "R0001")
        }
    }

    /// Path segments cannot survive: no separator is left to make them mean anything.
    @Test func parentSegmentsAreDefused() {
        let sanitized = FileName.sanitized("../../etc/passwd", fallback: "x")
        #expect(sanitized == "-..-etc-passwd")
        #expect(URL(fileURLWithPath: "/out").appendingPathComponent(sanitized).standardizedFileURL.path.hasPrefix("/out/"))
    }

    @Test func containmentIsAboutTheFolderNotAboutHowItsPathIsSpelled() {
        let folder = URL(fileURLWithPath: "/private/tmp")
        #expect(FileName.isContained(folder.appendingPathComponent("not-there-\(UUID().uuidString).jpg"), in: folder))
        #expect(!FileName.isContained(folder.appendingPathComponent("../x.jpg"), in: folder))
        #expect(!FileName.isContained(folder.appendingPathComponent("a/../../x.jpg"), in: folder))
        #expect(!FileName.isContained(folder.appendingPathComponent(".."), in: folder))
        #expect(!FileName.isContained(URL(fileURLWithPath: "/etc/passwd"), in: folder))
    }

    @Test func aHostileFallbackIsSanitizedToo() {
        #expect(FileName.sanitized("", fallback: "../x") == "-x")
        #expect(FileName.sanitized("", fallback: "..") == FileName.lastResort)
    }

    @Test func aLongNameIsCutToWhatAFileSystemTakesWithoutSplittingACharacter() {
        let long = String(repeating: "é", count: 300)
        let sanitized = FileName.sanitized(long, fallback: "x")
        // The file system is handed the decomposed name, where "é" weighs three bytes.
        #expect((253...255).contains(FileName.fileSystemBytes(sanitized)))
        #expect(sanitized.allSatisfy { $0 == "é" })
        // Room left for an extension and a "-12" suffix.
        #expect(FileName.fileSystemBytes(FileName.sanitized(long, fallback: "x", reserving: 10)) <= 245)
        #expect(FileName.sanitized(String(repeating: "n", count: 300), fallback: "x").count == 255)
        let family = String(repeating: "👨‍👩‍👧‍👦", count: 40)
        #expect(FileName.sanitized(family, fallback: "x").allSatisfy { $0 == "👨‍👩‍👧‍👦" })
    }
}

@Suite struct ExportDestinationTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-destination-\(UUID().uuidString)").standardizedFileURL
    let source = URL(fileURLWithPath: "/photos/R0007010.DNG")

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func preset(_ template: String) -> ExportPreset {
        var preset = ExportPreset(name: "Hostile")
        preset.fileNameTemplate = template
        return preset
    }

    /// A template comes from a JSON file that photographers pass around.
    @Test(arguments: ["../../{name}", "/tmp/{name}", "{name}/../../x", "..", "a/b/c", "\u{0}{name}"])
    func aTemplateCannotLeaveTheFolder(template: String) {
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = preset(template).destination(for: source, in: folder).standardizedFileURL
        #expect(destination.deletingLastPathComponent().path == folder.path)
        #expect(destination.pathExtension == "jpg")
    }

    @Test func anEmptyTemplateFallsBackToTheNameOfTheSource() {
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(preset("").fileName(for: source) == "R0007010.jpg")
        #expect(preset("..").fileName(for: source) == "R0007010.jpg")
    }

    @Test func aHostileSourceNameIsSanitizedToo() {
        defer { try? FileManager.default.removeItem(at: folder) }
        let hostile = URL(fileURLWithPath: "/photos").appendingPathComponent("a:b\nc.DNG")
        #expect(preset("{name}-web").fileName(for: hostile) == "a-b-c-web.jpg")
    }

    @Test func aVeryLongNameStillGetsItsExtensionAndItsNumber() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let preset = preset(String(repeating: "n", count: 300))
        let first = preset.destination(for: source, in: folder)
        #expect(first.lastPathComponent.utf8.count <= 255 && first.pathExtension == "jpg")
        try Data().write(to: first)
        let second = preset.destination(for: source, in: folder)
        #expect(second != first && second.lastPathComponent.utf8.count <= 255 && second.lastPathComponent.hasSuffix("-2.jpg"))
    }

    /// Found on a real export to /private/tmp: `standardizedFileURL` drops "/private" from a
    /// path that exists (the folder) and keeps it on one that does not yet (the file), so the
    /// file looked like it sat elsewhere, and every export was called "Untitled".
    @Test func aFolderReachedThroughAnotherPathKeepsTheNamesOfItsFiles() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = folder.resolvingSymlinksInPath().path
        let spelled = URL(fileURLWithPath: real.hasPrefix("/private") ? real : "/private" + real)
        #expect(FileManager.default.fileExists(atPath: spelled.path))
        #expect(preset("{name}-web").destination(for: source, in: spelled).lastPathComponent == "R0007010-web.jpg")

        let link = folder.appendingPathComponent("link")
        let target = folder.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(preset("{name}-web").destination(for: source, in: link).lastPathComponent == "R0007010-web.jpg")
        // And a folder that does not exist yet, which a batch creates.
        let later = folder.appendingPathComponent("not/yet/there")
        #expect(preset("{name}-web").destination(for: source, in: later).lastPathComponent == "R0007010-web.jpg")
    }

    /// Two photos of the same name, from two days, exported together: two files.
    @Test func twoSourcesOfTheSameNameGiveTwoFiles() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = ExportPreset(name: "Full").destination(for: URL(fileURLWithPath: "/day1/R0000357.DNG"), in: folder)
        try Data().write(to: first)
        let second = ExportPreset(name: "Full").destination(for: URL(fileURLWithPath: "/day2/R0000357.DNG"), in: folder)
        #expect(first.lastPathComponent == "R0000357.jpg" && second.lastPathComponent == "R0000357-2.jpg")
    }
}

@Suite struct JSONFileStoreSafetyTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-store-safety-\(UUID().uuidString)").standardizedFileURL

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var store: JSONFileStore<Preset> { JSONFileStore(directory: directory) }

    private func look(_ name: String, contrast: Double = 0) -> Preset {
        var adjustments = Adjustments()
        adjustments.contrast = contrast
        return Preset(name: name, capturing: adjustments, groups: [.light])
    }

    private var files: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    @Test(arguments: ["../escaped", "..", ".", "", ".hidden", "a\u{0}b", "a/\u{0301}b", String(repeating: "é", count: 300)])
    func whateverTheNameTheFileStaysInTheFolderAndTheNameSurvives(name: String) throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save(look(name, contrast: 12))
        let entry = try #require(store.entries().first)
        #expect(entry.item.name == name && entry.item.adjustments.contrast == 12)
        let file = try #require(entry.url).standardizedFileURL
        #expect(file.deletingLastPathComponent().path == directory.path)
        #expect(!file.lastPathComponent.hasPrefix(".") && file.lastPathComponent.utf8.count <= 255)
        #expect(files.count == 1)
    }

    /// "a/b", "a:b" and "a-b" all wanted the same file: the last one saved wiped the others.
    @Test func namesThatWantTheSameFileDoNotReplaceOneAnother() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, name) in ["a/b", "a:b", "a-b"].enumerated() { try store.save(look(name, contrast: Double(index + 1))) }
        #expect(store.all().map(\.name).sorted() == ["a-b", "a/b", "a:b"])
        #expect(Set(store.all().map(\.adjustments.contrast)) == [1, 2, 3])
        // Saving one of them again updates it, and only it.
        try store.save(look("a:b", contrast: 20))
        #expect(store.all().count == 3 && store.all().first { $0.name == "a:b" }?.adjustments.contrast == 20)
    }

    /// On a case-insensitive volume "Look" and "look" are one file: they are one item.
    @Test func namesThatDifferByCaseAreOneItem() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save(look("Look", contrast: 1))
        try store.save(look("look", contrast: 2))
        #expect(store.all().map(\.name) == ["look"] && store.all().first?.adjustments.contrast == 2)
        #expect(files.count == 1)
    }

    /// A file dropped in by hand, whose name inside differs from the file's.
    @Test func deletingRemovesTheFileTheItemCameFrom() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try look("Inside name").encoded().write(to: directory.appendingPathComponent("outside name.json"))
        try store.save(look("Bystander"))
        #expect(store.all().map(\.name) == ["Bystander", "Inside name"])
        try store.delete(named: "Inside name")
        #expect(store.all().map(\.name) == ["Bystander"])
        #expect(files == ["Bystander.json"])
    }

    /// Two files carrying the same name gave two items of the same id.
    @Test func twoFilesOfTheSameNameAreOneItemTheMostRecent() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let (older, newer) = (directory.appendingPathComponent("first.json"), directory.appendingPathComponent("second.json"))
        try look("Twin", contrast: 1).encoded().write(to: older)
        try look("Twin", contrast: 2).encoded().write(to: newer)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: older.path)
        #expect(store.all().map(\.name) == ["Twin"] && store.all().first?.adjustments.contrast == 2)
        // Saving updates the file in use; deleting leaves no twin behind to come back.
        try store.save(look("Twin", contrast: 3))
        #expect(store.all().first?.adjustments.contrast == 3)
        try store.delete(named: "Twin")
        #expect(store.all().isEmpty && files.isEmpty)
    }

    /// `isBuiltIn(_:)` costs one look at the file system, so that a view may ask; `entries()`
    /// reads the folder and knows about a file dropped in under another name.
    @Test func entriesSayExactlyWhatIsBuiltIn() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONFileStore(directory: directory, builtIns: [look("Camera match")])
        #expect(store.isBuiltIn("Camera match") && store.entries().first?.isBuiltIn == true)
        try look("Camera match", contrast: 5).encoded().write(to: directory.appendingPathComponent("my version.json"))
        #expect(store.all().count == 1 && store.entries().first?.isBuiltIn == false)
        try store.delete(named: "Camera match")
        #expect(store.entries().first?.isBuiltIn == true && store.all().first?.adjustments.contrast == 0)

        try store.save(look("camera MATCH", contrast: 7))
        #expect(!store.isBuiltIn("Camera match") && store.all().map(\.name) == ["camera MATCH"])
    }
}
