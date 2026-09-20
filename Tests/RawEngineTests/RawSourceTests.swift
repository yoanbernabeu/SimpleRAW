import CoreImage
import Foundation
import Testing
import TestSupport
@testable import RawEngine

@Suite struct RawSourceTests {
    @Test func rejectsFilesThatAreNotRaw() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("simpleraw-\(UUID().uuidString).dng")
        try Data("definitely not a raw file".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: RawEngineError.unsupportedFile(url)) {
            try RawSource(url: url)
        }
    }

    @Test func rejectsMissingFiles() {
        let url = URL(fileURLWithPath: "/nonexistent/photo.dng")
        #expect(throws: RawEngineError.unsupportedFile(url)) {
            try RawSource(url: url)
        }
    }
}

/// Whatever is handed to the engine (a drop, a memory card, a library restored from
/// elsewhere), opening it ends with a picture or a clear error: never a crash, and never a
/// decoder let loose on something that is not a file.
@Suite struct UntrustedFileTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-untrusted-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @Test func aFolderIsNotAPhoto() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appendingPathComponent("looks like.dng")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(throws: RawEngineError.notARegularFile(directory)) { try RawSource(url: directory) }
    }

    @Test func aBrokenLinkIsNotAPhoto() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = folder.appendingPathComponent("dangling.dng")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.appendingPathComponent("gone.dng"))
        #expect(throws: RawEngineError.notARegularFile(link)) { try RawSource(url: link) }
    }

    @Test func anEmptyFileIsNotAPhoto() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let empty = folder.appendingPathComponent("empty.dng")
        try Data().write(to: empty)
        #expect(throws: RawEngineError.unsupportedFile(empty)) { try RawSource(url: empty) }
    }

    /// The size is read from the file system: nothing of a file too large is ever loaded.
    @Test func aFileTooLargeIsRefusedOnItsSizeAlone() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("large.dng")
        try Data("not a raw file, but a large one".utf8).write(to: file)
        #expect(throws: RawEngineError.fileTooLarge(file, limit: 8)) { try RawSource(url: file, maximumSize: 8) }
        #expect(RawSource.maximumFileSize == 1_073_741_824)
    }

    /// A link to a photo is the photo: libraries are sometimes made of links.
    @Test func aLinkToAPictureOpens() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let picture = folder.appendingPathComponent("picture.png")
        try HostileDocumentRenderingTests.writeSample(to: picture)
        let link = folder.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: picture)
        #expect(try RawSource(url: link).info.imageSize == CGSize(width: 96, height: 64))
    }

    /// A card pulled out while copying, a download cut short. Every sample, cut at several
    /// places: a clear error or a picture, whatever the decoder makes of it.
    @Test(.enabled(if: Sample.url != nil, "Needs a DNG in Samples/"), arguments: [64, 4096, 1_000_000])
    func aTruncatedRawFileIsAnErrorOrAPictureNeverACrash(length: Int) throws {
        MemoryFuse.arm()
        defer { try? FileManager.default.removeItem(at: folder) }
        let handle = try FileHandle(forReadingFrom: try #require(Sample.url))
        let head = try #require(try handle.read(upToCount: length))
        try handle.close()
        // In a temporary folder: tests write nothing in Samples/.
        let truncated = folder.appendingPathComponent("truncated-\(length).dng")
        try head.write(to: truncated)

        do {
            let source = try RawSource(url: truncated)
            // Opened all the same: then a small render must come out, or fail cleanly.
            let image = try source.image(scaleFactor: 0.05)
            #expect(!image.extent.isInfinite)
            _ = try? PixelProbe().average(of: image)
        } catch let error as RawEngineError {
            #expect(error == .unsupportedFile(truncated))
        }
    }
}

@Suite struct ExportFailureTests {
    /// "Export failed" says nothing: the cause (no such folder, no permission, disk full) does.
    @Test func aFailedExportSaysWhy() throws {
        MemoryFuse.arm()
        let nowhere = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/out.jpg")
        let picture = PixelProbe.swatch(r: 0.5, g: 0.5, b: 0.5)
        do {
            try Renderer.shared.write(picture, to: nowhere)
            Issue.record("writing to a folder that does not exist succeeded")
        } catch let error as RawEngineError {
            guard case .exportFailed(let url, let underlying) = error else { Issue.record("\(error)"); return }
            #expect(url == nowhere && !underlying.isEmpty)
            let message = try #require(error.errorDescription)
            #expect(message.contains(nowhere.path) && message.contains(underlying))
        }
    }
}
