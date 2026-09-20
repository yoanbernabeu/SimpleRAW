import Foundation
import RawEngine
import Testing
@testable import Catalog

/// A photo can keep several developments under a name: the color one and the black and white
/// one, say. They belong to the photo: they go with it, and they are backed up with it.
@Suite struct VersionTests {
    let catalog: PhotoCatalog
    let photo: Int64

    init() throws {
        catalog = try PhotoCatalog.inMemory()
        photo = try catalog.add(makePhoto())
    }

    private var blackAndWhite: Adjustments {
        var adjustments = Adjustments()
        adjustments.blackAndWhite.isEnabled = true
        return adjustments
    }

    @Test func aVersionKeepsItsSettingsUnderAName() throws {
        #expect(try catalog.versions(of: photo).isEmpty)
        let id = try catalog.saveVersion(named: "Black & white", of: photo, adjustments: blackAndWhite)
        let versions = try catalog.versions(of: photo)
        #expect(versions.map(\.name) == ["Black & white"] && versions[0].id == id)
        #expect(try versions[0].adjustments == blackAndWhite)
    }

    @Test func versionsComeInTheOrderTheyWereMadeAndCanBeRenamedAndDeleted() throws {
        let first = try catalog.saveVersion(named: "Color", of: photo, adjustments: Adjustments())
        let second = try catalog.saveVersion(named: "B&W", of: photo, adjustments: blackAndWhite)
        try catalog.renameVersion(second, to: "Black & white")
        #expect(try catalog.versions(of: photo).map(\.name) == ["Color", "Black & white"])
        try catalog.deleteVersion(first)
        #expect(try catalog.versions(of: photo).map(\.id) == [second])
    }

    @Test func aBlankNameIsRefused() throws {
        #expect(throws: (any Error).self) { try catalog.saveVersion(named: "  ", of: photo, adjustments: Adjustments()) }
    }

    @Test func versionsGoWithTheirPhoto() throws {
        let other = try catalog.add(makePhoto("R0002.DNG"))
        _ = try catalog.saveVersion(named: "Color", of: photo, adjustments: Adjustments())
        _ = try catalog.saveVersion(named: "Other", of: other, adjustments: Adjustments())
        try catalog.remove([photo])
        #expect(try catalog.versions(of: photo).isEmpty)
        #expect(try catalog.versions(of: other).count == 1)
    }

    /// A backup only goes when the revision moved: a saved version is something to back up.
    @Test func savingAVersionMovesTheRevision() throws {
        let before = try catalog.revision
        _ = try catalog.saveVersion(named: "Color", of: photo, adjustments: Adjustments())
        #expect(try catalog.revision > before)
    }
}
