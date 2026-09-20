import CoreImage
import Foundation
import Testing
import TestSupport
@testable import RawEngine

/// Showing a picture through the profile of the paper it is going to be printed on.
@Suite struct SoftProofTests {
    let probe = PixelProbe()

    /// A saturated green: inside what a screen shows, well outside what ink holds.
    let vividGreen = PixelProbe.swatch(r: 0.0, g: 0.95, b: 0.1, size: CGSize(width: 60, height: 40))
    /// A grey, which every profile ever made can print.
    let grey = PixelProbe.swatch(r: 0.45, g: 0.45, b: 0.45, size: CGSize(width: 60, height: 40))

    private func cmyk(warnsAboutGamut: Bool = false) throws -> SoftProof {
        let profile = try #require(
            ProfileLibrary.profiles().first { $0.name.contains("Generic CMYK") },
            "no CMYK profile on this machine: ColorSync ships one"
        )
        return try #require(SoftProof(profile: profile, warnsAboutGamut: warnsAboutGamut))
    }

    @Test func theMachineOffersTheProfilesColorSyncHolds() throws {
        let profiles = ProfileLibrary.profiles()
        #expect(profiles.count > 3)
        #expect(profiles.contains { $0.name.contains("CMYK") }, "\(profiles.map(\.name))")
        // Sorted by name, and each name appears once however many folders hold it.
        #expect(profiles.map(\.name) == profiles.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(Set(profiles.map(\.name)).count == profiles.count)
    }

    @Test func aFileThatIsNotAProfileIsNotOffered() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "simpleraw-profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("not a profile".utf8).write(to: folder.appending(path: "Broken.icc"))

        let profile = try #require(ProfileLibrary.profiles(in: [folder]).first)
        #expect(profile.colorSpace() == nil)
        #expect(SoftProof(profile: profile) == nil, "a file that is not a profile proofs nothing")
    }

    /// The point of the whole thing: a colour the ink cannot hold comes back changed, and a
    /// grey comes back as it went.
    @Test func whatThePaperCannotHoldComesBackChanged() throws {
        let proof = try cmyk()
        let printed = try probe.average(of: proof.applied(to: vividGreen))
        let onScreen = try probe.average(of: vividGreen)
        #expect(abs(printed.g - onScreen.g) > 0.02 || abs(printed.r - onScreen.r) > 0.02, "\(onScreen) → \(printed)")
        #expect(printed.chroma < onScreen.chroma, "ink holds less colour than a screen")

        let neutral = try probe.average(of: proof.applied(to: grey))
        let asShown = try probe.average(of: grey)
        #expect(abs(neutral.luminance - asShown.luminance) < 0.02, "a grey prints as a grey")
    }

    /// The warning says *where* the colour is lost, not by how much: flat grey over those
    /// pixels, and nothing at all over the ones that print.
    @Test func theGamutWarningMarksOnlyWhatIsLost() throws {
        let side = CGSize(width: 60, height: 40)
        let picture = vividGreen.transformed(by: CGAffineTransform(translationX: 60, y: 0))
            .composited(over: PixelProbe.swatch(r: 0.45, g: 0.45, b: 0.45, size: CGSize(width: 120, height: 40)))
        let marked = try cmyk(warnsAboutGamut: true).applied(to: picture)

        let green = try probe.average(of: marked, in: CGRect(x: 70, y: 10, width: 20, height: 20))
        #expect(green.chroma < 0.02, "what the paper cannot hold is marked flat")
        let kept = try probe.average(of: marked, in: CGRect(x: 10, y: 10, width: 20, height: 20))
        #expect(abs(kept.luminance - 0.45) < 0.06, "what prints is left as it is: \(kept)")
        #expect(marked.extent == picture.extent)
        _ = side
    }

    /// Without the warning, proofing only shows the picture as it will print.
    @Test func withoutTheWarningNothingIsPainted() throws {
        let proof = try cmyk()
        let plain = try probe.average(of: proof.applied(to: vividGreen))
        #expect(plain.chroma > 0.1, "the proof is still a picture, not a flat mark")
    }
}
