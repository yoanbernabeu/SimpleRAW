import Foundation

/// One scalar setting of `Adjustments`, without anything visual: its name in the JSON
/// document, where it lives, how far a slider goes and where it rests. Every front end builds
/// on this table: the inspector decorates it, the CLI sets values through it (`--set`), and
/// decoding bounds documents with it. **A new scalar field of `Adjustments` is a new entry
/// here**; a test fails otherwise.
public struct AdjustmentParameter: Sendable {
    public enum Storage: Sendable {
        case value(WritableKeyPath<Adjustments, Double> & Sendable)
        /// `nil` = the decoder's choice for this camera.
        case decoderAmount(WritableKeyPath<Adjustments, Double?> & Sendable)
    }

    /// As written in the JSON document.
    public let name: String
    public let storage: Storage
    /// What a slider offers.
    public let range: ClosedRange<Double>
    /// What a document may hold: the range, unless stated otherwise.
    public let bounds: ClosedRange<Double>

    /// Where the slider rests. `nil` when that is up to the decoder.
    public var neutral: Double? {
        switch storage {
        case .value(let keyPath): Adjustments()[keyPath: keyPath]
        case .decoderAmount: nil
        }
    }

    public func value(in adjustments: Adjustments) -> Double? {
        switch storage {
        case .value(let keyPath): adjustments[keyPath: keyPath]
        case .decoderAmount(let keyPath): adjustments[keyPath: keyPath]
        }
    }

    /// Sets the value, brought back within `bounds`.
    public func set(_ value: Double, in adjustments: inout Adjustments) {
        let bounded = value.bounded(to: bounds, else: neutral ?? bounds.lowerBound)
        switch storage {
        case .value(let keyPath): adjustments[keyPath: keyPath] = bounded
        case .decoderAmount(let keyPath): adjustments[keyPath: keyPath] = bounded
        }
    }

    /// Applies what a command line was given: `clarity=20`. Validated against the table, and
    /// told rather than clamped in silence: somebody typing `clarity=400` made a mistake.
    public static func apply(_ assignment: String, to adjustments: inout Adjustments) throws {
        let parts = assignment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty else {
            throw RawEngineError.invalidSetting(assignment, reason: "expected name=value")
        }
        guard let parameter = named(parts[0]) else {
            throw RawEngineError.invalidSetting(assignment, reason: "no setting named \"\(parts[0])\". Settings: \(all.map(\.name).joined(separator: ", "))")
        }
        guard let value = Double(parts[1]), value.isFinite else {
            throw RawEngineError.invalidSetting(assignment, reason: "\"\(parts[1])\" is not a number")
        }
        guard parameter.bounds.contains(value) else {
            throw RawEngineError.invalidSetting(assignment, reason: "\(parameter.name) goes from \(parameter.bounds.lowerBound.formatted()) to \(parameter.bounds.upperBound.formatted())")
        }
        parameter.set(value, in: &adjustments)
    }

    public static func named(_ name: String) -> AdjustmentParameter? {
        all.first { $0.name == name }
    }

    private static func centered(_ name: String, _ keyPath: WritableKeyPath<Adjustments, Double> & Sendable) -> AdjustmentParameter {
        AdjustmentParameter(name: name, storage: .value(keyPath), range: -100...100, bounds: -100...100)
    }

    private static func amount(_ name: String, _ keyPath: WritableKeyPath<Adjustments, Double> & Sendable) -> AdjustmentParameter {
        AdjustmentParameter(name: name, storage: .value(keyPath), range: 0...100, bounds: 0...100)
    }

    private static func decoderAmount(_ name: String, _ keyPath: WritableKeyPath<Adjustments, Double?> & Sendable) -> AdjustmentParameter {
        AdjustmentParameter(name: name, storage: .decoderAmount(keyPath), range: 0...100, bounds: 0...100)
    }

    public static let all: [AdjustmentParameter] = [
        // A slider offers five stops; a document may hold what a script asked for.
        AdjustmentParameter(name: "exposure", storage: .value(\.exposure), range: -5...5, bounds: AdjustmentLimits.exposure),
        centered("contrast", \.contrast), centered("highlights", \.highlights), centered("shadows", \.shadows),
        centered("whites", \.whites), centered("blacks", \.blacks),
        centered("vibrance", \.vibrance), centered("saturation", \.saturation),
        amount("enhance", \.enhance),
        centered("clarity", \.clarity), centered("structure", \.structure), centered("dehaze", \.dehaze),
        amount("glow", \.glow), amount("grain", \.grain),
        decoderAmount("sharpness", \.sharpness),
        decoderAmount("luminanceNoiseReduction", \.luminanceNoiseReduction),
        decoderAmount("colorNoiseReduction", \.colorNoiseReduction),
        centered("vignetting", \.vignetting),
        // Reachable from the command line like every other scalar, whether or not this build
        // can act on it: a document written elsewhere keeps its value either way.
        centered("distortion", \.distortion),
    ]
}

extension Double {
    /// The value within `range`; `fallback` when it is not a number at all.
    func bounded(to range: ClosedRange<Double>, else fallback: Double) -> Double {
        isNaN ? fallback : Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
