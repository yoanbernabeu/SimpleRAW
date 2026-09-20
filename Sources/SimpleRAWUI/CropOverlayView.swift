import RawEngine
import SwiftUI

/// The crop frame drawn over the whole image: drag a corner to resize, drag inside to move.
/// All the rules (limits, locked ratio) live in `CropRect`; this only translates gestures.
struct CropOverlayView: View {
    @Binding var crop: CropRect?
    /// Width / height of the frame being cropped.
    let frameAspect: CGFloat
    /// Ratio to hold while resizing, in `CropRect` units; `nil` for a free crop.
    let lockedAspect: Double?

    @State private var drag: (start: CropRect, target: CropHitTest.Target)?

    var body: some View {
        GeometryReader { geometry in
            let frame = FitGeometry.frame(forAspect: frameAspect, in: geometry.size, padding: FitGeometry.padding)
            let rect = FitGeometry.rect(of: crop ?? .full, in: frame)
            ZStack {
                // Everything outside the crop is dimmed.
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geometry.size))
                    path.addRect(rect)
                }
                .fill(.black.opacity(0.6), style: FillStyle(eoFill: true))

                thirds(in: rect).stroke(.white.opacity(0.35), lineWidth: 0.5)
                Rectangle().path(in: rect).stroke(.white, lineWidth: 1)
                ForEach(CropRect.Edge.allCases, id: \.self) { edge in
                    handle(for: edge, in: rect)
                }
                ForEach(CropRect.Corner.allCases, id: \.self) { corner in
                    handle(for: corner, in: rect)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(in: frame))
        }
    }

    private func dragGesture(in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let current = crop ?? .full
                if drag == nil {
                    guard let target = CropHitTest.target(at: value.startLocation, in: FitGeometry.rect(of: current, in: frame)) else { return }
                    drag = (current, target)
                }
                guard let drag else { return }
                switch drag.target {
                case .corner(let corner):
                    let point = FitGeometry.normalized(value.location, in: frame)
                    crop = drag.start.resized(dragging: corner, toX: point.x, y: point.y, aspect: lockedAspect)
                case .edge(let edge):
                    let point = FitGeometry.normalized(value.location, in: frame)
                    let position = edge == .left || edge == .right ? point.x : point.y
                    crop = drag.start.resized(dragging: edge, to: position, aspect: lockedAspect)
                case .inside:
                    crop = drag.start.moved(
                        byX: value.translation.width / frame.width,
                        y: value.translation.height / frame.height
                    )
                }
            }
            .onEnded { _ in drag = nil }
    }

    private static func location(of corner: CropRect.Corner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    private func handle(for corner: CropRect.Corner, in rect: CGRect) -> some View {
        let position: FrameResizePosition = switch corner {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
        return Rectangle()
            .fill(.white)
            .frame(width: 12, height: 12)
            .pointerStyle(.frameResize(position: position))
            .position(Self.location(of: corner, in: rect))
    }

    /// A short bar in the middle of each edge: edges can be dragged too.
    private func handle(for edge: CropRect.Edge, in rect: CGRect) -> some View {
        let isVertical = edge == .left || edge == .right
        let (center, position): (CGPoint, FrameResizePosition) = switch edge {
        case .top: (CGPoint(x: rect.midX, y: rect.minY), .top)
        case .bottom: (CGPoint(x: rect.midX, y: rect.maxY), .bottom)
        case .left: (CGPoint(x: rect.minX, y: rect.midY), .leading)
        case .right: (CGPoint(x: rect.maxX, y: rect.midY), .trailing)
        }
        return Capsule()
            .fill(.white)
            .frame(width: isVertical ? 4 : 26, height: isVertical ? 26 : 4)
            .pointerStyle(.frameResize(position: position))
            .position(center)
    }

    private func thirds(in rect: CGRect) -> Path {
        var path = Path()
        for third in 1..<3 {
            let offset = CGFloat(third) / 3
            path.move(to: CGPoint(x: rect.minX + rect.width * offset, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * offset, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * offset))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * offset))
        }
        return path
    }
}

/// Controls of the crop tool, shown under the image while cropping.
struct CropBar: View {
    @Bindable var session: DevelopSession
    let context: SliderContext

    var body: some View {
        HStack(spacing: 16) {
            // `set: session.apply` reads better and is a method reference across an actor
            // boundary, which makes the compiler emit a reabstraction thunk — and emitting
            // that thunk is what killed the compiler on the runner, by name. Written as a
            // closure there is no thunk, and nothing else changes.
            Picker("Aspect", selection: Binding(get: { session.cropAspect }, set: { session.apply($0) })) {
                ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 130)
            .labelsHidden()

            Button("Turn Ratio", systemImage: "rectangle.portrait.rotate", action: session.turnCropAspect)
                .disabled(session.lockedCropAspect == nil || session.cropAspect == .original || session.cropAspect == .square)
                .help("Turn the ratio between landscape and portrait (X)")

            Button("Rotate left", systemImage: "rotate.left") { session.turn(clockwise: false) }
            Button("Rotate right", systemImage: "rotate.right") { session.turn(clockwise: true) }

            Button("Level", systemImage: "level") { session.tool = session.tool == .level ? .crop : .level }
                .foregroundStyle(session.tool == .level ? Theme.accent : Color.primary)
                .help("Straighten by drawing a line along something level")

            ForEach(SliderSpec.all(in: .geometry)) { spec in
                SliderRow(spec: spec, adjustments: $session.adjustments, context: context)
                    .frame(width: 220)
            }

            Button("Reset", action: session.resetGeometry)
                .disabled(session.adjustments.geometry.isNeutral)
            Button("Cancel", action: session.cancelTool)
                .help("Give up this crop (Esc)")
            Button("Done") { session.isCropping = false }
                .keyboardShortcut(.defaultAction)
                // The default button takes the system accent, not the tint: said outright.
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .help("Keep this crop (Return)")
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.panel)
    }
}
