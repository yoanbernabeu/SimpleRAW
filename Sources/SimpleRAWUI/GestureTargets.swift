import SwiftUI

/// Where the views a script wants to press are, in the window.
///
/// A scripted gesture cannot ask SwiftUI where anything is: there is no view hierarchy to
/// walk and no identifier to look one up by. So the views that a script drives say so
/// themselves, once, as they lay out — a name and the frame that goes with it. Nothing reads
/// this but `GestureScript`, and nothing records into it unless the app was started with
/// `-gestures`.
@MainActor
final class GestureTargets {
    static let shared = GestureTargets()

    /// Off unless the app is being driven: an app nobody is scripting keeps no frames at all.
    var isRecording = false

    private(set) var frames: [String: CGRect] = [:]

    func record(_ name: String, _ frame: CGRect) {
        guard isRecording else { return }
        frames[name] = frame
    }

    func frame(of name: String) -> CGRect? { frames[name] }

    /// What a script can press, for the message that says a name was not one of them.
    var names: [String] { frames.keys.sorted() }

    /// The canvas: the picture and every tool overlay drawn over it.
    static let canvas = "canvas"
    /// A slider, by the name the interface gives it.
    static func slider(_ title: String) -> String { "slider:\(title)" }
    /// The square the tone curve is drawn in.
    static let curve = "curve"
    /// The colour grading wheel of whichever range is showing.
    static let wheel = "wheel"
}

extension View {
    /// Says where this view is, so that a scripted gesture can find it. It costs one geometry
    /// reading, and nothing at all when no script is running.
    func gestureTarget(_ name: String) -> some View {
        onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
            GestureTargets.shared.record(name, frame)
        }
    }
}
