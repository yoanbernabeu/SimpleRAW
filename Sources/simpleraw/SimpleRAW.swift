import ArgumentParser
import Catalog
import Foundation
import RawEngine

@main
struct SimpleRAW: ParsableCommand {
    /// A render gone wrong must cost this process, not the computer.
    static func main() {
        MemoryFuse.arm()
        main(nil)
    }

    static let configuration = CommandConfiguration(
        commandName: "simpleraw",
        abstract: "Develops RAW files with the SimpleRAW engine.",
        subcommands: [Develop.self, Batch.self, Import.self, Presets.self, Info.self, Preview.self, Noise.self, Plist.self],
        defaultSubcommand: Develop.self
    )
}

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Shows what the engine knows about a RAW file.")

    @Argument(help: "RAW file.", transform: URL.init(fileURLWithPath:))
    var input: URL

    func run() throws {
        let info = try RawSource(url: input).info
        let rows: [(String, String?)] = [
            ("Camera", info.model ?? info.make),
            ("Lens", info.lens),
            ("Dimensions", ExposureFormat.dimensions(info.nativeSize)),
            ("Date", info.captureDateText),
            ("ISO", info.iso.map(String.init)),
            ("Shutter speed", info.exposureTime.map { ExposureFormat.shutterSpeed($0) }),
            ("Aperture", info.aperture.map { ExposureFormat.aperture($0) }),
            ("Focal length", info.focalLength.map { ExposureFormat.focalLength($0) }),
            ("White balance", "\(ExposureFormat.kelvins(info.asShotWhiteBalance.temperature)), tint \(info.asShotWhiteBalance.tint.formatted(.number.precision(.fractionLength(1))))"),
            ("Baseline exposure", info.baselineExposure.map { "\($0.formatted(.number.precision(.fractionLength(2)).sign(strategy: .always()))) EV" }),
            ("Decoder", info.decoderVersion),
            ("Sharpness", Self.support(info.capabilities.sharpness)),
            ("Luminance noise reduction", Self.support(info.capabilities.luminanceNoiseReduction)),
            ("Color noise reduction", Self.support(info.capabilities.colorNoiseReduction)),
            ("Lens correction", Self.support(info.capabilities.lensCorrection)),
        ]
        for (label, value) in rows {
            // Camera and lens names come from the file.
            print("\(label.padding(toLength: 27, withPad: " ", startingAt: 0)) \(FileName.displayable(value ?? ExposureFormat.missing))")
        }
    }

    private static func support(_ supported: Bool) -> String {
        supported ? "supported" : "not supported"
    }
}

struct Noise: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Measures what can be done about the noise in a photograph.",
        discussion: """
            Renders the middle of the file twice — once neutral, once with a setting pushed to \
            its end — and prints how far apart the two are, as a fraction of full luminance. \
            One level out of 255 is 0.0039, so anything under half of that is a difference \
            nobody can see. Sharpening is measured too, as a yardstick: it is a setting \
            everybody can see.

            This is what settles whether a photograph needs more denoising than the decoder \
            gives it. On a Ricoh GR III at ISO 100 and 400 the answer is no, by a factor of \
            fifty; the question is worth asking again on a file shot at 3200 or 6400.
            """
    )

    @Argument(help: "RAW file.", transform: URL.init(fileURLWithPath:))
    var input: URL

    @Option(name: .shortAndLong, help: "Measure the photo as it will be developed, in EV: write --exposure=3 to push a dark frame back up.")
    var exposure: Double = 0

    func run() throws {
        let report = try NoiseReport.measure(input, exposure: exposure)
        print("ISO                         \(report.iso.map(String.init) ?? ExposureFormat.missing)")
        if report.exposure != 0 {
            print(String(format: "Measured at                 %+.1f EV", report.exposure))
        }
        if report.isRaw {
            print(String(format: "Decoder's own denoising     luminance %.3f, colour %.3f (out of 1)",
                         report.defaults.luminanceNoiseReduction / 100, report.defaults.colorNoiseReduction / 100))
        } else {
            print("Decoder's own denoising     none: not a RAW file")
        }
        print("")
        for change in report.changes {
            // Formatted, not localized: the output of this tool is read next to a number
            // written down last month, and a decimal comma would not compare with a point.
            let label = change.name.padding(toLength: 40, withPad: " ", startingAt: 0)
            print(label + String(format: " %.5f  ", change.amount) + (change.isVisible ? "visible" : "not visible"))
        }
        print("")
        print(report.holdsVisibleNoiseControl
            ? "There is noise here that the app can act on."
            : "Nothing the app can do about noise shows on this file.")
    }
}

struct Plist: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Prints the property list the app bundle is built with.",
        discussion: """
            A build tool, not something to run every day: `scripts/make-app.sh` asks for these \
            rather than keeping a copy of them. The list of file types the app offers to open \
            is the one the importer uses, so the two can never say different things.
            """
    )

    // Qualified: the catalog has a `Flag` of its own, the one a photographer puts on a photo.
    @ArgumentParser.Flag(help: "Print the rights the bundle asks for instead: the sandbox and what it needs.")
    var entitlements = false

    func run() {
        print(entitlements ? AppBundle.entitlements : AppBundle.infoPlist, terminator: "")
    }
}

struct Preview: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Extracts the JPEG embedded by the camera, to compare renderings."
    )

    @Argument(help: "RAW file.", transform: URL.init(fileURLWithPath:))
    var input: URL

    @Option(name: .shortAndLong, help: "Output file (default: <input>-preview.jpg).", transform: URL.init(fileURLWithPath:))
    var output: URL?

    func run() throws {
        let destination = output ?? input.deletingPathExtension().appendingToFileName("-preview", extension: "jpg")
        try Renderer.shared.writeJPEG(RawSource(url: input).embeddedPreview(), to: destination)
        print(FileName.displayable(destination.path))
    }
}

extension URL {
    func appendingToFileName(_ suffix: String, extension ext: String) -> URL {
        deletingLastPathComponent().appendingPathComponent(lastPathComponent + suffix).appendingPathExtension(ext)
    }
}
