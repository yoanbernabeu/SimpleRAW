import Catalog
import RawEngine
import SwiftUI

/// Under the grid, always: what is shown or selected, and the way to the keywords and to what
/// is said about the selection. Its presence never changes, so that selecting does not make
/// the grid jump.
struct SelectionBar: View {
    @Bindable var session: LibrarySession
    @State private var showsKeywords = false
    @State private var showsCredits = false

    var body: some View {
        HStack(spacing: 12) {
            Text(PhotoCaption.summary(selected: session.selectedPhotos, shown: session.photos.count))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            if !session.keywordText.isEmpty {
                Text(session.keywordText).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
            }
            Button("Show Large", systemImage: "arrow.up.left.and.arrow.down.right", action: session.toggleLoupe)
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .frame(width: Theme.minimumTarget, height: Theme.minimumTarget)
                .contentShape(Rectangle())
                .disabled(session.photos.isEmpty)
                .help("Show the photo large, to cull (Space)")
            Button("Description", systemImage: "text.alignleft") { showsCredits.toggle() }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .foregroundStyle(session.shownCredits.isEmpty ? Color.secondary : Theme.accent)
                .frame(width: Theme.minimumTarget, height: Theme.minimumTarget)
                .contentShape(Rectangle())
                .keyboardShortcut("i")
                .disabled(session.selection.isEmpty)
                .help("Title, caption and credits of the selection (⌘I)")
                .popover(isPresented: $showsCredits, arrowEdge: .top) { CreditsEditor(session: session) }
            Button("Keywords", systemImage: "tag") { showsKeywords.toggle() }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .foregroundStyle(session.keywordText.isEmpty ? Color.secondary : Theme.accent)
                .frame(width: Theme.minimumTarget, height: Theme.minimumTarget)
                .contentShape(Rectangle())
                .keyboardShortcut("k")
                .disabled(session.selection.isEmpty)
                .help("Keywords of the selection (⌘K)")
                .popover(isPresented: $showsKeywords, arrowEdge: .top) { KeywordEditor(session: session) }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(.bar)
    }
}

/// What is said about the selected photos. A title and a caption name one picture, so they
/// are only offered for one; an author and a copyright sign a whole shoot, and signing leaves
/// each photo the title it has of its own. Written when the popover is left, as the keywords
/// are.
private struct CreditsEditor: View {
    /// The field the popover opens on: the first one it shows.
    private enum Field { case title, author }

    @Bindable var session: LibrarySession
    @State private var draft = PhotoCredits()
    @FocusState private var focus: Field?

    private var isOnePhoto: Bool { session.selection.count == 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isOnePhoto ? "Description" : "Credits").sectionTitleStyle()
            if isOnePhoto {
                field("Title", "Rue de la Gare", text: binding(\.title)).focused($focus, equals: .title)
                field("Caption", "Waiting for the last train.", text: binding(\.caption))
            }
            field("Author", "Yoan Bernabeu", text: binding(\.author)).focused($focus, equals: .author)
            field("Copyright", "© 2026 Yoan Bernabeu", text: binding(\.copyright))
            Text(
                isOnePhoto
                    ? "Written into the file when the photo is exported."
                    : "The author and the copyright of the \(Count.of(session.selection.count, "selected photo")). A title names one photo: select one to give it one."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            draft = session.shownCredits
            focus = isOnePhoto ? .title : .author
        }
        .onSubmit(commit)
        .onDisappear(perform: commit)
    }

    private func field(_ label: String, _ example: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(example, text: text).textFieldStyle(.roundedBorder)
        }
    }

    /// A blank field is nothing, not an empty line: `PhotoCredits` is the one rule.
    private func binding(_ field: WritableKeyPath<PhotoCredits, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: field] ?? "" }, set: { draft[keyPath: field] = PhotoCredits.nonBlank($0) })
    }

    private func commit() {
        guard draft != session.shownCredits else { return }
        if isOnePhoto {
            session.setCredits(draft)
        } else {
            session.setSignature(author: draft.author, copyright: draft.copyright)
        }
    }
}

/// The keywords the selection shares, edited in place. Whatever way the popover is left,
/// what was typed is kept, for the photos it was typed for.
private struct KeywordEditor: View {
    @Bindable var session: LibrarySession
    @State private var draft = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keywords").sectionTitleStyle()
            TextField("street, Lille, night", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($isEditing)
                .onSubmit { session.commitKeywords(draft) }
            Text(
                session.selection.count == 1
                    ? "Separated by commas."
                    : "Separated by commas. Shared by the \(Count.of(session.selection.count, "selected photo")): what each has of its own is kept."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            draft = session.keywordText
            session.beginEditingKeywords()
            isEditing = true
        }
        .onChange(of: session.keywordText) { draft = session.keywordText }
        .onDisappear { session.endEditingKeywords(draft) }
    }
}
