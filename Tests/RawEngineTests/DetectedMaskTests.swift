import CoreImage
import Foundation
import Testing
import TestSupport
@testable import RawEngine

/// A mask the machine finds is computed somewhere else and arrives later, while
/// `Mask.image(in:)` is pure and synchronous and the pipeline is shared. These are the rules
/// that make the two fit together.
@Suite struct DetectedMaskTests {
    let probe = PixelProbe()
    let extent = CGRect(x: 0, y: 0, width: 120, height: 80)

    init() {
        MaskRasterStore.shared.removeAll()
    }

    /// The rule the whole arrangement rests on: no picture yet means a black mask, which is
    /// a layer that changes nothing. The photograph shows as it was until the answer comes,
    /// rather than flickering.
    @Test func aMaskWithNoPictureYetIsBlack() throws {
        let mask = Mask.detected(DetectedMask(subject: .subject))
        let image = mask.image(in: extent)
        #expect(image.extent == extent)
        #expect(try probe.average(of: image).luminance < 0.001, "a mask nobody has found yet must change nothing")
    }

    @Test func aMaskUsesThePictureFoundForIt() throws {
        let found = DetectedMask(subject: .subject)
        // White on the left half, black on the right: something was found on the left.
        let raster = PixelProbe.swatch(r: 1, g: 1, b: 1, size: CGSize(width: 30, height: 40))
            .composited(over: PixelProbe.swatch(r: 0, g: 0, b: 0, size: CGSize(width: 60, height: 40)))
        MaskRasterStore.shared.store(raster, for: found.id)

        let image = Mask.detected(found).image(in: extent)
        #expect(image.extent == extent)
        // Stretched to the frame asked for, as a painted mask is.
        #expect(try probe.average(of: image, in: CGRect(x: 5, y: 30, width: 20, height: 20)).luminance > 0.95)
        #expect(try probe.average(of: image, in: CGRect(x: 95, y: 30, width: 20, height: 20)).luminance < 0.05)
    }

    @Test func invertingTurnsTheMaskInsideOut() throws {
        var found = DetectedMask(subject: .person)
        let raster = PixelProbe.swatch(r: 1, g: 1, b: 1, size: CGSize(width: 30, height: 40))
            .composited(over: PixelProbe.swatch(r: 0, g: 0, b: 0, size: CGSize(width: 60, height: 40)))
        MaskRasterStore.shared.store(raster, for: found.id)
        found.isInverted = true

        let image = Mask.detected(found).image(in: extent)
        #expect(try probe.average(of: image, in: CGRect(x: 5, y: 30, width: 20, height: 20)).luminance < 0.05)
        #expect(try probe.average(of: image, in: CGRect(x: 95, y: 30, width: 20, height: 20)).luminance > 0.95)
    }

    /// The document holds what was asked for and not one pixel of the answer: finding a mask
    /// of two hundred and forty thousand pixels must not add a byte to it.
    @Test func theDocumentHoldsNoPixels() throws {
        var adjustments = Adjustments()
        let found = DetectedMask(subject: .person, instance: 2)
        adjustments.locals = [LocalAdjustment(mask: .detected(found))]
        let beforeFinding = try adjustments.jsonData()

        MaskRasterStore.shared.store(PixelProbe.swatch(r: 1, g: 1, b: 1, size: CGSize(width: 600, height: 400)), for: found.id)
        let json = try adjustments.jsonData()
        #expect(json == beforeFinding, "the answer reached the document")
        // And what it does hold is small: a mask is four short fields.
        let mask = try #require(String(decoding: json, as: UTF8.self).range(of: "\"detected\""))
        _ = mask
        let decoded = try JSONDecoder().decode(Adjustments.self, from: json)
        guard case .detected(let read) = decoded.locals.first?.mask else {
            Issue.record("the mask did not survive the round trip")
            return
        }
        #expect(read.id == found.id && read.subject == .person && read.instance == 2)
    }

    /// A document written by hand, or by a newer version, cannot ask for the thousandth
    /// person in the frame.
    @Test func aWildInstanceIsBroughtBack() throws {
        let json = #"{"version":1,"locals":[{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","opacity":1,"isEnabled":true,"settings":{},"mask":{"detected":{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3302","subject":"person","instance":100000,"isInverted":false}}}]}"#
        let decoded = try JSONDecoder().decode(Adjustments.self, from: Data(json.utf8))
        guard case .detected(let mask) = decoded.locals.first?.mask else {
            Issue.record("the mask did not decode")
            return
        }
        #expect(mask.instance == AdjustmentLimits.maximumMaskInstance)
    }

