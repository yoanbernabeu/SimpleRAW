import RawEngine
import SwiftUI

/// The looks, shown as the open photo would become: hover one to try it on the canvas, click
/// to apply it, "+" to save the current settings as a new one.
struct LooksPanelView: View {
    @Bindable var session: DevelopSession
    @State private var isSaving = false

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(session.presets) { preset in
                    LookTile(
                        name: preset.name,
                        thumbnail: session.lookThumbnails[preset.name],
                        isApplied: session.isApplied(preset)
                    ) {
                        session.previewedPreset = nil
                        session.apply(preset)
                    } hover: { isHovered in
                        // Only the tile being left may clear the preview: events of two
                        // neighbouring tiles do not come in a guaranteed order.
                        if isHovered { session.previewedPreset = preset } else if session.previewedPreset == preset { session.previewedPreset = nil }
                    }
                    .help(AdjustmentGroup.allCases.filter(preset.groups.contains).map(\.title).joined(separator: ", "))
                    .contextMenu {
                        Button("Delete", role: .destructive) { session.deletePreset(preset) }
                            .disabled(!session.canDelete(preset))
                    }
                }
            }
            if let dosed = session.dosedLook {
                LookAmountRow(look: dosed, amount: session.lookAmount) { session.setLookAmount($0) }
            }

            Button { isSaving = true } label: { Label("New Look", systemImage: "plus") }
                .buttonStyle(.borderless)
                .disabled(!session.hasChanges)
                .help("Save the current settings as a look")
        }
        .onAppear { session.showsLookThumbnails = true }
        .onDisappear {
            session.showsLookThumbnails = false
            session.previewedPreset = nil
        }
        .sheet(isPresented: $isSaving) {
            SaveLookSheet(proposed: session.editedGroups, taken: session.lookToOverwrite(named:)) { name, groups in
                session.savePreset(named: name, groups: groups, overwriting: true)
            }
        }
    }
}

/// How much of the look just applied shows. It stays up until the next edit: a look is
/// picked with the eyes, then dialled back until it is right.
private struct LookAmountRow: View {
    let look: Preset
    let amount: Double
    let setAmount: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Amount")
                Spacer()
                Text(amount, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            ValueSlider(
                value: Binding(get: { amount * 100 }, set: { setAmount($0 / 100) }),
                range: 0...100, neutral: 100
            )
            if !look.switchesAtHalf.isEmpty {
                Text("\(look.switchesAtHalf.formatted(.list(type: .and))) cannot fade: they come in at 50 %.")
                    .font(.system(size: Theme.smallSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }
}

/// One look: the photo as it would become, and its name.
private struct LookTile: View {
    let name: String
    let thumbnail: CGImage?
    let isApplied: Bool
    let apply: () -> Void
    let hover: (Bool) -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: apply) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.cornerRadius).fill(Theme.control)
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 2).resizable().scaledToFill()
                    }
                }
                .aspectRatio(3.0 / 2, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .strokeBorder(isApplied ? Theme.accent : Color.white.opacity(isHovered ? 0.35 : 0), lineWidth: isApplied ? 2 : 1)
                )
                Text(name)
                    .font(.system(size: Theme.smallSize))
                    .foregroundStyle(isApplied ? Theme.accent : .secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            hover(hovering)
        }
        .accessibilityLabel(name)
        .accessibilityAddTraits(isApplied ? [.isSelected] : [])
    }
}

/// Asks for a name and for the groups of settings the look should carry.
private struct SaveLookSheet: View {
    /// The look this name would replace, spelled as it is.
    let taken: (String) -> String?
    let save: (String, Set<AdjustmentGroup>) -> Void
    @State private var name = ""
    @State private var groups: Set<AdjustmentGroup>
    @State private var showsGroups = false
    @State private var isReplacing = false
    @FocusState private var nameIsFocused: Bool
    @Environment(\.dismiss) private var dismiss

    /// - Parameter proposed: the groups that hold edits. The list stays folded: most of the
    ///   time that is exactly what the look should carry.
    init(
        proposed: Set<AdjustmentGroup>,
        taken: @escaping (String) -> String?,
        save: @escaping (String, Set<AdjustmentGroup>) -> Void
    ) {
        self.taken = taken
        self.save = save
        _groups = State(initialValue: proposed.isEmpty ? AdjustmentGroup.defaultSelection : proposed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Look").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameIsFocused)
                .onSubmit(commit)

            DisclosureGroup(isExpanded: $showsGroups) {
            AdjustmentGroupPicker(groups: $groups)
            .padding(.top, 6)
            } label: {
                Text("Includes \(Count.of(groups.count, "group")) of settings").font(.subheadline).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || groups.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { nameIsFocused = true }
        .confirmationDialog(
            taken(name).map { "Replace the look “\($0)”?" } ?? "", isPresented: $isReplacing
        ) {
            Button("Replace", role: .destructive) {
                save(name, groups)
                dismiss()
            }
            Button("Cancel", role: .cancel) { nameIsFocused = true }
        } message: {
            Text("Its settings are lost. Give it another name to keep both.")
        }
    }

    /// A name that is taken asks first: nobody loses a look by typing a name twice.
    private func commit() {
        if taken(name) != nil {
            isReplacing = true
        } else {
            save(name, groups)
            dismiss()
        }
    }
}
