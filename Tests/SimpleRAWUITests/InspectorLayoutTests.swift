import Foundation
import RawEngine
import Testing
@testable import SimpleRAWUI

@Suite struct InspectorLayoutTests {
    let context = SliderContext(
        asShotWhiteBalance: WhiteBalance(temperature: 5000, tint: 10),
        decoderDefaults: .init(sharpness: 30, luminanceNoiseReduction: 20, colorNoiseReduction: 50)
    )

    /// A section that belongs to no tab would be a tool nobody can reach.
    @Test func everyPanelIsReachableFromExactlyOneTab() {
        let placed = InspectorTab.allCases.flatMap(\.panels)
        #expect(Set(placed).count == placed.count)
        for section in SliderSpec.Section.listed {
            #expect(placed.contains(.sliders(section)), "\(section) is in no tab")
        }
        for panel in [InspectorPanel.curve, .blackAndWhite, .hsl, .grading, .looks, .mood, .layers, .spots, .versions] {
            #expect(placed.contains(panel), "\(panel) is in no tab")
        }
    }

    /// Opening a panel whose controls act on the canvas picks up its tool; leaving it puts the
    /// tool down. Without that, masks stayed on the picture while exposure was being set.
    @Test func panelsThatWorkOnTheCanvasComeWithTheirTool() {
        #expect(InspectorPanel.layers.tool == .local)
        #expect(InspectorPanel.spots.tool == .spots)
        #expect(InspectorPanel.curve.tool == nil && InspectorPanel.sliders(.light).tool == nil)

        #expect(InspectorLayout.tool(whenShowing: .layers, current: .none) == .local)
        #expect(InspectorLayout.tool(whenShowing: .sliders(.light), current: .local) == Tool.none)
        #expect(InspectorLayout.tool(whenShowing: nil, current: .spots) == Tool.none)
        // The crop tool and the eyedropper have no panel of their own: they are left alone.
        #expect(InspectorLayout.tool(whenShowing: .sliders(.light), current: .crop) == .crop)
        #expect(InspectorLayout.tool(whenShowing: .sliders(.color), current: .whiteBalance) == .whiteBalance)
        // Even under a panel that has a tool: cropping is not interrupted by the inspector.
        #expect(InspectorLayout.tool(whenShowing: .layers, current: .crop) == .crop)
        #expect(InspectorLayout.tool(whenShowing: .spots, current: .local) == .spots)
    }

    @Test func aFreshPictureHasNothingMarkedAsEdited() {
        for tab in InspectorTab.allCases {
            #expect(!tab.isEdited(Adjustments(), context), "\(tab)")
        }
    }

    @Test func anEditMarksItsPanelAndItsTabOnly() {
        var adjustments = Adjustments()
        adjustments.hsl[.blue].saturation = -20
        #expect(InspectorPanel.hsl.isEdited(adjustments, context))
        #expect(InspectorTab.color.isEdited(adjustments, context))
        #expect(!InspectorPanel.grading.isEdited(adjustments, context))
        #expect(!InspectorTab.light.isEdited(adjustments, context) && !InspectorTab.local.isEdited(adjustments, context))
    }

    @Test func sliderPanelsAreEditedWhenOneOfTheirSlidersIs() {
        let cases: [(InspectorPanel, (inout Adjustments) -> Void)] = [
            (.sliders(.light), { $0.exposure = 0.5 }),
            (.sliders(.essentials), { $0.enhance = 12 }),
            (.sliders(.effects), { $0.clarity = 12 }),
            (.sliders(.optics), { $0.vignetting = 12 }),
        ]
        for (panel, edit) in cases {
            var adjustments = Adjustments()
            edit(&adjustments)
            #expect(panel.isEdited(adjustments, context), "\(panel)")
        }
    }

    @Test func specialPanelsKnowWhenTheyAreEdited() {
        var adjustments = Adjustments()
        adjustments.curves.red.insert(.init(x: 0.5, y: 0.6))
        adjustments.blackAndWhite.isEnabled = true
        adjustments.grading[.shadows] = ColorWheel(hue: 200, saturation: 30)
        adjustments.locals = [LocalAdjustment(mask: .brush(BrushMask()))]
        adjustments.spots = [Spot(target: .init(x: 0.5, y: 0.5), source: .init(x: 0.6, y: 0.5), radius: 0.02)]
        adjustments.lut = LUTSetting(name: "Teal", amount: 60)
        for panel in [InspectorPanel.curve, .blackAndWhite, .grading, .mood, .layers, .spots] {
            #expect(panel.isEdited(adjustments, context), "\(panel)")
        }
        // Looks are actions, not settings: they are never "edited".
        #expect(!InspectorPanel.looks.isEdited(adjustments, context))
    }

    /// Picking a tool on the canvas must bring its controls into view.
    @Test func toolsKnowTheirTab() {
        #expect(InspectorTab.tab(for: .local) == .local && InspectorTab.tab(for: .spots) == .local)
        #expect(InspectorTab.tab(for: .crop) == nil && InspectorTab.tab(for: .none) == nil)
    }
}