    /// The store is shared by the canvas, the thumbnails and the exports, so it must not grow
    /// without end: the least recently wanted goes first.
    @Test func theStoreKeepsOnlySoMany() {
        let store = MaskRasterStore()
        let ids = (0..<(MaskRasterStore.capacity + 4)).map { _ in UUID() }
        let raster = PixelProbe.swatch(r: 1, g: 1, b: 1, size: CGSize(width: 4, height: 4))
        for id in ids { store.store(raster, for: id) }
        #expect(!store.holdsRaster(for: ids[0]), "the oldest was dropped")
        #expect(store.holdsRaster(for: ids[ids.count - 1]))

        // Asking for one makes it recent: the next eviction takes another.
        let kept = ids[ids.count - 2]
        _ = store.raster(for: kept)
        for _ in 0..<3 { store.store(raster, for: UUID()) }
        #expect(store.holdsRaster(for: kept), "what was just wanted must not be the first to go")
    }

    @Test func aMaskCanBeForgotten() {
        let store = MaskRasterStore()
        let id = UUID()
        store.store(PixelProbe.swatch(r: 1, g: 1, b: 1, size: CGSize(width: 4, height: 4)), for: id)
        #expect(store.holdsRaster(for: id))
        store.forget(id)
        #expect(!store.holdsRaster(for: id) && store.raster(for: id) == nil)
    }

    /// Detection misses a strand of hair and takes in a shoulder nobody wanted. Painting over
    /// what was found is what turns the tool from a party trick into a tool.
    @Test func whatIsPaintedAddsToWhatWasFound() throws {
        var mask = DetectedMask(subject: .subject)
        // Found: the left half.
        let raster = PixelProbe.swatch(r: 1, g: 1, b: 1, size: CGSize(width: 30, height: 40))
            .composited(over: PixelProbe.swatch(r: 0, g: 0, b: 0, size: CGSize(width: 60, height: 40)))
        MaskRasterStore.shared.store(raster, for: mask.id)
        // Painted: a blob on the right, where nothing was found.
        mask.corrections = BrushMask(strokes: [.init(points: [.init(x: 0.85, y: 0.5)], radius: 0.12)])

        let image = Mask.detected(mask).image(in: extent)
        #expect(try probe.average(of: image, in: CGRect(x: 5, y: 30, width: 20, height: 20)).luminance > 0.95, "what was found is still there")
        #expect(try probe.average(of: image, in: CGRect(x: 96, y: 36, width: 8, height: 8)).luminance > 0.9, "what was painted was not added")
    }

    @Test func whatIsErasedIsTakenOutOfWhatWasFound() throws {
        var mask = DetectedMask(subject: .subject)
        let raster = PixelProbe.swatch(r: 1, g: 1, b: 1, size: CGSize(width: 60, height: 40))
        MaskRasterStore.shared.store(raster, for: mask.id)
        // All of it found; a blob taken out of the middle.
        mask.corrections = BrushMask(strokes: [.init(points: [.init(x: 0.5, y: 0.5)], radius: 0.15, isErasing: true)])

        let image = Mask.detected(mask).image(in: extent)
        #expect(try probe.average(of: image, in: CGRect(x: 56, y: 36, width: 8, height: 8)).luminance < 0.1, "the erased part is still there")
        #expect(try probe.average(of: image, in: CGRect(x: 2, y: 2, width: 6, height: 6)).luminance > 0.9, "the rest was taken away with it")
    }

    /// Painting is worth showing before the machine has answered: the photographer is working
    /// now, not when the model finishes loading.
    @Test func paintingShowsEvenBeforeAnythingIsFound() throws {
        var mask = DetectedMask(subject: .person)
        mask.corrections = BrushMask(strokes: [.init(points: [.init(x: 0.5, y: 0.5)], radius: 0.2)])
        let image = Mask.detected(mask).image(in: extent)
        #expect(try probe.average(of: image, in: CGRect(x: 56, y: 36, width: 8, height: 8)).luminance > 0.9)
        #expect(try probe.average(of: image, in: CGRect(x: 2, y: 2, width: 6, height: 6)).luminance < 0.1)
    }

    /// Every sort of mask is offered by the same list, and the found ones say they are found.
    @Test func theKindsSayWhichOnesTheMachineFinds() {
        #expect(MaskKind.allCases.filter(\.isDetected) == [.subject, .person])
        #expect(Mask.detected(DetectedMask(subject: .subject)).kind == .subject)
        #expect(Mask.detected(DetectedMask(subject: .person)).kind == .person)
        #expect(!MaskKind.brush.isDetected)
    }
}
