import RawEngine
import SwiftUI

/// Sets up one export: a preset as its starting point, then everything about it — size,
/// format, sharpening, and how much of what the camera wrote goes into the file. What was
/// set up can be kept as a preset of its own: nobody is going to write JSON to export at
/// 1600 px.
struct ExportSheet: View {
    @Bindable var session: DevelopSession
    /// Runs once the settings are agreed on: the save panel, then the export itself.
    let export: (ExportPreset) -> Void
    @State private var savedName = ""
    @State private var isNaming = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let draft = Binding($session.exportDraft) {
                Text("Export").font(.headline).padding(.bottom, 14)
                form(draft)
                footer(draft.wrappedValue)
            }
        }
        .padding(20)
        .frame(width: 420)
        .sheet(isPresented: $isNaming) {
            NameExportPresetSheet(name: $savedName) { session.saveExportPreset(named: $0) }
        }
    }

    @ViewBuilder
    private func form(_ draft: Binding<ExportPreset>) -> some View {
        Form {
            Picker("Preset", selection: presetSelection) {
                ForEach(session.exportPresets) { Text($0.name).tag($0.name) }
            }

            Section {
                Picker("Format", selection: draft.options.format) {
                    ForEach(ExportOptions.Format.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if draft.wrappedValue.options.format.isLossy {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: draft.options.quality, in: 0.05...1)
                            Text(draft.wrappedValue.options.quality, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                LabeledContent("Long edge") {
                    HStack {
                        Toggle("Full size", isOn: isFullSize(draft))
                        if let longEdge = draft.wrappedValue.options.longEdge {
                            TextField("px", value: Binding(
                                get: { longEdge },
                                set: { draft.wrappedValue.options.longEdge = $0 }
                            ), format: .number)
                            .frame(width: 70)
                            Text("px").foregroundStyle(.secondary)
                        }
                    }
                }
                Picker("Color space", selection: draft.options.colorSpace) {
                    ForEach(ExportOptions.ColorSpace.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Sharpening", selection: draft.options.sharpening) {
                    ForEach(ExportOptions.Sharpening.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }

            Section("Metadata") {
                Picker("Keep", selection: draft.options.metadata) {
                    ForEach(ExportOptions.Metadata.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(draft.wrappedValue.options.metadata.explanation)
                    .font(.system(size: Theme.smallSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Author", text: optional(draft.options.author), prompt: Text("Left as it is"))
                TextField("Copyright", text: optional(draft.options.copyright), prompt: Text("Left as it is"))
            }

            Section("File name") {
                TextField("Template", text: draft.fileNameTemplate)
                    .help("{name} stands for the name of the original file.")
                if let name = session.exportFileName {
                    Text(name).font(.system(size: Theme.smallSize)).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func footer(_ draft: ExportPreset) -> some View {
        HStack {
            Button("Save as Preset…") {
                savedName = draft.name
                isNaming = true
            }
            if session.canDeleteExportPreset(draft) {
                Button("Delete Preset", role: .destructive) { session.deleteExportPreset(draft) }
            }
            Spacer()
            Button("Cancel", role: .cancel) { close() }
                .keyboardShortcut(.cancelAction)
            Button("Export…") {
                close()
                export(draft)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 14)
    }

    private func close() {
        session.cancelExport()
        dismiss()
    }

    /// Picking a preset starts the settings again from it, name and template included.
    private var presetSelection: Binding<String> {
        Binding(
            get: { session.exportDraft?.name ?? "" },
            set: { name in
                guard let preset = session.exportPresets.first(where: { $0.name == name }) else { return }
                session.exportDraft = preset
            }
        )
    }

    /// Full size is no size at all; unticking it proposes a common one rather than zero.
    private func isFullSize(_ draft: Binding<ExportPreset>) -> Binding<Bool> {
        Binding(
            get: { draft.wrappedValue.options.longEdge == nil },
            set: { draft.wrappedValue.options.longEdge = $0 ? nil : ExportSheet.proposedLongEdge }
        )
    }

    private static let proposedLongEdge = 2048

    /// A field left empty adds nothing to the file, which is not the same as adding "".
    private func optional(_ value: Binding<String?>) -> Binding<String> {
        Binding(
            get: { value.wrappedValue ?? "" },
            set: { typed in
                let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                value.wrappedValue = trimmed.isEmpty ? nil : typed
            }
        )
    }
}

/// Asks what to call the export settings being kept.
private struct NameExportPresetSheet: View {
    @Binding var name: String
    let save: (String) -> Void
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Export Preset").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { isFocused = true }
    }

    private func commit() {
        save(name)
        dismiss()
    }
}

// MARK: - What the options are called on screen

extension ExportOptions.Format {
    var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .tiff16: "TIFF 16-bit"
        case .png: "PNG"
        case .heic: "HEIC"
        }
    }

    /// Only these two have a quality to set.
    var isLossy: Bool { self == .jpeg || self == .heic }
}

extension ExportOptions.ColorSpace {
    var title: String {
        switch self {
        case .sRGB: "sRGB"
        case .displayP3: "Display P3"
        }
    }
}

extension ExportOptions.Sharpening {
    var title: String {
        switch self {
        case .none: "None"
        case .low: "Low"
        case .standard: "Standard"
        case .high: "High"
        }
    }
}

extension ExportOptions.Metadata {
    var title: String {
        switch self {
        case .all: "Everything"
        case .withoutLocation: "Not where, nor with what"
        case .copyrightOnly: "Author and copyright only"
        }
    }

    var explanation: String {
        switch self {
        case .all: "Everything the camera wrote, including the place and the serial number."
        case .withoutLocation: "No GPS, no place name, no maker notes, no serial number. What a picture made for the web should carry."
        case .copyrightOnly: "The author, the copyright and which way up. Nothing else."
        }
    }
}
