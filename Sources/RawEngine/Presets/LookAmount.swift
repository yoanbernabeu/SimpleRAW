import Foundation

/// A look dosed from 0 to 100 %. A pure function of the settings of the photo and those of
/// the look, inside the groups the look carries: numbers go part of the way, curves meet
/// point by point, hues take the short way round the circle. What has no in-between (black
/// and white on or off, a crop, a stack of layers) switches at the middle of the slider.
extension Preset {
    /// - Parameters:
    ///   - amount: from 0 (the photo as it is) to 1 (the look applied, exactly as `apply` does).
    ///   - asShot: the white balance of the camera, which is what a photo with none of its own
    ///     starts from. Without it, a white balance can only switch.
    public func applied(to current: Adjustments, amount: Double, asShot: WhiteBalance? = nil) -> Adjustments {
        let amount = amount.bounded(to: 0...1, else: 0)
        guard amount > 0 else { return current }
        let target = current.applying(adjustments, groups: groups)
        guard amount < 1 else { return target }
        return groups.reduce(into: current) { result, group in
            Blend(amount: amount, asShot: asShot).blend(group, from: current, to: target, into: &result)
        }
    }

    /// What this look brings that has no in-between, named as someone would say it: the
    /// amount slider switches these at the middle instead of fading them in. Empty when
    /// everything the look carries interpolates — most looks have nothing to warn about.
    public var switchesAtHalf: [String] {
        var named: [String] = []
        if groups.contains(.color), adjustments.blackAndWhite.isEnabled { named.append("black and white") }
        if groups.contains(.geometry), adjustments.geometry != Geometry() { named.append("the framing") }
        if groups.contains(.local), !adjustments.locals.isEmpty { named.append("layers") }
        if groups.contains(.spots), !adjustments.spots.isEmpty { named.append("spots") }
        return named
    }
}

private struct Blend {
    let amount: Double
    let asShot: WhiteBalance?

    /// What has no in-between comes in at the middle.
    var isPastTheMiddle: Bool { amount >= 0.5 }

    func number(_ from: Double, _ to: Double) -> Double {
        from + (to - from) * amount
    }

    /// Both set: part of the way. Else there is no number to start from, or to go to.
    func number(_ from: Double?, _ to: Double?) -> Double? {
        if let from, let to { return number(from, to) }
        return isPastTheMiddle ? to : from
    }

    func blend(_ group: AdjustmentGroup, from current: Adjustments, to target: Adjustments, into result: inout Adjustments) {
        switch group {
        case .light:
            for keyPath in [\Adjustments.exposure, \.contrast, \.highlights, \.shadows, \.whites, \.blacks] { blend(keyPath, current, target, &result) }
        case .effects:
            for keyPath in [\Adjustments.enhance, \.clarity, \.structure, \.dehaze, \.glow, \.grain] { blend(keyPath, current, target, &result) }
        case .color:
            for keyPath in [\Adjustments.vibrance, \.saturation] { blend(keyPath, current, target, &result) }
            result.blackAndWhite = blackAndWhite(current.blackAndWhite, target.blackAndWhite)
        case .detail:
            result.sharpness = number(current.sharpness, target.sharpness)
            result.luminanceNoiseReduction = number(current.luminanceNoiseReduction, target.luminanceNoiseReduction)
            result.colorNoiseReduction = number(current.colorNoiseReduction, target.colorNoiseReduction)
        case .optics:
            blend(\.vignetting, current, target, &result)
            // A fringe correction belongs to a lens, not to a look, but it fades like every
            // other number rather than jumping: half a look is half of what it carries.
            for keyPath in [\Adjustments.aberration.redCyan, \.aberration.blueYellow, \.distortion, \.purpleFringe.amount] { blend(keyPath, current, target, &result) }
            result.lensCorrection = isPastTheMiddle ? target.lensCorrection : current.lensCorrection
        case .curve:
            result.curves.rgb = curve(current.curves.rgb, target.curves.rgb)
            result.curves.red = curve(current.curves.red, target.curves.red)
            result.curves.green = curve(current.curves.green, target.curves.green)
            result.curves.blue = curve(current.curves.blue, target.curves.blue)
        case .whiteBalance:
            result.whiteBalance = whiteBalance(current.whiteBalance, target.whiteBalance)
        case .hsl:
            for band in ColorBandName.allCases {
                let (from, to) = (current.hsl[band], target.hsl[band])
                result.hsl[band] = ColorBand(hue: number(from.hue, to.hue), saturation: number(from.saturation, to.saturation), luminance: number(from.luminance, to.luminance))
            }
        case .grading:
            for range in TonalRange.allCases { result.grading[range] = wheel(current.grading[range], target.grading[range]) }
            result.grading.balance = number(current.grading.balance, target.grading.balance)
            result.lut = mood(current.lut, target.lut)
        case .geometry:
            result.geometry = isPastTheMiddle ? target.geometry : current.geometry
        case .local:
            result.locals = isPastTheMiddle ? target.locals : current.locals
        case .spots:
            result.spots = isPastTheMiddle ? target.spots : current.spots
        }
    }

