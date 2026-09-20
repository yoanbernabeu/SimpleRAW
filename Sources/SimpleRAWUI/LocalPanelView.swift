import RawEngine
import SwiftUI

/// The layers of the picture, top one first. Each local adjustment is a layer: it can be
/// hidden, faded, renamed, moved, copied or removed without touching the others.
struct LocalPanelView: View {
    @Bindable var session: DevelopSession
    let context: SliderContext
    @State private var renaming: UUID?
    @State private var draftName = ""
    @FocusState private var nameIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.layers.isEmpty {
                Text("Add a mask to adjust one part of the picture.")
                    .font(.system(size: Theme.labelSize))
                    .foregroundStyle(.secondary)
            }
            ForEach(session.layers) { layer in
                row(for: layer)
            }

            Menu {
                ForEach(MaskKind.allCases.filter { !$0.isDetected }) { kind in
                    Button { session.addLocal(kind) } label: { Label(kind.rawValue, systemImage: kind.systemImage) }
                }
                // What the machine finds, apart: a mask nobody has to draw.
                Divider()
                ForEach(MaskKind.allCases.filter(\.isDetected)) { kind in
                    Button { session.addLocal(kind) } label: { Label(kind.rawValue, systemImage: kind.systemImage) }
                }
            } label: {
                Label("Add Mask", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if let local = session.selectedLocal {
                layerActions(for: local)
                maskOptions(for: local)
                LuminanceRangeRow(session: session)
                ForEach(SliderSpec.local(id: local.id)) { spec in
                    SliderRow(spec: spec, adjustments: $session.adjustments, context: context)
                }
            }
        }
    }

