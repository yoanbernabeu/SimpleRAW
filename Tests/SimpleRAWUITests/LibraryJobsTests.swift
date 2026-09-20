import Catalog
import CoreGraphics
import Foundation
import ImageIO
import RawEngine
import Testing
import UniformTypeIdentifiers
@testable import SimpleRAWUI

/// A memory card of small PNGs, each different so that none is a duplicate of another: imports
/// and exports are tested anywhere, without a RAW file.
struct Card {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-card-\(UUID().uuidString)")
    var folder: URL { root.appendingPathComponent("DCIM") }
    var libraryRoot: URL { root.appendingPathComponent("library") }

    init(photos: Int) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 1...photos {
            try Self.writePNG(to: folder.appendingPathComponent("IMG_000\(index).png"), shade: CGFloat(index) / CGFloat(photos + 1))
        }
    }

    static func writePNG(to url: URL, shade: CGFloat) throws {
        let context = try #require(CGContext(
            data: nil, width: 48, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: shade, green: 0.4, blue: 1 - shade, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

/// Holds a background job at a known point until the test lets it go.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var arrivals = 0
    private let opened = DispatchSemaphore(value: 0)
    private let stopsAt: Int

    init(stopsAtArrival stopsAt: Int) { self.stopsAt = stopsAt }

    var wasReached: Bool { lock.withLock { arrivals >= stopsAt } }

    func arrive() {
        let count = lock.withLock { arrivals += 1; return arrivals }
        if count == stopsAt { opened.wait() }
    }

    func open() { opened.signal() }

    func reached() async {
        while !wasReached { try? await Task.sleep(for: .milliseconds(2)) }
    }
}

/// Every test here drives a background job and waits on it. A wait that never ends is a
/// suite that never ends, so the whole suite is on a clock: a minute is a hundred times what
/// the slowest of them takes, and a job that stops answering fails rather than holds the run.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct LibraryJobsTests {
    @Test func aFolderIsImportedAndTheGridShowsIt() async throws {
        let card = try Card(photos: 3)
        defer { card.cleanUp() }
        let session = LibrarySession(library: try Library(root: card.libraryRoot))
        let summary = await session.importFolder(card.folder)
        await session.settle()
        #expect(summary.imported.count == 3 && summary.failures.isEmpty)
        #expect(session.photos.count == 3 && session.totalCount == 3)
        #expect(session.notice == "3 photos imported.")
        #expect(session.importProgress == nil)
    }

    /// Files dropped on the window are imported like a folder is; what is not a photo is left.
    @Test func filesAreImportedAsWellAsFolders() async throws {
        let card = try Card(photos: 3)
        defer { card.cleanUp() }
        let notes = card.root.appendingPathComponent("notes.txt")
        try Data("not a photo".utf8).write(to: notes)
        let session = LibrarySession(library: try Library(root: card.libraryRoot))
        let files = ["IMG_0001.png", "IMG_0003.png"].map(card.folder.appendingPathComponent)
        let summary = await session.importItems(files + [notes])
        await session.settle()
        #expect(summary.imported.count == 2 && summary.failures.isEmpty)
        #expect(Set(session.photos.map(\.fileName)) == ["IMG_0001.png", "IMG_0003.png"])
    }

    /// A card also holds videos and text files: the import says that it left them, rather
    /// than leaving the photographer to wonder where they went.
    @Test func anImportSaysWhatItIgnored() async throws {
        let card = try Card(photos: 2)
        defer { card.cleanUp() }
        try Data("clip".utf8).write(to: card.folder.appendingPathComponent("MOVIE.mov"))
        try Data("notes".utf8).write(to: card.folder.appendingPathComponent("notes.txt"))
        let session = LibrarySession(library: try Library(root: card.libraryRoot))
        let summary = await session.importFolder(card.folder)
        #expect(summary.ignored.count == 2)
        #expect(session.notice == "2 photos imported. 2 files ignored.")

        let again = await session.importItems([card.folder.appendingPathComponent("notes.txt")])
        #expect(again.ignored.count == 1)
        #expect(session.notice == "No photo was found there. 1 file ignored.")
    }

    @Test func anImportCanBeCancelled() async throws {
        let card = try Card(photos: 5)
        defer { card.cleanUp() }
        let gate = Gate(stopsAtArrival: 2)
        let session = LibrarySession(library: try Library(root: card.libraryRoot), metadata: {
            gate.arrive()
            return try FileMetadata.read(from: $0)
        })
        let importing = Task { await session.importFolder(card.folder) }
        await gate.reached()
        // The gate is reached on a background thread; the overlay is lit by the main actor
        // reading the progress stream. On a loaded machine that arrives a moment later, so
        // it is waited for — bounded, since a wait that never ends is a suite that never ends.
        for _ in 0..<2_000 where session.importProgress?.total != 5 { await Task.yield() }
        #expect(session.importProgress?.total == 5)
        session.cancelImport()
        gate.open()
        let summary = await importing.value
        await session.settle()

        // The file that was being copied is finished, the others are left alone.
        #expect(summary.imported.count == 2)
        #expect(session.photos.count == 2)
        #expect(session.notice == "Import cancelled. 2 photos imported.")
        #expect(session.importProgress == nil)
    }

    /// ⇧⌘I twice used to run two imports over each other.
    @Test func aSecondImportIsRefusedWhileOneIsRunning() async throws {
        let card = try Card(photos: 3)
        defer { card.cleanUp() }
        let gate = Gate(stopsAtArrival: 1)
        let session = LibrarySession(library: try Library(root: card.libraryRoot), metadata: {
            gate.arrive()
            return try FileMetadata.read(from: $0)
        })
        let importing = Task { await session.importFolder(card.folder) }
        await gate.reached()
        #expect(session.isImporting)

        let refused = await session.importFolder(card.folder)
        #expect(refused.imported.isEmpty && refused.duplicates.isEmpty)
        #expect(session.isImporting)

        gate.open()
        #expect(await importing.value.imported.count == 3)
        #expect(!session.isImporting)
    }

    /// Progress used to be sent by unstructured tasks: one of them landing late lit the
    /// overlay again after the job was over.
    @Test func nothingReportsProgressOnceTheJobIsOver() async throws {
        let card = try Card(photos: 4)
        defer { card.cleanUp() }
        let session = LibrarySession(library: try Library(root: card.libraryRoot))
        _ = await session.importFolder(card.folder)
        await session.settle()
        session.selectAll()
        _ = await session.exportSelection(to: card.root.appendingPathComponent("out"), using: ExportPreset(name: "Web"))
        for _ in 0..<20 { await Task.yield() }
        #expect(session.importProgress == nil && session.exportProgress == nil)
    }

    @Test func anExportCanBeCancelled() async throws {
        let card = try Card(photos: 8)
        defer { card.cleanUp() }
        let session = LibrarySession(library: try Library(root: card.libraryRoot))
        _ = await session.importFolder(card.folder)
        await session.settle()
        session.selectAll()

        let destination = card.root.appendingPathComponent("out")
        let exporting = Task { await session.exportSelection(to: destination, using: ExportPreset(name: "Web")) }
        // Waiting for the overlay to show has to be bounded. Progress is read from a stream
        // that buffers: when the files go faster than the main actor comes back, the whole
        // batch is drained without a suspension, `exportProgress` is nil again before this
        // line ever sees it, and an unbounded `while` spins for as long as the suite lasts —
        // it held this one for fifteen minutes under load.
        var wasCaughtRunning = false
        for _ in 0..<2_000 where !wasCaughtRunning {
            wasCaughtRunning = session.exportProgress != nil
            await Task.yield()
        }
        session.cancelExport()
        let outcomes = await exporting.value

        // True whichever way the race went: nothing is left running, no file failed, and
        // every outcome is a file on the disk.
        #expect(session.exportProgress == nil)
        #expect(outcomes.filter { !$0.isSuccess }.isEmpty)
        let written = ((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []).count
        #expect(written == outcomes.count)
        // What cancelling promises, when there was still something to cancel.
        if outcomes.count < 8 {
            #expect(session.notice?.hasPrefix("Export cancelled.") == true)
        }
    }
}

