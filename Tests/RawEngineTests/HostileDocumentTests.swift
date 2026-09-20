import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RawEngine

/// A sidecar, a look or a catalog row may come from anywhere: downloaded, shared, restored.
/// Whatever it holds, decoding gives a document the engine can render, or a clear error.
/// One case per field.
@Suite struct HostileDocumentTests {
    static let huge = "1e308"

    private func decode(_ json: String) throws -> Adjustments {
        try JSONDecoder().decode(Adjustments.self, from: Data(json.utf8))
    }

    // MARK: Scalars

    @Test func exposureIsBounded() throws {
        #expect(try decode(#"{"exposure": \#(Self.huge)}"#).exposure == 10)
        #expect(try decode(#"{"exposure": -\#(Self.huge)}"#).exposure == -10)
        #expect(try decode(#"{"exposure": 7.5}"#).exposure == 7.5)
    }

    @Test func whiteBalanceIsBounded() throws {
        #expect(try decode(#"{"whiteBalance": {"temperature": 0, "tint": -1e9}}"#).whiteBalance == WhiteBalance(temperature: 1500, tint: -150))
        #expect(try decode(#"{"whiteBalance": {"temperature": 1e12, "tint": 1e9}}"#).whiteBalance == WhiteBalance(temperature: 50000, tint: 150))
    }