    private func row(for layer: DevelopSession.LayerSummary) -> some View {
        let isSelected = layer.id == session.selectedLocalID
        return HStack(spacing: 6) {
            Button {
                session.setLayer(layer.id, enabled: !layer.isEnabled)
            } label: {
                Image(systemName: layer.isEnabled ? "eye" : "eye.slash").frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(layer.isEnabled ? "Hide this layer" : "Show this layer")

            Image(systemName: layer.kind.systemImage).frame(width: 16).foregroundStyle(.secondary)

            if renaming == layer.id {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .focused($nameIsFocused)
                    .onSubmit { commitRename(of: layer.id) }
                    .onChange(of: nameIsFocused) { _, focused in
                        if !focused { commitRename(of: layer.id) }
                    }
            } else {
                Text(layer.name)
                    .lineLimit(1)
                    .opacity(layer.isEnabled ? 1 : 0.45)
                    .onTapGesture(count: 2) {
                        draftName = layer.name
                        renaming = layer.id
                        nameIsFocused = true
                    }
            }
            Spacer(minLength: 0)
            if layer.opacity < 100 {
                Text("\(Int(layer.opacity)) %").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if isSelected {
                Button("Delete", systemImage: "trash") { session.removeLayer(layer.id) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Delete this layer")
            }
        }
        .contextMenu {
            Button("Rename") {
                draftName = layer.name
                renaming = layer.id
                nameIsFocused = true
            }
            Button("Duplicate") { session.duplicateLayer(layer.id) }
            Divider()
            Button("Move Up") { session.moveLayer(layer.id, up: true) }.disabled(!session.canMoveLayer(layer.id, up: true))
            Button("Move Down") { session.moveLayer(layer.id, up: false) }.disabled(!session.canMoveLayer(layer.id, up: false))
            Divider()
            Button("Delete", role: .destructive) { session.removeLayer(layer.id) }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isSelected ? Theme.accent.opacity(0.28) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            session.selectedLocalID = layer.id
            session.tool = .local
        }
        .help("Double-click the name to rename; right-click for more")
    }

    private func commitRename(of id: UUID) {
        guard renaming == id else { return }
        session.renameLayer(id, to: draftName)
        renaming = nil
    }

    private func layerActions(for local: LocalAdjustment) -> some View {
        VStack(spacing: 8) {
            LabeledSlider("Opacity", value: Binding(
                get: { local.opacity },
                set: { session.setLayer(local.id, opacity: $0) }
            ), range: 0...100)
        }
    }

    @ViewBuilder
    private func maskOptions(for local: LocalAdjustment) -> some View {
        switch local.mask {
        case .linear:
            EmptyView()
        case .radial(let mask):
            Toggle("Invert", isOn: Binding(
                get: { mask.isInverted },
                set: { isInverted in
                    var edited = mask
                    edited.isInverted = isInverted
                    session.perform { session.updateSelectedMask(.radial(edited)) }
                }
            ))
            .font(.callout)
            LabeledSlider("Feather", value: Binding(
                get: { mask.feather * 100 },
                set: { var edited = mask; edited.feather = $0 / 100; session.updateSelectedMask(.radial(edited)) }
            ), range: 0...100)
        case .brush:
            Picker("Mode", selection: $session.isErasing) {
                Text("Paint").tag(false)
                Text("Erase").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            LabeledSlider("Size", value: Binding(
                get: { session.brushRadius * 1000 },
                set: { session.brushRadius = $0 / 1000 }
            ), range: 5...250)
        case .detected(let mask):
            Toggle("Invert", isOn: Binding(
                get: { mask.isInverted },
                set: { isInverted in
                    var edited = mask
                    edited.isInverted = isInverted
                    session.perform { session.updateSelectedMask(.detected(edited)) }
                }
            ))
            .font(.callout)
            // Only when there is a choice to make: a picker with one row is noise, and most
            // photographs hold one subject.
            if let found = session.detectedInstances[mask.subject], found > 1 {
                Picker("Which one", selection: Binding(
                    get: { mask.instance },
                    set: { session.chooseInstance($0, of: mask) }
                )) {
                    ForEach(0..<found, id: \.self) { instance in
                        Text(mask.subject == .person ? "Person \(instance + 1)" : "Subject \(instance + 1)").tag(instance)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            // While the machine is looking, the layer changes nothing: say so, rather than
            // leave a layer that seems to do nothing at all.
            if !session.hasRaster(for: mask) {
                Text("Looking for the \(mask.subject == .person ? "person" : "subject")…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // The same brush as a painted mask, on what was found: detection misses a strand
            // of hair and takes in a shoulder nobody wanted.
            Picker("Mode", selection: $session.isErasing) {
                Text("Add").tag(false)
                Text("Remove").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            LabeledSlider("Brush size", value: Binding(
                get: { session.brushRadius * 1000 },
                set: { session.brushRadius = $0 / 1000 }
            ), range: 5...250)
        }
    }
}

/// Holds a layer to a range of tones: the graduated filter on the sky that spares the
/// steeple standing in it. The ramp under the sliders is what the layer is worth on each
/// tone, from black to white.
private struct LuminanceRangeRow: View {
    @Bindable var session: DevelopSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Range of tones", isOn: $session.limitsSelectedLayerToTones)
                .font(.callout)
            if session.limitsSelectedLayerToTones {
                LuminanceRamp(samples: session.luminanceRampSamples())
                bound("Darkest", value: session.selectedLuminanceRange.lower) { $0.lower = $1 }
                bound("Brightest", value: session.selectedLuminanceRange.upper) { $0.upper = $1 }
                bound("Softness", value: session.selectedLuminanceRange.softness) { $0.softness = $1 }
            }
        }
    }

    /// The range is written whole: its bounds are put back in order where they are stored,
    /// not here.
    private func bound(
        _ title: String, value: Double, _ change: @escaping (inout LuminanceRange, Double) -> Void
    ) -> some View {
        LabeledSlider(title, value: Binding(
            get: { value * 100 },
            set: {
                var edited = session.selectedLuminanceRange
                change(&edited, $0 / 100)
                session.setSelectedLuminanceRange(edited)
            }
        ), range: 0...100)
    }
}

/// How much of the layer each tone gets, black on the left, white on the right.
private struct LuminanceRamp: View {
    let samples: [Double]

    var body: some View {
        GeometryReader { geometry in
            let step = geometry.size.width / CGFloat(max(samples.count - 1, 1))
            Path { path in
                path.move(to: CGPoint(x: 0, y: geometry.size.height))
                for (index, sample) in samples.enumerated() {
                    path.addLine(to: CGPoint(x: CGFloat(index) * step, y: (1 - sample) * geometry.size.height))
                }
                path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                path.closeSubpath()
            }
            .fill(LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing).opacity(0.75))
        }
        .frame(height: 22)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
    }
}

/// The spot removal tool: click the picture to add a spot, drag its two ends.
struct SpotsPanelView: View {
    @Bindable var session: DevelopSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.adjustments.spots.isEmpty ? "Click a blemish to remove it." : Count.of(session.adjustments.spots.count, "spot"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let spot = session.adjustments.spots.first(where: { $0.id == session.selectedSpotID }) {
                LabeledSlider("Size", value: Binding(
                    get: { spot.radius * 1000 },
                    set: { var edited = spot; edited.radius = $0 / 1000; session.updateSpot(edited) }
                ), range: 3...100)
                Button("Delete Spot", systemImage: "trash", action: session.removeSelectedSpot)
                    .controlSize(.small)
            }
        }
    }
}

/// A slider that belongs to a tool rather than to the adjustments document.
private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) {
        self.title = title
        _value = value
        self.range = range
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(0))).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            ValueSlider(value: $value, range: range, neutral: range.lowerBound)
        }
    }
}
