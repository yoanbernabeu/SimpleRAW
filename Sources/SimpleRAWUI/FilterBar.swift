import Catalog
import SwiftUI

/// Above the grid: search, one Filter button, one View menu. Everything that narrows the grid
/// lives in a second row that the button unfolds, and that stays in sight while it filters.
struct FilterBar: View {
    @Bindable var session: LibrarySession
    @Binding var thumbnailSize: Double

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                searchField
                filterButton
                Spacer(minLength: 12)
                if let count = session.filteredCountText {
                    Text(count).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                viewMenu
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if session.isFilterRowVisible {
                Divider()
                FilterRow(session: session)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(.bar)
        .clipped()
        .animation(.easeOut(duration: 0.18), value: session.isFilterRowVisible)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $session.searchText).textFieldStyle(.plain)
            if !session.searchText.isEmpty {
                Button("Clear Search", systemImage: "xmark.circle.fill") { session.searchText = "" }
                    .buttonStyle(.plain)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .frame(maxWidth: 260)
        .help("Search file names, cameras and keywords")
    }

    private var filterButton: some View {
        let count = session.filter.criteriaCount
        return Button {
            session.showsFilters.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: count > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                Text("Filter")
                if count > 0 { Text("\(count)").monospacedDigit().fontWeight(.semibold) }
            }
            .foregroundStyle(count > 0 ? Theme.accent : .primary)
            .frame(minHeight: Theme.minimumTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(count > 0 ? "\(Count.of(count, "criterion", plural: "criteria")) narrowing the grid" : "Filter by rating, flag, label, camera, ISO or date")
        .accessibilityLabel(count > 0 ? "Filter, \(Count.of(count, "criterion", plural: "criteria")) active" : "Filter")
    }

    /// An icon, not a pop-up button: its longest label was cut off in a narrow window.
    private var viewMenu: some View {
        Menu {
            Picker("Sort By", selection: $session.sort) {
                Text("Newest First").tag(PhotoSort.captureDate(ascending: false))
                Text("Oldest First").tag(PhotoSort.captureDate(ascending: true))
                Text("Last Imported").tag(PhotoSort.importDate)
                Text("Best Rated").tag(PhotoSort.rating)
                Text("File Name").tag(PhotoSort.fileName)
            }
            .pickerStyle(.inline)
            Picker("Thumbnail Size", selection: Binding(get: { ThumbnailSize(closestTo: thumbnailSize) }, set: { thumbnailSize = $0.points })) {
                ForEach(ThumbnailSize.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "ellipsis.circle").frame(width: Theme.minimumTarget, height: Theme.minimumTarget)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(Color.secondary)
        .fixedSize()
        .help("Sort order and thumbnail size")
        .accessibilityLabel("View")
    }
}

/// What narrows the grid: stars, flags, labels, edited, then camera, ISO and date as menus.
private struct FilterRow: View {
    @Bindable var session: LibrarySession
    @State private var smartAlbumName: String?

    var body: some View {
        HStack(spacing: 14) {
            stars
            flags
            labels
            Toggle("Edited", isOn: $session.filter.isEditedOnly)
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Only photos that were developed")
            if session.cameras.count > 1 { cameraMenu }
            isoMenu
            dateMenu
            Spacer(minLength: 0)
            if !session.filter.isEmpty {
                Button("Clear", action: session.clearFilter).controlSize(.small).help("Show everything again")
                Button("Save as Smart Album…") { smartAlbumName = "" }
                    .controlSize(.small)
                    .help("An album that always shows the photos matching this filter")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .alert("New Smart Album", isPresented: Binding(isPresent: $smartAlbumName)) {
            TextField("Name", text: Binding(get: { smartAlbumName ?? "" }, set: { smartAlbumName = $0 }))
            Button("Save") { session.saveFilterAsSmartAlbum(named: smartAlbumName ?? "") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will always show the photos that match the current filter.")
        }
    }

    private var stars: some View {
        HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { stars in
                let isOn = stars <= session.filter.minimumRating
                Button {
                    session.filter.toggleMinimumRating(stars)
                } label: {
                    Image(systemName: isOn ? "star.fill" : "star")
                        .foregroundStyle(isOn ? Theme.accent : .secondary)
                        .frame(width: Theme.minimumTarget, height: Theme.minimumTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(stars == 5 ? "5 stars" : "\(Count.of(stars, "star")) and more")
                .accessibilityLabel("At least \(Count.of(stars, "star"))")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }

    private var flags: some View {
        HStack(spacing: 4) {
            flagToggle(.picked, "Picked", "flag.fill", key: "P")
            flagToggle(.none, "Unflagged", "flag", key: "U")
            flagToggle(.rejected, "Rejected", "xmark", key: "X")
        }
    }

    private func flagToggle(_ flag: Flag, _ title: String, _ icon: String, key: String) -> some View {
        Toggle(title, systemImage: icon, isOn: Binding(
            get: { session.filter.flags?.contains(flag) == true },
            set: { _ in session.filter.toggle(flag) }
        ))
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .help("\(title) (\(key))")
    }

    private var labels: some View {
        HStack(spacing: 0) {
            ForEach(ColorLabel.allCases, id: \.self) { label in
                let isOn = session.filter.colorLabels?.contains(label) == true
                Button {
                    session.filter.toggle(label)
                } label: {
                    // Off is a full-contrast ring, not a dimmed dot: blue and purple at a third
                    // of their opacity could not be seen on a dark bar.
                    Circle()
                        .strokeBorder(label.color, lineWidth: 1.5)
                        .background(Circle().fill(isOn ? label.color : .clear))
                        .frame(width: 12, height: 12)
                        .frame(width: Theme.minimumTarget, height: Theme.minimumTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(KeyRouter.key(for: label).map { "\(label.title) (\($0))" } ?? label.title)
                .accessibilityLabel("\(label.title) label")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }

    private var cameraMenu: some View {
        let chosen = session.filter.cameras
        return criterionMenu(chosen.map { $0.count == 1 ? $0[0] : "\($0.count) Cameras" } ?? "Camera", isOn: chosen != nil) {
            Button("Any Camera") { session.filter.cameras = nil }
            Divider()
            ForEach(session.cameras, id: \.self) { camera in
                Toggle(camera, isOn: Binding(
                    get: { chosen?.contains(camera) == true },
                    set: { _ in session.filter.toggle(camera: camera) }
                ))
            }
        }
    }

    private var isoMenu: some View {
        let range = session.filter.isoRange
        return criterionMenu(range == .any ? "ISO" : range?.title ?? "Custom ISO", isOn: range != .any) {
            Picker("ISO", selection: Binding(get: { range ?? .any }, set: { session.filter.isoRange = $0 })) {
                ForEach(ISORange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    private var dateMenu: some View {
        let range = session.filter.dateRange()
        return criterionMenu(range == .any ? "Date" : range?.title ?? "Custom Dates", isOn: range != .any) {
            Picker("Date", selection: Binding(get: { range ?? .any }, set: { session.filter.setDateRange($0) })) {
                ForEach(DateRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    /// A criterion with more than a few values: a quiet menu that turns amber when it filters.
    private func criterionMenu(_ title: String, isOn: Bool, @ViewBuilder content: () -> some View) -> some View {
        Menu(content: content) {
            Text(title).font(.callout).foregroundStyle(isOn ? Theme.accent : .secondary)
        }
        .menuStyle(.borderlessButton)
        .tint(isOn ? Theme.accent : Color.secondary)
        .fixedSize()
    }
}
