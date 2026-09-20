import AppKit
import Catalog
import RawEngine

/// The system panels of the develop view, in one place: the toolbar and the menus open the same.
@MainActor
enum DevelopPanels {
    static func open(_ openFile: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Importer.importedTypes
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            openFile(url)
        }
    }

    /// - Parameter folder: where the panel opens. The library's own Exports folder, which is
    ///   backed up with it; the user may still go anywhere else.
    static func export(_ session: DevelopSession, using preset: ExportPreset, in folder: URL? = nil) {
        guard let fileName = session.suggestedFileName(for: preset) else { return }
        let panel = NSSavePanel()
        panel.directoryURL = folder
        panel.allowedContentTypes = [preset.options.format.contentType]
        panel.nameFieldStringValue = fileName
        panel.message = "Export preset: \(preset.name)"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                try await session.export(to: destination, options: preset.options)
            } catch {
                session.report(error, title: "The export failed")
            }
        }
    }
}

extension DevelopSession {
    /// What a plain "Export…" uses: the full-size preset.
    var defaultExportPreset: ExportPreset? {
        exportPresets.first { $0.options.longEdge == nil } ?? exportPresets.first
    }
}
