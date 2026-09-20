import Foundation

/// How far the values of a settings document may go, and how many things it may hold. One
/// place for it: a sidecar, a look or a catalog row may come from anywhere (downloaded,
/// shared, restored), and a value that is a number but absurd (1e308, a crop of no width, a
/// million brush strokes) must not crash the app or freeze it on every launch.
///
/// Values are brought back within bounds in silence; counts over the limit are an error,
/// because dropping strokes or spots would be losing somebody's work without a word.
public enum AdjustmentLimits {
    public static let exposure = -10.0...10.0
    public static let temperature = 1500.0...50000.0
    public static let tint = -150.0...150.0
    public static let straighten = -45.0...45.0
    static let bipolar = -100.0...100.0
    static let unipolar = 0.0...100.0
    static let unit = 0.0...1.0
    /// Positions may sit outside of the picture (a gradient often starts there), not far.
    static let position = -1.0...2.0
    /// Radii are shares of the frame: above zero, up to the whole of it.
    static let radius = 0.0001...1.0
    /// The highest instance a found mask may ask for. Nobody photographs a hundred people
    /// and masks the hundredth; a document that says so was not written by this app.
    static let maximumMaskInstance = 99

    public static let curvePoints = 16
    public static let locals = 64
    public static let brushStrokes = 500
    public static let pointsPerStroke = 5000
    /// All strokes together: 500 strokes of 5 000 points would take minutes to draw.
    public static let pointsPerBrush = 100_000
    public static let spots = 200

    static func check(_ count: Int, _ what: String, atMost limit: Int) throws {
        guard count <= limit else { throw RawEngineError.tooManyItems(what, count: count, limit: limit) }
    }
}

// MARK: - The document

extension Adjustments {
    /// The same document with every value within `AdjustmentLimits`. Decoding ends with it; a
    /// sane document comes through untouched.
    public func sanitized() -> Adjustments {
        var result = self
        for parameter in AdjustmentParameter.all {
            if let value = parameter.value(in: result) { parameter.set(value, in: &result) }
        }
        result.whiteBalance = whiteBalance?.sanitized()
        result.curves = curves.sanitized()
        result.hsl = hsl.sanitized()
        result.blackAndWhite = blackAndWhite.sanitized()
        result.grading = grading.sanitized()
        result.geometry = geometry.sanitized()
        result.locals = locals.map { $0.sanitized() }
        result.spots = spots.map { $0.sanitized() }
        result.lut = lut?.sanitized()
        return result
    }

    /// Throws when the document holds more than the engine agrees to render.
    func checkLimits() throws {
        for curve in [curves.rgb, curves.red, curves.green, curves.blue] {
            try AdjustmentLimits.check(curve.points.count, "curve points", atMost: AdjustmentLimits.curvePoints)
        }
        try AdjustmentLimits.check(locals.count, "local adjustments", atMost: AdjustmentLimits.locals)
        try AdjustmentLimits.check(spots.count, "spots", atMost: AdjustmentLimits.spots)
        for case .brush(let brush) in locals.map(\.mask) {
            try AdjustmentLimits.check(brush.strokes.count, "brush strokes", atMost: AdjustmentLimits.brushStrokes)
            for stroke in brush.strokes {
                try AdjustmentLimits.check(stroke.points.count, "points in a brush stroke", atMost: AdjustmentLimits.pointsPerStroke)
            }
            try AdjustmentLimits.check(brush.strokes.reduce(0) { $0 + $1.points.count }, "points in a brush", atMost: AdjustmentLimits.pointsPerBrush)
        }
    }
}

// MARK: - Its parts

extension WhiteBalance {
    func sanitized() -> WhiteBalance {
        WhiteBalance(
            temperature: temperature.bounded(to: AdjustmentLimits.temperature, else: RenderedDecoder.neutralWhiteBalance.temperature),
            tint: tint.bounded(to: AdjustmentLimits.tint, else: 0)
        )
    }
}

extension Curves {
    func sanitized() -> Curves {
        var result = self
        (result.rgb, result.red, result.green, result.blue) = (rgb.sanitized(), red.sanitized(), green.sanitized(), blue.sanitized())
        return result
    }
}

extension HSLAdjustments {
    func sanitized() -> HSLAdjustments {
        var result = self
        for band in ColorBandName.allCases {
            let value = self[band]
            result[band] = ColorBand(
                hue: value.hue.bounded(to: AdjustmentLimits.bipolar, else: 0),
                saturation: value.saturation.bounded(to: AdjustmentLimits.bipolar, else: 0),
                luminance: value.luminance.bounded(to: AdjustmentLimits.bipolar, else: 0)
            )
        }
        return result
    }
}

