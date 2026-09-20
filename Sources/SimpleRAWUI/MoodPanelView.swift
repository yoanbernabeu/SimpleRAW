import RawEngine
import SwiftUI

/// The mood the picture wears: a `.cube` file from the LUTs folder, and how much of it.
/// Moods are files someone made elsewhere or bought as a pack, so the panel says where the
/// folder is and opens it, rather than pretending they appear on their own.
struct MoodPanelView: View {
    @Bindable var session: DevelopSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.moodNames.isEmpty {
                Text("No LUT yet. Put .cube files in your LUTs folder and they show up here.")
                    .font(.system(size: Theme.labelSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Mood", selection: moodName) {
                    Text("None").tag(String?.none)
                    Divider()
                    ForEach(session.moodNames, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden()

                if session.adjustments.lut != nil {
                    MoodAmountRow(amount: session.moodAmount) { session.setMoodAmount($0) }
                }
            }

            HStack(spacing: 10) {
                Button("Reveal LUTs Folder", systemImage: "folder") { session.revealMoodFolder() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                Button("Refresh", systemImage: "arrow.clockwise") { session.reloadMoodNames() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Read the folder again, after adding files to it")
            }
        }
        .onAppear { session.reloadMoodNames() }
    }

    /// Picking a mood keeps the amount that was on screen: trying several at 60 % is the
    /// whole point of the list.
    private var moodName: Binding<String?> {
        Binding(
            get: { session.adjustments.lut?.name },
            set: { session.setMood($0) }
        )
    }
}

private struct MoodAmountRow: View {
    let amount: Double
    let setAmount: (Double) -> Void

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text("Amount")
                Spacer()
                Text(amount, format: .number.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            ValueSlider(
                value: Binding(get: { amount }, set: { setAmount($0) }),
                range: 0...100, neutral: 100, title: "Amount"
            )
        }
    }
}
