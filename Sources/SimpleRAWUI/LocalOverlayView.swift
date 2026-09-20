import RawEngine
import SwiftUI

/// The on-canvas side of the local and spot tools. Masks and spots are positioned in the
/// original frame, which is what these tools display; `DevelopSession.toolFrame` maps it to
/// the view, fitted or at 100 %.
struct LocalOverlayView: View {
    @Bindable var session: DevelopSession
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            // Fitted, or the larger frame a 100 % view looks into: handles follow the zoom.
            let frame = session.toolFrame(in: geometry.size, backingScale: displayScale)
            // These tools show the whole original frame, where masks and spots are placed: what
            // the crop leaves out is dimmed, so that it is clear what will be in the picture.
            if let crop = session.cropShownByLocalTools {
                let kept = FitGeometry.rect(of: crop, in: frame)
                Path { path in
                    path.addRect(frame)
                    path.addRect(kept)
                }
                .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                Rectangle().path(in: kept).stroke(.white.opacity(0.5), lineWidth: 1).allowsHitTesting(false)
            }
            if session.tool == .whiteBalance {
                EyedropperOverlay(session: session, frame: frame)
            } else if session.tool == .spots {
                SpotsOverlay(session: session, frame: frame)
            } else if let local = session.selectedLocal {
                switch local.mask {
                case .linear(let mask):
                    LinearMaskOverlay(mask: mask, frame: frame) { session.updateSelectedMask(.linear($0)) }
                case .radial(let mask):
                    RadialMaskOverlay(mask: mask, frame: frame) { session.updateSelectedMask(.radial($0)) }
                case .brush:
                    BrushOverlay(session: session, frame: frame)
                // A found mask has no handle to drag — what shapes it is the picture — but
                // it takes the brush, to add the strand of hair detection missed.
                case .detected:
                    BrushOverlay(session: session, frame: frame)
                }
            }
        }
        .clipped()
    }
}

private extension NormalizedPoint {
    init(_ location: CGPoint, in frame: CGRect) {
        let point = FitGeometry.normalized(location, in: frame)
        self.init(x: point.x, y: point.y)
    }

    func location(inView frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + x * frame.width, y: frame.minY + y * frame.height)
    }
}

private struct Handle: View {
    var isHollow = false

    var body: some View {
        Circle()
            .fill(isHollow ? Color.black.opacity(0.4) : Color.white)
            .stroke(.white, lineWidth: 1.5)
            .frame(width: 13, height: 13)
            .shadow(radius: 2)
            .contentShape(Circle().inset(by: -10))
    }
}

/// Two handles: the filled one is where the effect is full, the hollow one where it ends.
private struct LinearMaskOverlay: View {
    let mask: LinearMask
    let frame: CGRect
    let update: (LinearMask) -> Void

    var body: some View {
        let (start, end) = (mask.start.location(inView: frame), mask.end.location(inView: frame))
        ZStack {
            Path { path in
                path.move(to: start)
                path.addLine(to: end)
            }
            .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            Handle()
                .position(start)
                .gesture(DragGesture().onChanged { drag in
                    var edited = mask
                    edited.start = NormalizedPoint(drag.location, in: frame)
                    update(edited)
                })
            Handle(isHollow: true)
                .position(end)
                .gesture(DragGesture().onChanged { drag in
                    var edited = mask
                    edited.end = NormalizedPoint(drag.location, in: frame)
                    update(edited)
                })
        }
    }
}

/// The ellipse, a handle to move it, and one handle per axis to size it.
private struct RadialMaskOverlay: View {
    let mask: RadialMask
    let frame: CGRect
    let update: (RadialMask) -> Void

    /// Smallest radius a handle can be dragged down to, in frame fractions.
    private static let minimumRadius = 0.02

    var body: some View {
        let center = mask.center.location(inView: frame)
        let (radiusX, radiusY) = (mask.radiusX * frame.width, mask.radiusY * frame.height)
        ZStack {
            Ellipse()
                .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: radiusX * 2, height: radiusY * 2)
                .position(center)
                .allowsHitTesting(false)
            Handle()
                .position(center)
                .gesture(DragGesture().onChanged { drag in
                    var edited = mask
                    edited.center = NormalizedPoint(drag.location, in: frame)
                    update(edited)
                })
            Handle(isHollow: true)
                .position(x: center.x + radiusX, y: center.y)
                .gesture(DragGesture().onChanged { drag in
                    var edited = mask
                    edited.radiusX = max(Self.minimumRadius, abs(drag.location.x - center.x) / frame.width)
                    update(edited)
                })
            Handle(isHollow: true)
                .position(x: center.x, y: center.y + radiusY)
                .gesture(DragGesture().onChanged { drag in
                    var edited = mask
                    edited.radiusY = max(Self.minimumRadius, abs(drag.location.y - center.y) / frame.height)
                    update(edited)
                })
        }
    }
}

