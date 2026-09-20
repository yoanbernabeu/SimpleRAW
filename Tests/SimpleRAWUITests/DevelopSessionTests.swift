import CoreImage
import Foundation
import RawEngine
import TestSupport
import Testing
@testable import SimpleRAWUI

@MainActor
@Suite struct EmptySessionTests {
    let session = DevelopSession()

    @Test func startsWithoutADocument() {
        #expect(session.info == nil)
        #expect(session.previewImage(fitting: CGSize(width: 800, height: 600)) == nil)
        #expect(session.histogram == nil)
        #expect(!session.hasChanges)
    }

    @Test func surfacesErrorsReportedByViews() {
        session.report(RawEngineError.analysisFailed)
        #expect(session.errorMessage == RawEngineError.analysisFailed.localizedDescription)
        session.dismissError()
        #expect(session.errorMessage == nil)
    }

    @Test func reportsFilesItCannotOpen() {
        session.open(URL(fileURLWithPath: "/nonexistent/photo.dng"))
        #expect(session.info == nil)
        #expect(session.errorMessage?.isEmpty == false)
        #expect(session.errorTitle == "This file could not be opened")
    }
}

@MainActor
@Suite
struct DevelopSessionTests {
    let session = DevelopSession()
    let probe = PixelProbe()
    let viewSize = CGSize(width: 750, height: 500)

    init() throws {
        session.open(TestPhoto.url)
    }

    @Test func openingLoadsTheDocument() {
        #expect(session.info?.model?.isEmpty == false)
        #expect(session.errorMessage == nil)
        #expect(session.adjustments == Adjustments())
    }

    @Test func previewIsDecodedAtViewResolution() throws {
        let preview = try #require(session.previewImage(fitting: viewSize))
        #expect(preview.extent.width <= viewSize.width + 1)
        #expect(preview.extent.height <= viewSize.height + 1)
        #expect(preview.extent.width > viewSize.width * 0.9 || preview.extent.height > viewSize.height * 0.9)
    }

    @Test func adjustmentsShowInThePreview() throws {
        let before = try luminance()
        session.adjustments.exposure = 1
        #expect(try luminance() > before * 1.2)
    }

    @Test func showingTheOriginalBypassesAdjustmentsWithoutLosingThem() throws {
        let original = try luminance()
        session.adjustments.exposure = 2
        session.showsOriginal = true
        #expect(abs(try luminance() - original) < 0.001)
        #expect(session.adjustments.exposure == 2)
    }

    @Test func resetRestoresNeutralAdjustments() {
        session.adjustments.contrast = 40
        #expect(session.hasChanges)
        session.reset()
        #expect(session.adjustments == Adjustments())
        #expect(!session.hasChanges)
    }

    @Test func openingAnotherFileStartsFromNeutral() throws {
        session.adjustments.shadows = 60
        session.showsOriginal = true
        session.open(TestPhoto.all[1])
        #expect(session.adjustments == Adjustments())
        #expect(!session.showsOriginal)
    }

    @Test func aFailedOpenKeepsTheCurrentDocument() {
        session.open(URL(fileURLWithPath: "/nonexistent/photo.dng"))
        #expect(session.info != nil)
        #expect(session.errorMessage != nil)
    }

    @Test func aCroppedPreviewStillFillsTheView() throws {
        session.adjustments.geometry.crop = CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let preview = try #require(session.previewImage(fitting: viewSize))
        #expect(preview.extent.width > viewSize.width * 0.9 || preview.extent.height > viewSize.height * 0.9)
    }

    @Test func croppingShowsTheWholeFrameAndKeepsTheCrop() throws {
        let whole = try #require(session.previewImage(fitting: viewSize)).extent.size
        session.adjustments.geometry.crop = CropRect(x: 0, y: 0, width: 0.3, height: 1)
        session.isCropping = true
        let shown = try #require(session.previewImage(fitting: viewSize)).extent.size
        #expect(abs(shown.width / shown.height - whole.width / whole.height) < 0.02)
        #expect(session.adjustments.geometry.crop != nil)
    }

