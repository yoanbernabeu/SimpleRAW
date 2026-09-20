import CoreImage
import CoreImage.CIFilterBuiltins

/// Keystone correction, by moving the four corners of the frame.
///
/// It runs **early**, with the other optical corrections, and not with the crop — although it
/// is `Geometry` that carries its settings, because it changes the shape of the frame. Two
/// reasons, and the second is the one that decided it:
///
/// - A converging vertical is what the lens and the viewpoint did to the scene, like vignetting
///   and distortion; the crop is what the photographer chose.
/// - A homography is not an affine transform. Put after the blurs of clarity, dehaze and glow,
///   it made Core Image render and keep a whole new set of them on every frame of a drag —
///   some three hundred megabytes a frame, eight gigabytes in a couple of seconds, measured.
///   In front of them it costs one resampling of a decoded picture, and the blurs then work on
///   a picture whose size does not change under their feet.
///
/// What follows from that order: a mask or a spot is placed on the picture as it is corrected,
/// which is the picture the photographer is looking at. Changing the correction afterwards
/// moves the scene under them, as it does in every tool that works this way.
public struct LensCorrectionStage: PipelineStage {
    public init() {}

    public func apply(_ adjustments: Adjustments, to image: CIImage) -> CIImage {
        guard !image.extent.isInfinite else { return image }
        // The lens first, then the viewpoint: the fringes and the bulge are in the picture as
        // it was taken, so they are undone before anything moves the frame.
        var output = Self.deFringed(image, by: adjustments.aberration)
        output = Self.washed(output, by: adjustments.purpleFringe)
        output = Self.straightenedLines(output, by: adjustments.distortion)
        return Self.corrected(output, by: adjustments.geometry.perspective)
    }