    private func blend(_ keyPath: WritableKeyPath<Adjustments, Double>, _ current: Adjustments, _ target: Adjustments, _ result: inout Adjustments) {
        result[keyPath: keyPath] = number(current[keyPath: keyPath], target[keyPath: keyPath])
    }

    private func blackAndWhite(_ from: BlackAndWhite, _ to: BlackAndWhite) -> BlackAndWhite {
        var result = isPastTheMiddle ? to : from
        for channel in BlackAndWhite.channels { result[keyPath: channel] = number(from[keyPath: channel], to[keyPath: channel]) }
        return result
    }

    private func whiteBalance(_ from: WhiteBalance?, _ to: WhiteBalance?) -> WhiteBalance? {
        guard let start = from ?? asShot, let end = to ?? asShot else { return isPastTheMiddle ? to : from }
        let blended = WhiteBalance(temperature: number(start.temperature, end.temperature), tint: number(start.tint, end.tint))
        // As shot is stored as no white balance at all.
        return blended == asShot ? nil : blended
    }

    /// A mood fades in by its own amount, which is exactly what dosing a look should do to
    /// it. Two different tables have nothing in between, so those switch at the middle.
    private func mood(_ from: LUTSetting?, _ to: LUTSetting?) -> LUTSetting? {
        func faded(_ name: String, _ amount: Double) -> LUTSetting? {
            amount > 0 ? LUTSetting(name: name, amount: amount) : nil
        }
        switch (from, to) {
        case (let from?, let to?) where from.name == to.name:
            return faded(to.name, number(from.amount, to.amount))
        case (nil, let to?):
            return faded(to.name, number(0, to.amount))
        case (let from?, nil):
            return faded(from.name, number(from.amount, 0))
        default:
            return isPastTheMiddle ? to : from
        }
    }

    /// A wheel without saturation tints nothing, so it has no hue to start from, or to go to.
    private func wheel(_ from: ColorWheel, _ to: ColorWheel) -> ColorWheel {
        let hue: Double
        if from.saturation == 0 {
            hue = to.hue
        } else if to.saturation == 0 {
            hue = from.hue
        } else {
            // The short way round: from 350° to 10° is 20° through red.
            let arc = (to.hue - from.hue + 540).truncatingRemainder(dividingBy: 360) - 180
            hue = (from.hue + arc * amount + 360).truncatingRemainder(dividingBy: 360)
        }
        return ColorWheel(hue: hue, saturation: number(from.saturation, to.saturation), luminance: number(from.luminance, to.luminance))
    }

    /// The curve between two curves, drawn through the points of both. Past what a curve may
    /// hold, through evenly spaced points instead.
    private func curve(_ from: Curve, _ to: Curve) -> Curve {
        guard from != to else { return from }
        var positions: [Double] = []
        for x in (from.points + to.points).map(\.x).sorted() where positions.last.map({ x - $0 >= Curve.minimumGap }) ?? true {
            positions.append(x)
        }
        if positions.count > AdjustmentLimits.curvePoints {
            positions = (0..<AdjustmentLimits.curvePoints).map { Double($0) / Double(AdjustmentLimits.curvePoints - 1) }
        }
        return Curve(points: positions.map { Curve.Point(x: $0, y: number(from.value(at: $0), to.value(at: $0))) })
    }
}
