import SwiftUI

/// A long job, shown over the window: what it is doing, how far along it is, and a way out.
struct ProgressOverlay: View {
    let title: String
    let done: Int
    let total: Int
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 260)
            Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Button("Cancel", action: onCancel).controlSize(.small).keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