/// Auto on a selection: the everyday use of a batch. Each photo needs *its own* Auto, read
/// off its own picture, which is why it is a background job with progress rather than a look.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct AutoToneSelectionTests {
    /// An Auto that depends on the file it is given, without decoding anything.
    private func answering(_ gate: Gate? = nil) -> @Sendable (URL) throws -> AutoToneResult {
        { url in
            gate?.arrive()
            let index = Double(url.deletingPathExtension().lastPathComponent.last?.wholeNumberValue ?? 0)
            return AutoToneResult(exposure: index / 10, contrast: 10, highlights: 0, shadows: 0, whites: 0, blacks: 0, vibrance: 5)
        }
    }

    private func session(_ card: Card, gate: Gate? = nil) throws -> LibrarySession {
        LibrarySession(library: try Library(root: card.libraryRoot), autoTone: answering(gate))
    }

    @Test func eachPhotoGetsItsOwnAuto() async throws {
        let card = try Card(photos: 3)
        defer { card.cleanUp() }
        let session = try session(card)
        _ = await session.importFolder(card.folder)
        await session.settle()
        session.selectAll()

        await session.autoToneSelection()
        await session.settle()
        #expect(session.photos.allSatisfy { $0.adjustments.contrast == 10 && $0.adjustments.vibrance == 5 })
        // Not one answer copied across: each file got its own.
        #expect(Set(session.photos.map(\.adjustments.exposure)).count == 3)
        #expect(session.notice == "Auto applied to 3 photos.")
        #expect(session.autoToneProgress == nil)
    }

    /// Auto replaces the light and vibrance and leaves the rest of the edits alone; the whole
    /// batch is one undo, like a look applied to a selection.
    @Test func autoKeepsTheRestOfTheEditsAndUndoesAtOnce() async throws {
        let card = try Card(photos: 2)
        defer { card.cleanUp() }
        let session = try session(card)
        _ = await session.importFolder(card.folder)
        await session.settle()

        var own = Adjustments()
        own.contrast = 42
        own.grain = 30
        try session.library.catalog.setAdjustments(own, for: session.photos[0].id)
        session.reload()
        await session.settle()

        session.selectAll()
        await session.autoToneSelection()
        await session.settle()
        #expect(session.photos.allSatisfy { $0.adjustments.contrast == 10 })
        #expect(session.photos.first { $0.adjustments.grain == 30 } != nil, "grain is none of Auto's business")

        session.undoLastChange()
        await session.settle()
        #expect(session.photos.map(\.adjustments.contrast).sorted() == [0, 42])
    }

    @Test func autoCanBeCancelledAndKeepsWhatItDid() async throws {
        let card = try Card(photos: 5)
        defer { card.cleanUp() }
        let gate = Gate(stopsAtArrival: 2)
        let session = try session(card, gate: gate)
        _ = await session.importFolder(card.folder)
        await session.settle()
        session.selectAll()

        let running = Task { await session.autoToneSelection() }
        await gate.reached()
        #expect(session.autoToneProgress?.total == 5)
        session.cancelAutoTone()
        gate.open()
        await running.value
        await session.settle()

        #expect(session.photos.filter { $0.adjustments.contrast == 10 }.count == 2)
        #expect(session.notice == "Auto cancelled. 2 photos done.")
        #expect(session.autoToneProgress == nil)
    }

    /// A photo whose file cannot be read is reported and does not stop the others.
    @Test func aPhotoThatCannotBeAnalysedIsSaidAndSkipped() async throws {
        let card = try Card(photos: 3)
        defer { card.cleanUp() }
        let session = LibrarySession(library: try Library(root: card.libraryRoot), autoTone: { url in
            guard !url.lastPathComponent.contains("2") else { throw RawEngineError.analysisFailed }
            return AutoToneResult(exposure: 1, contrast: 10, highlights: 0, shadows: 0, whites: 0, blacks: 0, vibrance: 5)
        })
        _ = await session.importFolder(card.folder)
        await session.settle()
        session.selectAll()

        await session.autoToneSelection()
        await session.settle()
        #expect(session.photos.filter { $0.adjustments.contrast == 10 }.count == 2)
        #expect(session.errorMessage?.contains("IMG_0002") == true)
    }

    @Test func autoOnNothingDoesNothing() async throws {
        let card = try Card(photos: 1)
        defer { card.cleanUp() }
        let session = try session(card)
        await session.autoToneSelection()
        #expect(session.notice == nil && !session.canUndoLastChange)
    }
}

