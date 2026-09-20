import Foundation
import RawEngine
import TestSupport
import Testing
@testable import Catalog

/// A library and a fake memory card in a throwaway folder. Files are a few bytes long, and
/// their metadata comes from a stub: import logic is tested without decoding a single RAW.
struct ImportSandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-import-\(UUID().uuidString)")
    var card: URL { root.appendingPathComponent("card/DCIM/100RICOH") }
    let library: Library

    init() throws {
        library = try Library(root: root.appendingPathComponent("library"))
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
    }

    @discardableResult
    func addFile(_ name: String, content: String, in folder: URL? = nil) throws -> URL {
        let file = (folder ?? card).appendingPathComponent(name)
        try Data(content.utf8).write(to: file)
        return file
    }

    /// Every file was shot on 2026-09-11, unless its name says "undated".
    func importer() -> Importer {
        Importer(library: library) { url in
            FileMetadata(
                captureDate: url.lastPathComponent.contains("undated") ? nil : ISO8601DateFormatter.catalog.date(from: "2026-09-11T11:14:40"),
                camera: "RICOH GR III", lens: nil, iso: 100, exposureTime: 0.002, aperture: 7.1, focalLength: 18.3,
                width: 6000, height: 4000
            )
        }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct ImporterTests {
    let sandbox: ImportSandbox

    init() throws {
        sandbox = try ImportSandbox()
    }

    /// RAW files, and the rendered formats a photo library is also made of. Nothing else.
    @Test func findsPhotosWhereverTheyAreOnTheCard() throws {
        defer { sandbox.cleanUp() }
        try sandbox.addFile("R0002.DNG", content: "b")
        try sandbox.addFile("R0001.dng", content: "a")
        try sandbox.addFile("R0001.JPG", content: "jpeg")
        try sandbox.addFile("IMG_0003.HEIC", content: "heic")
        try sandbox.addFile("scan.tif", content: "tiff")
        try sandbox.addFile("notes.txt", content: "text")
        try sandbox.addFile("clip.mov", content: "video")
        try sandbox.addFile(".hidden.DNG", content: "x")
        let found = Importer.scan(sandbox.root.appendingPathComponent("card"))
        #expect(found.map(\.lastPathComponent) == ["IMG_0003.HEIC", "R0001.dng", "R0001.JPG", "R0002.DNG", "scan.tif"])
    }

    @Test func filesAreCopiedIntoDatedFoldersAndCatalogued() throws {
        defer { sandbox.cleanUp() }
        let file = try sandbox.addFile("R0001.DNG", content: "a")
        let summary = sandbox.importer().run([file])

        #expect(summary.imported.count == 1 && summary.duplicates.isEmpty && summary.failures.isEmpty)
        let photo = try #require(try sandbox.library.catalog.photo(summary.imported[0]))
        #expect(photo.relativePath == "Originals/2026/2026-09-11/R0001.DNG")
        #expect(try String(contentsOf: sandbox.library.url(for: photo), encoding: .utf8) == "a")
        #expect(photo.camera == "RICOH GR III" && photo.width == 6000)
        // The card is left as it was: importing copies, it never moves.
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aFileAlreadyInTheLibraryIsSkipped() throws {
        defer { sandbox.cleanUp() }
        let file = try sandbox.addFile("R0001.DNG", content: "same bytes")
        let renamed = try sandbox.addFile("COPY.DNG", content: "same bytes")
        let first = sandbox.importer().run([file])
        let second = sandbox.importer().run([file, renamed])
        #expect(first.imported.count == 1)
        #expect(second.imported.isEmpty && second.duplicates.count == 2)
        #expect(try sandbox.library.catalog.count(matching: PhotoFilter()) == 1)
    }

    @Test func twoDifferentFilesWithTheSameNameBothGetIn() throws {
        defer { sandbox.cleanUp() }
        let other = sandbox.root.appendingPathComponent("card/DCIM/101RICOH")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let first = try sandbox.addFile("R0001.DNG", content: "one")
        let second = try sandbox.addFile("R0001.DNG", content: "two", in: other)
        let summary = sandbox.importer().run([first, second])
        let paths = try summary.imported.map { try sandbox.library.catalog.photo($0)?.relativePath }
        #expect(paths == ["Originals/2026/2026-09-11/R0001.DNG", "Originals/2026/2026-09-11/R0001-2.DNG"])
    }

    @Test func filesWithoutADateGoToTheirOwnFolder() throws {
        defer { sandbox.cleanUp() }
        let file = try sandbox.addFile("undated.DNG", content: "u")
        let summary = sandbox.importer().run([file])
        #expect(try sandbox.library.catalog.photo(summary.imported[0])?.relativePath == "Originals/Undated/undated.DNG")
    }

    @Test func oneBadFileDoesNotStopTheImport() throws {
        defer { sandbox.cleanUp() }
        let good = try sandbox.addFile("R0001.DNG", content: "a")
        let missing = sandbox.card.appendingPathComponent("gone.DNG")
        var reported: [String] = []
        let summary = sandbox.importer().run([missing, good]) { reported.append($0.lastPathComponent) }
        #expect(summary.imported.count == 1 && summary.failures.map(\.file.lastPathComponent) == ["gone.DNG"])
        #expect(reported == ["gone.DNG", "R0001.DNG"])
    }

    @Test func anImportPresetAppliesItsLookKeywordsSignatureAndNaming() throws {
        defer { sandbox.cleanUp() }
        var look = Adjustments()
        look.contrast = 15
        var preset = ImportPreset(name: "Street")
        preset.look = Preset(name: "Look", capturing: look, groups: [.light])
        preset.keywords = ["street"]
        preset.author = "Yoan Bernabeu"
        preset.copyright = "© 2026 Yoan Bernabeu"
        preset.fileNameTemplate = "{date}_{name}"

        let file = try sandbox.addFile("R0001.DNG", content: "a")
        let summary = sandbox.importer().run([file], preset: preset)
        let photo = try #require(try sandbox.library.catalog.photo(summary.imported[0]))
        #expect(photo.fileName == "20260911-111440_R0001.DNG")
        #expect(photo.adjustments.contrast == 15 && photo.isEdited)
        #expect(try sandbox.library.catalog.keywords(for: photo.id) == ["street"])
        // Signed on the way in: every photo of every card carries it, without a second pass.
        #expect(photo.credits.author == "Yoan Bernabeu" && photo.credits.copyright == "© 2026 Yoan Bernabeu")
        // A title is never given to a photo that has not been looked at.
        #expect(photo.credits.title == nil)
    }

    /// A preset that signs nothing writes nothing: an unsigned import leaves the columns empty
    /// rather than filling them with blanks.
    @Test func aPresetWithoutASignatureLeavesTheColumnsEmpty() throws {
        defer { sandbox.cleanUp() }
        var preset = ImportPreset(name: "Plain")
        preset.author = "   "
        let file = try sandbox.addFile("R0001.DNG", content: "a")
        let summary = sandbox.importer().run([file], preset: preset)
        #expect(try sandbox.library.catalog.credits(for: summary.imported[0]) == PhotoCredits())
    }

    /// Regression: the row was added first, so a failure while applying the import preset
    /// left a photo in the catalog with no file behind it.
    @Test func aFailureWhileApplyingThePresetLeavesNothingBehind() throws {
        defer { sandbox.cleanUp() }
        let file = try sandbox.addFile("R0001.DNG", content: "a")
        var preset = ImportPreset(name: "Broken")
        // A keyword SQLite cannot store as text makes the last step of the import fail.
        preset.keywords = [String(repeating: "k", count: 10)]
        try sandbox.library.catalog.database.execute("CREATE TRIGGER refuse_keywords BEFORE INSERT ON keywords BEGIN SELECT RAISE(ABORT, 'refused'); END")

        let summary = sandbox.importer().run([file], preset: preset)
        #expect(summary.imported.isEmpty && summary.failures.count == 1)
        #expect(try sandbox.library.catalog.count(matching: PhotoFilter()) == 0)
        #expect(!FileManager.default.fileExists(atPath: sandbox.library.originals.appendingPathComponent("2026/2026-09-11/R0001.DNG").path))
    }

    /// Everything under the library that is not the catalog itself.
    private func filesInTheLibrary() -> [String] {
        let enumerator = FileManager.default.enumerator(at: sandbox.library.root, includingPropertiesForKeys: [.isRegularFileKey])
        return (enumerator?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && !$0.lastPathComponent.hasPrefix("catalog.sqlite") }
            .map(\.lastPathComponent)
    }

    /// The disk fills up half way through: the half that was written must not stay.
    @Test func aFailedCopyLeavesNoTraceInTheCatalog() throws {
        defer { sandbox.cleanUp() }
        struct DiskFull: Error {}
        let file = try sandbox.addFile("R0001.DNG", content: "a file that does not make it")
        let importer = Importer(library: sandbox.library, metadata: { _ in throw RawEngineError.analysisFailed }) { source, destination in
            try Data("a file that".utf8).write(to: destination)
            throw DiskFull()
        }
        let summary = importer.run([file])
        #expect(summary.failures.count == 1 && summary.failures[0].error is DiskFull)
        #expect(try sandbox.library.catalog.count(matching: PhotoFilter()) == 0)
        #expect(filesInTheLibrary().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sandbox.library.root.appendingPathComponent(Importer.stagingFolder).path))
    }

    @Test func aFileTheEngineCannotReadLeavesNothingBehind() throws {
        defer { sandbox.cleanUp() }
        let file = try sandbox.addFile("R0001.DNG", content: "a")
        let broken = Importer(library: sandbox.library) { _ in throw RawEngineError.analysisFailed }
        let summary = broken.run([file])
        #expect(summary.failures.count == 1)
        #expect(try sandbox.library.catalog.count(matching: PhotoFilter()) == 0)
        #expect(filesInTheLibrary().isEmpty)
    }

    @Test func aCopyThatCannotReachItsFolderLeavesNothingBehind() throws {
        defer { sandbox.cleanUp() }
        let folder = sandbox.library.originals.appendingPathComponent("2026/2026-09-11")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let summary = sandbox.importer().run([try sandbox.addFile("R0001.DNG", content: "a")])
        #expect(summary.failures.count == 1 && summary.imported.isEmpty)
        #expect(try sandbox.library.catalog.count(matching: PhotoFilter()) == 0)
        #expect(filesInTheLibrary().isEmpty)
    }

    /// The card is read once, and may be pulled out right after: the fingerprint is that of
    /// the bytes the library holds, and the metadata is read from them, not from the card.
    @Test func theFingerprintAndTheMetadataAreThoseOfTheCopy() throws {
        defer { sandbox.cleanUp() }
        let file = try sandbox.addFile("R0001.DNG", content: "the original bytes")
        let root = sandbox.library.root.resolvingSymlinksInPath().path
        let importer = Importer(library: sandbox.library) { url in
            #expect(url.resolvingSymlinksInPath().path.hasPrefix(root + "/") && url.lastPathComponent == "R0001.DNG")
            // The card changes under our feet once the copy is made: too late to matter.
            try Data("rewritten".utf8).write(to: file)
            return FileMetadata(captureDate: nil, camera: nil, lens: nil, iso: nil, exposureTime: nil, aperture: nil, focalLength: nil, width: 1, height: 1)
        }
        let id = try #require(importer.run([file]).imported.first)
        let photo = try #require(try sandbox.library.catalog.photo(id))
        #expect(photo.contentHash == ContentHash.sha256(of: Data("the original bytes".utf8)))
        #expect(try ContentHash.sha256(of: sandbox.library.url(for: photo)) == photo.contentHash)
        #expect(filesInTheLibrary() == ["R0001.DNG"])
    }

    /// A link could point anywhere, and hashing would follow it where copying would not.
    @Test func whatIsNotARegularFileIsIgnored() throws {
        defer { sandbox.cleanUp() }
        let real = try sandbox.addFile("R0001.DNG", content: "a")
        let link = sandbox.card.appendingPathComponent("LINK.DNG")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let folder = sandbox.card.appendingPathComponent("FOLDER.DNG")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        #expect(Importer.scan(sandbox.card).map(\.lastPathComponent) == ["R0001.DNG"])
        let summary = sandbox.importer().run([link, folder, real])
        #expect(summary.imported.count == 1 && summary.failures.isEmpty)
        #expect(summary.ignored.map(\.lastPathComponent) == ["LINK.DNG", "FOLDER.DNG"])
    }

    /// "212 files ignored" is an answer; a card that seems to import half of itself is a worry.
    @Test func theSummarySaysHowManyFilesWereNotPhotos() throws {
        defer { sandbox.cleanUp() }
        try sandbox.addFile("R0001.DNG", content: "a")
        try sandbox.addFile("notes.txt", content: "text")
        try sandbox.addFile("clip.mov", content: "video")
        try sandbox.addFile(".hidden.txt", content: "x")
        let found = Importer.survey(sandbox.root.appendingPathComponent("card"))
        #expect(found.photos.map(\.lastPathComponent) == ["R0001.DNG"])
        #expect(found.ignored.map(\.lastPathComponent) == ["clip.mov", "notes.txt"])

        var reported = 0
        let summary = sandbox.importer().run(found) { _ in reported += 1 }
        #expect(summary.imported.count == 1 && summary.ignored.count == 2 && reported == 1)
    }
}

@Suite struct HashingCopyTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-copy-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @Test func copiesAndHashesInOnePass() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (source, destination) = (folder.appendingPathComponent("a"), folder.appendingPathComponent("b"))
        let content = Data((0..<10_000).map { UInt8($0 % 251) })
        try content.write(to: source)
        // Small chunks, so that the file takes several.
        #expect(try HashingCopy.copy(source, to: destination, chunkSize: 1024) == ContentHash.sha256(of: content))
        #expect(try Data(contentsOf: destination) == content)
        #expect(try ContentHash.sha256(of: destination) == ContentHash.sha256(of: content))
    }

    @Test func aCopyThatFailsHalfWayLeavesNoFile() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        struct DiskFull: Error {}
        let (source, destination) = (folder.appendingPathComponent("a"), folder.appendingPathComponent("b"))
        try Data(repeating: 7, count: 10_000).write(to: source)
        var chunks = 0
        #expect(throws: DiskFull.self) {
            try HashingCopy.copy(source, to: destination, chunkSize: 1024) { handle, chunk in
                chunks += 1
                if chunks == 3 { throw DiskFull() }
                try handle.write(contentsOf: chunk)
            }
        }
        #expect(chunks == 3 && !FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func neverFollowsALink() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (real, link) = (folder.appendingPathComponent("real"), folder.appendingPathComponent("link"))
        try Data("secret".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: ImportError.notARegularFile) { try HashingCopy.copy(link, to: folder.appendingPathComponent("b")) }
        #expect(throws: ImportError.notARegularFile) { try HashingCopy.copy(folder, to: folder.appendingPathComponent("c")) }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("b").path))
    }
}

