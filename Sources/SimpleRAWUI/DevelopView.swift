import Catalog
import RawEngine
import SwiftUI
import UniformTypeIdentifiers

/// The single window of the app: the image, and an inspector that gets out of the way.
public struct DevelopView: View {
    @Bindable var session: DevelopSession
    /// How a file from outside is opened: the app keeps track of what is open; alone, the
    /// session simply opens it.
    private let openFile: @MainActor @Sendable (URL) -> Void
    /// Where the export panel opens: the library's Exports folder, when there is a library.
    private let exportsFolder: @MainActor @Sendable () -> URL?
    @AppStorage(DevelopView.showsInspectorKey) private var showsInspector = true
    @State private var isDropTargeted = false
    @State private var showsZoomBadge = false
    @State private var canvasSize = CGSize.zero
    /// Translation already applied during the current pan, to turn it into increments.
    @State private var appliedPan = CGSize.zero
    @Environment(\.displayScale) private var displayScale

    /// Shared with the View menu.
    static let showsInspectorKey = "develop.showsInspector"

    public init(
        session: DevelopSession,
        openFile: (@MainActor @Sendable (URL) -> Void)? = nil,
        exportsFolder: @escaping @MainActor @Sendable () -> URL? = { nil }
    ) {
        self.session = session
        self.exportsFolder = exportsFolder
        self.openFile = openFile ?? { [session] in session.open($0) }
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                canvas
                // Under the picture, never over it: over it, the bar hid the bottom handles.
                if session.isCropping, !session.showsOriginal, let context = session.sliderContext {
                    CropBar(session: session, context: context)
                }
            }
            if showsInspector, let context = session.sliderContext {
                InspectorView(session: session, context: context)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Theme.canvas)
        .tint(Theme.accent)
        .environment(\.discreteEdit, DiscreteEdit { [session] change in session.perform(nil, change) })
        .animation(.easeInOut(duration: 0.2), value: showsInspector)
        // Masks and spots are added from the inspector: without it the tool would seem dead.
        .onChange(of: session.tool) { _, tool in
            if tool == .local || tool == .spots { showsInspector = true }
        }
        .toolbar { toolbar }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: open(droppedItems:))
        // Edits are saved shortly after each change; this catches the last ones on quit.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            session.flush()
        }
        .overlay { NoticeView(text: session.notice, dismiss: session.dismissNotice) }
        .sheet(isPresented: $session.isChoosingCopiedGroups) { CopySettingsSheet(session: session) }
        .sheet(isPresented: exportIsPresented) {
            ExportSheet(session: session) { preset in presentExportPanel(using: preset) }
        }
        .alert(session.errorTitle, isPresented: errorIsPresented) {
            Button("OK", action: session.dismissError)
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    // MARK: - Pieces

    private var canvas: some View {
        ZStack {
            GeometryReader { geometry in
                MetalImageView(
                    image: { session.previewImage(fitting: $0) },
                    revision: AnyHashable(Revision(file: session.fileName, adjustments: session.adjustments, original: session.showsOriginal, tool: session.tool, zoom: session.zoom, clipping: session.showsClipping, overlay: session.showsMaskOverlay ? session.selectedLocalID : nil, triedLook: session.previewedPreset?.name, masks: session.maskRevision)),
                    onScroll: session.zoom == .fit ? nil : scrollHandler
                )
                .gesture(zoomGesture(in: geometry.size), including: session.tool == .none ? .all : .none)
                .gesture(panGesture, including: session.tool == .none ? .all : .none)

                .pointerStyle(session.zoom != .fit && session.tool == .none ? .grabIdle : .default)
            }
            if session.tool == .crop, !session.showsOriginal, let frame = session.cropFrameSize {
                CropOverlayView(
                    crop: $session.adjustments.geometry.crop,
                    frameAspect: frame.width / frame.height,
                    lockedAspect: session.lockedCropAspect
                )
            }
            if session.tool == .level, !session.showsOriginal {
                LevelOverlayView(session: session)
            }
            if [.local, .spots, .whiteBalance].contains(session.tool), !session.showsOriginal, session.info != nil {
                LocalOverlayView(session: session)
            }
            if session.info == nil {
                ContentUnavailableView(
                    "Open a photo",
                    systemImage: "camera.aperture",
                    description: Text("Drop a file here, or press ⌘O.")
                )
            }
            if session.showsOriginal {
                // Stays as long as the state does, and is the way out of it.
                Button { session.showsOriginal = false } label: { badge("Original") }
                    .buttonStyle(.plain)
                    .help("Back to your edit (B)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if showsZoomBadge, session.zoom != .fit {
                badge("100 %")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            if session.isExporting {
                ProgressView("Exporting…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent, lineWidth: 3).padding(8)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .onGeometryChange(for: CGSize.self, of: \.size) { canvasSize = $0 }
        .gestureTarget(GestureTargets.canvas)
        // On the whole canvas rather than on the picture: tool overlays sit above it.
        .simultaneousGesture(pinchGesture(in: canvasSize), including: session.tool == .crop ? .subviews : .all)
        // Says what just happened, then leaves the picture alone.
        .task(id: session.zoom == .fit) {
            showsZoomBadge = session.zoom != .fit
            try? await Task.sleep(for: .milliseconds(1200))
            withAnimation(.easeOut(duration: 0.3)) { showsZoomBadge = false }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 24)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            // No "no tool" segment: clicking the tool in use puts it down, and so does Escape.
            ControlGroup {
                toolToggle(.crop, "Crop", systemImage: "crop", help: "Crop, rotate and straighten (C)")
                toolToggle(.local, "Masks", systemImage: "circle.dashed", help: "Local adjustments (M)")
                toolToggle(.spots, "Spots", systemImage: "bandage", help: "Spot removal (S)")
            }
            .disabled(session.info == nil)
        }
        ToolbarItemGroup {
            Button("History", systemImage: "clock.arrow.circlepath") { session.showsHistory.toggle() }
                .help("Every step of this photo: click one to go back to it (⌥⌘Z)")
                .disabled(session.info == nil)
                .popover(isPresented: $session.showsHistory, arrowEdge: .bottom) { HistoryView(session: session) }

            Toggle("Original", systemImage: "circle.lefthalf.filled", isOn: $session.showsOriginal)
                .help("Compare with the unedited image (B, or \\)")
                .disabled(session.info == nil)

            Button("Zoom", systemImage: session.zoom == .fit ? "plus.magnifyingglass" : "minus.magnifyingglass") {
                session.toggleZoom(at: CGPoint(x: 0.5, y: 0.5))
            }
            .help("Switch between fit and 100 % (Z, a pinch, or a double-click on the picture)")
            .disabled(session.info == nil || session.tool == .crop)

            Menu {
                // One click per preset, for an export that needs no thinking about; the
                // button itself opens the settings, where a preset is made in the first place.
                ForEach(session.exportPresets) { preset in
                    Button(preset.name) { presentExportPanel(using: preset) }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            } primaryAction: {
                if let preset = session.defaultExportPreset { session.beginExport(with: preset) }
            }
            .keyboardShortcut("e")
            .help("Export (⇧⌘E). Click the arrow to export straight away with a preset.")
            .disabled(session.info == nil || session.isExporting)

            Toggle("Inspector", systemImage: "sidebar.trailing", isOn: $showsInspector)
                .help("Show or hide the adjustments (⌥⌘I)")
        }
    }

    private func toolToggle(_ tool: Tool, _ title: String, systemImage: String, help: String) -> some View {
        Toggle(title, systemImage: systemImage, isOn: Binding(
            get: { session.tool == tool },
            set: { session.tool = $0 ? tool : .none }
        ))
        .help(help)
    }

    /// Double-click: 100 % on the point that was clicked, or back to the fitted view.
    private func zoomGesture(in size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2).onEnded { tap in
            guard let shown = session.shownImageSize, shown.height > 0 else { return }
            session.toggleZoom(at: ZoomGeometry.imagePoint(
                at: tap.location, aspect: shown.width / shown.height, in: size, padding: FitGeometry.padding
            ))
        }
    }

    /// A pinch goes to 100 % where the fingers are, or back: two states, like the rest of the zoom.
    private func pinchGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture().onEnded { pinch in
            guard let shown = session.shownImageSize, shown.height > 0 else { return }
            if pinch.magnification > 1.15 {
                session.zoomToActualSize(at: ZoomGeometry.imagePoint(
                    at: pinch.startLocation, aspect: shown.width / shown.height, in: size, padding: FitGeometry.padding
                ))
            } else if pinch.magnification < 0.87 {
                session.zoomToFit()
            }
        }
    }

    /// What two fingers over the picture do at 100 %. The canvas keeps it past one frame, so
    /// it holds the session and the scale, never the view.
    private var scrollHandler: @MainActor @Sendable (CGSize) -> Void {
        { [session, displayScale] delta in
            guard let shown = session.shownImageSize else { return }
            session.pan(by: ZoomGeometry.panDelta(forDrag: delta, backingScale: displayScale, image: shown))
        }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { drag in
                guard let shown = session.shownImageSize else { return }
                let step = CGSize(width: drag.translation.width - appliedPan.width, height: drag.translation.height - appliedPan.height)
                session.pan(by: ZoomGeometry.panDelta(forDrag: step, backingScale: displayScale, image: shown))
                appliedPan = drag.translation
            }
            .onEnded { _ in appliedPan = .zero }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.dismissError() } })
    }

    private var exportIsPresented: Binding<Bool> {
        Binding(get: { session.exportDraft != nil }, set: { if !$0 { session.cancelExport() } })
    }

    // MARK: - Actions

    private func presentExportPanel(using preset: ExportPreset) {
        DevelopPanels.export(session, using: preset, in: exportsFolder())
    }

    /// Anything can be dragged onto a window. Only what the app opens is opened: the same
    /// rule the open panel and imports go by, asked of the file rather than of its name.
    private func open(droppedItems providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, Importer.opens(url) else { return }
            Task { @MainActor in openFile(url) }
        }
        return true
    }
}

extension ExportOptions.Format {
    var contentType: UTType {
        switch self {
        case .jpeg: .jpeg
        case .tiff16: .tiff
        case .png: .png
        case .heic: .heic
        }
    }
}

/// Everything that changes the displayed image, bundled so that SwiftUI redraws the canvas.
private struct Revision: Hashable {
    let file: String?
    let adjustments: Adjustments
    let original: Bool
    let tool: Tool
    let zoom: Zoom
    let clipping: Bool
    /// The mask laid over the picture, if any.
    let overlay: UUID?
    /// The look being tried on the canvas, if any.
    let triedLook: String?
    /// Moves when a mask the machine found arrives: it is not in `adjustments`, so nothing
    /// else here would tell the canvas to draw again.
    let masks: Int

    func hash(into hasher: inout Hasher) {
        hasher.combine(file)
        hasher.combine(original)
        hasher.combine(tool)
        hasher.combine(overlay)
        hasher.combine(triedLook)
        hasher.combine(masks)
    }
}
