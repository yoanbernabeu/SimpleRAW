import RawEngine
import SwiftUI

/// Which curve of `Curves` the editor is working on.
enum CurveChannel: String, CaseIterable, Identifiable {
    case rgb = "RGB"
    case red = "R"
    case green = "G"
    case blue = "B"

    var id: Self { self }

    var keyPath: WritableKeyPath<Curves, Curve> {
        switch self {
        case .rgb: \.rgb
        case .red: \.red
        case .green: \.green
        case .blue: \.blue
        }
    }

    var color: Color {
        switch self {
        case .rgb: .white
        case .red: .red
        case .green: .green
        case .blue: .blue
        }
    }

    /// Curves are drawn with y up; views have y down.
    static func curvePoint(at location: CGPoint, in size: CGSize) -> Curve.Point {
        Curve.Point(x: location.x / size.width, y: 1 - location.y / size.height)
    }

    static func viewLocation(of point: Curve.Point, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
    }

    /// Where the trace of `curve` goes, left to right, in view coordinates. Through one
    /// lookup table: evaluating a curve point by point works its tangents out again at every
    /// point, a hundred times per frame while one is dragged.
    static func tracePoints(of curve: Curve, in size: CGSize, samples: Int = 96) -> [CGPoint] {
        let levels = curve.lookupTable(size: samples + 1)
        return levels.enumerated().map { index, level in
            viewLocation(of: Curve.Point(x: Double(index) / Double(samples), y: Double(level)), in: size)
        }
    }
}

/// Point curve editor. Click to add a point, drag to move it, drag it out of the square to
/// remove it. All the rules (ordering, clamping, end points) live in `Curve`.
struct CurveEditorView: View {
    @Binding var curves: Curves
    /// Drawn faintly behind the curve: where the tones of this picture are.
    var histogram: Histogram?
    @State private var channel = CurveChannel.rgb
    @State private var draggedIndex: Int?
    @Environment(\.discreteEdit) private var discreteEdit
    /// Whether the press under way landed on a point that was already there.
    @State private var pressedExistingPoint = false
    @State private var lastClick: (index: Int, date: Date)?
    private static let doubleClickInterval: TimeInterval = 0.3
    private static let clickDistance: CGFloat = 3

    /// How close to a point a click must land to grab it, in curve units.
    private static let grabDistance = 0.06
    /// How far out of the square a point must be dropped to be removed, in points.
    private static let removalMargin: CGFloat = 24

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Channel", selection: $channel) {
                    ForEach(CurveChannel.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Button("Reset", systemImage: "arrow.counterclockwise") { discreteEdit { curve = .identity } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(curve.isIdentity)
                    .help("Reset this curve")
            }
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.35))
                    if let bins = histogramBins {
                        HistogramShape(bins: bins).fill(channel.color.opacity(0.15))
                    }
                    grid(in: geometry.size).stroke(.white.opacity(0.12), lineWidth: 0.5)
                    path(in: geometry.size).stroke(channel.color.opacity(0.9), lineWidth: 1.5)
                    ForEach(curve.points.indices, id: \.self) { index in
                        Circle()
                            .fill(index == draggedIndex ? channel.color : .black)
                            .stroke(channel.color, lineWidth: 1.5)
                            .frame(width: 9, height: 9)
                            .position(CurveChannel.viewLocation(of: curve.points[index], in: geometry.size))
                    }
                }
                .contentShape(Rectangle())
                .gesture(drag(in: geometry.size))
                .gestureTarget(GestureTargets.curve)
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .help("Click to add a point. Double-click a point, or drag it out, to remove it.")
    }

    private var curve: Curve {
        get { curves[keyPath: channel.keyPath] }
        nonmutating set { curves[keyPath: channel.keyPath] = newValue }
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                var edited = curve
                if draggedIndex == nil {
                    let start = CurveChannel.curvePoint(at: value.startLocation, in: size)
                    let existing = edited.indexOfPoint(near: start, within: Self.grabDistance)
                    pressedExistingPoint = existing != nil
                    draggedIndex = existing ?? edited.insert(start)
                }
                if let draggedIndex {
                    edited.move(at: draggedIndex, to: CurveChannel.curvePoint(at: value.location, in: size))
                }
                curve = edited
            }
            .onEnded { value in
                let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -Self.removalMargin, dy: -Self.removalMargin)
                if let draggedIndex, !bounds.contains(value.location) {
                    var edited = curve
                    edited.remove(at: draggedIndex)
                    curve = edited
                } else if let draggedIndex, pressedExistingPoint, isClick(value) {
                    // The drag wins over a tap gesture here, so the double-click is told by hand.
                    if let lastClick, lastClick.index == draggedIndex, Date().timeIntervalSince(lastClick.date) < Self.doubleClickInterval {
                        discreteEdit {
                            var edited = curve
                            edited.remove(at: draggedIndex)
                            curve = edited
                        }
                        self.lastClick = nil
                    } else {
                        lastClick = (draggedIndex, Date())
                    }
                }
                draggedIndex = nil
            }
    }

    private func isClick(_ value: DragGesture.Value) -> Bool {
        abs(value.translation.width) < Self.clickDistance && abs(value.translation.height) < Self.clickDistance
    }

    /// The tones of the channel being edited; of the three together for the master curve.
    private var histogramBins: [Float]? {
        guard let histogram else { return nil }
        switch channel {
        case .red: return histogram.red
        case .green: return histogram.green
        case .blue: return histogram.blue
        case .rgb: return zip(zip(histogram.red, histogram.green), histogram.blue).map { ($0.0 + $0.1 + $1) / 3 }
        }
    }

    private func path(in size: CGSize) -> Path {
        var path = Path()
        path.addLines(CurveChannel.tracePoints(of: curve, in: size))
        return path
    }

    private func grid(in size: CGSize) -> Path {
        var path = Path()
        for quarter in 1..<4 {
            let offset = CGFloat(quarter) / 4
            path.move(to: CGPoint(x: size.width * offset, y: 0))
            path.addLine(to: CGPoint(x: size.width * offset, y: size.height))
            path.move(to: CGPoint(x: 0, y: size.height * offset))
            path.addLine(to: CGPoint(x: size.width, y: size.height * offset))
        }
        path.move(to: CGPoint(x: 0, y: size.height))
        path.addLine(to: CGPoint(x: size.width, y: 0))
        return path
    }
}