    /// The violet halo along a hard edge, taken out where there is an edge and nowhere else.
    ///
    /// Two pieces, both stock. `PurpleFringe` washes a narrow band of hues to their own
    /// brightness, baked into a lookup table like every other colour transform here. And
    /// `CIEdges` says where the picture has an edge, which is what keeps the table off a
    /// violet flower, a dress or a dusk sky — the correction only ever lands on the few pixels
    /// either side of a hard line, which is the only place a lens puts a fringe.
    static func washed(_ image: CIImage, by fringe: PurpleFringe) -> CIImage {
        guard !fringe.isNeutral else { return image }
        let extent = image.extent
        let cube = CIFilter.colorCube()
        cube.inputImage = image
        cube.cubeDimension = Float(ColorCube.dimension)
        cube.cubeData = ColorCube { fringe.corrected($0) }.data
        guard let washed = cube.outputImage else { return image }

        let edges = CIFilter.edges()
        edges.inputImage = image
        // Enough that a real edge reads as white and film grain does not.
        edges.intensity = Float(Self.edgeStrength)
        guard let found = edges.outputImage else { return image }
        // The mask is read as brightness, and a fringe is a few pixels wide: blurred a little
        // so that the wash reaches across it rather than stopping on the line itself.
        let grey = CIFilter.maximumComponent()
        grey.inputImage = found
        let spread = CIFilter.gaussianBlur()
        spread.inputImage = (grey.outputImage ?? found).clampedToExtent()
        spread.radius = Float(Self.edgeSpread)
        guard let mask = spread.outputImage?.cropped(to: extent) else { return image }

        let blend = CIFilter.blendWithMask()
        blend.backgroundImage = image
        blend.inputImage = washed
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: extent) ?? image
    }

    /// How hard `CIEdges` looks. Measured on a swatch: below this a soft gradient starts to
    /// read as an edge, above it a real one is already white.
    static let edgeStrength = 4.0
    /// How far either side of the line the wash reaches, in pixels of the decoded preview.
    static let edgeSpread = 2.0

    /// Barrel and pincushion: the one treatment here that stock filters cannot express, since
    /// it moves each pixel by an amount that depends on where it is. Without the kernel — a
    /// build with no Metal compiler — the picture goes through untouched, and the interface
    /// does not offer the slider.
    static func straightenedLines(_ image: CIImage, by slider: Double) -> CIImage {
        let amount = Slider.bipolar(slider)
        guard amount != 0, let kernel = MetalKernels.warp("lensDistortion") else { return image }
        let extent = image.extent
        let centre = CIVector(x: extent.midX, y: extent.midY)
        let halfDiagonal = Float(hypot(extent.width, extent.height) / 2)
        // One coefficient: a slider is a correction by eye, not a measured profile. `k2` is
        // there for the day a profile is measured off a test chart.
        let k1 = Float(amount * Self.maximumDistortion)
        let corrected = kernel.apply(
            extent: extent,
            // A pixel of the answer can come from a little outside the region asked for: how
            // far is exactly what the correction moves the corner by.
            roiCallback: { _, rect in rect.insetBy(dx: -CGFloat(halfDiagonal) * 0.1, dy: -CGFloat(halfDiagonal) * 0.1) },
            image: image.clampedToExtent(),
            arguments: [k1, Float(0), centre, halfDiagonal]
        )
        return corrected?.cropped(to: extent) ?? image
    }

    /// What a slider at full scale corrects, as the `k1` of `r' = r(1 + k1 r²)`. A tenth is
    /// already twice what a wide-angle compact leaves.
    static let maximumDistortion = 0.10

    /// Brings the red and the blue channel back to the size of the green one. A uniform radial
    /// scale is an affine transform, which is why this much of a lens profile needs no kernel.
    static func deFringed(_ image: CIImage, by aberration: ChromaticAberration) -> CIImage {
        guard !aberration.isNeutral else { return image }
        let extent = image.extent
        let (red, blue) = aberration.scales

        func scaled(by factor: Double) -> CIImage {
            guard factor != 1 else { return image }
            let transform = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
                .concatenating(CGAffineTransform(scaleX: factor, y: factor))
                .concatenating(CGAffineTransform(translationX: extent.midX, y: extent.midY))
            // Clamped first, or a channel shrunk towards the middle leaves a transparent rim;
            // cropped back at the end, so nothing infinite ever leaves this function.
            return image.clampedToExtent().transformed(by: transform)
        }

        func only(_ channel: Channel, of image: CIImage) -> CIImage {
            let filter = CIFilter.colorMatrix()
            filter.inputImage = image
            filter.rVector = CIVector(x: channel == .red ? 1 : 0, y: 0, z: 0, w: 0)
            filter.gVector = CIVector(x: 0, y: channel == .green ? 1 : 0, z: 0, w: 0)
            filter.bVector = CIVector(x: 0, y: 0, z: channel == .blue ? 1 : 0, w: 0)
            // Opaque, always. Core Image holds colour premultiplied by alpha: a part kept at
            // alpha zero reads as black whatever its colour, and the three added up gave a
            // black picture. They are added opaque, and the alpha of the sum is set at the end.
            filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            filter.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return filter.outputImage ?? image
        }

        // The larger of the two, channel by channel, rather than the sum: each part is zero
        // everywhere but in its own channel, so the greater one is the one that has it — and
        // the alpha of the result stays one instead of adding up to three, which added a
        // division by three to every colour.
        func combined(_ first: CIImage, _ second: CIImage) -> CIImage {
            let filter = CIFilter.maximumCompositing()
            filter.inputImage = first
            filter.backgroundImage = second
            return filter.outputImage ?? first
        }

        let recombined = combined(only(.red, of: scaled(by: red)), combined(only(.green, of: image), only(.blue, of: scaled(by: blue))))
        return recombined.cropped(to: extent)
    }

    private enum Channel { case red, green, blue }

    private static func corrected(_ image: CIImage, by perspective: Perspective) -> CIImage {
        guard !perspective.isNeutral else { return image }
        let extent = image.extent
        let shape = extent.height / extent.width
        let halfWidth = extent.width / 2
        // `Perspective` measures both axes in half-widths, with y up, as Core Image does.
        func place(_ corner: Perspective.Point) -> CGPoint {
            CGPoint(x: extent.midX + corner.x * halfWidth, y: extent.midY + corner.y * halfWidth)
        }
        let corners = perspective.corners(ofShape: shape)
        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = image
        filter.topLeft = place(corners[0])
        filter.topRight = place(corners[1])
        filter.bottomRight = place(corners[2])
        filter.bottomLeft = place(corners[3])
        guard let tilted = filter.outputImage else { return image }

        // Cut back to the largest frame of the same shape that holds no empty triangle.
        let scale = perspective.scale(ofShape: shape)
        let kept = CGRect(
            x: extent.midX - extent.width * scale / 2, y: extent.midY - extent.height * scale / 2,
            width: extent.width * scale, height: extent.height * scale
        )
        return tilted.cropped(to: Geometry.integral(kept))
    }
}