@Suite struct ImportPresetTests {
    @Test func roundTripsThroughJSON() throws {
        var preset = ImportPreset(name: "Street")
        preset.keywords = ["street"]
        preset.fileNameTemplate = "{date}_{name}"
        preset.look = Preset.builtIns.first
        #expect(try ImportPreset.decode(from: preset.encoded(), fallbackName: "") == preset)
    }

    /// A look written by hand inside an import preset is read like a look file: the groups it
    /// means to change are those of the fields it mentions.
    @Test func aHandWrittenLookIsReadLikeALookFile() throws {
        let json = Data(#"{"name": "Street", "look": {"contrast": 20, "hsl": {"red": {"hue": 5}}}}"#.utf8)
        let look = try #require(try ImportPreset.decode(from: json, fallbackName: "").look)
        #expect(look.groups == [.light, .hsl])
        var adjustments = Adjustments()
        look.apply(to: &adjustments)
        #expect(adjustments.contrast == 20 && adjustments.hsl[.red].hue == 5)
    }

    /// Regression: the look went through an untyped JSON value whose `try?`s hid what was wrong.
    @Test func aLookThatIsWrongSaysWhere() throws {
        let json = Data(#"{"name": "Street", "look": {"name": "Hard", "adjustments": {"contrast": "a lot"}}}"#.utf8)
        do {
            _ = try ImportPreset.decode(from: json, fallbackName: "")
            Issue.record("should have thrown")
        } catch let DecodingError.typeMismatch(_, context) {
            #expect(context.codingPath.map(\.stringValue) == ["look", "adjustments", "contrast"])
        }
    }

    /// `NewPhoto` holds the metadata of the file as the importer read it, not a copy of each field.
    @Test func aNewPhotoCarriesTheMetadataOfItsFile() {
        let metadata = FileMetadata(captureDate: nil, camera: "RICOH GR III", lens: "GR", iso: 200, exposureTime: 0.01, aperture: 2.8, focalLength: 18.3, width: 6000, height: 4000)
        var photo = NewPhoto(relativePath: "Originals/a.DNG", fileName: "a.DNG", contentHash: "h", metadata: metadata)
        #expect(photo.metadata == metadata && photo.camera == "RICOH GR III" && photo.iso == 200)
        photo.camera = "FUJIFILM X100V"
        #expect(photo.metadata.camera == "FUJIFILM X100V")
        #expect(photo == NewPhoto(
            relativePath: "Originals/a.DNG", fileName: "a.DNG", contentHash: "h", captureDate: nil, camera: "FUJIFILM X100V", lens: "GR",
            iso: 200, exposureTime: 0.01, aperture: 2.8, focalLength: 18.3, width: 6000, height: 4000
        ))
    }
}

