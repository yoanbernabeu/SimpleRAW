import Catalog
import SwiftUI

/// An album or a smart album, as the sidebar talks about it.
struct AlbumReference: Equatable {
    let id: Int64
    let name: String
}

/// An album being named: a new one, or one that exists.
struct AlbumPrompt: Equatable {
    var album: AlbumReference?
    var name: String

    static let new = AlbumPrompt(album: nil, name: "")
}

/// Where the grid takes its photos from: the whole library, an album, a smart album.
struct LibrarySidebar: View {
    @Bindable var session: LibrarySession
    @Binding var albumPrompt: AlbumPrompt?
    /// Asked about before it goes: a slip of the pointer must not cost an album sorted by hand.
    @State private var albumToDelete: AlbumReference?
    @State private var dropTarget: Int64?

    var body: some View {
        List(selection: Binding(get: { session.source }, set: { if let source = $0 { session.source = source } })) {
            Section("Library") {
                Label("All Photos", systemImage: "photo.on.rectangle").badge(session.totalCount).tag(LibrarySource.allPhotos)
            }
            Section {
                ForEach(session.albums) { album in
                    Label(album.name, systemImage: "rectangle.stack")
                        .tag(LibrarySource.album(album.id))
                        .listRowBackground(dropTarget == album.id ? Theme.accent.opacity(0.25) : nil)
                        .dropDestination(for: String.self) { items, _ in
                            let ids = items.compactMap(PhotoDrag.photoIDs(in:)).flatMap(\.self)
                            session.add(ids, toAlbum: album.id)
                            return !ids.isEmpty
                        } isTargeted: { isTargeted in
                            if isTargeted { dropTarget = album.id } else if dropTarget == album.id { dropTarget = nil }
                        }
                        .contextMenu {
                            Button("Add Selection") { session.addSelection(toAlbum: album.id) }.disabled(session.selection.isEmpty)
                            Button("Rename…") { albumPrompt = AlbumPrompt(album: AlbumReference(id: album.id, name: album.name), name: album.name) }
                            Divider()
                            Button("Delete Album…", role: .destructive) { albumToDelete = AlbumReference(id: album.id, name: album.name) }
                        }
                }
            } header: {
                HStack {
                    Text("Albums")
                    Spacer()
                    Button("New Album", systemImage: "plus") { albumPrompt = .new }
                        .buttonStyle(.plain)
                        .labelStyle(.iconOnly)
                        .frame(width: Theme.minimumTarget, height: Theme.minimumTarget)
                        .contentShape(Rectangle())
                        .help(session.selection.isEmpty ? "New album" : "New album with the selection")
                }
            }
            if !session.months.isEmpty {
                // Where a shoot is, when nobody remembers which album it went into: the
                // library in time, newest first, grouped as the folders of Originals are.
                Section("By Date") {
                    ForEach(session.months) { month in
                        Label(MonthName.of(month), systemImage: "calendar")
                            .badge(month.count)
                            .tag(session.monthSource(month))
                    }
                }
            }
            if !session.smartAlbums.isEmpty {
                Section("Smart Albums") {
                    ForEach(session.smartAlbums) { album in
                        Label(album.name, systemImage: "rectangle.stack.badge.plus")
                            .tag(LibrarySource.smartAlbum(album.id))
                            .contextMenu {
                                Button("Rename…") { albumPrompt = AlbumPrompt(album: AlbumReference(id: album.id, name: album.name), name: album.name) }
                                Divider()
                                Button("Delete Smart Album…", role: .destructive) { albumToDelete = AlbumReference(id: album.id, name: album.name) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .confirmationDialog(
            "Delete “\(albumToDelete?.name ?? "")”?", isPresented: Binding(isPresent: $albumToDelete), presenting: albumToDelete
        ) { album in
            Button("Delete Album", role: .destructive) { session.deleteAlbum(album.id) }
        } message: { _ in
            Text("The photos stay in your library.")
        }
    }
}

/// What a month of shooting is called in the sidebar: "September 2026", in the interface's
/// own language and calendar, from a year and a month the catalog counted in UTC.
enum MonthName {
    static func of(_ month: PhotoCatalog.CaptureMonth) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: month.year, month: month.month)) else {
            return "\(month.year)"
        }
        return date.formatted(.dateTime.year().month(.wide).locale(Locale(identifier: "en_US")))
    }
}