    @Test func choosingAnAspectRatioCropsToIt() throws {
        session.apply(.square)
        let frame = try #require(session.cropFrameSize)
        let crop = try #require(session.adjustments.geometry.crop)
        #expect(abs(crop.width * frame.width - crop.height * frame.height) < 1)
    }

    /// ⌘1 and ⌘0, and a pinch: unlike Z, they say where to go, and doing it twice changes nothing.
    @Test func zoomCommandsSayWhereToGo() {
        session.zoomToActualSize(at: CGPoint(x: 0.25, y: 0.75))
        #expect(session.zoom == .actualSize(center: CGPoint(x: 0.25, y: 0.75)))
        session.zoomToActualSize(at: CGPoint(x: 0.5, y: 0.5))
        #expect(session.zoom == .actualSize(center: CGPoint(x: 0.25, y: 0.75)), "already there: the view stays put")
        session.zoomToFit()
        session.zoomToFit()
        #expect(session.zoom == .fit)
    }

    @Test func zoomingShowsActualPixels() throws {
        session.toggleZoom(at: CGPoint(x: 0.5, y: 0.5))
        let zoomed = try #require(session.previewImage(fitting: viewSize))
        // One image pixel per view pixel: the preview is exactly the size of the view.
        #expect(zoomed.extent.size == viewSize)
        session.toggleZoom(at: CGPoint(x: 0.5, y: 0.5))
        #expect(session.zoom == .fit)
    }

    /// Painting a mask or removing a spot is done at 100 %; cropping needs the whole frame.
    @Test func theLocalToolsZoomAndTheCropToolDoesNot() throws {
        session.tool = .local
        session.zoomToActualSize()
        #expect(try #require(session.previewImage(fitting: viewSize)).extent.size == viewSize)

        session.tool = .crop
        #expect(session.zoom == .fit)
        session.zoomToActualSize()
        #expect(session.zoom == .fit)
    }

