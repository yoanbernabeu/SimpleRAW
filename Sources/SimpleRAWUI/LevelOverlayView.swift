import RawEngine
import SwiftUI

/// Drawing the level: a line is dragged along something that ought to be level, and the
/// picture is turned when it is let go. The line is only ever on screen while it is drawn —
/// it is a gesture, not a setting.
struct LevelOverlayView: View {
    @Bindable var session: DevelopSession
    @State private var line: (start: CGPoint, end: CGPoint)?

    var body: some View {
        ZStack {
            if let line {
                Path {
                    $0.move(to: line.start)
                    $0.addLine(to: line.end)
                }
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                // The ends, so that it can be aimed at a corner of a window frame.
                ForEach([line.start, line.end], id: \.self) { end in
                    Circle().fill(Theme.accent).frame(width: 6, height: 6).position(end)
                }
            }
            Text("Drag along something that should be level — a horizon, the edge of a door.")
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.thinMaterial, in: Capsule())
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 18)
                .opacity(line == nil ? 1 : 0)
        }
        // The whole canvas, said outright: a stack takes the size of what is in it, and what
        // is in this one is a line that is not drawn yet and a sentence. Without this the
        // tool only answered a drag that began within the width of that sentence — which is
        // how it shipped, and what pressing the mouse for real is for.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .pointerStyle(.rectSelection)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { line = (start: $0.startLocation, end: $0.location) }
                .onEnded { drag in
                    line = nil
                    session.level(from: drag.startLocation, to: drag.location)
                }
        )
    }
}
