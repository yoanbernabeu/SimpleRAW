import Catalog
import CoreImage
import Foundation
import RawEngine
import TestSupport
import Testing
@testable import SimpleRAWUI

@MainActor
@Suite struct LibraryKeywordTests {
    @Test func keywordsTypedWithCommasGoToTheWholeSelection() async throws {
        let sandbox = try LibrarySandbox(photos: 3)
        defer { sandbox.cleanUp() }
        let session = sandbox.session
        let ids = session.photos.map(\.id)
        session.select(ids[0])
        session.select(ids[1], toggling: true)
        session.setKeywords(fromText: "street,  Lille , ,street")
        await session.settle()
        #expect(try session.keywords(for: ids[0]) == ["Lille", "street"])
        #expect(try session.keywords(for: ids[1]) == ["Lille", "street"])
        #expect(try session.keywords(for: ids[2]).isEmpty)
        #expect(session.keywordText == "Lille, street")
    }

    /// Regression: the field shows what the selection shares, and submitting it used to
    /// replace the whole list of every photo, wiping the keywords each one had of its own —
    /// even when nothing had been typed.
    @Test func submittingTheFieldNeverWipesWhatEachPhotoHasOfItsOwn() async throws {
        let sandbox = try LibrarySandbox(photos: 2)
        defer { sandbox.cleanUp() }
        let session = sandbox.session
        let ids = session.photos.map(\.id)
        session.select(ids[0])
        session.setKeywords(fromText: "street, night")
        await session.settle()
        session.select(ids[1])
        session.setKeywords(fromText: "street, portrait")
        await session.settle()

        session.selectAll()
        await session.settle()
        session.setKeywords(fromText: session.keywordText)  // nothing typed
        await session.settle()
        #expect(try session.keywords(for: ids[0]) == ["night", "street"])
        #expect(try session.keywords(for: ids[1]) == ["portrait", "street"])

        session.setKeywords(fromText: "street, Lille")  // one keyword added
        await session.settle()
        #expect(try session.keywords(for: ids[0]) == ["Lille", "night", "street"])
        #expect(try session.keywords(for: ids[1]) == ["Lille", "portrait", "street"])

        session.setKeywords(fromText: "Lille")  // a shared keyword removed
        await session.settle()
        #expect(try session.keywords(for: ids[0]) == ["Lille", "night"])
        #expect(try session.keywords(for: ids[1]) == ["Lille", "portrait"])
    }

    /// Keywords typed then left by clicking the next photo used to be lost. They are kept, and
    /// go to the photos they were typed for, not to the one that was clicked.
    @Test func keywordsLeftByClickingElsewhereGoToThePhotosTheyWereTypedFor() async throws {
        let sandbox = try LibrarySandbox(photos: 2)
        defer { sandbox.cleanUp() }
        let session = sandbox.session
        let ids = session.photos.map(\.id)
        try sandbox.library.catalog.setKeywords(["portrait"], for: ids[1])
        session.select(ids[0])
        await session.settle()

        session.beginEditingKeywords()
        session.select(ids[1])
        session.endEditingKeywords("street")
        await session.settle()
        #expect(try session.keywords(for: ids[0]) == ["street"])
        #expect(try session.keywords(for: ids[1]) == ["portrait"])
        #expect(session.keywordText == "portrait")

        // The field no longer has the keyboard: what it still holds is committed to no one.
        session.commitKeywords("street")
        await session.settle()
        #expect(try session.keywords(for: ids[1]) == ["portrait"])
    }

    /// With several photos selected, the field shows what they all share.
    @Test func theFieldShowsTheKeywordsCommonToTheSelection() async throws {
        let sandbox = try LibrarySandbox(photos: 2)
        defer { sandbox.cleanUp() }
        let session = sandbox.session
        let ids = session.photos.map(\.id)
        session.select(ids[0])
        session.setKeywords(fromText: "street, night")
        await session.settle()
        session.select(ids[1])
        session.setKeywords(fromText: "street")
        await session.settle()
        session.selectAll()
        await session.settle()
        #expect(session.keywordText == "street")
    }
}