    @Test func zoomedInDifferentPlacesShowsDifferentPixels() throws {
        session.toggleZoom(at: CGPoint(x: 0.1, y: 0.1))
        let topLeft = try probe.average(of: try #require(session.previewImage(fitting: viewSize)))
        session.pan(by: CGSize(width: 0.8, height: 0.8))
        let bottomRight = try probe.average(of: try #require(session.previewImage(fitting: viewSize)))
        #expect(abs(topLeft.luminance - bottomRight.luminance) > 0.001)
    }

    @Test func panningDoesNothingWhenTheImageFits() {
        session.pan(by: CGSize(width: 0.3, height: 0.3))
        #expect(session.zoom == .fit)
    }

    /// A square view tells the two apart: at 100 % the preview fills it, fitted it cannot.
    @Test func theCropToolAlwaysShowsTheWholeFrame() throws {
        let square = CGSize(width: 500, height: 500)
        session.toggleZoom(at: CGPoint(x: 0.5, y: 0.5))
        #expect(try #require(session.previewImage(fitting: square)).extent.size == square)

        session.isCropping = true
        let shown = try #require(session.previewImage(fitting: square)).extent.size
        #expect(shown.width <= square.width + 1 && shown.height < square.height * 0.8)
    }

    /// The histogram describes the picture, not the part of it on screen.
    @Test func histogramIgnoresZoomAndTheCropTool() async throws {
        session.adjustments.geometry.crop = CropRect(x: 0, y: 0, width: 0.5, height: 0.5)
        await session.histogramSettled()
        let reference = try #require(session.histogram)
        session.toggleZoom(at: CGPoint(x: 0.9, y: 0.9))
        await session.histogramSettled()
        #expect(session.histogram == reference)
        session.isCropping = true
        await session.histogramSettled()
        #expect(session.histogram == reference)
    }

    /// A drag asks for a histogram on every frame; only the last request matters.
    @Test func aBurstOfChangesSettlesOnTheLastOne() async throws {
        for value in stride(from: -2.0, through: 3.0, by: 0.1) { session.adjustments.exposure = value }
        await session.histogramSettled()
        #expect(try #require(session.histogram).clipsHighlights)
    }

    @Test func histogramFollowsAdjustments() async throws {
        await session.histogramSettled()
        let neutral = try #require(session.histogram)
        session.adjustments.exposure = 3
        await session.histogramSettled()
        let pushed = try #require(session.histogram)
        #expect(pushed != neutral)
        #expect(pushed.clipsHighlights)
    }

    @Test func exportsAtFullResolution() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("simpleraw-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await session.export(to: destination)

        let exported = try #require(CIImage(contentsOf: destination))
        #expect(exported.extent.size == session.info?.imageSize)
        #expect(!session.isExporting)
        #expect(session.notice == "Exported to “\(destination.lastPathComponent)”.")
    }

    private func luminance() throws -> Float {
        try probe.average(of: try #require(session.previewImage(fitting: viewSize))).luminance
    }
}

@MainActor
@Suite struct SliderSpecTests {
    let asShot = WhiteBalance(temperature: 5000, tint: 10)
    /// Every slider the inspector can show: the fixed ones, plus those of the HSL and grading panels.
    let everySpec = SliderSpec.all
        + ColorBandName.allCases.flatMap(SliderSpec.hsl(band:))
        + TonalRange.allCases.flatMap(SliderSpec.grading(range:))
        + SliderSpec.all(in: .geometry)
        + SliderSpec.all(in: .blackAndWhite)

    @Test func everySliderStartsAtItsNeutralValue() {
        let context = SliderContext(asShotWhiteBalance: asShot, decoderDefaults: .init(sharpness: 30, luminanceNoiseReduction: 20, colorNoiseReduction: 50))
        let adjustments = Adjustments()
        for spec in everySpec {
            #expect(spec.value(adjustments, context) == spec.neutral(context), "\(spec.title)")
        }
    }

    @Test func everySliderWritesAndResets() {
        let context = SliderContext(asShotWhiteBalance: asShot, decoderDefaults: .init(sharpness: 30, luminanceNoiseReduction: 20, colorNoiseReduction: 50))
        for spec in everySpec {
            var adjustments = Adjustments()
            let target = spec.range.upperBound
            spec.setValue(&adjustments, target, context)
            #expect(spec.value(adjustments, context) == target, "\(spec.title)")
            #expect(adjustments != Adjustments(), "\(spec.title)")

            spec.reset(&adjustments, context)
            #expect(adjustments == Adjustments(), "\(spec.title)")
        }
    }

    @Test func hslSlidersEditOnlyTheirBand() {
        let context = SliderContext(asShotWhiteBalance: asShot, decoderDefaults: .init(sharpness: 30, luminanceNoiseReduction: 20, colorNoiseReduction: 50))
        var adjustments = Adjustments()
        let saturation = SliderSpec.hsl(band: .orange)[1]
        saturation.setValue(&adjustments, 40, context)
        #expect(adjustments.hsl[.orange] == ColorBand(saturation: 40))
        #expect(adjustments.hsl[.red] == ColorBand())
    }

    @Test func titlesAreUnique() {
        #expect(Set(SliderSpec.all.map(\.title)).count == SliderSpec.all.count)
    }
}

@Suite struct CurveChannelTests {
    @Test func eachChannelEditsItsOwnCurve() {
        for channel in CurveChannel.allCases {
            var curves = Curves()
            curves[keyPath: channel.keyPath].insert(.init(x: 0.5, y: 0.8))
            let edited = CurveChannel.allCases.filter { !curves[keyPath: $0.keyPath].isIdentity }
            #expect(edited == [channel])
        }
    }

    /// The editor draws with y up; views have y down.
    @Test func convertsBetweenViewAndCurveCoordinates() {
        let size = CGSize(width: 200, height: 100)
        let point = CurveChannel.curvePoint(at: CGPoint(x: 50, y: 25), in: size)
        #expect(point == Curve.Point(x: 0.25, y: 0.75))
        #expect(CurveChannel.viewLocation(of: point, in: size) == CGPoint(x: 50, y: 25))
    }

    /// The trace is the curve, read off one lookup table rather than evaluated point by
    /// point: same drawing, tangents worked out once instead of a hundred times a frame.
    @Test func theTraceFollowsTheCurve() throws {
        let size = CGSize(width: 200, height: 100)
        var curve = Curve.identity
        curve.insert(.init(x: 0.25, y: 0.5))
        curve.insert(.init(x: 0.75, y: 0.6))

        let trace = CurveChannel.tracePoints(of: curve, in: size, samples: 8)
        #expect(trace.count == 9)
        #expect(trace.first == CGPoint(x: 0, y: 100) && trace.last == CGPoint(x: 200, y: 0))
        // Left to right, never backwards: a path of lines is drawn in order.
        #expect(zip(trace, trace.dropFirst()).allSatisfy { $0.x < $1.x })
        for (index, point) in trace.enumerated() {
            let x = Double(index) / 8
            #expect(abs(point.y - (1 - curve.value(at: x)) * size.height) < 0.01, "at \(x)")
        }
    }
}

@Suite struct ColorWheelGeometryTests {
    let size = CGSize(width: 100, height: 100)

    @Test func theCenterIsNoTintAtAll() {
        #expect(ColorWheelGeometry.wheel(at: CGPoint(x: 50, y: 50), in: size).saturation == 0)
    }

    /// Red on the right, hues turning counter-clockwise, like on a standard hue circle.
    @Test func anglesFollowTheHueCircle() {
        let right = ColorWheelGeometry.wheel(at: CGPoint(x: 100, y: 50), in: size)
        let top = ColorWheelGeometry.wheel(at: CGPoint(x: 50, y: 0), in: size)
        let left = ColorWheelGeometry.wheel(at: CGPoint(x: 0, y: 50), in: size)
        #expect(abs(right.hue - 0) < 1e-9 && right.saturation == 100)
        #expect(abs(top.hue - 90) < 1e-9)
        #expect(abs(left.hue - 180) < 1e-9)
    }

    @Test func draggingPastTheRimStaysOnTheRim() {
        #expect(ColorWheelGeometry.wheel(at: CGPoint(x: 400, y: 50), in: size).saturation == 100)
    }

    @Test func locationsAndValuesRoundTrip() {
        let wheel = ColorWheel(hue: 210, saturation: 60)
        let location = ColorWheelGeometry.location(of: wheel, in: size)
        let back = ColorWheelGeometry.wheel(at: location, in: size)
        #expect(abs(back.hue - 210) < 1e-6)
        #expect(abs(back.saturation - 60) < 1e-6)
    }
}

@Suite struct CropAspectTests {
    /// 4:5 is what gets published most, and a vertical crop out of a horizontal shot is an
    /// everyday move: the ratio can be turned against the orientation of the frame.
    @Test func aRatioCanBeTurnedAgainstTheFrame() throws {
        let landscape = CGSize(width: 6000, height: 4000)
        let along = try #require(CropAspect.fiveByFour.normalizedAspect(in: landscape))
        let across = try #require(CropAspect.fiveByFour.normalizedAspect(in: landscape, turned: true))
        // In pixels: width / height of the crop.
        #expect(abs(along * 1.5 - 5.0 / 4) < 1e-9)
        #expect(abs(across * 1.5 - 4.0 / 5) < 1e-9)
        #expect(CropAspect.free.normalizedAspect(in: landscape, turned: true) == nil)
        #expect(CropAspect.allCases.contains(.sevenByFive))
    }

    let landscape = CGSize(width: 6000, height: 4000)
    let portrait = CGSize(width: 4000, height: 6000)

    @Test func freeCropHasNoRatio() {
        #expect(CropAspect.free.normalizedAspect(in: landscape) == nil)
    }

    @Test func theOriginalRatioIsTheFullFrame() {
        #expect(CropAspect.original.normalizedAspect(in: landscape) == 1)
    }

    /// Normalized: pixel ratio divided by the frame's own ratio.
    @Test func ratiosAreExpressedInFrameUnits() throws {
        let square = try #require(CropAspect.square.normalizedAspect(in: landscape))
        #expect(abs(square - 1 / 1.5) < 1e-9)
    }

    @Test func ratiosFollowTheOrientationOfTheFrame() throws {
        // 16:9 on a portrait frame means 9:16.
        let wide = try #require(CropAspect.sixteenByNine.normalizedAspect(in: portrait))
        #expect(abs(wide - (9.0 / 16) / (4000.0 / 6000)) < 1e-9)
    }
}

@Suite struct FitGeometryTests {
    @Test func aWideImageIsLimitedByTheWidth() {
        let frame = FitGeometry.frame(forAspect: 2, in: CGSize(width: 440, height: 440), padding: 20)
        #expect(frame == CGRect(x: 20, y: 120, width: 400, height: 200))
    }

    @Test func aTallImageIsLimitedByTheHeight() {
        let frame = FitGeometry.frame(forAspect: 0.5, in: CGSize(width: 440, height: 440), padding: 20)
        #expect(frame == CGRect(x: 120, y: 20, width: 200, height: 400))
    }

    @Test func aViewSmallerThanItsPaddingHasNoFrame() {
        #expect(FitGeometry.frame(forAspect: 1.5, in: CGSize(width: 30, height: 30), padding: 20).isEmpty)
    }

    @Test func cropRectsMapToTheFrameAndBack() {
        let frame = CGRect(x: 20, y: 120, width: 400, height: 200)
        let crop = CropRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        let rect = FitGeometry.rect(of: crop, in: frame)
        #expect(rect == CGRect(x: 120, y: 220, width: 200, height: 50))
        #expect(FitGeometry.normalized(CGPoint(x: 120, y: 220), in: frame) == CGPoint(x: 0.25, y: 0.5))
    }
}

@Suite struct ZoomGeometryTests {
    /// At 100 % the whole picture is a frame larger than the canvas: masks, spots and the
    /// eyedropper are positioned in it, and so line up with the zoomed picture.
    @Test func theWholeImageHasAFrameAroundTheCanvas() {
        // 6000 × 4000 px seen through a 600 × 400 pt canvas at 2x, without padding: 1200 × 800 px.
        let frame = ZoomGeometry.imageFrame(
            of: CGSize(width: 6000, height: 4000), centeredOn: CGPoint(x: 0.5, y: 0.5),
            in: CGSize(width: 600, height: 400), padding: 0, backingScale: 2
        )
        #expect(frame == CGRect(x: -1200, y: -800, width: 3000, height: 2000))
        // The center of the picture is at the center of the canvas.
        #expect(CGPoint(x: frame.midX, y: frame.midY) == CGPoint(x: 300, y: 200))
    }

    @Test func aPictureSmallerThanTheCanvasKeepsItsFittedFrame() {
        let frame = ZoomGeometry.imageFrame(
            of: CGSize(width: 400, height: 200), centeredOn: CGPoint(x: 0.5, y: 0.5),
            in: CGSize(width: 600, height: 400), padding: 0, backingScale: 1
        )
        #expect(frame == FitGeometry.frame(forAspect: 2, in: CGSize(width: 600, height: 400), padding: 0))
    }

    let image = CGSize(width: 6000, height: 4000)
    let view = CGSize(width: 1500, height: 1000)

    @Test func theVisibleAreaIsCenteredOnTheFocusPoint() {
        let rect = ZoomGeometry.visibleRect(of: image, in: view, centeredOn: CGPoint(x: 0.5, y: 0.5))
        #expect(rect == CGRect(x: 2250, y: 1500, width: 1500, height: 1000))
    }

    @Test func itNeverLeavesTheImage() {
        let corner = ZoomGeometry.visibleRect(of: image, in: view, centeredOn: CGPoint(x: 0, y: 1))
        #expect(corner == CGRect(x: 0, y: 3000, width: 1500, height: 1000))
    }

    @Test func anImageSmallerThanTheViewIsShownWhole() {
        let small = CGSize(width: 800, height: 600)
        let rect = ZoomGeometry.visibleRect(of: small, in: view, centeredOn: CGPoint(x: 0.9, y: 0.9))
        #expect(rect == CGRect(origin: .zero, size: small))
    }

    /// Where the focus really ends up once the visible area has been kept inside the image.
    @Test func theFocusPointIsClampedTheSameWay() {
        let focus = ZoomGeometry.clampedCenter(CGPoint(x: 0, y: 1), image: image, view: view)
        #expect(focus == CGPoint(x: 0.125, y: 0.875))
    }

    /// Dragging the picture to the right reveals what was further left.
    @Test func draggingMovesThePictureWithThePointer() {
        let delta = ZoomGeometry.panDelta(forDrag: CGSize(width: 300, height: -100), backingScale: 2, image: image)
        #expect(delta == CGSize(width: -0.1, height: 0.05))
    }

    @Test func aClickInTheFittedImageMapsToAPointOfThePicture() {
        // A 3:2 picture in a 640 × 440 canvas with 20 of padding sits at (20, 20), 600 × 400.
        let point = ZoomGeometry.imagePoint(at: CGPoint(x: 170, y: 320), aspect: 1.5, in: CGSize(width: 640, height: 440), padding: 20)
        #expect(point == CGPoint(x: 0.25, y: 0.75))
        let outside = ZoomGeometry.imagePoint(at: CGPoint(x: 0, y: 0), aspect: 1.5, in: CGSize(width: 640, height: 440), padding: 20)
        #expect(outside == CGPoint(x: 0, y: 0))
    }
}

@MainActor
@Suite
struct ZoomCacheTests {
    let session = DevelopSession()
    let viewSize = CGSize(width: 750, height: 500)

    init() throws {
        session.open(TestPhoto.url)
    }

    /// Panning only moves a window over a picture that did not change: once the settings have
    /// settled it is developed at full size once, in the background, and panning reuses it.
    @Test func panningReusesTheDevelopedPicture() async throws {
        session.toggleZoom(at: CGPoint(x: 0.3, y: 0.3))
        _ = session.previewImage(fitting: viewSize)
        await session.zoomCacheSettled()
        _ = session.previewImage(fitting: viewSize)
        #expect(session.fullSizeRenderCount == 1 && session.isServingZoomFromCache)
        for _ in 0..<10 {
            session.pan(by: CGSize(width: 0.01, height: 0.01))
            _ = session.previewImage(fitting: viewSize)
        }
        await session.zoomCacheSettled()
        #expect(session.fullSizeRenderCount == 1)
    }

    @Test func aChangeOfSettingsDevelopsAgainAndNeverShowsAStalePicture() async throws {
        let probe = PixelProbe()
        session.toggleZoom(at: CGPoint(x: 0.5, y: 0.5))
        _ = session.previewImage(fitting: viewSize)
        await session.zoomCacheSettled()
        let before = try probe.average(of: try #require(session.previewImage(fitting: viewSize))).luminance

        session.adjustments.exposure = 1
        // Right away, before the background render: the change must already show.
        let during = try probe.average(of: try #require(session.previewImage(fitting: viewSize))).luminance
        #expect(during > before * 1.3 && !session.isServingZoomFromCache)

        await session.zoomCacheSettled()
        let after = try probe.average(of: try #require(session.previewImage(fitting: viewSize))).luminance
        #expect(session.fullSizeRenderCount == 2 && session.isServingZoomFromCache)
        #expect(abs(after - during) < during * 0.03)
    }

    @Test func leavingTheZoomFreesTheCache() async throws {
        session.toggleZoom(at: CGPoint(x: 0.5, y: 0.5))
        _ = session.previewImage(fitting: viewSize)
        await session.zoomCacheSettled()
        session.toggleZoom(at: CGPoint(x: 0.5, y: 0.5))
        #expect(!session.isServingZoomFromCache)
    }
}
