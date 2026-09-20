import Foundation

/// Develops a list of files the same way: each photo's saved edits, an optional look on top,
/// then an export preset.
public struct BatchJob: Sendable {
    public struct Outcome: Sendable {
        public let source: URL
        public let result: Result<URL, Error>

        public var isSuccess: Bool { destination != nil }
        public var destination: URL? { try? result.get() }
        public var error: Error? {
            if case .failure(let error) = result { return error }
            return nil
        }
    }

    public let preset: Preset?
    public let exportPreset: ExportPreset
    public let outputDirectory: URL
    /// Where the saved edits of each photo are read from; `nil` ignores them.
    public let sidecars: (any AdjustmentsPersistence)?
    /// What each photo says about itself, written into the file that leaves. The library
    /// knows it; a batch over loose files has none.
    public let credits: @Sendable (URL) -> PhotoCredits

    public init(
        preset: Preset?, exportPreset: ExportPreset, outputDirectory: URL,
        sidecars: (any AdjustmentsPersistence)? = nil,
        credits: @escaping @Sendable (URL) -> PhotoCredits = { _ in PhotoCredits() }
    ) {
        self.preset = preset
        self.exportPreset = exportPreset
        self.outputDirectory = outputDirectory
        self.sidecars = sidecars
        self.credits = credits
    }

    /// One file failing never stops the others.
    /// - Parameter progress: called after each file, in order.
    @discardableResult
    public func run(on files: [URL], progress: (Outcome) -> Void = { _ in }) -> [Outcome] {
        files.map { file in
            let outcome = Outcome(source: file, result: Result { try develop(file, with: .shared) })
            progress(outcome)
            return outcome
        }
    }

    private func develop(_ file: URL, with renderer: Renderer) throws -> URL {
        let source = try RawSource(url: file)
        // The photo's own edits first; the look then replaces the groups it carries.
        var adjustments = try sidecars?.load(for: file) ?? Adjustments()
        preset?.apply(to: &adjustments)

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let destination = exportPreset.destination(for: file, in: outputDirectory)
        try renderer.write(source.image(adjustments: adjustments), to: destination, options: exportPreset.options, credits: credits(file))
        return destination
    }
}