/// The title, the caption, the author and the copyright of the selection: what the photographer
/// says about a picture, as opposed to what the camera wrote.
@MainActor
@Suite struct LibraryCreditsTests {
    @Test func whatIsSaidAboutOnePhotoIsKeptAndShown() async throws {
        let sandbox = try LibrarySandbox(photos: 2)
        defer { sandbox.cleanUp() }
        let session = sandbox.session
        let ids = session.photos.map(\.id)
        session.select(ids[0])
        #expect(session.shownCredits == PhotoCredits())

        session.setCredits(PhotoCredits(title: "Rue de la Gare", caption: "The last train.", author: "Yoan"))
        await session.settle()
        #expect(session.shownCredits.title == "Rue de la Gare")
        // Shown without a query: the row of the grid carries it.
        #expect(session.photos.first { $0.id == ids[0] }?.credits.caption == "The last train.")
        #expect(try session.library.catalog.credits(for: ids[0]).author == "Yoan")
        #expect(try session.library.catalog.credits(for: ids[1]) == PhotoCredits())
    }

    /// A title names one picture; an author signs a whole shoot. Signing leaves each photo the
    /// title it has of its own.
    @Test func signingASelectionLeavesEachTitleAlone() async throws {
        let sandbox = try LibrarySandbox(photos: 3)
        defer { sandbox.cleanUp() }
        let session = sandbox.session
        let ids = session.photos.map(\.id)
        session.select(ids[0])
        session.setCredits(PhotoCredits(title: "Gare"))
        await session.settle()

        session.selectAll()
        #expect(session.shownCredits.title == nil, "the selection shares no title")
        session.setSignature(author: "Yoan", copyright: "© 2026 Yoan")
        await session.settle()
        #expect(session.shownCredits.author == "Yoan" && session.shownCredits.copyright == "© 2026 Yoan")
        #expect(try ids.map { try session.library.catalog.credits(for: $0).author } == ["Yoan", "Yoan", "Yoan"])
        #expect(try session.library.catalog.credits(for: ids[0]).title == "Gare")
        #expect(try session.library.catalog.credits(for: ids[1]).title == nil)
    }

    /// The fields show what the selection shares, and nothing where it differs — like the
    /// keyword field, and for the same reason: what is shown is what submitting would write.
    @Test func theFieldsShowOnlyWhatTheSelectionShares() async throws {
        let sandbox = try LibrarySandbox(photos: 2)
        defer { sandbox.cleanUp() }
        let session = sandbox.session
        let ids = session.photos.map(\.id)
        session.select(ids[0])
        session.setCredits(PhotoCredits(title: "Gare", author: "Yoan"))
        await session.settle()
        session.select(ids[1])
        session.setCredits(PhotoCredits(title: "Canal", author: "Yoan"))
        await session.settle()

        session.selectAll()
        #expect(session.shownCredits == PhotoCredits(author: "Yoan"))
        session.deselectAll()
        #expect(session.shownCredits == PhotoCredits())
    }

    /// A photo found by its title must leave the grid when the title stops matching the search.
    @Test func changingATitleReloadsAGridThatSearchesForIt() async throws {
        let sandbox = try LibrarySandbox(photos: 2)
        defer { sandbox.cleanUp() }
        let session = sandbox.session
        let ids = session.photos.map(\.id)
        session.select(ids[0])
        session.setCredits(PhotoCredits(title: "Rue de la Gare"))
        await session.settle()

        session.searchText = "gare"
        await session.settle()
        #expect(session.photos.map(\.id) == [ids[0]])
        session.select(ids[0])
        session.setCredits(PhotoCredits(title: "Canal"))
        await session.settle()
        #expect(session.photos.isEmpty)
    }
}

