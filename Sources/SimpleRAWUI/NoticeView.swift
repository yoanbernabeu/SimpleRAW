import SwiftUI

/// Good news, said once and briefly: it slides in at the bottom and leaves by itself.
struct NoticeView: View {
    let text: String?
    let dismiss: () -> Void

    var body: some View {
        VStack {
            Spacer()
            if let text {
                Label(text, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary, Theme.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: text) {
                        try? await Task.sleep(for: .seconds(4))
                        dismiss()
                    }
                    .onTapGesture(perform: dismiss)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(duration: 0.35), value: text)
        .allowsHitTesting(text != nil)
    }
}
