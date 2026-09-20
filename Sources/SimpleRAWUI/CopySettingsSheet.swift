import RawEngine
import SwiftUI

/// Which groups of settings a copy takes: all of a look, or only the white balance of one
/// photo for the rest of a series.
struct CopySettingsSheet: View {
    @Bindable var session: DevelopSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Copy Settings").font(.headline)
            AdjustmentGroupPicker(groups: $session.copiedGroups)
            HStack {
                Button("All") { session.copiedGroups = AdjustmentGroup.defaultSelection }
                Button("None") { session.copiedGroups = [] }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Copy") {
                    session.copyAdjustments()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(session.copiedGroups.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

/// Two columns of checkboxes, one per group of settings. Shared by the sheets that choose some.
struct AdjustmentGroupPicker: View {
    @Binding var groups: Set<AdjustmentGroup>

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 6) {
            ForEach(AdjustmentGroup.allCases, id: \.self) { group in
                Toggle(group.title, isOn: Binding(
                    get: { groups.contains(group) },
                    set: { isOn in
                        if isOn { groups.insert(group) } else { groups.remove(group) }
                    }
                ))
            }
        }
    }
}