@MainActor
@Suite
struct LibraryFileActionsTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-actions-\(UUID().uuidString)")
    let app: AppSession

    init() throws {
        let library = try Library(root: root.appendingPathComponent("library"))
        _ = Importer(library: library).run(Array(TestPhoto.all.prefix(2)))
        // Removed originals are deleted here rather than sent to the user's Trash.
        let session = LibrarySession(library: library) { try FileManager.default.removeItem(at: $0) }
        app = AppSession(library: library, librarySession: session)
    }

    @Test func settingsCopiedInDevelopArePastedOnTheSelection() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = app.library.photos
        #expect(!app.canPasteSettingsToSelection)
        app.open(photos[0])
        app.develop.adjustments.contrast = 22
        app.develop.adjustments.geometry.straighten = 3
        app.develop.copyAdjustments(groups: AdjustmentGroup.defaultSelection)
        app.showLibrary()

        app.library.selectAll()
        #expect(app.canPasteSettingsToSelection)
        app.pasteSettingsToSelection()
        await app.library.settle()
        #expect(app.library.photos.map { $0.adjustments.contrast } == [22, 22])
        // Framing is not part of a default copy: the second photo keeps its own.
        #expect(app.library.photos[1].adjustments.geometry.straighten == 0)
    }

    /// Settings could only be pasted in the grid after a trip to the develop view to copy them.
    @Test func settingsAreCopiedFromTheGridToo() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = app.library.photos
        var edits = Adjustments()
        edits.contrast = 18
        app.library.select(photos[0].id)
        app.library.apply(Preset(name: "Edits", capturing: edits, groups: [.light]))
        await app.library.settle()

        app.copySettings(from: app.library.photos[0])
        #expect(app.library.notice == "Settings copied.")
        app.library.select(photos[1].id)
        app.pasteSettingsToSelection()
        await app.library.settle()
        #expect(app.library.photos[1].adjustments.contrast == 18)
    }

    /// Thumbnails are developed on the GPU: while a photo is being edited, it is not theirs —
    /// unless the filmstrip is on screen, which needs them to show the rest of the shoot.
    @Test func thumbnailsWaitWhileAPhotoIsBeingDevelopedWithoutTheFilmstrip() {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!app.thumbnails.isSuspended)
        app.showsFilmstrip = false
        app.open(app.library.photos[0])
        #expect(app.thumbnails.isSuspended)
        app.showLibrary()
        #expect(!app.thumbnails.isSuspended)
    }

    @Test func theSelectionIsExportedWithItsEdits() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = app.library.photos[0]
        app.library.select(photo.id)
        var look = Adjustments()
        look.saturation = -100
        app.library.apply(Preset(name: "Mono", capturing: look, groups: [.color]))
        await app.library.settle()

        var preset = ExportPreset(name: "Tiny")
        preset.options.longEdge = 320
        let output = root.appendingPathComponent("out")
        let outcomes = await app.library.exportSelection(to: output, using: preset)

        #expect(outcomes.count == 1 && outcomes[0].isSuccess)
        let file = try #require(outcomes[0].destination)
        let image = try #require(CIImage(contentsOf: file))
        #expect(try PixelProbe().average(of: image).chroma < 0.02)
        #expect(app.library.exportProgress == nil)
    }

    /// Keywords are the photographer's own work: they travel with the file that leaves,
    /// rather than staying in the catalog.
    @Test func theKeywordsOfAPhotoAreWrittenIntoItsExport() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = app.library.photos[0]
        app.library.select(photo.id)
        app.library.beginEditingKeywords()
        app.library.endEditingKeywords("street, Lille")
        await app.library.settle()
        #expect(try app.library.library.catalog.keywords(for: photo.id).sorted() == ["Lille", "street"])

        var preset = ExportPreset(name: "Tiny")
        preset.options.longEdge = 320
        let outcomes = await app.library.exportSelection(to: root.appendingPathComponent("out"), using: preset)
        let file = try #require(outcomes.first?.destination)
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let iptc = try #require(properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any])
        #expect((iptc[kCGImagePropertyIPTCKeywords as String] as? [String])?.sorted() == ["Lille", "street"])
    }

    /// The photo's own title and author beat the export preset's: the preset signs a batch,
    /// the catalog knows the picture.
    @Test func whatThePhotoSaysAboutItselfIsWrittenIntoItsExport() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = app.library.photos[0]
        app.library.select(photo.id)
        app.library.setCredits(PhotoCredits(title: "Rue de la Gare", author: "Yoan Bernabeu"))
        await app.library.settle()

        var preset = ExportPreset(name: "Tiny")
        preset.options.longEdge = 320
        preset.options.author = "Preset author"
        let outcomes = await app.library.exportSelection(to: root.appendingPathComponent("out"), using: preset)
        let file = try #require(outcomes.first?.destination)
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let iptc = try #require(properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any])
        #expect(iptc[kCGImagePropertyIPTCObjectName as String] as? String == "Rue de la Gare")
        #expect(iptc[kCGImagePropertyIPTCByline as String] as? [String] == ["Yoan Bernabeu"])
    }

    /// Exporting the photo being worked on keeps what the catalog says about it, exactly as
    /// exporting it from the grid does. A file opened from outside the library has none.
    @Test func theOpenPhotoIsExportedWithWhatTheCatalogSaysAboutIt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = app.library.photos[0]
        app.library.select(photo.id)
        app.library.setCredits(PhotoCredits(title: "Rue de la Gare"))
        app.library.beginEditingKeywords()
        app.library.endEditingKeywords("street")
        await app.library.settle()

        app.open(app.library.photos[0])
        #expect(app.develop.credits == PhotoCredits(title: "Rue de la Gare", keywords: ["street"]))
        var options = ExportOptions()
        options.longEdge = 320
        let destination = root.appendingPathComponent("open.jpg")
        try await app.develop.export(to: destination, options: options)
        let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let iptc = try #require(properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any])
        #expect(iptc[kCGImagePropertyIPTCObjectName as String] as? String == "Rue de la Gare")
        #expect(iptc[kCGImagePropertyIPTCKeywords as String] as? [String] == ["street"])

        app.openFile(app.library.library.url(for: photo))
        #expect(app.develop.credits == PhotoCredits(), "a loose file has nothing said about it")
    }

    /// Nothing used to say that an import or an export had worked.
    @Test func anImportSaysWhatItDid() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let card = root.appendingPathComponent("card")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: TestPhoto.all[0], to: card.appendingPathComponent("already-there.\(TestPhoto.all[0].pathExtension)"))

        _ = await app.library.importFolder(card)
        #expect(app.library.notice == "Nothing new to import: 1 photo was already in the library.")
        app.library.dismissNotice()
        #expect(app.library.notice == nil)
    }

    @Test func anExportSaysWhereItWent() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        app.library.selectAll()
        var preset = ExportPreset(name: "Tiny")
        preset.options.longEdge = 200
        _ = await app.library.exportSelection(to: root.appendingPathComponent("out"), using: preset)
        #expect(app.library.notice == "2 photos exported to “out”.")
    }

    @Test func errorsSayWhatFailed() async {
        defer { try? FileManager.default.removeItem(at: root) }
        struct Refused: Error {}
        let session = LibrarySession(library: app.library.library) { _ in throw Refused() }
        session.selectAll()
        session.removeSelectionFromLibrary()
        await session.settle()
        #expect(session.errorTitle == "Some photos could not be removed")
    }

    @Test func removedPhotosLeaveTheCatalogAndTheirOriginalIsDiscarded() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = app.library.photos[0]
        let original = app.library.library.url(for: photo)
        app.library.select(photo.id)
        app.library.removeSelectionFromLibrary()
        await app.library.settle()

        #expect(app.library.photos.count == 1 && app.library.selection.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(try app.library.library.catalog.photoID(withContentHash: photo.contentHash) == nil)
    }

    @Test func aPhotoWhoseOriginalCannotBeDiscardedStaysInTheCatalog() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        struct Refused: Error {}
        let library = app.library.library
        let session = LibrarySession(library: library) { _ in throw Refused() }
        session.selectAll()
        session.removeSelectionFromLibrary()
        await session.settle()
        #expect(session.photos.count == 2)
        #expect(session.errorMessage != nil)
        #expect(FileManager.default.fileExists(atPath: library.url(for: session.photos[0]).path))
    }
}
