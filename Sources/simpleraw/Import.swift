import ArgumentParser
import Catalog
import Foundation
import RawEngine

struct Import: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Imports the RAW files of a folder into a library.",
        discussion: "Files are copied, never moved, and a file the library already has is skipped."
    )

    @Argument(help: "Folder or memory card to import from.", transform: URL.init(fileURLWithPath:))
    var folder: URL

    @Option(name: .shortAndLong, help: "Library folder (default: ~/Pictures/SimpleRAW Library).", transform: URL.init(fileURLWithPath:))
    var library: URL?

    func run() throws {
        let library = try Library(root: library ?? Library.defaultRoot)
        let files = Importer.scan(folder)
        var done = 0
        let summary = Importer(library: library).run(files) { file in
            done += 1
            print(FileName.displayable("[\(done)/\(files.count)] \(file.lastPathComponent)"))
        }
        for failure in summary.failures {
            print(FileName.displayable("FAILED \(failure.file.lastPathComponent): \(failure.error.localizedDescription)"))
        }
        print("\(summary.imported.count) imported, \(summary.duplicates.count) already in the library, \(summary.failures.count) failed — \(library.root.path)")
        if !summary.failures.isEmpty { throw ExitCode.failure }
    }
}
