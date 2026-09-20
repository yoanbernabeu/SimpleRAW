import SwiftUI

/// The named versions of the photo: click one to go back to it, save the current settings as
/// a new one. The color version and the black and white one live side by side.
struct VersionsPanelView: View {
    @Bindable var session: DevelopSession
    @State private var draftName: String?
    @State private var renaming: SavedVersion?
    @FocusState private var nameIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.versions.isEmpty, draftName == nil {
                Text("Keep several developments of this photo, each under a name.")
                    .font(.system(size: Theme.labelSize))
                    .foregroundStyle(.secondary)
            }
            ForEach(session.versions) { version in
                row(for: version)
            }
            if let draftName {
                TextField("Name", text: Binding(get: { draftName }, set: { self.draftName = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .focused($nameIsFocused)
                    .onSubmit(commit)
                    .onExitCommand { (self.draftName, renaming) = (nil, nil) }
            } else {
                Button { begin(naming: nil) } label: { Label("Save Version", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .help("Keep the current settings under a name")
            }
        }
    }

    private func row(for version: SavedVersion) -> some View {
        let isShown = session.isShown(version)
        return Button { session.show(version) } label: {
            HStack(spacing: 6) {
                Image(systemName: isShown ? "circle.inset.filled" : "circle").font(.system(size: 9))
                Text(version.name).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: Theme.labelSize))
            .foregroundStyle(isShown ? Theme.accent : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.control, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isShown ? "This is the version on screen" : "Show this version")
        .contextMenu {
            Button("Rename") { begin(naming: version) }
            Button("Delete", role: .destructive) { session.deleteVersion(version) }
        }
    }

    private func begin(naming version: SavedVersion?) {
        renaming = version
        draftName = version?.name ?? ""
        nameIsFocused = true
    }

    private func commit() {
        guard let name = draftName else { return }
        if let renaming { session.renameVersion(renaming, to: name) } else { session.saveVersion(named: name) }
        (draftName, renaming) = (nil, nil)
    }
}
