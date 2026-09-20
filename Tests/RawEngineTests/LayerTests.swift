import CoreImage
import Foundation
import Testing
import TestSupport
@testable import RawEngine

/// A local adjustment is a layer: it can be hidden, faded, renamed, moved and copied, and
/// none of that touches the layers around it.
@Suite struct LayerStageTests {
    let probe = PixelProbe()
    let stage = LocalAdjustmentsStage()
    let gray = PixelProbe.swatch(r: 0.2, g: 0.2, b: 0.2, size: CGSize(width: 300, height: 200))

    /// Covers the whole frame, so that only the layer's own properties matter.
    private func layer(exposure: Double) -> LocalAdjustment {
        var settings = LocalSettings()
        settings.exposure = exposure
        return LocalAdjustment(mask: .linear(LinearMask(start: .init(x: 0.5, y: 2), end: .init(x: 0.5, y: 3))), settings: settings)
    }

    private func luminance(_ locals: [LocalAdjustment]) throws -> Float {
        var adjustments = Adjustments()
        adjustments.locals = locals
        return try probe.average(of: stage.apply(adjustments, to: gray)).luminance
    }

    @Test func aHiddenLayerDoesNothing() throws {
        var hidden = layer(exposure: 1)
        hidden.isEnabled = false
        #expect(abs(try luminance([hidden]) - 0.2) < 0.002)
    }

    @Test func hidingALayerLeavesTheOnesAboveAtWork() throws {
        var hidden = layer(exposure: 1)
        hidden.isEnabled = false
        #expect(abs(try luminance([hidden, layer(exposure: 1)]) - 0.4) < 0.01)
    }

    @Test func opacityFadesTheLayer() throws {
        var faded = layer(exposure: 1)
        faded.opacity = 50
        // Halfway between 0.2 (untouched) and 0.4 (one stop up).
        #expect(abs(try luminance([faded]) - 0.3) < 0.01)
        faded.opacity = 0
        #expect(abs(try luminance([faded]) - 0.2) < 0.002)
    }

    @Test func aLayerWithNoEffectCostsNothing() {
        var adjustments = Adjustments()
        var transparent = layer(exposure: 1)
        transparent.opacity = 0
        var hidden = layer(exposure: 1)
        hidden.isEnabled = false
        adjustments.locals = [transparent, hidden]
        #expect(stage.apply(adjustments, to: gray) === gray)
    }
}

@Suite struct LayerDocumentTests {
    @Test func layerPropertiesRoundTripThroughJSON() throws {
        var layer = LocalAdjustment(mask: .brush(BrushMask()))
        layer.name = "Sky"
        layer.isEnabled = false
        layer.opacity = 40
        var adjustments = Adjustments()
        adjustments.locals = [layer]
        #expect(try JSONDecoder().decode(Adjustments.self, from: adjustments.jsonData()) == adjustments)
    }

    /// Documents written before layers existed: visible, fully opaque, unnamed.
    @Test func olderDocumentsGetTheDefaults() throws {
        let json = Data(#"{"locals": [{"id": "11111111-1111-1111-1111-111111111111", "mask": {"brush": {"strokes": []}}, "settings": {"exposure": 1}}]}"#.utf8)
        let layer = try #require(try JSONDecoder().decode(Adjustments.self, from: json).locals.first)
        #expect(layer.isEnabled && layer.opacity == 100 && layer.name == nil)
        #expect(layer.settings.exposure == 1)
    }
}

@Suite struct LayerStackTests {
    private func stack() -> [LocalAdjustment] {
        (1...3).map { index in
            var layer = LocalAdjustment(mask: .brush(BrushMask()))
            layer.name = "L\(index)"
            return layer
        }
    }

    @Test func movingALayerKeepsTheOthersInOrder() {
        var layers = stack()
        layers.moveLayer(withID: layers[0].id, by: 2)
        #expect(layers.map(\.name) == ["L2", "L3", "L1"])
        layers.moveLayer(withID: layers[2].id, by: -1)
        #expect(layers.map(\.name) == ["L2", "L1", "L3"])
    }

    @Test func aLayerCannotLeaveTheStack() {
        var layers = stack()
        layers.moveLayer(withID: layers[0].id, by: -5)
        layers.moveLayer(withID: layers[2].id, by: 5)
        #expect(layers.map(\.name) == ["L1", "L2", "L3"])
    }

    @Test func aDuplicateSitsRightAboveItsOriginalWithItsOwnIdentity() throws {
        var layers = stack()
        let duplicated = layers.duplicateLayer(withID: layers[1].id)
        let copy = try #require(duplicated)
        #expect(layers.map(\.name) == ["L1", "L2", "L2 copy", "L3"])
        #expect(copy.id != layers[1].id && layers[2].id == copy.id)
        #expect(layers[2].mask == layers[1].mask && layers[2].settings == layers[1].settings)
    }

    @Test func layersAreNamedAfterTheirMaskUntilRenamed() {
        var layers = [
            LocalAdjustment(mask: .linear(LinearMask(start: .init(x: 0, y: 0), end: .init(x: 0, y: 1)))),
            LocalAdjustment(mask: .brush(BrushMask())),
            LocalAdjustment(mask: .brush(BrushMask())),
        ]
        #expect(layers.displayNames == ["Gradient 1", "Brush 1", "Brush 2"])
        layers[1].name = "Face"
        #expect(layers.displayNames == ["Gradient 1", "Face", "Brush 2"])
    }
}
