import RawEngine
import SwiftUI

/// Where a tint sits on its wheel: angle is hue (red on the right, turning counter-clockwise),
/// distance from the center is saturation.
enum ColorWheelGeometry {
    static func wheel(at location: CGPoint, in size: CGSize) -> (hue: Double, saturation: Double) {
        let radius = min(size.width, size.height) / 2
        let dx = location.x - size.width / 2
        let dy = size.height / 2 - location.y  // views have y down
        var hue = atan2(dy, dx) * 180 / .pi
        if hue < 0 { hue += 360 }
        return (hue, min(1, hypot(dx, dy) / radius) * 100)
    }

    static func location(of wheel: ColorWheel, in size: CGSize) -> CGPoint {
        let radius = min(size.width, size.height) / 2 * wheel.saturation / 100
        let angle = wheel.hue * .pi / 180
        return CGPoint(x: size.width / 2 + radius * cos(angle), y: size.height / 2 - radius * sin(angle))
    }
}

/// Color grading: one wheel at a time, its luminance, and the balance between ranges.
struct ColorGradingPanelView: View {
    @Binding var adjustments: Adjustments
    let context: SliderContext
    @State private var range = TonalRange.shadows

    var body: some View {
        VStack(spacing: 10) {
            Picker("Range", selection: $range) {
                ForEach(TonalRange.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ColorWheelControl(wheel: $adjustments.grading[range])
                .frame(width: 150, height: 150)
                .gestureTarget(GestureTargets.wheel)
                .help("Drag to tint, double-click to reset")

            ForEach(SliderSpec.grading(range: range) + SliderSpec.all(in: .grading)) { spec in
                SliderRow(spec: spec, adjustments: $adjustments, context: context)
            }
        }
    }
}

private struct ColorWheelControl: View {
    @Binding var wheel: ColorWheel

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // SwiftUI sweeps gradients clockwise; hues turn the other way, hence the reversal.
                Circle().fill(AngularGradient(colors: Self.hues.reversed(), center: .center))
                Circle().fill(RadialGradient(colors: [.gray, .gray.opacity(0)], center: .center, startRadius: 0, endRadius: geometry.size.width / 2))
                Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1)
                Circle()
                    .fill(.white)
                    .stroke(.black.opacity(0.6), lineWidth: 1)
                    .frame(width: 10, height: 10)
                    .position(ColorWheelGeometry.location(of: wheel, in: geometry.size))
            }
            .opacity(0.9)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let picked = ColorWheelGeometry.wheel(at: value.location, in: geometry.size)
                    wheel.hue = picked.hue
                    wheel.saturation = picked.saturation
                }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { wheel = ColorWheel(luminance: wheel.luminance) }
            )
        }
    }

    private static let hues = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
        Color(hue: $0, saturation: 0.85, brightness: 0.9)
    }
}
