import ArgumentParser
import Foundation
import RawEngine

struct Develop: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Develops a RAW file into a JPEG.",
        discussion: """
            Settings come from a JSON file (--adjustments), from options, or both: options \
            win. Any slider can be set by the name it has in the JSON document: --set clarity=20 \
            --set grain=15. For a negative value, write --exposure=-0.5 or --set exposure=-0.5.
            """
    )

    @Argument(help: "RAW file.", transform: URL.init(fileURLWithPath:))
    var input: URL

    @Option(name: .shortAndLong, help: "Output file (default: <input>.jpg).", transform: URL.init(fileURLWithPath:))
    var output: URL?

    @Option(name: .shortAndLong, help: "JSON adjustments file.", transform: URL.init(fileURLWithPath:))
    var adjustments: URL?

    @Option(help: "Exposure, in EV.") var exposure: Double?
    @Option(help: "Contrast, from -100 to 100.") var contrast: Double?
    @Option(help: "Highlights, from -100 to 100.") var highlights: Double?
    @Option(help: "Shadows, from -100 to 100.") var shadows: Double?
    @Option(help: "Whites, from -100 to 100.") var whites: Double?
    @Option(help: "Blacks, from -100 to 100.") var blacks: Double?
    @Option(help: "Color temperature, in kelvins.") var temperature: Double?
    @Option(help: "Tint (green ↔ magenta).") var tint: Double?
    @Option(help: "Enhance, from 0 to 100: one slider that improves most pictures.") var enhance: Double?
    @Option(help: "Vibrance, from -100 to 100.") var vibrance: Double?
    @Option(help: "Saturation, from -100 to 100.") var saturation: Double?
    @Option(help: "Sharpness, from 0 to 100.") var sharpness: Double?
    @Option(help: "Luminance noise reduction, from 0 to 100.") var luminanceNr: Double?
    @Option(help: "Color noise reduction, from 0 to 100.") var colorNr: Double?
    @Flag(help: "Disables lens correction.") var noLensCorrection = false
    @Option(help: "Vignetting, from -100 (darker corners) to 100 (brighter corners).") var vignetting: Double?

    @Option(help: "JPEG quality, from 0 to 1.") var quality: Double = 0.92
    @Option(help: "Long edge size, in pixels.") var longEdge: Int?
    @Option(help: "Output color space: srgb or p3.") var colorSpace: ExportOptions.ColorSpace = .sRGB
    @Option(name: .customLong("set"), parsing: .singleValue, help: "A setting by its JSON name, as name=value. May be repeated.")
    var settings: [String] = []

    @Flag(help: "Sets light and vibrance automatically, over the JSON file if there is one and before any other option applies.") var auto = false
    @Flag(help: "Prints the adjustments actually applied, as JSON.") var printAdjustments = false

    func run() throws {
        let start = Date()
        let source = try RawSource(url: input)
        // The document first, then Auto over its light sliders, as the button does in the app
        // on a photo already edited; explicit options have the last word. Auto used to be
        // thrown away as soon as a document was given.
        var base = try adjustments.map(Adjustments.init(contentsOf:)) ?? Adjustments()
        if auto { try AutoTone.settings(for: source).apply(to: &base) }
        let resolved = try resolvedAdjustments(from: base, asShot: source.info.asShotWhiteBalance)

        var options = ExportOptions()
        options.quality = quality
        options.longEdge = longEdge
        options.colorSpace = colorSpace

        let destination = output ?? input.deletingPathExtension().appendingPathExtension("jpg")
        try Renderer.shared.writeJPEG(source.image(adjustments: resolved), to: destination, options: options)

        if printAdjustments {
            print(String(decoding: try resolved.jsonData(), as: UTF8.self))
        }
        let elapsed = Date().timeIntervalSince(start).formatted(.number.precision(.fractionLength(2)))
        print("\(FileName.displayable(destination.path)) (\(elapsed) s)")
    }

    private func resolvedAdjustments(from base: Adjustments, asShot: WhiteBalance) throws -> Adjustments {
        var result = base
        if let exposure { result.exposure = exposure }
        if let contrast { result.contrast = contrast }
        if let highlights { result.highlights = highlights }
        if let shadows { result.shadows = shadows }
        if let whites { result.whites = whites }
        if let blacks { result.blacks = blacks }
        if let enhance { result.enhance = enhance }
        if let vibrance { result.vibrance = vibrance }
        if let saturation { result.saturation = saturation }
        if let sharpness { result.sharpness = sharpness }
        if let luminanceNr { result.luminanceNoiseReduction = luminanceNr }
        if let colorNr { result.colorNoiseReduction = colorNr }
        if noLensCorrection { result.lensCorrection = false }
        if let vignetting { result.vignetting = vignetting }
        if let temperature { result.setTemperature(temperature, asShot: asShot) }
        if let tint { result.setTint(tint, asShot: asShot) }
        // Every slider of the engine, by name: no list to keep up here.
        for setting in settings { try AdjustmentParameter.apply(setting, to: &result) }
        return result
    }
}

extension ExportOptions.ColorSpace: ExpressibleByArgument {}
