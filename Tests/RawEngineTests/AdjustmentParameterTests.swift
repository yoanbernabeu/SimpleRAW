import Foundation
import Testing
@testable import RawEngine

@Suite struct AdjustmentParameterTests {
    /// A scalar field added to `Adjustments` without an entry would be out of reach of the
    /// CLI, and unbounded when decoded.
    @Test func everyScalarFieldOfTheDocumentIsInTheTable() {
        let scalars = Mirror(reflecting: Adjustments()).children.compactMap { child -> String? in
            // The exact type, not `is Double?`: a nil optional of any type passes that one.
            let type = type(of: child.value)
            return type == Double.self || type == Double?.self ? child.label : nil
        }
        #expect(scalars.count >= 18)
        #expect(Set(scalars) == Set(AdjustmentParameter.all.map(\.name)))
        #expect(AdjustmentParameter.all.count == Set(AdjustmentParameter.all.map(\.name)).count)
    }

    /// The name is the one the JSON document uses, and the key path leads to the same field.
    @Test(arguments: AdjustmentParameter.all)
    func aParameterIsNamedAfterItsFieldInTheDocument(parameter: AdjustmentParameter) throws {
        var adjustments = Adjustments()
        let value = parameter.range.upperBound / 2
        parameter.set(value, in: &adjustments)
        let document = try #require(try JSONSerialization.jsonObject(with: adjustments.jsonData()) as? [String: Any])
        #expect(document[parameter.name] as? Double == value)
        #expect(parameter.value(in: adjustments) == value)
    }

    @Test(arguments: AdjustmentParameter.all)
    func aParameterRestsWithinItsRangeAndBounds(parameter: AdjustmentParameter) {
        #expect(parameter.bounds.lowerBound <= parameter.range.lowerBound && parameter.bounds.upperBound >= parameter.range.upperBound)
        if let neutral = parameter.neutral { #expect(parameter.range.contains(neutral)) }
        #expect(parameter.value(in: Adjustments()) == parameter.neutral)
    }

    @Test func settingAValueBringsItWithinBounds() throws {
        var adjustments = Adjustments()
        try #require(AdjustmentParameter.named("clarity")).set(400, in: &adjustments)
        try #require(AdjustmentParameter.named("sharpness")).set(-3, in: &adjustments)
        #expect(adjustments.clarity == 100 && adjustments.sharpness == 0)
        #expect(AdjustmentParameter.named("nonsense") == nil)
    }
}
