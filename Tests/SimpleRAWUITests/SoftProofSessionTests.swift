import CoreImage
import Foundation
import RawEngine
import TestSupport
import Testing
@testable import SimpleRAWUI

/// Judging a photo against the paper it is going to be printed on. A viewing condition, not
/// a setting: it must change what is on screen and nothing else.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SoftProofSessionTests {
    let session = DevelopSession()
    let probe = PixelProbe()
    let viewSize = CGSize(width: 400, height: 300)

    init() throws {
        session.open(TestPhoto.url)
    }

    private func cmyk() throws -> PrintProfile {
        try #require(session.printProfiles.first { $0.name.contains("CMYK") }, "ColorSync ships a CMYK profile")
    }

    @Test func theMachinesProfilesAreOffered() throws {
        #expect(session.printProfiles.count > 3)
        #expect(session.softProofProfile == nil, "the screen, until a paper is chosen")
    }

    /// The table takes a few hundred milliseconds to build, so the picture is shown as it was
    /// until it is ready: a picture shown in the wrong colours for a moment would be worse
    /// than one shown a moment late.
    @Test func thePictureChangesOnceTheProofIsBuilt() async throws {
        let plain = try #require(session.previewImage(fitting: viewSize))
        let before = try probe.average(of: plain)

        session.setSoftProof(try cmyk())
        await session.softProofSettled()
        let proofed = try #require(session.previewImage(fitting: viewSize))
        #expect(proofed.extent == plain.extent, "proofing changes the colours, not the frame")
        let after = try probe.average(of: proofed)
        #expect(after.chroma < before.chroma + 0.001, "ink holds no more colour than a screen")

        session.setSoftProof(nil)
        await session.softProofSettled()
        let back = try probe.average(of: try #require(session.previewImage(fitting: viewSize)))
        #expect(abs(back.r - before.r) < 0.001 && abs(back.g - before.g) < 0.001)
    }

    /// Nothing of it is stored with the photo, and nothing of it reaches a file.
    @Test func proofingIsNotAnEdit() async throws {
        let edits = session.adjustments
        session.setSoftProof(try cmyk(), warnsAboutGamut: true)
        await session.softProofSettled()
        #expect(session.adjustments == edits, "proofing is not an edit")
        #expect(!session.canUndo, "and takes no step")
    }

    @Test func theWarningIsOnlyOfferedWithAPaper() async throws {
        session.setSoftProofWarnsAboutGamut(true)
        #expect(session.softProofWarnsAboutGamut)
        #expect(session.softProofProfile == nil, "warning about nothing changes no picture")
        let plain = try #require(session.previewImage(fitting: viewSize))
        #expect(try probe.average(of: plain).chroma > 0, "without a paper, the picture is the picture")
    }

    /// Choosing another paper while the first is still being built must not leave the picture
    /// showing the first one.
    @Test func thelastPaperChosenIsTheOneShown() async throws {
        let profiles = session.printProfiles.filter { $0.colorSpace() != nil }
        try #require(profiles.count >= 2)
        session.setSoftProof(profiles[0])
        session.setSoftProof(profiles[1])
        await session.softProofSettled()
        #expect(session.softProofProfile == profiles[1])
    }
}
