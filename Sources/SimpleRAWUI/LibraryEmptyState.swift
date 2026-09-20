import SwiftUI

/// The first thing a new user sees: where photos go, and that nothing will happen to theirs.
struct LibraryEmptyState: View {
    let isDropTargeted: Bool
    let importPhotos: () -> Void
    let openPhoto: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(isDropTargeted ? Theme.accent : .secondary)
            VStack(spacing: 6) {
                Text("Drop a folder or a memory card").font(.title2.weight(.medium))
                Text("Originals are copied, never moved.").font(.callout).foregroundStyle(.secondary)
            }
            Button(action: importPhotos) {
                Text("Import Photos…")
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.canvas)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Theme.accent, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            Button("or open a single photo (⌘O)", action: openPhoto)
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: 560, maxHeight: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(isDropTargeted ? Theme.accent : Theme.dropZone, style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                .background(RoundedRectangle(cornerRadius: 18).fill(isDropTargeted ? Theme.accent.opacity(0.06) : .clear))
                .frame(maxWidth: 560, maxHeight: 380)
                .padding(28)
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .accessibilityElement(children: .contain)
    }
}
