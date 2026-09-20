import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Testing
import TestSupport
@testable import RawEngine

/// Clarity, structure, dehaze, glow and grain, each measured on synthetic pictures.
@Suite struct CharacterStageTests {
    let probe = PixelProbe()

    /// Dark on the left, light on the right, with a soft transition in the middle.
    private func softEdge(_ size: CGSize = CGSize(width: 400, height: 200)) -> CIImage {
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: size.width * 0.45, y: 0)
        gradient.point1 = CGPoint(x: size.width * 0.55, y: 0)
        gradient.color0 = CIColor(red: 0.1, green: 0.1, blue: 0.1)
        gradient.color1 = CIColor(red: 0.4, green: 0.4, blue: 0.4)
        return gradient.outputImage!.cropped(to: CGRect(origin: .zero, size: size))
    }

    private func adjustments(_ edit: (inout Adjustments) -> Void) -> Adjustments {
        var adjustments = Adjustments()
        edit(&adjustments)
        return adjustments
    }

    /// Contrast right across the edge: light side minus dark side, sampled just outside the
    /// transition (45 % to 55 % of the width), where local contrast acts.
    private func edgeContrast(_ image: CIImage) throws -> Float {
        let (w, h) = (image.extent.width, image.extent.height)
        let dark = try probe.average(of: image, in: CGRect(x: w * 0.435, y: h * 0.4, width: w * 0.01, height: h * 0.2)).luminance
        let light = try probe.average(of: image, in: CGRect(x: w * 0.555, y: h * 0.4, width: w * 0.01, height: h * 0.2)).luminance
        return light - dark
    }

    @Test func clarityStrengthensEdgesAndLeavesFlatAreasAlone() throws {
        let image = softEdge()
        let output = LocalContrastStage().apply(adjustments { $0.clarity = 100 }, to: image)
        #expect(try edgeContrast(output) > edgeContrast(image) * 1.03)
        let farLeft = CGRect(x: 10, y: 80, width: 20, height: 40)
        #expect(abs(try probe.average(of: output, in: farLeft).luminance - probe.average(of: image, in: farLeft).luminance) < 0.01)
        #expect(output.extent == image.extent)
    }

    @Test func negativeClaritySoftens() throws {
        let image = softEdge()
        let output = LocalContrastStage().apply(adjustments { $0.clarity = -100 }, to: image)
        #expect(try edgeContrast(output) < edgeContrast(image))
    }

    /// The preview and the export must look the same: radii follow the size of the picture.
    @Test func clarityDoesNotDependOnResolution() throws {
        let small = LocalContrastStage().apply(adjustments { $0.clarity = 80 }, to: softEdge())
        let large = LocalContrastStage().apply(adjustments { $0.clarity = 80 }, to: softEdge(CGSize(width: 1600, height: 800)))
        #expect(abs(try edgeContrast(small) - edgeContrast(large)) < 0.02)
    }

    @Test func structureWorksAtAFinerScaleThanClarity() throws {
        let image = softEdge()
        let structure = try edgeContrast(LocalContrastStage().apply(adjustments { $0.structure = 100 }, to: image))
        #expect(structure > (try edgeContrast(image)))
    }

    @Test func dehazeDeepensAVeiledPicture() throws {
        // Haze: blacks lifted, contrast low.
        let veiled = PixelProbe.swatch(r: 0.35, g: 0.36, b: 0.38, size: CGSize(width: 200, height: 100))
            .composited(over: PixelProbe.swatch(r: 0.5, g: 0.5, b: 0.52, size: CGSize(width: 400, height: 100)))
        let output = DevelopPipeline(stages: [DehazeStage(), LocalContrastStage()]).apply(adjustments { $0.dehaze = 100 }, to: veiled)
        let darkBefore = try probe.average(of: veiled, in: CGRect(x: 20, y: 20, width: 60, height: 60)).luminance
        let darkAfter = try probe.average(of: output, in: CGRect(x: 20, y: 20, width: 60, height: 60)).luminance
        #expect(darkAfter < darkBefore - 0.03)
    }

    @Test func glowSpreadsLightAroundBrightAreas() throws {
        let scene = PixelProbe.swatch(r: 0.9, g: 0.9, b: 0.9, size: CGSize(width: 40, height: 40))
            .transformed(by: CGAffineTransform(translationX: 180, y: 80))
            .composited(over: PixelProbe.swatch(r: 0.05, g: 0.05, b: 0.05, size: CGSize(width: 400, height: 200)))
        let output = GlowStage().apply(adjustments { $0.glow = 100 }, to: scene)
        let halo = CGRect(x: 225, y: 90, width: 6, height: 20)
        #expect(try probe.average(of: output, in: halo).luminance > probe.average(of: scene, in: halo).luminance + 0.02)
        #expect(output.extent == scene.extent)
    }

    @Test func grainAddsTextureWithoutChangingBrightness() throws {
        let flat = PixelProbe.swatch(r: 0.3, g: 0.3, b: 0.3, size: CGSize(width: 400, height: 200))
        let region = CGRect(x: 100, y: 50, width: 64, height: 64)
        let output = GrainStage().apply(adjustments { $0.grain = 100 }, to: flat)
        #expect(try probe.standardDeviation(of: flat, in: region) < 0.001)
        #expect(try probe.standardDeviation(of: output, in: region) > 0.01)
        #expect(abs(try probe.average(of: output, in: region).luminance - 0.3) < 0.02)
    }

    @Test func grainIsTheSameEveryTime() throws {
        let flat = PixelProbe.swatch(r: 0.3, g: 0.3, b: 0.3, size: CGSize(width: 400, height: 200))
        let region = CGRect(x: 10, y: 10, width: 4, height: 4)
        let first = try probe.average(of: GrainStage().apply(adjustments { $0.grain = 60 }, to: flat), in: region)
        let second = try probe.average(of: GrainStage().apply(adjustments { $0.grain = 60 }, to: flat), in: region)
        #expect(first.r == second.r && first.g == second.g)
    }

    @Test func everyCharacterSettingIsInTheDocumentAndInAGroup() throws {
        let edited = adjustments { $0.clarity = 10; $0.structure = 20; $0.dehaze = 30; $0.glow = 40; $0.grain = 50 }
        #expect(try JSONDecoder().decode(Adjustments.self, from: edited.jsonData()) == edited)
        var target = Adjustments()
        target.apply(edited, groups: [.effects])
        #expect(target == edited)
    }
}

