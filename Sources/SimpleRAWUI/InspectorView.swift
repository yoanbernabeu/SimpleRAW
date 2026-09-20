import RawEngine
import SwiftUI

/// The adjustments panel: a histogram, four families of tools, and inside the chosen family
/// one open panel at a time. Little on screen, everything two clicks away; a dot marks what
/// holds edits, so nothing has to be opened to be found.
struct InspectorView: View {
    @Bindable var session: DevelopSession
    let context: SliderContext
    @AppStorage(InspectorLayout.tabKey) private var tabName = InspectorTab.light.rawValue
    /// The open panel of each tab, by tab name.
    @AppStorage(InspectorLayout.openPanelsKey) private var openPanelsStorage = ""

    private var tab: InspectorTab { InspectorTab(rawValue: tabName) ?? .light }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HistogramView(histogram: session.histogram, showsClipping: $session.showsClipping)
                if let info = session.info {
                    ShotSummary(info: info)
                }
                tabBar
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(tab.panels.filter(isAvailable), id: \.self) { panel in
                        InspectorSection(
                            title: panel.title,
                            isEdited: panel.isEdited(session.adjustments, context),
                            isOpen: openPanel(of: tab) == panel,
                            toggle: { toggle(panel) }
                        ) {
                            content(of: panel)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .frame(width: Theme.panelWidth)
        .background(Theme.panel)
        .disabled(session.showsOriginal)
        // The other way round: the panel on screen decides which tool the canvas holds, so
        // that masks do not stay over the picture while another family of tools is in use.
        .onChange(of: tabName) { _, _ in syncTool() }
        .onChange(of: openPanelsStorage) { _, _ in syncTool() }
        // Picking a tool on the canvas brings its controls into view.
        .onChange(of: session.tool) { _, tool in showControls(of: tool) }
        // The inspector may appear with a tool already in hand (a photo opened on a tool, the
        // inspector shown again): the two are brought in step then too.
        .onAppear {
            if InspectorTab.tab(for: session.tool) != nil { showControls(of: session.tool) } else { syncTool() }
        }
    }

    private func showControls(of tool: Tool) {
        guard let wanted = InspectorTab.tab(for: tool) else { return }
        tabName = wanted.rawValue
        switch tool {
        case .spots: setOpenPanel(.spots, of: wanted)
        case .local: setOpenPanel(.layers, of: wanted)
        case .whiteBalance: setOpenPanel(.sliders(.color), of: wanted)
        case .none, .crop, .level: break
        }
    }

    /// What only a RAW decoder can do is not offered for a JPEG: a slider that does nothing
    /// is worse than no slider.
    private func isAvailable(_ panel: InspectorPanel) -> Bool {
        switch panel {
        case .sliders(.detail): session.info?.isRaw != false
        // Versions are kept by the library: a file from elsewhere has nowhere to keep them.
        case .versions: session.canKeepVersions
        default: true
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(InspectorTab.allCases) { candidate in
                let isSelected = candidate == tab
                Button { tabName = candidate.rawValue } label: {
                    VStack(spacing: 3) {
                        Image(systemName: candidate.systemImage).font(.system(size: 14, weight: .medium))
                        Text(candidate.title).font(.system(size: 9.5, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(isSelected ? Theme.accent : .secondary)
                    .background(isSelected ? Theme.control : .clear, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                    .overlay(alignment: .topTrailing) {
                        if candidate.isEdited(session.adjustments, context) {
                            Circle().fill(Theme.accent).frame(width: 5, height: 5).padding(6)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(candidate.title)
            }
        }
    }

    @ViewBuilder
    private func content(of panel: InspectorPanel) -> some View {
        switch panel {
        case .sliders(let section):
            if section == .essentials {
                Button(action: session.autoTone) {
                    Label("Auto", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .help("Set light and color from the picture itself (⌘U)")
            }
            if section == .color {
                HStack(spacing: 8) {
                    Picker("White balance", selection: Binding(
                        get: { session.whiteBalancePreset },
                        set: { if let preset = $0 { session.apply(preset) } }
                    )) {
                        if session.whiteBalancePreset == nil { Text("Custom").tag(WhiteBalancePreset?.none) }
                        ForEach(WhiteBalancePreset.allCases) { Text($0.rawValue).tag(WhiteBalancePreset?.some($0)) }
                    }
                    .labelsHidden()
                    Toggle("Eyedropper", systemImage: "eyedropper", isOn: Binding(
                        get: { session.tool == .whiteBalance },
                        set: { session.tool = $0 ? .whiteBalance : .none }
                    ))
                    .toggleStyle(.button)
                    .labelStyle(.iconOnly)
                    .help("Pick something neutral in the picture (W)")
                    .disabled(session.info?.isRaw == false)
                }
                .controlSize(.small)
            }
            ForEach(SliderSpec.all(in: section)) { spec in
                SliderRow(spec: spec, adjustments: $session.adjustments, context: context)
            }
        case .looks:
            LooksPanelView(session: session)
        case .curve:
            CurveEditorView(curves: $session.adjustments.curves, histogram: session.histogram)
        case .blackAndWhite:
            Toggle("Convert to Black & White", isOn: Binding(
                get: { session.adjustments.blackAndWhite.isEnabled },
                set: { isOn in session.perform { session.adjustments.blackAndWhite.isEnabled = isOn } }
            ))
            .font(.callout)
            if session.adjustments.blackAndWhite.isEnabled {
                ForEach(SliderSpec.all(in: .blackAndWhite)) { spec in
                    SliderRow(spec: spec, adjustments: $session.adjustments, context: context)
                }
            }
        case .hsl:
            HSLPanelView(adjustments: $session.adjustments, context: context)
        case .grading:
            ColorGradingPanelView(adjustments: $session.adjustments, context: context)
        case .mood:
            MoodPanelView(session: session)
        case .layers:
            LocalPanelView(session: session, context: context)
        case .spots:
            SpotsPanelView(session: session)
        case .versions:
            VersionsPanelView(session: session)
        }
    }

    // MARK: - One open panel per tab

    private var openPanels: [String: String] {
        // A preference is outside input: a key written twice must not take the app down.
        Dictionary(openPanelsStorage.split(separator: "|").compactMap { entry in
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }, uniquingKeysWith: { _, last in last })
    }

    private func openPanel(of tab: InspectorTab) -> InspectorPanel? {
        guard let stored = openPanels[tab.rawValue] else { return tab.defaultPanel }
        return tab.panels.first { $0.title == stored }
    }

    private func setOpenPanel(_ panel: InspectorPanel?, of tab: InspectorTab) {
        var panels = openPanels
        panels[tab.rawValue] = panel?.title ?? "-"
        openPanelsStorage = panels.map { "\($0.key)=\($0.value)" }.joined(separator: "|")
    }

    private func syncTool() {
        session.tool = InspectorLayout.tool(whenShowing: openPanel(of: tab), current: session.tool)
    }

    /// Opening a panel closes the one that was open; clicking the open one closes it.
    private func toggle(_ panel: InspectorPanel) {
        withAnimation(.easeInOut(duration: 0.18)) {
            setOpenPanel(openPanel(of: tab) == panel ? nil : panel, of: tab)
        }
    }
}

/// A collapsible block of the inspector. A dot says it holds edits, open or not.
private struct InspectorSection<Content: View>: View {
    let title: String
    let isEdited: Bool
    let isOpen: Bool
    let toggle: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    // Upper case is a look, not the text: VoiceOver reads a word, not a spelling.
                    Text(title).textCase(.uppercase).sectionTitleStyle()
                    if isEdited {
                        Circle().fill(Theme.accent).frame(width: 5, height: 5)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isOpen ? "expanded" : "collapsed")
            .accessibilityHint(isEdited ? "Holds edits" : "")

            if isOpen {
                VStack(alignment: .leading, spacing: 11) { content }
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}

struct SliderRow: View {
    let spec: SliderSpec
    @Binding var adjustments: Adjustments
    let context: SliderContext
    @Environment(\.discreteEdit) private var discreteEdit
    /// The value being typed, while it is: a click on the number turns it into a field.
    @State private var typedValue: String?
    @FocusState private var isTyping: Bool

    var body: some View {
        let value = spec.value(adjustments, context)
        let neutral = spec.neutral(context)
        VStack(spacing: 1) {
            HStack {
                Text(spec.title).foregroundStyle(.primary.opacity(0.85))
                    .onTapGesture(count: 2, perform: reset)
                Spacer()
                valueLabel(value, isNeutral: value == neutral)
            }
            .font(.system(size: Theme.labelSize))

            ValueSlider(
                value: Binding(get: { value }, set: { spec.setValue(&adjustments, $0, context) }),
                range: spec.range, neutral: neutral, step: spec.step,
                title: spec.title, track: spec.track?.colors ?? [], onReset: reset
            )
        }
        .help("Double-click to reset. Hold ⌥ for fine steps, click the value to type one.")
    }

    @ViewBuilder
    private func valueLabel(_ value: Double, isNeutral: Bool) -> some View {
        if let typedValue {
            TextField("", text: Binding(get: { typedValue }, set: { self.typedValue = $0 }))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 56)
                .focused($isTyping)
                .onSubmit(commitTypedValue)
                .onExitCommand { self.typedValue = nil }
                .onChange(of: isTyping) { _, isTyping in
                    if !isTyping { commitTypedValue() }
                }
        } else {
            Text(value, format: .number.precision(.fractionLength(spec.fractionDigits)))
                .monospacedDigit()
                .foregroundStyle(isNeutral ? Color.secondary : Theme.accent)
                .contentShape(Rectangle())
                .onTapGesture {
                    typedValue = value.formatted(.number.precision(.fractionLength(spec.fractionDigits)).grouping(.never))
                    isTyping = true
                }
                .accessibilityHidden(true)
        }
    }

    private func reset() {
        discreteEdit { spec.reset(&adjustments, context) }
    }

    private func commitTypedValue() {
        guard let typed = typedValue else { return }
        typedValue = nil
        guard let parsed = SliderGeometry.parsed(typed, range: spec.range) else { return }
        discreteEdit { spec.setValue(&adjustments, parsed, context) }
    }
}

private struct ShotSummary: View {
    let info: RawInfo

    var body: some View {
        Text(parts.joined(separator: "  ·  "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var parts: [String] {
        [
            info.iso.map(ExposureFormat.iso),
            info.exposureTime.map { ExposureFormat.shutterSpeed($0) },
            info.aperture.map { ExposureFormat.aperture($0) },
            info.focalLength.map { ExposureFormat.focalLength($0) },
        ].compactMap(\.self)
    }
}

extension SliderSpec.Track {
    var colors: [Color] {
        switch self {
        case .temperature: Theme.temperatureTrack
        case .tint: Theme.tintTrack
        }
    }
}
