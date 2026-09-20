import Catalog
import Foundation
import SwiftUI
import Testing
@testable import SimpleRAWUI

/// Two frames of the same moment, side by side: the one thing a grid of thumbnails cannot
/// settle. The photo being judged is the selected one, so rating, flagging and labelling
/// work exactly as they do everywhere else.
@MainActor
@Suite struct ComparisonTests {
    let sandbox: LibrarySandbox
    var session: LibrarySession { sandbox.session }

    init() throws {
        sandbox = try LibrarySandbox()
    }

    @Test func comparingTakesTheTwoSelectedPhotos() {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        #expect(!session.isComparing && session.comparedPhotos.isEmpty)

        session.select(ids[1])
        session.select(ids[3], extending: false, toggling: true)
        session.toggleComparing()
        #expect(session.isComparing)
        #expect(session.comparedPhotos.map(\.id) == [ids[1], ids[3]])
        // One of the two is the one being judged: what a rating would land on.
        #expect(session.selection == [ids[1]])
    }

    /// One photo selected: it is compared with the one next to it, which is what "is the
    /// next frame better?" means.
    @Test func withOnePhotoItComparesWithTheNextOne() {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        session.select(ids[0])
        session.toggleComparing()
        #expect(session.comparedPhotos.map(\.id) == [ids[0], ids[1]])

        // At the end of the grid, with the one before it.
        session.stopComparing()
        session.select(ids[4])
        session.toggleComparing()
        #expect(session.comparedPhotos.map(\.id) == [ids[3], ids[4]])
        #expect(session.selection == [ids[4]], "the photo asked for stays the one being judged")
    }

    @Test func aLibraryOfOnePhotoHasNothingToCompare() throws {
        let small = try LibrarySandbox(photos: 1)
        defer { small.cleanUp() }
        small.session.selectAll()
        small.session.toggleComparing()
        #expect(!small.session.isComparing)
    }

    /// Left and right choose which of the two is being judged, rather than walking the grid.
    @Test func arrowsMoveBetweenTheTwoSides() {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        session.select(ids[1])
        session.select(ids[3], extending: false, toggling: true)
        session.toggleComparing()

        session.move(.right)
        #expect(session.selection == [ids[3]])
        session.move(.right)
        #expect(session.selection == [ids[3]], "there is no third photo to go to")
        session.move(.left)
        #expect(session.selection == [ids[1]])
        // Up and down have no meaning between two pictures.
        session.move(.down)
        #expect(session.selection == [ids[1]])
    }

    @Test func ratingLandsOnThePhotoBeingJudged() {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        session.select(ids[0])
        session.toggleComparing()
        session.move(.right)
        session.setRating(4)
        #expect(session.photos.first { $0.id == ids[1] }?.rating == 4)
        #expect(session.photos.first { $0.id == ids[0] }?.rating == 0)
        #expect(session.isComparing, "rating does not end the comparison")
    }

    @Test func comparingAndTheLoupeAreNeverBothOn() {
        defer { sandbox.cleanUp() }
        session.select(session.photos[0].id)
        session.toggleLoupe()
        session.toggleComparing()
        #expect(session.isComparing && !session.isLoupeOpen)

        session.toggleLoupe()
        #expect(session.isLoupeOpen && !session.isComparing)
    }

    /// A photo that leaves the grid — the filter changed, it was removed — takes the
    /// comparison with it rather than leaving half of it on screen.
    @Test func aComparedPhotoLeavingTheGridEndsIt() async throws {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        session.select(ids[0])
        session.toggleComparing()
        #expect(session.isComparing)

        session.setFlag(.rejected)
        session.filter.flags = [.picked]
        await session.settle()
        #expect(!session.isComparing && session.comparedPhotos.isEmpty)
    }

    /// C compares, in the grid only: in the develop view it is the crop tool.
    @Test func theKeyThatCompares() {
        #expect(KeyRouter.command(for: .init(characters: "c", isShiftDown: false), mode: .library, tool: .none, isTypingText: false) == .toggleComparing)
        #expect(KeyRouter.command(for: .init(characters: "c", isShiftDown: false), mode: .develop, tool: .none, isTypingText: false) == .setTool(.crop))
    }

    @Test func escapeLeavesTheComparison() {
        #expect(LibraryKeyMap.command(key: .escape, characters: "\u{1B}", modifiers: [], isLoupeOpen: false, isComparing: true) == .closeLoupe)
        #expect(LibraryKeyMap.command(key: .escape, characters: "\u{1B}", modifiers: [], isLoupeOpen: false, isComparing: false) == nil)
        // Select All would rate both sides: not while two pictures are being judged.
        #expect(LibraryKeyMap.command(key: "a", characters: "a", modifiers: .command, isLoupeOpen: false, isComparing: true) == nil)
    }
}