/// Found on a real export: with dehaze, a picture exported for the web came out with a
/// vertical seam in its sky, one block lighter than the next. Measured on the reference
/// sample: nothing at full size nor at 4 000 px, a step forty times the others at 2 048 px and
/// under, which is what the built-in web presets export. Dehaze alone does it, clarity does
/// not: the wide scale of local contrast is the suspect (6 % of the long edge, a radius of
/// 360 px at full size, far more than `CISharpenLuminance` is made for). Rendering the picture
/// to an intermediate before scaling it, cached or not, changes nothing. Open: recorded as a
/// known issue so that it shows until fixed, most likely by working that scale out on a
/// reduced copy of the picture, as `GlowStage` does, which would make it cheaper too.
///
/// Synthetic skies did not reproduce it (two tries): it takes a real 24 MP picture. So the
/// regression case is the reference sample itself, where it was found.
@Suite struct ResizedExportTests {
    static let reference = Sample.all.first { $0.lastPathComponent == "R0000357.DNG" }

    /// Mean luminance of columns across the smooth sky left of the large cloud, read from the
    /// file an export of that size writes: how Core Image tiles depends on who asks, and
    /// rendering to a bitmap here did not show at 2 048 px what the written JPEG does.
    private func skyProfile(_ adjustments: Adjustments, longEdge: Int) throws -> [Double] {
        var options = ExportOptions()
        options.longEdge = longEdge
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-seam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("export.jpg")
        try Renderer.shared.write(try RawSource(url: try #require(Self.reference)).image(adjustments: adjustments), to: file, options: options)

        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        let written = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let (width, height) = (written.width, written.height)
        let bitmap = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        bitmap.draw(written, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
        let rows = Int(Double(height) * 0.017)..<Int(Double(height) * 0.06)
        let columnWidth = max(1, width / 240)
        return stride(from: Int(Double(width) * 0.2), to: Int(Double(width) * 0.3), by: columnWidth).map { x in
            var sum = 0.0
            for y in rows { for dx in 0..<columnWidth {
                let pixel = (y * width + x + dx) * 4
                sum += 0.2126 * Double(data[pixel]) + 0.7152 * Double(data[pixel + 1]) + 0.0722 * Double(data[pixel + 2])
            } }
            return sum / Double(rows.count * columnWidth) / 255
        }
    }

    @Test(.enabled(if: ResizedExportTests.reference != nil, "Needs the reference sample, R0000357.DNG"), arguments: [2048, 700])
    func dehazeLeavesNoSeamInTheSkyOfAnExportForTheWeb(longEdge: Int) throws {
        MemoryFuse.arm()
        var dehazed = Adjustments()
        dehazed.dehaze = 70
        let (before, after) = (try skyProfile(Adjustments(), longEdge: longEdge), try skyProfile(dehazed, longEdge: longEdge))
        // What dehaze changes varies slowly across a smooth sky: a seam is a sudden step in it.
        let change = zip(after, before).map { $0 - $1 }
        let steps = zip(change, change.dropFirst()).map { abs($1 - $0) }
        print(String(format: "SEAM at %d px, largest step in what dehaze changes: %.4f (median %.4f)", longEdge, steps.max() ?? 0, steps.sorted()[steps.count / 2]))
        #expect((steps.max() ?? 1) < 0.008, "a step of \(steps.max() ?? 0) in the sky at \(longEdge) px")
    }
}
