import Catalog
import SwiftUI

/// The selected photo, as large as the window, with nothing around it: what a cull is made
/// on. Keys do what they do in the grid; a click goes back to it, a double-click develops.
struct LibraryLoupe: View {
    @Bindable var app: AppSession
    let photo: Photo
    @FocusState private var isFocused: Bool

    private var session: LibrarySession { app.library }
    private var loader: LoupeLoader { app.loupe }

    var body: some View {
        ZStack {
            Theme.canvas
            if let image = loader.image, loader.photoID == photo.id {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .opacity(photo.flag == .rejected ? 0.45 : 1)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 56)
            } else if loader.hasFailed {
                ContentUnavailableView(
                    "This photo could not be read", systemImage: "photo.badge.exclamationmark",
                    description: Text("Its original may be missing.")
                )
            }
        }
        .overlay(alignment: .bottom) { caption.padding(.bottom, 14) }
        .contentShape(Rectangle())
        .onTapGesture {
            // One gesture, as in the grid: stacking a double-tap would delay every click.
            if NSApp.currentEvent?.clickCount == 2 { app.perform(.openSelection) } else { app.perform(.closeLoupe) }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(action: app.handle)
        .onAppear { isFocused = true }
        .onChange(of: photo, initial: true) {
            loader.show(photo, placeholder: app.thumbnails.cachedImage(for: photo.id), next: session.photoAfterLoupe)
        }
        .onDisappear(perform: loader.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(PhotoCaption.accessibilityLabel(for: photo))
    }

    /// What was said about the photo, quietly: rating, flag, label, and where it is in the grid.
    private var caption: some View {
        HStack(spacing: 12) {
            switch photo.flag {
            case .picked: Image(systemName: "flag.fill").foregroundStyle(.primary)
            case .rejected: Image(systemName: "xmark").foregroundStyle(Theme.warning)
            case .none: EmptyView()
            }
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { star in
                    Image(systemName: star <= photo.rating ? "star.fill" : "star")
                        .foregroundStyle(star <= photo.rating ? Theme.accent : Color.secondary.opacity(0.5))
                }
            }
            if let label = photo.colorLabel {
                Circle().fill(label.color).frame(width: 9, height: 9)
            }
            Text(photo.fileName).foregroundStyle(.secondary)
            if let position = session.loupePosition {
                Text(position).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
    }
}
