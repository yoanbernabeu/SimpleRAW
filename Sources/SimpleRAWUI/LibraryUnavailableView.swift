import SwiftUI

/// Shown instead of the app when the library cannot be opened: says why, and offers a way out.
public struct LibraryUnavailableView: View {
    let location: URL
    let error: Error
    let retry: () -> Void
    let chooseLocation: (URL) -> Void

    public init(location: URL, error: Error, retry: @escaping () -> Void, chooseLocation: @escaping (URL) -> Void) {
        self.location = location
        self.error = error
        self.retry = retry
        self.chooseLocation = chooseLocation
    }

    public var body: some View {
        ContentUnavailableView {
            Label("The Library Could Not Be Opened", systemImage: "externaldrive.badge.xmark")
        } description: {
            Text(error.localizedDescription)
            Text(location.path).font(.callout).foregroundStyle(.tertiary).textSelection(.enabled)
        } actions: {
            Button("Try Again", action: retry)
            Button("Choose Another Location…", action: pickLocation)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .tint(Theme.accent)
    }

    private func pickLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose the folder that holds your library, or an empty one to start a new library."
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        chooseLocation(folder)
    }
}