/// What is dropped on the window is imported the way the import panel would: with the look
/// chosen for imports.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct DroppedImportTests {
    @Test func aDropIsImportedWithTheLookChosenForImports() async throws {
        let card = try Card(photos: 2)
        defer { card.cleanUp() }
        let defaults = UserDefaults(suiteName: "simpleraw-tests-\(UUID().uuidString)")!
        let library = try Library(root: card.libraryRoot)
        let app = AppSession(library: library, librarySession: LibrarySession(library: library, defaults: defaults))
        let look = try #require(app.develop.presets.first)
        app.library.importLookName = look.name

        await app.importItems([card.folder])
        await app.library.settle()
        #expect(app.library.photos.count == 2)
        var expected = Adjustments()
        look.apply(to: &expected)
        #expect(app.library.photos.allSatisfy { $0.adjustments == expected })
    }

    /// A photographer signs their own work once, not photo by photo: the author and the
    /// copyright typed in the import panel are remembered and written on everything that
    /// comes in, whichever way it comes in.
    @Test func everyImportedPhotoIsSignedWithWhatWasTypedOnce() async throws {
        let card = try Card(photos: 2)
        defer { card.cleanUp() }
        let defaults = UserDefaults(suiteName: "simpleraw-tests-\(UUID().uuidString)")!
        let library = try Library(root: card.libraryRoot)
        let session = LibrarySession(library: library, defaults: defaults)
        session.importAuthor = "Yoan Bernabeu"
        session.importCopyright = "© 2026 Yoan Bernabeu"
        let app = AppSession(library: library, librarySession: session)

        await app.importItems([card.folder])
        await app.library.settle()
        #expect(app.library.photos.allSatisfy { $0.credits.author == "Yoan Bernabeu" })
        #expect(app.library.photos.allSatisfy { $0.credits.copyright == "© 2026 Yoan Bernabeu" })

        // Remembered for the next launch, on the library's own defaults.
        let reopened = LibrarySession(library: library, defaults: defaults)
        #expect(reopened.importAuthor == "Yoan Bernabeu" && reopened.importCopyright == "© 2026 Yoan Bernabeu")
    }
}
