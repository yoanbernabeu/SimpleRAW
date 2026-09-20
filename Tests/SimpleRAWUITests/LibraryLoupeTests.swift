import Catalog
import CoreGraphics
import Foundation
import SwiftUI
import TestSupport
import Testing
@testable import SimpleRAWUI

/// Culling on thumbnails is guessing: the loupe shows the selected photo as large as the
/// window, and everything that rates still works on it.
@MainActor
@Suite struct LibraryLoupeTests {
    let sandbox: LibrarySandbox
    var session: LibrarySession { sandbox.session }

    init() throws {
        sandbox = try LibrarySandbox()
    }

    @Test func theLoupeShowsTheSelectedPhoto() {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        #expect(!session.isLoupeOpen && session.loupePhoto == nil)
        session.select(ids[2])
        session.toggleLoupe()
        #expect(session.isLoupeOpen && session.loupePhoto?.id == ids[2])
        #expect(session.loupePosition == "3 of 5")
        session.toggleLoupe()
        #expect(!session.isLoupeOpen && session.loupePhoto == nil)
        #expect(session.selection == [ids[2]])
    }

    @Test func withNothingSelectedItStartsOnTheFirstPhoto() {
        defer { sandbox.cleanUp() }
        session.toggleLoupe()
        #expect(session.loupePhoto?.id == session.photos[0].id)
        #expect(session.selection == [session.photos[0].id])
    }

    /// One photo is on screen: a selection of several comes down to the one last clicked.
    @Test func aSelectionOfSeveralComesDownToOne() {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        session.select(ids[1])
        session.select(ids[3], toggling: true)
        session.openLoupe()
        #expect(session.selection == [ids[3]] && session.loupePhoto?.id == ids[3])
    }

    @Test func anEmptyGridHasNothingToShowLarge() async {
        defer { sandbox.cleanUp() }
        session.filter.minimumRating = 5
        await session.settle()
        session.toggleLoupe()
        #expect(!session.isLoupeOpen)
    }

    @Test func arrowsGoToTheNeighboursInTheLoupeAndAlongTheRowsInTheGrid() {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        session.gridColumns = 3
        session.select(ids[0])
        session.move(.down)
        #expect(session.selection == [ids[3]])
        session.move(.left)
        #expect(session.selection == [ids[2]])

        session.openLoupe()
        session.move(.down)
        #expect(session.loupePhoto?.id == ids[3])
        session.move(.up)
        session.move(.left)
        #expect(session.loupePhoto?.id == ids[1])
        session.move(.right)
        #expect(session.loupePhoto?.id == ids[2])
    }

    @Test func ratingInTheLoupeShowsOnThePhoto() {
        defer { sandbox.cleanUp() }
        session.select(session.photos[1].id)
        session.openLoupe()
        session.setRating(4)
        session.setFlag(.picked)
        #expect(session.loupePhoto?.rating == 4 && session.loupePhoto?.flag == .picked)
    }

    /// A photo that a rating takes out of what the filter shows leaves the loupe to its
    /// neighbour, not to a blank.
    @Test func whenThePhotoLeavesTheGridTheLoupeMovesOn() async {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        session.selectAll()
        session.setRating(3)
        session.filter.minimumRating = 3
        await session.settle()
        session.select(ids[1])
        session.openLoupe()
        session.setRating(1)
        await session.settle()
        #expect(session.isLoupeOpen && session.loupePhoto?.id == ids[2])

        // And with nothing left to show, it closes.
        session.filter.minimumRating = 5
        await session.settle()
        #expect(!session.isLoupeOpen)
    }
}

@Suite struct LibraryKeyMapTests {
    private func command(_ key: KeyEquivalent, _ characters: String = "", _ modifiers: EventModifiers = [], loupe: Bool = false) -> AppCommand? {
        LibraryKeyMap.command(key: key, characters: characters, modifiers: modifiers, isLoupeOpen: loupe)
    }

    @Test func arrowsMoveAndReturnOpens() {
        #expect(command(.leftArrow) == .moveSelection(.left))
        #expect(command(.rightArrow) == .moveSelection(.right))
        #expect(command(.upArrow) == .moveSelection(.up))
        #expect(command(.downArrow, loupe: true) == .moveSelection(.down))
        #expect(command(.return) == .openSelection)
        #expect(command(.return, loupe: true) == .openSelection)
    }

