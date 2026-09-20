import Foundation
import Testing
@testable import RawEngine

@Suite struct AdjustmentGroupTests {
    /// Every field away from neutral, so that a group forgetting one of its fields shows.
    static let edited: Adjustments = {
        var a = Adjustments()
        a.exposure = 0.5; a.contrast = 10; a.highlights = -20; a.shadows = 30; a.whites = 5; a.blacks = -5
        a.curves.rgb.insert(.init(x: 0.5, y: 0.6))
        a.whiteBalance = WhiteBalance(temperature: 6000, tint: 4)
        a.vibrance = 15; a.saturation = -10
        a.blackAndWhite.isEnabled = true; a.blackAndWhite.red = 20
        a.enhance = 35; a.clarity = 20; a.structure = 10; a.dehaze = 15; a.glow = 25; a.grain = 30
        a.hsl[.blue].saturation = -30
        a.grading[.shadows] = ColorWheel(hue: 210, saturation: 40)
        a.sharpness = 60; a.luminanceNoiseReduction = 25; a.colorNoiseReduction = 70
        a.lensCorrection = false; a.vignetting = 35
        a.aberration = ChromaticAberration(redCyan: -20, blueYellow: 15); a.distortion = 25
        a.purpleFringe = PurpleFringe(amount: 40)
        a.lut = LUTSetting(name: "Teal", amount: 80)
        a.geometry.straighten = 2
        a.spots = [Spot(target: .init(x: 0.5, y: 0.5), source: .init(x: 0.6, y: 0.5), radius: 0.02)]
        a.locals = [LocalAdjustment(mask: .linear(LinearMask(start: .init(x: 0.5, y: 0.2), end: .init(x: 0.5, y: 0.6))))]
        return a
    }()

    @Test func copyingEveryGroupCopiesEverything() {
        var target = Adjustments()
        target.apply(Self.edited, groups: Set(AdjustmentGroup.allCases))
        #expect(target == Self.edited)
    }

    @Test(arguments: AdjustmentGroup.allCases)
    func aGroupCopiesItsFieldsAndNothingElse(group: AdjustmentGroup) {
        var target = Adjustments()
        target.apply(Self.edited, groups: [group])
        #expect(target != Adjustments(), "\(group) copied nothing")

        // Whatever it copied is its own: the other groups, together, restore neutral.
        var others = Self.edited
        others.apply(Adjustments(), groups: Set(AdjustmentGroup.allCases).subtracting([group]))
        #expect(others == target)
    }

    /// A field added to `Adjustments` without a group would silently stay out of presets.
    @Test func everyFieldOfTheDocumentBelongsToExactlyOneGroup() throws {
        let document = try JSONSerialization.jsonObject(with: Self.edited.jsonData()) as? [String: Any]
        let fields = Set(try #require(document).keys).subtracting(["version"])
        let claimed = AdjustmentGroup.allCases.flatMap(\.fields)
        #expect(Set(claimed) == fields)
        #expect(claimed.count == Set(claimed).count)
    }

    private func document(_ adjustments: Adjustments) throws -> [String: NSObject] {
        try #require(try JSONSerialization.jsonObject(with: adjustments.jsonData()) as? [String: NSObject])
    }

    /// The net above reads the keys of `edited`. A field left at neutral in `edited` would
    /// slip through it: an optional one is not even written. So `edited` must hold every
    /// stored property of `Adjustments`, each away from its neutral value.
    @Test func theEditedDocumentMovesEveryFieldAwayFromNeutral() throws {
        let (edited, neutral) = (try document(Self.edited), try document(Adjustments()))
        #expect(edited.count == Mirror(reflecting: Adjustments()).children.count)
        for (field, value) in edited where field != "version" {
            #expect(neutral[field] != value, "\(field) is neutral in `edited`")
        }
    }

    /// A field forgotten in the hand-written `init(from:)` decodes as neutral, for ever: only
    /// a round trip of a document where nothing is neutral can tell.
    @Test func theEditedDocumentSurvivesARoundTrip() throws {
        let decoded = try JSONDecoder().decode(Adjustments.self, from: Self.edited.jsonData())
        #expect(decoded == Self.edited)
        #expect(try document(decoded) == document(Self.edited))
    }

    @Test func groupsPresentInADocumentAreDetected() throws {
        let json = Data(#"{"contrast": 20, "hsl": {"red": {"hue": 5}}, "version": 1}"#.utf8)
        #expect(try AdjustmentGroup.groups(presentIn: json) == [.light, .hsl])
        #expect(AdjustmentGroup.groups(presentIn: ["contrast", "hsl", "version", "unknown"] as Set<String>) == [.light, .hsl])
        #expect(AdjustmentGroup.groups(presentIn: [] as Set<String>).isEmpty)
    }

    /// Framing and masks belong to one picture: copying settings leaves them out unless asked.
    @Test func whatBelongsToOnePictureStaysOutOfTheDefaultSelection() {
        #expect(AdjustmentGroup.defaultSelection == Set(AdjustmentGroup.allCases).subtracting([.geometry, .local, .spots]))
    }
}
