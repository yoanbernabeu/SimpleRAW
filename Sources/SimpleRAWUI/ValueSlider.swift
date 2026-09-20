import SwiftUI

/// The app's slider: a thin track filled from the neutral position, so that a glance tells
/// both the direction and the size of a setting. Dragging anywhere on the row moves it, and
/// it snaps to the neutral position when close, which makes "back to zero" easy to hit.
/// Holding Option makes the drag four times finer; a double-click resets; with the focus on
/// it, the arrow keys move it by a step (ten with Shift). The arithmetic is `SliderGeometry`.
struct ValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let neutral: Double
    var step: Double = 1
    /// What VoiceOver calls it.
    var title = ""
    /// Colors laid under the track when its two ends mean something: cooler to warmer.
    var track: [Color] = []
    var onReset: (() -> Void)?

    @State private var dragStart: Double?
    @State private var lastClick = Date.distantPast
    @FocusState private var isFocused: Bool

    private static let knobSize: CGFloat = 11
    private static let fineSensitivity = 0.25
    private static let doubleClickInterval: TimeInterval = 0.3
    /// A press that moves less than this is a click, not a drag.
    private static let clickDistance: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - Self.knobSize, 1)
            let position = { (v: Double) in Self.knobSize / 2 + width * CGFloat(SliderGeometry.share(of: v, in: range)) }
            let (current, origin) = (position(value), position(neutral))
            ZStack(alignment: .leading) {
                trackShape.frame(height: 3)
                Capsule().fill(Theme.accent.opacity(0.9))
                    .frame(width: abs(current - origin), height: 3)
                    .offset(x: min(current, origin))
                // Where neutral is: no way to tell, otherwise, for a slider that starts mid-track.
                Rectangle().fill(Theme.sliderTick)
                    .frame(width: 1, height: 7)
                    .offset(x: origin - 0.5)
                Circle()
                    .fill(Theme.knob)
                    .frame(width: Self.knobSize, height: Self.knobSize)
                    .shadow(color: .black.opacity(0.4), radius: 1.5, y: 0.5)
                    .overlay(Circle().strokeBorder(Theme.accent, lineWidth: isFocused ? 1.5 : 0))
                    .offset(x: current - Self.knobSize / 2)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(drag(trackWidth: width))
        }
        .frame(height: 16)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            let steps: Double = (press.key == .leftArrow ? -1 : 1) * (press.modifiers.contains(.shift) ? 10 : 1)
            value = SliderGeometry.nudged(value, bySteps: steps, range: range, step: step)
            return .handled
        }
        .accessibilityRepresentation {
            Slider(value: $value, in: range, step: step) { Text(title) }
        }
        .gestureTarget(GestureTargets.slider(title))
    }

    @ViewBuilder
    private var trackShape: some View {
        if track.isEmpty {
            Capsule().fill(Theme.sliderTrack)
        } else {
            Capsule().fill(LinearGradient(colors: track, startPoint: .leading, endPoint: .trailing)).opacity(0.45)
        }
    }

    private func drag(trackWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                isFocused = true
                let start = dragStart ?? value
                dragStart = start
                if NSEvent.modifierFlags.contains(.option) {
                    value = SliderGeometry.value(
                        from: start, draggedByShare: Double(drag.translation.width / trackWidth),
                        range: range, step: step, sensitivity: Self.fineSensitivity
                    )
                } else {
                    let share = Double((drag.location.x - Self.knobSize / 2) / trackWidth)
                    value = SliderGeometry.value(atShare: share, range: range, neutral: neutral, step: step)
                }
            }
            .onEnded { drag in
                dragStart = nil
                let isClick = abs(drag.translation.width) < Self.clickDistance && abs(drag.translation.height) < Self.clickDistance
                guard isClick else { return lastClick = .distantPast }
                // The second click of a double-click lands here too: the drag wins over a tap
                // gesture on the track, so the double-click is told apart by hand.
                if Date().timeIntervalSince(lastClick) < Self.doubleClickInterval {
                    onReset?()
                    lastClick = .distantPast
                } else {
                    lastClick = Date()
                }
            }
    }
}