extension BlackAndWhite {
    func sanitized() -> BlackAndWhite {
        var result = self
        for channel in Self.channels {
            result[keyPath: channel] = self[keyPath: channel].bounded(to: AdjustmentLimits.bipolar, else: 0)
        }
        return result
    }
}

extension ColorGrading {
    func sanitized() -> ColorGrading {
        var result = self
        for range in TonalRange.allCases {
            let wheel = self[range]
            let hue = wheel.hue.isFinite ? wheel.hue.truncatingRemainder(dividingBy: 360) : 0
            result[range] = ColorWheel(
                hue: hue < 0 ? hue + 360 : hue,
                saturation: wheel.saturation.bounded(to: AdjustmentLimits.unipolar, else: 0),
                luminance: wheel.luminance.bounded(to: AdjustmentLimits.bipolar, else: 0)
            )
        }
        result.balance = balance.bounded(to: AdjustmentLimits.bipolar, else: 0)
        return result
    }
}

extension CropRect {
    /// Inside the frame, with sides a crop can be dragged down to at least.
    func sanitized() -> CropRect {
        let width = self.width.bounded(to: Self.minimumSide...1, else: 1)
        let height = self.height.bounded(to: Self.minimumSide...1, else: 1)
        return CropRect(x: x.bounded(to: 0...(1 - width), else: 0), y: y.bounded(to: 0...(1 - height), else: 0), width: width, height: height)
    }
}

extension Geometry {
    func sanitized() -> Geometry {
        var result = self
        result.straighten = straighten.bounded(to: AdjustmentLimits.straighten, else: 0)
        result.crop = crop?.sanitized()
        return result
    }
}

extension NormalizedPoint {
    func sanitized() -> NormalizedPoint {
        NormalizedPoint(x: x.bounded(to: AdjustmentLimits.position, else: 0.5), y: y.bounded(to: AdjustmentLimits.position, else: 0.5))
    }
}

extension Mask {
    func sanitized() -> Mask {
        switch self {
        case .linear(let mask):
            return .linear(LinearMask(start: mask.start.sanitized(), end: mask.end.sanitized()))
        case .radial(var mask):
            mask.center = mask.center.sanitized()
            mask.radiusX = mask.radiusX.bounded(to: AdjustmentLimits.radius, else: AdjustmentLimits.radius.lowerBound)
            mask.radiusY = mask.radiusY.bounded(to: AdjustmentLimits.radius, else: AdjustmentLimits.radius.lowerBound)
            mask.feather = mask.feather.bounded(to: AdjustmentLimits.unit, else: 0.5)
            return .radial(mask)
        case .brush(let mask):
            return .brush(BrushMask(strokes: mask.strokes.map { stroke in
                BrushMask.Stroke(
                    points: stroke.points.map { $0.sanitized() },
                    radius: stroke.radius.bounded(to: AdjustmentLimits.radius, else: AdjustmentLimits.radius.lowerBound),
                    isErasing: stroke.isErasing
                )
            }))
        case .detected(var mask):
            // A hostile document could ask for the thousandth person in the frame.
            mask.instance = max(0, min(mask.instance, AdjustmentLimits.maximumMaskInstance))
            return .detected(mask)
        }
    }
}

extension LocalSettings {
    func sanitized() -> LocalSettings {
        var result = self
        result.exposure = exposure.bounded(to: AdjustmentLimits.exposure, else: 0)
        for slider in Self.sliders {
            result[keyPath: slider] = self[keyPath: slider].bounded(to: AdjustmentLimits.bipolar, else: 0)
        }
        return result
    }
}

extension LocalAdjustment {
    func sanitized() -> LocalAdjustment {
        var result = self
        result.opacity = opacity.bounded(to: AdjustmentLimits.unipolar, else: 100)
        result.mask = mask.sanitized()
        result.luminanceRange = luminanceRange?.sanitized()
        result.settings = settings.sanitized()
        return result
    }
}

extension Spot {
    func sanitized() -> Spot {
        Spot(
            id: id, target: target.sanitized(), source: source.sanitized(),
            radius: radius.bounded(to: AdjustmentLimits.radius, else: AdjustmentLimits.radius.lowerBound),
            feather: feather.bounded(to: AdjustmentLimits.unit, else: 0.4)
        )
    }
}
