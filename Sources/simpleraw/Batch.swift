import ArgumentParser
import Foundation
import RawEngine

struct Batch: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Develops several RAW files the same way.",
        discussion: "Presets are given by name (see `simpleraw presets`) or as the path of a JSON file."
    )

    @Argument(help: "RAW files.", transform: URL.init(fileURLWithPath:))
    var inputs: [URL]

    @Option(name: .shortAndLong, help: "Look to apply. Omit for a neutral development.")
    var preset: String?

    @Option(name: .shortAndLong, help: "Export preset.")
    var export = "Full size"

    @Option(name: .shortAndLong, help: "Output directory.", transform: URL.init(fileURLWithPath:))
    var output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    @Flag(help: "Ignores the edits saved next to each photo by the app.")
    var ignoreEdits = false

    func run() throws {
        let job = BatchJob(
            preset: try preset.map(PresetLibrary.presets.resolve),
            exportPreset: try PresetLibrary.exportPresets.resolve(export),
            outputDirectory: output,
            sidecars: ignoreEdits ? nil : SidecarStore()
        )
        let start = Date()
        var done = 0
        let outcomes = job.run(on: inputs) { outcome in
            done += 1
            let status = outcome.destination?.path ?? "FAILED: \(outcome.error?.localizedDescription ?? "unknown error")"
            // File names come from memory cards: nothing in them may drive the terminal.
            print(FileName.displayable("[\(done)/\(inputs.count)] \(outcome.source.lastPathComponent) → \(status)"))
        }
        let failures = outcomes.filter { !$0.isSuccess }.count
        let elapsed = Date().timeIntervalSince(start).formatted(.number.precision(.fractionLength(1)))
        print("\(outcomes.count - failures) developed, \(failures) failed, in \(elapsed) s")
        if failures > 0 { throw ExitCode.failure }
    }
}

struct Presets: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Lists the looks and export presets available.")

    func run() {
        print("Looks (\(PresetLibrary.presets.directory.path)):")
        for preset in PresetLibrary.presets.all() {
            let groups = AdjustmentGroup.allCases.filter(preset.groups.contains).map(\.title).joined(separator: ", ")
            print("  \(preset.name)\(PresetLibrary.presets.isBuiltIn(preset.name) ? " (built-in)" : "") — \(groups)")
        }
        print("Export presets (\(PresetLibrary.exportPresets.directory.path)):")
        for preset in PresetLibrary.exportPresets.all() {
            let size = preset.options.longEdge.map { "\($0) px" } ?? "full size"
            print("  \(preset.name)\(PresetLibrary.exportPresets.isBuiltIn(preset.name) ? " (built-in)" : "") — \(size), quality \(preset.options.quality.formatted()), \(preset.fileNameTemplate).jpg")
        }
    }
}