/// Dragging paints (or erases); a circle shows the size of the brush under the pointer.
private struct BrushOverlay: View {
    @Bindable var session: DevelopSession
    let frame: CGRect
    @State private var pointer: CGPoint?
    @State private var isPainting = false

    var body: some View {
        let diameter = session.brushRadius * max(frame.width, frame.height) * 2
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        pointer = drag.location
                        let point = NormalizedPoint(drag.location, in: frame)
                        if isPainting {
                            session.continueStroke(to: point)
                        } else {
                            isPainting = true
                            session.beginStroke(at: point)
                        }
                    }
                    .onEnded { _ in
                        isPainting = false
                        session.endStroke()
                    })
                .onContinuousHover { phase in
                    if case .active(let location) = phase { pointer = location } else { pointer = nil }
                }
            if let pointer {
                Circle()
                    .stroke(session.isErasing ? Theme.warning : Color.white, lineWidth: 1)
                    .frame(width: diameter, height: diameter)
                    .position(pointer)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Click to add a spot. Each spot shows its target (solid) and its source (dashed), both
/// draggable, joined by a line.
private struct SpotsOverlay: View {
    @Bindable var session: DevelopSession
    let frame: CGRect

    var body: some View {
        ZStack {
            // One gesture for both: a click puts a spot down, a drag draws the line along a
            // wire or a scratch. A drag that never moves is a click, which is why the spot is
            // made when the pointer goes down and the line only grows if it travels.
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard frame.contains(drag.startLocation) else { return }
                            if session.healingLineID == nil {
                                session.beginHealingLine(at: NormalizedPoint(drag.startLocation, in: frame))
                            }
                            session.continueHealingLine(to: NormalizedPoint(drag.location, in: frame))
                        }
                        .onEnded { _ in session.endHealingLine() }
                )
            ForEach(session.adjustments.spots) { spot in
                marker(for: spot)
            }
        }
    }

    private func marker(for spot: Spot) -> some View {
        let (target, source) = (spot.target.location(inView: frame), spot.source.location(inView: frame))
        let diameter = spot.radius * max(frame.width, frame.height) * 2
        let color: Color = spot.id == session.selectedSpotID ? Theme.accent : .white
        return ZStack {
            Path { path in
                path.move(to: target)
                path.addLine(to: source)
            }
            .stroke(color.opacity(0.7), lineWidth: 1)
            // A line shows where it was drawn, as thick as it heals.
            if spot.isLine {
                Path { path in
                    path.addLines(spot.points.map { $0.location(inView: frame) })
                }
                .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: diameter, lineCap: .round, lineJoin: .round))
                .opacity(0.35)
                .allowsHitTesting(false)
            }
            Circle()
                .stroke(color, lineWidth: 1.5)
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
                .position(target)
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    session.selectedSpotID = spot.id
                    var edited = spot
                    let moved = NormalizedPoint(drag.location, in: frame)
                    // A line moves as a whole: its shape is what was drawn along the blemish.
                    let (dx, dy) = (moved.x - spot.target.x, moved.y - spot.target.y)
                    edited.target = moved
                    edited.path = spot.path.map { NormalizedPoint(x: $0.x + dx, y: $0.y + dy) }
                    session.updateSpot(edited)
                })
            Circle()
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
                .position(source)
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    session.selectedSpotID = spot.id
                    var edited = spot
                    edited.source = NormalizedPoint(drag.location, in: frame)
                    session.updateSpot(edited)
                })
        }
    }
}

/// One click on something that should be neutral: a wall, a road, a shirt.
private struct EyedropperOverlay: View {
    @Bindable var session: DevelopSession
    let frame: CGRect
    @State private var pointer: CGPoint?

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { tap in
                    guard frame.contains(tap.location) else { return }
                    session.pickWhiteBalance(at: NormalizedPoint(tap.location, in: frame))
                })
                .onContinuousHover { phase in
                    if case .active(let location) = phase { pointer = location } else { pointer = nil }
                }
            if let pointer, frame.contains(pointer) {
                Image(systemName: "eyedropper")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 1.5)
                    .position(x: pointer.x + 9, y: pointer.y - 9)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            Text("Click something that should be neutral gray or white")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 24)
                .allowsHitTesting(false)
        }
    }
}
