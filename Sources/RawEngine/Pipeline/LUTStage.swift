import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import simd

/// Applies the mood named by the settings: a `.cube` file read from the LUT folder, baked
/// into a table the GPU walks through.
///
/// It sits after the creative color stages and before glow and grain, where a mood belongs:
/// the picture is finished, and the LUT gives it its cast.
///
/// `CIColorCube` takes at most 64 nodes per axis while LUTs of 65 are common (Resolve writes
/// them), so a table that large is resampled — the same trilinear blend `CubeLUT.sample`
/// does, which is why it lives there and is tested there.
///
/// The amount is not baked into the table: the table depends on the file alone and is built
/// once, and dragging the amount only costs a blend between the picture and the picture with
/// the mood on.
public struct LUTStage: PipelineStage {
    private let library: LUTLibrary
    private static let cache = RecentValuesCache<Key, Data?>()

    public init(library: LUTLibrary = .applicationSupport) {
        self.library = library
    }

    /// What a baked table depends on: the file, as it is now. A LUT replaced on disk while
    /// the app runs is read again rather than remembered.
    private struct Key: Equatable, Sendable {
        let name: String
        let modified: Date?
        let size: Int?
    }

    public func apply(_ adjustments: Adjustments, to image: CIImage) -> CIImage {
        guard let setting = adjustments.lut, setting.amount > 0, !image.extent.isInfinite,
              let data = table(named: setting.name) else { return image }

        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(Self.dimension(of: data))
        filter.cubeData = data
        filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        // Highlights beyond display white must not be crushed onto the last node.
        filter.extrapolate = true
        guard let graded = filter.outputImage else { return image }

        let share = Slider.unipolar(setting.amount)
        guard share < 1 else { return graded.cropped(to: image.extent) }
        let mix = CIFilter.mix()
        mix.inputImage = graded
        mix.backgroundImage = image
        mix.amount = Float(share)
        return mix.outputImage?.cropped(to: image.extent) ?? image
    }

    /// The baked table of that LUT, or `nil` when there is no such file or it cannot be read:
    /// a broken file leaves the picture alone rather than failing an export.
    private func table(named name: String) -> Data? {
        let file = library.url(for: name)
        let attributes = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = Key(name: name, modified: attributes?.contentModificationDate, size: attributes?.fileSize)
        return Self.cache.value(for: key) {
            guard let lut = try? library.lut(named: name) else { return nil }
            return Self.bake(lut)
        }
    }

    /// The nodes Core Image reads: red fastest, four floats per node.
    private static func bake(_ lut: CubeLUT) -> Data {
        let size = min(lut.size, maximumDimension)
        var values = [Float](repeating: 1, count: size * size * size * 4)
        let scale = 1 / Float(size - 1)
        var offset = 0
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    // Exactly the file's own nodes when it fits; resampled when it does not.
                    let color = SIMD3(Float(red), Float(green), Float(blue)) * scale
                    let output = size == lut.size ? lut.entries[red + size * (green + size * blue)] : lut.sample(color)
                    values[offset] = output.x
                    values[offset + 1] = output.y
                    values[offset + 2] = output.z
                    offset += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// What `CIColorCube` takes. LUTs of 65 are common and are resampled to this.
    static let maximumDimension = 64

    private static func dimension(of data: Data) -> Int {
        Int(cbrt(Double(data.count / (4 * MemoryLayout<Float>.size))).rounded())
    }
}
