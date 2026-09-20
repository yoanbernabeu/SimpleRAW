import AppKit
import Catalog
import SwiftUI

/// The rest of the shoot, under the picture being developed: the way to the next frame
/// without going back to the grid. Its thumbnails are the grid's, so a series already
/// looked at shows up at once.
struct FilmstripView: View {
    @Bindable var app: AppSession
    @Environment(\.displayScale) private var displayScale

    private var loader: ThumbnailLoader { app.thumbnails }

    /// Height of the strip, and the long edge a frame is decoded at.
    static let height: CGFloat = 76
    private var frameWidth: CGFloat { Self.height * 1.5 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(app.filmstripPhotos) { photo in
                        frame(photo)
                            .id(photo.id)
                            .onAppear { loader.request(photo) }
                            .onChange(of: ThumbnailLoader.key(for: photo)) { loader.request(photo) }
                            .onDisappear { loader.cancel(photo.id) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(height: Self.height)
            .background(.bar)
            .onChange(of: app.openPhotoID, initial: true) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func frame(_ photo: Photo) -> some View {
        let isOpen = photo.id == app.openPhotoID
        return FilmstripFrame(photo: photo, slot: loader.slot(for: photo), isOpen: isOpen)
            .equatable()
            .frame(width: frameWidth)
            .contentShape(Rectangle())
            .onTapGesture { if !isOpen { app.open(photo) } }
            .help(photo.fileName)
    }
}

/// One frame of the strip: the thumbnail, its rating, and whether it is the one on screen.
private struct FilmstripFrame: View, Equatable {
    let photo: Photo
    /// The only thing the frame observes: a thumbnail that arrives redraws this frame alone.
    let slot: ThumbnailSlot
    let isOpen: Bool

    nonisolated static func == (a: FilmstripFrame, b: FilmstripFrame) -> Bool {
        a.photo == b.photo && a.isOpen == b.isOpen && a.slot === b.slot
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Theme.tile)
            if let image = slot.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .opacity(photo.flag == .rejected ? 0.35 : 1)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if photo.rating > 0 {
                Text(String(repeating: "★", count: photo.rating))
                    .font(.system(size: 7))
                    .foregroundStyle(Theme.accent)
                    .padding(3)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isOpen ? Theme.accent : .clear, lineWidth: 2))
        .animation(.easeOut(duration: 0.15), value: slot.image != nil)
        .accessibilityLabel(photo.fileName)
        .accessibilityAddTraits(isOpen ? [.isSelected] : [])
    }
}
