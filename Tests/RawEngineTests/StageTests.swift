import CoreImage
import Testing
import TestSupport
@testable import RawEngine

/// Each stage is tested in isolation on synthetic swatches: no RAW file required.
@Suite struct StageTests {
    let probe = PixelProbe()
    let darkGray = PixelProbe.swatch(r: 0.05, g: 0.05, b: 0.05)
    let lightGray = PixelProbe.swatch(r: 0.6, g: 0.6, b: 0.6)
    let mutedOrange = PixelProbe.swatch(r: 0.5, g: 0.4, b: 0.3)

    @Test(arguments: DevelopPipeline.standard.stages.indices)
    func neutralAdjustmentsLeaveTheImageUntouched(index: Int) {
        let stage = DevelopPipeline.standard.stages[index]
        #expect(stage.apply(Adjustments(), to: mutedOrange) === mutedOrange)
    }

    @Test func shadowsLiftDarkTones() throws {
        var adjustments = Adjustments()
        adjustments.shadows = 100
        let output = HighlightsShadowsStage().apply(adjustments, to: darkGray)
        #expect(try probe.average(of: output).luminance > probe.average(of: darkGray).luminance)
    }

    @Test func negativeHighlightsDarkenBrightTones() throws {
        var adjustments = Adjustments()
        adjustments.highlights = -100
        let output = HighlightsShadowsStage().apply(adjustments, to: lightGray)
        #expect(try probe.average(of: output).luminance < probe.average(of: lightGray).luminance)
    }

    @Test func contrastPushesTonesApart() throws {
        var adjustments = Adjustments()
        adjustments.contrast = 100
        let stage = ToneCurveStage()
        #expect(try probe.average(of: stage.apply(adjustments, to: darkGray)).luminance
            < probe.average(of: darkGray).luminance)
        #expect(try probe.average(of: stage.apply(adjustments, to: lightGray)).luminance
            > probe.average(of: lightGray).luminance)
    }

    /// Regression: the curve used to be wrapped in a second linear → sRGB conversion, which
    /// moved the pivot into the deep shadows and brightened mid-gray by more than a stop.
    @Test func contrastPivotsAroundPerceptualMidGray() throws {
        var adjustments = Adjustments()
        adjustments.contrast = 100
        let midGray = PixelProbe.swatch(r: 0.214, g: 0.214, b: 0.214) // sRGB 0.5, linearized
        let output = ToneCurveStage().apply(adjustments, to: midGray)
        #expect(abs(try probe.average(of: output).luminance - 0.214) < 0.01)
    }

    @Test func positiveHighlightsBrightenBrightTones() throws {
        var adjustments = Adjustments()
        adjustments.highlights = 100
        let output = ToneCurveStage().apply(adjustments, to: lightGray)
        #expect(try probe.average(of: output).luminance > probe.average(of: lightGray).luminance)
    }

    @Test func vibranceBoostsMutedColors() throws {
        var adjustments = Adjustments()
        adjustments.vibrance = 100
        let output = VibranceStage().apply(adjustments, to: mutedOrange)
        #expect(try probe.average(of: output).chroma > probe.average(of: mutedOrange).chroma)
    }

    @Test func fullDesaturationYieldsGray() throws {
        var adjustments = Adjustments()
        adjustments.saturation = -100
        let output = SaturationStage().apply(adjustments, to: mutedOrange)
        #expect(try probe.average(of: output).chroma < 0.01)
    }

    @Test func pipelineRunsStagesInOrder() {
        struct Tag: PipelineStage {
            let name: String
            func apply(_ adjustments: Adjustments, to image: CIImage) -> CIImage {
                let trail = (image.properties["trail"] as? String ?? "") + name
                return image.settingProperties(["trail": trail])
            }
        }
        let pipeline = DevelopPipeline(stages: [Tag(name: "a"), Tag(name: "b"), Tag(name: "c")])
        let output = pipeline.apply(Adjustments(), to: darkGray)
        #expect(output.properties["trail"] as? String == "abc")
    }
}

@Suite struct SliderTests {
    @Test func bipolarSlidersMapToMinusOneToOne() {
        #expect(Slider.bipolar(50) == 0.5)
        #expect(Slider.bipolar(-250) == -1)
        #expect(Slider.bipolar(250) == 1)
    }

    @Test func unipolarSlidersMapToZeroToOne() {
        #expect(Slider.unipolar(40) == 0.4)
        #expect(Slider.unipolar(-10) == 0)
        #expect(Slider.unipolar(180) == 1)
    }
}
