import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// A printing profile the picture can be shown through, so that what is on screen is what
/// will come off the paper.
///
/// A print is a narrower thing than a screen: dark blues block up, bright greens flatten,
/// and a photograph that sings on a display can print dull in exactly the places that made
/// it. Soft proofing renders the picture into the profile of the paper and back, so the
/// screen shows those losses while there is still time to work around them.
///
/// It is a **viewing condition, not a setting**: nothing about it is stored in the photo's
/// adjustments, and it changes no exported file.
public struct PrintProfile: Equatable, Sendable, Identifiable {
    public let name: String
    public let url: URL
    public var id: URL { url }

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }

    /// The colour space of the profile, read from its file. `nil` for a file that is not one.
    public func colorSpace() -> CGColorSpace? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return CGColorSpace(iccData: data as CFData)
    }
}

/// Where printing profiles are found: the folders ColorSync uses, which is where a printer's
/// installer puts them and where a paper maker's download is dropped by hand.
public enum ProfileLibrary {
    public static var folders: [URL] {
        [
            URL(fileURLWithPath: "/Library/ColorSync/Profiles", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/ColorSync/Profiles"),
            URL(fileURLWithPath: "/System/Library/ColorSync/Profiles", isDirectory: true),
        ]
    }

    /// Every profile the machine holds, by name, without duplicates, in name order.
    public static func profiles(in folders: [URL] = folders) -> [PrintProfile] {
        var byName: [String: PrintProfile] = [:]
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where ["icc", "icm"].contains(file.pathExtension.lowercased()) {
                let name = file.deletingPathExtension().lastPathComponent
                // The first folder wins: a profile installed for this Mac comes before the
                // system's copy of the same name.
                if byName[name] == nil { byName[name] = PrintProfile(name: name, url: file) }
            }
        }
        return byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Shows a picture as a given profile would print it.
///
/// The round trip is done by **ColorSync**, colour by colour, and baked into a lookup table:
/// `CIImage.matchedFromWorkingSpace(to:)` answers nothing for a CMYK profile, which is what
/// most papers come as, and in floating point a round trip through a narrow profile is
/// lossless anyway — a colour the ink cannot hold comes out as a number outside zero to one
/// and goes back exactly as it was. Converted as a colour, it is held to what the profile can
/// say, and the loss is real. That is what there is to look at.
///
/// Building the table costs a few hundred milliseconds, once per profile: never on the main
/// thread, and never per frame. Applying it costs what any lookup table costs.
public struct SoftProof: Sendable {
    /// How far a colour must move on the round trip before it counts as lost, as a distance
    /// in display-referred RGB. Two percent is about where an eye starts to see it.
    public static let gamutThreshold: Float = 0.02
    /// What lost colour is painted in: a flat mid grey, the way a proofing view does it.
    static let warningGrey = SIMD3<Float>(repeating: 0.5)

    private let cube: ColorCube

    public init?(profile: PrintProfile, warnsAboutGamut: Bool = false) {
        guard let colorSpace = profile.colorSpace() else { return nil }
        self.init(colorSpace: colorSpace, warnsAboutGamut: warnsAboutGamut)
    }

    public init(colorSpace: CGColorSpace, warnsAboutGamut: Bool = false) {
        let paper = ColorSyncRoundTrip(to: colorSpace)
        cube = ColorCube { rgb in
            guard let printed = paper.printed(rgb) else { return rgb }
            guard warnsAboutGamut else { return printed }
            let lost = printed - rgb
            let distance = (lost * lost).sum().squareRoot()
            return distance > Self.gamutThreshold ? Self.warningGrey : printed
        }
    }

    /// The picture as the paper would give it back.
    public func applied(to image: CIImage) -> CIImage {
        cube.apply(to: image)
    }
}

/// One colour, through a profile and back, as ColorSync does it.
private struct ColorSyncRoundTrip: Sendable {
    let paper: CGColorSpace
    let screen = CGColorSpace(name: CGColorSpace.sRGB)!

    init(to paper: CGColorSpace) {
        self.paper = paper
    }

    /// Relative colorimetric: what a proof is judged on, since it keeps the colours that do
    /// print exactly where they are and only moves the ones that cannot.
    func printed(_ rgb: SIMD3<Float>) -> SIMD3<Float>? {
        let components = [CGFloat(rgb.x), CGFloat(rgb.y), CGFloat(rgb.z), 1]
        guard let colour = CGColor(colorSpace: screen, components: components),
              let ink = colour.converted(to: paper, intent: .relativeColorimetric, options: nil),
              let back = ink.converted(to: screen, intent: .relativeColorimetric, options: nil),
              let printed = back.components, printed.count >= 3 else { return nil }
        return SIMD3(Float(printed[0]), Float(printed[1]), Float(printed[2]))
    }
}
