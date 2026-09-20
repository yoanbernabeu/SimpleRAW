import AppKit
import Catalog
import SwiftUI

/// Two photos side by side, as large as the window allows: the one question a grid of
/// thumbnails cannot settle — which of these two frames is the one to keep.
///
/// The photo being judged is outlined, and it is the selected one, so rating, flagging and
/// labelling need to know nothing about comparing. Left and right go from one to the other,
/// a click picks one, Escape goes back to the grid.
struct ComparisonView: View {
    @Bindable var app: AppSession
    let photos: [Photo]
    @FocusState private var isFocused: Bool

    private var session: LibrarySession { app.library }

    var body: some View {
        ZStack {
            Theme.canvas
            HStack(spacing: 2) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    side(photo, loader: index == 0 ? app.comparison.left : app.comparison.right)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 48)
        }
        .overlay(alignment: .bottom) { hint.padding(.bottom, 14) }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(action: app.handle)
        .onAppear { isFocused = true }
        .onDisappear {
            app.comparison.left.clear()
            app.comparison.right.clear()
        }
    }

    private func side(_ photo: Photo, loader: LoupeLoader) -> some View {
        let isJudged = session.selection.contains(photo.id)
        return VStack(spacing: 6) {
            ZStack {
                if let image = loader.image, loader.photoID == photo.id {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .opacity(photo.flag == .rejected ? 0.45 : 1)
                } else if loader.hasFailed {
                    ContentUnavailableView("Cannot be read", systemImage: "photo.badge.exclamationmark")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            caption(photo, isJudged: isJudged)
        }
        .padding(8)
        .background(isJudged ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isJudged ? Theme.accent : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture {
            // One gesture, as in the grid: a double-tap on top would delay every click.
            if NSApp.currentEvent?.clickCount == 2 { app.open(photo) } else { session.select(photo.id) }
        }
        .onChange(of: photo, initial: true) {
            loader.show(photo, placeholder: app.thumbnails.cachedImage(for: photo.id))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(PhotoCaption.accessibilityLabel(for: photo))
        .accessibilityAddTraits(isJudged ? [.isSelected] : [])
    }

    private func caption(_ photo: Photo, isJudged: Bool) -> some View {
        HStack(spacing: 10) {
            switch photo.flag {
            case .picked: Image(systemName: "flag.fill")
            case .rejected: Image(systemName: "xmark").foregroundStyle(Theme.warning)
            case .none: EmptyView()
            }
            Text(String(repeating: "★", count: photo.rating)).foregroundStyle(Theme.accent)
            if let label = photo.colorLabel {
                Circle().fill(label.color).frame(width: 9, height: 9)
            }
            Text(photo.fileName)
                .foregroundStyle(isJudged ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.callout)
    }

    private var hint: some View {
        Text("← → to choose the one you are judging · Return to develop it · Escape to go back")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
    }
}