/// A crash in the middle of an import leaves a folder of half-copied files behind. Nothing
/// reads it again, so it must not stay: it is copies of originals, and it grows every time.
@Suite struct InterruptedImportTests {
    let sandbox: ImportSandbox

    init() throws {
        sandbox = try ImportSandbox()
    }

    private var staging: URL { sandbox.library.root.appendingPathComponent(Importer.stagingFolder) }

    @Test func whatAnInterruptedImportLeftIsSweptAway() throws {
        defer { sandbox.cleanUp() }
        let leftover = staging.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: leftover.appendingPathComponent("0"), withIntermediateDirectories: true)
        try Data("half a photo".utf8).write(to: leftover.appendingPathComponent("0/R0001.DNG"))

        let swept = try Importer.sweepInterruptedImports(in: sandbox.library)
        #expect(swept == 1)
        #expect(!FileManager.default.fileExists(atPath: staging.path), "the folder goes too, not just its contents")
    }

    @Test func aLibraryWithNothingToSweepIsUntouched() throws {
        defer { sandbox.cleanUp() }
        #expect(try Importer.sweepInterruptedImports(in: sandbox.library) == 0)
        // The originals are never what it sweeps.
        let file = try sandbox.addFile("R0001.DNG", content: "a")
        _ = sandbox.importer().run([file])
        #expect(try Importer.sweepInterruptedImports(in: sandbox.library) == 0)
        #expect(try sandbox.library.catalog.photos(matching: PhotoFilter()).count == 1)
        #expect(FileManager.default.fileExists(atPath: sandbox.library.originals.path))
    }
}