    @Test func spaceOpensAndClosesTheLoupeAndEscapeOnlyCloses() {
        #expect(command(.space, " ") == .toggleLoupe)
        #expect(command(.space, " ", loupe: true) == .toggleLoupe)
        #expect(command(.escape, loupe: true) == .closeLoupe)
        #expect(command(.escape) == nil)
    }

    @Test func commandASelectsEverythingInTheGridOnly() {
        #expect(command("a", "a", .command) == .selectAll)
        #expect(command("a", "a", .command, loupe: true) == nil)
        #expect(command("a", "a") == nil)
        #expect(command(.rightArrow, "", .command) == nil)
    }
}

private func picture(_ width: Int) -> CGImage {
    CGContext(
        data: nil, width: width, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!.makeImage()!
}

private final class PreviewLog: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: [Int64] = []
    var order: [Int64] { lock.withLock { loaded } }
    func append(_ id: Int64) { lock.withLock { loaded.append(id) } }
}

@MainActor
@Suite struct LoupeLoaderTests {
    let sandbox: LibrarySandbox
    var photos: [Photo] { sandbox.session.photos }

    init() throws {
        sandbox = try LibrarySandbox()
    }

    @Test func theThumbnailStandsInUntilTheLargePictureIsRead() async {
        defer { sandbox.cleanUp() }
        let large = picture(2000)
        let loader = LoupeLoader { _ in large }
        loader.show(photos[0], placeholder: picture(512))
        #expect(loader.image?.width == 512 && loader.photoID == photos[0].id)
        await loader.waitUntilIdle()
        #expect(loader.image?.width == 2000)
    }

    /// Holding the arrow key down: only the photo one stops on matters.
    @Test func aPictureThatComesLateNeverReplacesTheCurrentOne() async {
        defer { sandbox.cleanUp() }
        let ids = photos.map(\.id)
        let loader = LoupeLoader { [ids] photo in
            if photo.id == ids[0] { Thread.sleep(forTimeInterval: 0.05) }
            return picture(photo.id == ids[0] ? 1000 : 2000)
        }
        loader.show(photos[0], placeholder: nil)
        loader.show(photos[1], placeholder: nil)
        await loader.waitUntilIdle()
        #expect(loader.photoID == ids[1] && loader.image?.width == 2000)
    }

    @Test func goingBackIsInstantAndTheNextPhotoIsReadAhead() async {
        defer { sandbox.cleanUp() }
        let log = PreviewLog()
        let loader = LoupeLoader { photo in
            log.append(photo.id)
            return picture(2000)
        }
        loader.show(photos[0], placeholder: nil, next: photos[1])
        await loader.waitUntilIdle()
        #expect(log.order == [photos[0].id, photos[1].id])

        loader.show(photos[1], placeholder: nil, next: photos[2])
        #expect(loader.image?.width == 2000)
        await loader.waitUntilIdle()
        loader.show(photos[0], placeholder: nil)
        #expect(loader.image?.width == 2000)
        await loader.waitUntilIdle()
        #expect(log.order == [photos[0].id, photos[1].id, photos[2].id])
    }

    @Test func anUnreadablePhotoSaysSo() async {
        defer { sandbox.cleanUp() }
        let loader = LoupeLoader { _ in nil }
        loader.show(photos[0], placeholder: nil)
        await loader.waitUntilIdle()
        #expect(loader.image == nil && loader.hasFailed)
    }

    /// An untouched photo shows the JPEG its camera embedded, which costs no development; an
    /// edited one shows its edits.
    @Test func thePictureIsReadFromTheFileItself() throws {
        defer { sandbox.cleanUp() }
        let image = try #require(LoupeLoader.embeddedPreview(of: TestPhoto.url, maxPixelSize: 600))
        #expect(max(image.width, image.height) <= 600 && image.width > image.height)
        #expect(LoupeLoader.embeddedPreview(of: sandbox.root.appendingPathComponent("missing.dng"), maxPixelSize: 600) == nil)
    }
}
