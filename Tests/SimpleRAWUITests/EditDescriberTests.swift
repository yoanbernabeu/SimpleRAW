import Foundation
import RawEngine
import Testing
@testable import SimpleRAWUI

/// The history names its steps by looking at what changed: nobody has to tell it.
@Suite struct EditDescriberTests {
    let context = SliderContext(
        asShotWhiteBalance: WhiteBalance(temperature: 5000, tint: 10),
        decoderDefaults: .init(sharpness: 30, luminanceNoiseReduction: 20, colorNoiseReduction: 50)
    )

    private func label(_ change: (inout Adjustments) -> Void, from start: Adjustments = Adjustments()) -> String {
        var edited = start
        change(&edited)
        return EditDescriber.label(from: start, to: edited, context: context)
    }

    @Test func oneSliderIsNamedWithItsValue() {
        #expect(label { $0.exposure = 0.35 } == "Exposure +0.35")
        #expect(label { $0.contrast = -20 } == "Contrast -20")
        #expect(label { $0.setTemperature(6500, asShot: context.asShotWhiteBalance) } == "Temperature 6500")
    }

    @Test func severalSlidersOfOneFamilyAreNamedAfterIt() {
        #expect(label { $0.highlights = -30; $0.shadows = 25 } == "Light")
        #expect(label { $0.exposure = 1; $0.vibrance = 20 } == "Several Settings")
    }

    @Test func toolsAreNamed() {
        #expect(label { $0.geometry.crop = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5) } == "Crop")
        #expect(label { $0.geometry.turn(clockwise: true) } == "Rotate")
        #expect(label { $0.geometry.straighten = 2 } == "Straighten")
        #expect(label { $0.curves.rgb.insert(.init(x: 0.5, y: 0.6)) } == "Curve")
        #expect(label { $0.hsl[.blue].saturation = -20 } == "Color Mixer")
        #expect(label { $0.grading[.shadows] = ColorWheel(hue: 210, saturation: 30) } == "Color Grading")
        #expect(label { $0.blackAndWhite.isEnabled = true } == "Black & White")
    }

    @Test func layersAndSpotsSayWhatHappenedToThem() {
        let mask = Mask.radial(RadialMask(center: .init(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2))
        var withLayer = Adjustments()
        withLayer.locals = [LocalAdjustment(mask: mask)]
        #expect(label { $0.locals = withLayer.locals } == "Added Mask")
        #expect(label({ $0.locals = [] }, from: withLayer) == "Removed Mask")
        #expect(label({ $0.locals[0].settings.exposure = 1 }, from: withLayer) == "Local Adjustment")
        #expect(label({ $0.locals[0].isEnabled = false }, from: withLayer) == "Hid Layer")
        #expect(label { $0.spots = [Spot(target: .init(x: 0.5, y: 0.5), source: .init(x: 0.6, y: 0.5), radius: 0.02)] } == "Added Spot")
    }

    @Test func goingBackToNothingIsAReset() {
        var edited = Adjustments()
        edited.exposure = 1
        edited.curves.rgb.insert(.init(x: 0.5, y: 0.6))
        #expect(EditDescriber.label(from: edited, to: Adjustments(), context: context) == "Reset")
    }
}
