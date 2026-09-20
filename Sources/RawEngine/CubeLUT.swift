import Foundation
import simd

/// A 3D lookup table read from a `.cube` file: the way a mood made in another editor, or
/// bought as a pack, is brought in. Pure — text in, nodes out — so that everything about the
/// format is decided and tested here, away from Core Image.
///
/// The file comes from elsewhere, so nothing about it is assumed: the size is bounded, the
/// number of entries must be exactly N³, and anything that is not three finite numbers is
/// refused rather than read as zero.
public struct CubeLUT: Equatable, Sendable {
    /// Nodes per axis, from 2 to 65.
    public let size: Int
    /// What the file calls itself, if it says.
    public let title: String?
    /// `size³` nodes, red varying fastest, then green, then blue — the order of the format.
    public let entries: [SIMD3<Float>]

    /// A LUT of 65 nodes weighs about 6 MB as text. Past this, it is not a LUT.
    public static let maximumFileSize = 32 * 1024 * 1024
    /// What the format allows and what a GPU can hold. 65 is common: Resolve writes it.
    public static let sizeRange = 2...65

    public enum ParsingError: Error, LocalizedError, Equatable {
        case noSize
        case sizeOutOfBounds(Int)
        case wrongEntryCount(expected: Int, found: Int)
        /// A line that is not three numbers between 0 and 1's worth of infinity.
        case badEntry(line: Int, text: String)
        /// Something the engine does not support, said rather than guessed at.
        case unsupported(String)

        public var errorDescription: String? {
            switch self {
            case .noSize:
                "This .cube file does not say its size (LUT_3D_SIZE)"
            case .sizeOutOfBounds(let size):
                "A .cube of \(size) points is not supported (\(CubeLUT.sizeRange.lowerBound) to \(CubeLUT.sizeRange.upperBound))"
            case .wrongEntryCount(let expected, let found):
                "This .cube holds \(found) entries where its size calls for \(expected)"
            case .badEntry(let line, let text):
                "Line \(line) of this .cube is not three numbers: \"\(text)\""
            case .unsupported(let what):
                "This .cube uses \(what), which is not supported"
            }
        }
    }

    /// - Throws: `RawEngineError.fileTooLarge` before reading a single byte of a huge file.
    public init(contentsOf url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maximumFileSize else { throw RawEngineError.fileTooLarge(url, limit: Self.maximumFileSize) }
        try self.init(parsing: try Data(contentsOf: url))
    }

    public init(parsing data: Data) throws {
        // Whatever an editor wrote: a byte order mark, CRLF, tabs, comments, blank lines.
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        var declaredSize: Int?
        var title: String?
        var entries: [SIMD3<Float>] = []

        // Split on newlines, not on "\n": a CRLF is one `Character` in Swift, so cutting on
        // "\n" leaves a file written on Windows as a single line.
        for (offset, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if let keyword = Self.keyword(of: line) {
                switch keyword {
                case "LUT_3D_SIZE":
                    guard declaredSize == nil else { throw ParsingError.unsupported("two sizes") }
                    guard let value = Int(Self.arguments(of: line).first ?? "") else { throw ParsingError.noSize }
                    guard Self.sizeRange.contains(value) else { throw ParsingError.sizeOutOfBounds(value) }
                    declaredSize = value
                case "TITLE":
                    title = line.drop { $0 != "\"" }.dropFirst().prefix { $0 != "\"" }.description
                case "DOMAIN_MIN", "DOMAIN_MAX":
                    // Only the plain 0…1 domain: anything else would silently change the look.
                    let expected: [Float] = keyword == "DOMAIN_MIN" ? [0, 0, 0] : [1, 1, 1]
                    guard Self.arguments(of: line).compactMap(Float.init) == expected else {
                        throw ParsingError.unsupported("a domain other than 0 to 1")
                    }
                default:
                    throw ParsingError.unsupported(keyword)
                }
                continue
            }

            guard let entry = Self.entry(of: line) else { throw ParsingError.badEntry(line: offset + 1, text: line) }
            entries.append(entry)
        }

        guard let declaredSize else { throw ParsingError.noSize }
        let expected = declaredSize * declaredSize * declaredSize
        guard entries.count == expected else {
            throw ParsingError.wrongEntryCount(expected: expected, found: entries.count)
        }
        size = declaredSize
        self.title = title
        self.entries = entries
    }

    /// The color `color` becomes, blended between the eight nodes around it. Colors outside
    /// the cube are read at its edge.
    /// - Parameter amount: from 0 (the color as it was) to 1 (the LUT applied whole).
    public func sample(_ color: SIMD3<Float>, amount: Float = 1) -> SIMD3<Float> {
        let last = Float(size - 1)
        let position = simd_clamp(color, SIMD3(repeating: 0), SIMD3(repeating: 1)) * last
        let low = SIMD3<Int>(position.rounded(.down))
        let base = simd_clamp(low, SIMD3(repeating: 0), SIMD3(repeating: size - 2))
        let t = position - SIMD3<Float>(base)

        var result = SIMD3<Float>()
        for corner in 0..<8 {
            let step = SIMD3(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1)
            let weight = ((step.x == 1 ? t.x : 1 - t.x) * (step.y == 1 ? t.y : 1 - t.y) * (step.z == 1 ? t.z : 1 - t.z))
            guard weight > 0 else { continue }
            result += entries[index(base &+ step)] * weight
        }
        let blend = min(max(amount, 0), 1)
        return color + (result - color) * blend
    }

    /// The node at these coordinates. Red varies fastest, as in the file.
    private func index(_ node: SIMD3<Int>) -> Int {
        let clamped = simd_clamp(node, SIMD3(repeating: 0), SIMD3(repeating: size - 1))
        return clamped.x + size * (clamped.y + size * clamped.z)
    }

    /// The keyword of a line that declares something, rather than a node.
    private static func keyword(of line: String) -> String? {
        let first = line.prefix { !$0.isWhitespace }
        guard first.contains(where: { $0.isLetter || $0 == "_" }) else { return nil }
        return String(first).uppercased()
    }

    private static func arguments(of line: String) -> [String] {
        line.split(whereSeparator: \.isWhitespace).dropFirst().map(String.init)
    }

    /// Three numbers, and nothing else. `Float(_:)` accepts "nan", "inf" and hexadecimal
    /// floats, none of which belong in a LUT: values are checked to be finite, and each one
    /// is brought back to the display range, so that a node can never make a pixel negative.
    private static func entry(of line: String) -> SIMD3<Float>? {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count == 3 else { return nil }
        var values = SIMD3<Float>()
        for (axis, field) in fields.enumerated() {
            guard !field.contains(where: { $0 == "x" || $0 == "X" }),
                  let value = Float(field), value.isFinite else { return nil }
            values[axis] = min(max(value, 0), 1)
        }
        return values
    }
}