/// An import template comes from a JSON file, and the name of a file comes from a memory
/// card: neither may decide where the copy lands. The same rule as for exports, applied to
/// the result of the template rather than to its parts.
@Suite struct ImportNamingTests {
    let sandbox: ImportSandbox

    init() throws {
        sandbox = try ImportSandbox()
    }

    private func imported(template: String, named name: String = "R0001.DNG") throws -> Photo {
        var preset = ImportPreset(name: "Hostile")
        preset.fileNameTemplate = template
        let file = try sandbox.addFile(name, content: "a")
        let summary = sandbox.importer().run([file], preset: preset)
        let id = try #require(summary.imported.first)
        return try #require(try sandbox.library.catalog.photo(id))
    }

    @Test(arguments: ["../../{name}", "/tmp/{name}", "{name}/../../x", "..", "a/b/c", "\u{0}{name}", "."])
    func aTemplateCannotLeaveTheFolderOfTheDay(template: String) throws {
        defer { sandbox.cleanUp() }
        let photo = try imported(template: template)
        #expect(photo.relativePath == "Originals/2026/2026-09-11/\(photo.fileName)")
        #expect(!photo.fileName.contains("/") && !photo.fileName.hasPrefix("."))
        #expect(photo.fileName.hasSuffix(".DNG"))

        let file = sandbox.library.root.appendingPathComponent(photo.relativePath)
        #expect(FileManager.default.fileExists(atPath: file.path), "the copy is where the row says")
    }