    /// Every plain slider, whatever gets added later: the table says how far each may go.
    @Test(arguments: AdjustmentParameter.all)
    func everySliderIsBounded(parameter: AdjustmentParameter) throws {
        let high = try decode(#"{"\#(parameter.name)": \#(Self.huge)}"#)
        let low = try decode(#"{"\#(parameter.name)": -\#(Self.huge)}"#)
        #expect(parameter.value(in: high) == parameter.bounds.upperBound)
        #expect(parameter.value(in: low) == parameter.bounds.lowerBound)
    }

    // MARK: Geometry

    @Test func straightenIsBounded() throws {
        #expect(try decode(#"{"geometry": {"straighten": 1e6}}"#).geometry.straighten == 45)
        #expect(try decode(#"{"geometry": {"straighten": -1e6}}"#).geometry.straighten == -45)
    }

    @Test(arguments: [
        #"{"x": 0.2, "y": 0.2, "width": 0, "height": 0}"#,
        #"{"x": 0.2, "y": 0.2, "width": -3, "height": -0.5}"#,
        #"{"x": -50, "y": 1e308, "width": 1e308, "height": 1e9}"#,
        #"{"x": 0.99, "y": 0.99, "width": 0.5, "height": 0.5}"#,
        #"{"x": 5, "y": 5, "width": 0.001, "height": 0.001}"#,
    ])
    func aCropStaysInsideTheFrameAndKeepsASide(crop: String) throws {
        let geometry = try decode(#"{"geometry": {"crop": \#(crop)}}"#).geometry
        let rect = geometry.crop ?? .full
        #expect(rect.x >= 0 && rect.y >= 0 && rect.maxX <= 1 + 1e-12 && rect.maxY <= 1 + 1e-12)
        #expect(rect.width >= CropRect.minimumSide - 1e-12 && rect.height >= CropRect.minimumSide - 1e-12)
        let size = geometry.outputSize(for: CGSize(width: 6000, height: 4000))
        #expect(size.width >= 1 && size.height >= 1 && size.width <= 6000 && size.height <= 4000)
    }

    // MARK: Masks and spots

    @Test func aRadialMaskIsBounded() throws {
        let document = try decode(#"{"locals": [{"id": "7E57AB1E-0000-4000-8000-000000000001", "opacity": 1e9, "mask": {"radial": {"center": {"x": 1e308, "y": -1e308}, "radiusX": 0, "radiusY": 1e12, "feather": 40, "isInverted": false}}}]}"#)
        guard case .radial(let mask) = document.locals[0].mask else { Issue.record("not a radial mask"); return }
        #expect(mask.center == NormalizedPoint(x: 2, y: -1))
        #expect(mask.radiusX > 0 && mask.radiusX <= 1 && mask.radiusY == 1)
        #expect(mask.feather == 1)
        #expect(document.locals[0].opacity == 100)
    }

    @Test func aGradientIsBounded() throws {
        let document = try decode(#"{"locals": [{"id": "7E57AB1E-0000-4000-8000-000000000002", "mask": {"linear": {"start": {"x": -1e30, "y": 0.5}, "end": {"x": 0.5, "y": 1e30}}}}]}"#)
        guard case .linear(let mask) = document.locals[0].mask else { Issue.record("not a gradient"); return }
        #expect(mask.start == NormalizedPoint(x: -1, y: 0.5) && mask.end == NormalizedPoint(x: 0.5, y: 2))
    }

    @Test func aBrushIsBounded() throws {
        let document = try decode(#"{"locals": [{"id": "7E57AB1E-0000-4000-8000-000000000003", "mask": {"brush": {"strokes": [{"points": [{"x": 1e308, "y": 0.5}], "radius": 1e308, "isErasing": false}, {"points": [{"x": 0.5, "y": 0.5}], "radius": -4, "isErasing": true}]}}}]}"#)
        guard case .brush(let mask) = document.locals[0].mask else { Issue.record("not a brush"); return }
        #expect(mask.strokes[0].points == [NormalizedPoint(x: 2, y: 0.5)])
        #expect(mask.strokes[0].radius == 1)
        #expect(mask.strokes[1].radius > 0 && mask.strokes[1].radius <= 1)
    }

    @Test func localSettingsAreBounded() throws {
        let settings = try decode(#"{"locals": [{"id": "7E57AB1E-0000-4000-8000-000000000004", "mask": {"brush": {"strokes": []}}, "settings": {"exposure": 1e308, "contrast": -1e308, "temperature": 1e308}}]}"#).locals[0].settings
        #expect(settings.exposure == 10 && settings.contrast == -100 && settings.temperature == 100)
    }

    @Test func aSpotIsBounded() throws {
        let spot = try decode(#"{"spots": [{"id": "7E57AB1E-0000-4000-8000-000000000005", "target": {"x": 1e308, "y": 0.5}, "source": {"x": 0.5, "y": -1e308}, "radius": 1e308, "feather": -3}]}"#).spots[0]
        #expect(spot.target.x == 2 && spot.source.y == -1)
        #expect(spot.radius == 1 && spot.feather == 0)
    }

    // MARK: Curves and color

    @Test func curvePointsStayInTheUnitSquareAndApart() throws {
        let curve = try decode(#"{"curves": {"rgb": {"points": [{"x": -5, "y": -5}, {"x": 0.5, "y": 0.2}, {"x": 0.500000000001, "y": 0.9}, {"x": 9, "y": 9}]}}}"#).curves.rgb
        #expect(curve.points.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        for (previous, next) in zip(curve.points, curve.points.dropFirst()) {
            #expect(next.x - previous.x >= Curve.minimumGap - 1e-12)
        }
        // A secant between points a hair apart was infinite, and the table full of NaN.
        #expect(curve.lookupTable(size: 1024).allSatisfy { $0.isFinite && (0...1).contains($0) })
    }

    @Test func colorPanelsAreBounded() throws {
        let document = try decode(#"{"hsl": {"red": {"hue": 1e308, "saturation": -1e308}}, "grading": {"shadows": {"hue": 1e308, "saturation": 1e308, "luminance": -1e308}, "balance": 1e308}, "blackAndWhite": {"isEnabled": true, "red": 1e308}}"#)
        #expect(document.hsl[.red].hue == 100 && document.hsl[.red].saturation == -100)
        #expect(document.grading[.shadows].saturation == 100 && document.grading[.shadows].luminance == -100)
        #expect((0..<360).contains(document.grading[.shadows].hue))
        #expect(document.grading.balance == 100 && document.blackAndWhite.red == 100)
    }

    // MARK: How many

    private func points(_ count: Int) -> String {
        (0..<count).map { #"{"x": \#(Double($0) / Double(count)), "y": 0.5}"# }.joined(separator: ",")
    }

    private func expectTooMany(_ what: String, limit: Int, _ json: String) {
        #expect(throws: RawEngineError.tooManyItems(what, count: limit + 1, limit: limit)) { try decode(json) }
    }

    @Test func aCurveHoldsSixteenPointsAtMost() throws {
        #expect(try decode(#"{"curves": {"red": {"points": [\#(points(16))]}}}"#).curves.red.points.count > 2)
        expectTooMany("curve points", limit: 16, #"{"curves": {"red": {"points": [\#(points(17))]}}}"#)
    }

    @Test func aDocumentHoldsSixtyFourLayersAtMost() {
        let layer = #"{"id": "7E57AB1E-0000-4000-8000-000000000006", "mask": {"brush": {"strokes": []}}}"#
        expectTooMany("local adjustments", limit: 64, #"{"locals": [\#(Array(repeating: layer, count: 65).joined(separator: ","))]}"#)
    }

    @Test func aBrushHoldsFiveHundredStrokesOfFiveThousandPointsAtMost() {
        func brush(_ strokes: String) -> String {
            #"{"locals": [{"id": "7E57AB1E-0000-4000-8000-000000000007", "mask": {"brush": {"strokes": [\#(strokes)]}}}]}"#
        }
        let dot = #"{"points": [{"x": 0.5, "y": 0.5}], "radius": 0.01, "isErasing": false}"#
        expectTooMany("brush strokes", limit: 500, brush(Array(repeating: dot, count: 501).joined(separator: ",")))
        expectTooMany("points in a brush stroke", limit: 5000, brush(#"{"points": [\#(points(5001))], "radius": 0.01, "isErasing": false}"#))
    }

    @Test func aDocumentHoldsTwoHundredSpotsAtMost() {
        let spot = #"{"id": "7E57AB1E-0000-4000-8000-000000000008", "target": {"x": 0.5, "y": 0.5}, "source": {"x": 0.6, "y": 0.5}, "radius": 0.01, "feather": 0.4}"#
        expectTooMany("spots", limit: 200, #"{"spots": [\#(Array(repeating: spot, count: 201).joined(separator: ","))]}"#)
    }

    // MARK: What is already fine is left alone

    @Test func aSaneDocumentComesThroughUntouched() throws {
        let edited = AdjustmentGroupTests.edited
        #expect(edited.sanitized() == edited)
        #expect(try JSONDecoder().decode(Adjustments.self, from: edited.jsonData()) == edited)
        #expect(Adjustments().sanitized() == Adjustments())
    }

    /// Values set in memory (a slider gone wrong) may not even be numbers.
    @Test func whatIsNotANumberGoesBackToNeutral() {
        var document = Adjustments()
        document.exposure = .nan
        document.contrast = .infinity
        document.geometry.straighten = .nan
        let sanitized = document.sanitized()
        #expect(sanitized.exposure == 0 && sanitized.contrast == 100 && sanitized.geometry.straighten == 0)
    }
}

@Suite struct HostileExportOptionsTests {
    private func decode(_ json: String) throws -> ExportOptions {
        try JSONDecoder().decode(ExportOptions.self, from: Data(json.utf8))
    }

    @Test func qualityIsBounded() throws {
        #expect(try decode(#"{"quality": 7}"#).quality == 1)
        #expect(try decode(#"{"quality": -3}"#).quality == 0.05)
        #expect(try decode(#"{"quality": 0.8}"#).quality == 0.8)
    }

    @Test func aLongEdgeTooSmallToMeanAnythingIsFullSize() throws {
        for value in [0, -5, 3, 15] { #expect(try decode(#"{"longEdge": \#(value)}"#).longEdge == nil) }
        #expect(try decode(#"{"longEdge": 16}"#).longEdge == 16)
        #expect(try decode(#"{"longEdge": 2048}"#).longEdge == 2048)
    }
}

/// A settings or preset file is read only if its size makes sense.
@Suite struct OversizedFileTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-oversized-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Valid JSON, over the limit: spaces are cheap.
    private func oversized(_ name: String) throws -> URL {
        let file = folder.appendingPathComponent(name)
        var data = Data(#"{"contrast": 20"#.utf8)
        data.append(Data(repeating: 0x20, count: DocumentFile.maximumSize))
        data.append(Data("}".utf8))
        try data.write(to: file)
        return file
    }

    @Test func anOversizedSidecarIsRefusedBeforeBeingRead() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try oversized("big.json")
        #expect(throws: RawEngineError.fileTooLarge(file, limit: DocumentFile.maximumSize)) { try Adjustments(contentsOf: file) }
        let small = folder.appendingPathComponent("small.json")
        try Data(#"{"contrast": 20}"#.utf8).write(to: small)
        #expect(try Adjustments(contentsOf: small).contrast == 20)
    }

    @Test func anOversizedPresetIsSkippedAndCannotBeResolved() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try oversized("Big look.json")
        try Data(#"{"contrast": 20}"#.utf8).write(to: folder.appendingPathComponent("Small look.json"))
        let store = JSONFileStore<Preset>(directory: folder)
        #expect(store.all().map(\.name) == ["Small look"])
        #expect(throws: RawEngineError.fileTooLarge(file, limit: DocumentFile.maximumSize)) { try store.resolve(file.path) }
    }
}

/// The point of it all: a hostile document, once decoded, develops and exports.
@Suite struct HostileDocumentRenderingTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-hostile-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A small PNG drawn by Core Graphics: a finite picture, and no Core Image generator.
    static func writeSample(to file: URL) throws {
        let (width, height) = (96, 64)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        for band in 0..<8 {
            context.setFillColor(red: CGFloat(band) / 8, green: 0.4, blue: 1 - CGFloat(band) / 8, alpha: 1)
            context.fill(CGRect(x: band * 12, y: 0, width: 12, height: height))
        }
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func sample() throws -> URL {
        let file = folder.appendingPathComponent("sample.png")
        try Self.writeSample(to: file)
        return file
    }

    @Test func aHostileDocumentDevelopsAndExports() throws {
        MemoryFuse.arm()
        defer { try? FileManager.default.removeItem(at: folder) }
        let huge = HostileDocumentTests.huge
        let json = #"""
        {"exposure": \#(huge), "contrast": -\#(huge), "highlights": \#(huge), "shadows": \#(huge), "clarity": \#(huge),
         "structure": -\#(huge), "dehaze": \#(huge), "glow": \#(huge), "grain": \#(huge), "vignetting": -\#(huge), "enhance": \#(huge),
         "whiteBalance": {"temperature": \#(huge), "tint": -\#(huge)},
         "geometry": {"straighten": \#(huge), "quarterTurns": 7, "crop": {"x": -4, "y": 9, "width": 0, "height": -1}},
         "curves": {"rgb": {"points": [{"x": 0.5, "y": -9}, {"x": 0.5000000000001, "y": 9}, {"x": 7, "y": 0.5}]}},
         "hsl": {"blue": {"hue": \#(huge), "saturation": \#(huge), "luminance": -\#(huge)}},
         "grading": {"highlights": {"hue": \#(huge), "saturation": \#(huge)}, "balance": -\#(huge)},
         "spots": [{"id": "7E57AB1E-0000-4000-8000-00000000000A", "target": {"x": \#(huge), "y": 0.5}, "source": {"x": 0.2, "y": -\#(huge)}, "radius": \#(huge), "feather": \#(huge)},
                   {"id": "7E57AB1E-0000-4000-8000-00000000000B", "target": {"x": 0.5, "y": 0.5}, "source": {"x": 0.7, "y": 0.5}, "radius": 0, "feather": -1}],
         "locals": [{"id": "7E57AB1E-0000-4000-8000-00000000000C", "opacity": \#(huge), "settings": {"exposure": -\#(huge), "shadows": \#(huge)},
                     "mask": {"radial": {"center": {"x": -\#(huge), "y": \#(huge)}, "radiusX": 0, "radiusY": \#(huge), "feather": \#(huge), "isInverted": true}}},
                    {"id": "7E57AB1E-0000-4000-8000-00000000000D", "settings": {"exposure": 1},
                     "mask": {"brush": {"strokes": [{"points": [{"x": \#(huge), "y": 0.5}, {"x": 0.5, "y": 0.5}], "radius": \#(huge), "isErasing": false},
                                                    {"points": [{"x": 0.4, "y": 0.4}], "radius": 0, "isErasing": true}]}}}]}
        """#
        let document = try JSONDecoder().decode(Adjustments.self, from: Data(json.utf8))
        var options = try JSONDecoder().decode(ExportOptions.self, from: Data(#"{"quality": 1e9, "longEdge": -7}"#.utf8))
        options.format = .jpeg

        let image = try RawSource(url: sample()).image(adjustments: document)
        #expect(!image.extent.isInfinite && image.extent.width >= 1 && image.extent.height >= 1)
        let destination = folder.appendingPathComponent("out.jpg")
        try Renderer.shared.write(image, to: destination, options: options)

        let written = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(written, 0, nil) as? [String: Any])
        #expect((properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0) >= 1)
    }
}