    /// Anything can be dragged onto a window: what the app opens is decided by the file, not
    /// by its name. The open panel, an import and a drop all ask this one question.
    @Test func whatTheAppOpensIsReadOffTheFile() throws {
        defer { sandbox.cleanUp() }
        let photo = try sandbox.addFile("R0001.DNG", content: "a")
        #expect(Importer.opens(photo))

        #expect(!Importer.opens(try sandbox.addFile("notes.txt", content: "hello")))
        #expect(!Importer.opens(try sandbox.addFile("clip.mov", content: "not a photo")))
        // macOS reads the type of an ordinary file off its extension, so a text file renamed
        // .DNG passes this door: what refuses it is the decoder, which is handed no file it
        // has not been asked to open. The guarantee here is that a drop cannot hand the app
        // something it never opens — a folder, a video, a text file.
        #expect(!Importer.opens(sandbox.card), "a folder is not a photo")
        #expect(!Importer.opens(sandbox.card.appendingPathComponent("gone.DNG")))
    }

    /// Nothing left of the template: the name the file came with.
    @Test func anEmptyTemplateKeepsTheNameOfTheFile() throws {
        defer { sandbox.cleanUp() }
        #expect(try imported(template: "  ").fileName == "R0001.DNG")
    }

    /// A card may hold a name of any length; a file system may not.
    @Test func aVeryLongNameIsCutToWhatTheFileSystemTakes() throws {
        defer { sandbox.cleanUp() }
        let name = try imported(template: String(repeating: "é", count: 400) + "{name}").fileName
        #expect(name.decomposedStringWithCanonicalMapping.utf8.count <= FileName.maximumBytes)
        #expect(name.hasSuffix(".DNG"))
    }
}

@Suite(.enabled(if: Sample.url != nil, "No DNG in Samples/"))
struct RealImportTests {
    @Test func importsARealRawWithItsMetadata() throws {
        let sandbox = try ImportSandbox()
        defer { sandbox.cleanUp() }
        // The reference photograph, not just any: this asserts its camera and its size.
        let sample = try #require(Sample.reference, "needs \(Sample.referenceName) in Samples/")
        let summary = Importer(library: sandbox.library).run([sample])
        let id = try #require(summary.imported.first)
        let photo = try #require(try sandbox.library.catalog.photo(id))
        #expect(photo.camera?.contains("GR III") == true)
        #expect(photo.width == 6000 && photo.height == 4000)
        #expect(photo.captureDate != nil && photo.relativePath.hasPrefix("Originals/20"))
        #expect(photo.contentHash.count == 64)
    }
}
