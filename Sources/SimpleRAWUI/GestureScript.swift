import AppKit
import RawEngine
import SwiftUI

/// Presses the app's own buttons, with real mouse events, and says whether anything answered.
///
/// Everything this app does is tested at the level of the session, and none of it says whether
/// a *gesture* arrives: whether the press reaches the slider or a view above it, whether a
/// crop handle sits where the picture is, whether a tool that was just switched on takes the
/// drag. That gap was never covered, and it is the one place where a hundred green tests can
/// sit above an app nobody can use.
///
/// So the app drives itself. `NSEvent`s are posted into its own window, a frame apart, and
/// what the session holds afterwards is compared with what the gesture asks for. Nothing
/// outside the process is touched and no permission is needed, which is the whole reason for
/// doing it from the inside rather than with a robot.
///
/// `SimpleRAWApp -file photo.dng -gestures all`; `scripts/exercise-gestures.sh` runs it.
@MainActor
public enum GestureScript {
    /// Turns the recording of view frames on, before the window lays out. Called from the
    /// delegate: a target missed because the view was measured too early would look exactly
    /// like a gesture that does not work.
    public static func prepare(_ arguments: LaunchArguments = LaunchArguments()) {
        GestureTargets.shared.isRecording = arguments.value(for: "gestures") != nil
    }

    /// Runs the gestures asked for, prints what each one did, and leaves — with a failing
    /// status when one of them changed nothing.
    public static func begin(_ arguments: LaunchArguments = LaunchArguments(), on app: AppSession) {
        guard let selection = arguments.value(for: "gestures") else { return }
        Task { @MainActor in
            let failures = await run(selection, on: app)
            exit(failures == 0 ? 0 : 1)
        }
    }

    // MARK: - Running

    private static func run(_ selection: String, on app: AppSession) async -> Int {
        let chosen = selection == "all" ? all : all.filter { $0.name == selection }
        guard !chosen.isEmpty else {
            print("No gesture is called \(selection). There are: \(all.map(\.name).joined(separator: ", "))")
            return 1
        }
        guard let window = await windowOnScreen() else {
            print("The window never came up.")
            return 1
        }
        guard await photoIsOpen(app) else {
            print("No photo is open: a scripted gesture needs one (-file).")
            return 1
        }
        let mouse = Mouse(window: window)
        print("\(mouse.description)\n")
        // A window that is not the one being talked to swallows the press that would make it
        // so, and every gesture then reads as dead. Whether a process started from a terminal
        // may come to the front is the system's call, not ours — so the run says it could not
        // ask rather than blaming twelve tools for it.
        guard window.isKeyWindow else {
            print("""
                Inconclusive: the app never came to the front, and a window nobody is talking \
                to answers no gesture. Run this with the terminal frontmost and nothing else \
                taking focus.
                """)
            return 1
        }
        var failures = 0
        for gesture in chosen {
            // The panel first, then the state, then the tool: the inspector answers a change
            // of what it shows by putting a tool down, so the tool is set last.
            prepareInterface(showing: gesture.shows)
            await pause(.milliseconds(400))
            reset(app)
            gesture.setUp(app)
            // The frames of whatever the setup brought on screen are read on the next pass.
            await pause(.milliseconds(400))
            mouse.forget()
            var complaint: String?
            do {
                try await gesture.play(mouse, app)
                await pause(.milliseconds(250))
                complaint = gesture.check(app)
            } catch {
                complaint = "\(error)"
            }
            if complaint != nil { failures += 1 }
            print("GESTURE \(gesture.name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(complaint.map { "FAILED  \($0)" } ?? "ok")")
            // Only when something is wrong: where the mouse went is the first thing to
            // suspect, and reading it every time would bury the answer.
            if complaint != nil {
                for step in mouse.trail { print("        \(step)") }
                print("        tool \(app.develop.tool), inspector on \(UserDefaults.standard.string(forKey: InspectorLayout.tabKey) ?? "?") showing \(UserDefaults.standard.string(forKey: InspectorLayout.openPanelsKey) ?? "?")")
            }
        }
        print("\n\(chosen.count) gestures, \(failures) of them dead.")
        return failures
    }

    private static func reset(_ app: AppSession) {
        let session = app.develop
        session.tool = .none
        session.isCropping = false
        session.selectedLocalID = nil
        session.adjustments = Adjustments()
    }

    /// Brings one panel into view, whatever the person using this machine last left on screen:
    /// the inspector remembers its tab and its open panel between launches, and a run that
    /// took that memory as it came would press whatever happened to be there.
    private static func prepareInterface(showing panel: InspectorPanel) {
        let tab = InspectorTab.allCases.first { $0.panels.contains(panel) } ?? .light
        UserDefaults.standard.set(true, forKey: DevelopView.showsInspectorKey)
        UserDefaults.standard.set(tab.rawValue, forKey: InspectorLayout.tabKey)
        UserDefaults.standard.set("\(tab.rawValue)=\(panel.title)", forKey: InspectorLayout.openPanelsKey)
    }

    private static func pause(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }

    /// The window of the app, once AppKit has put it up and made it the one being talked to.
    ///
    /// This matters more than it looks: a window that is not key takes no mouse event at all,
    /// and the app then answers every gesture by doing nothing — which reads exactly like
    /// eight broken tools. The app is brought to the front until it is key, and if it never
    /// gets there the run says so rather than blaming the gestures.
    private static func windowOnScreen() async -> NSWindow? {
        for _ in 0..<100 {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }) else {
                await pause(.milliseconds(100))
                continue
            }
            for _ in 0..<40 where !window.isKeyWindow {
                NSRunningApplication.current.activate(options: .activateAllWindows)
                window.makeKeyAndOrderFront(nil)
                await pause(.milliseconds(200))
            }
            return window
        }
        return nil
    }

    private static func photoIsOpen(_ app: AppSession) async -> Bool {
        for _ in 0..<150 {
            if app.develop.info != nil { return true }
            await pause(.milliseconds(100))
        }
        return false
    }

    // MARK: - The gestures

    /// One thing a hand does, and what the app is supposed to hold afterwards.
    struct ScriptedGesture {
        let name: String
        /// The panel the gesture needs in view. A canvas gesture takes the default: something
        /// has to be showing, and a slider panel is the quietest thing to have there.
        var shows = InspectorPanel.sliders(.light)
        /// Puts the app in the state the gesture starts from.
        var setUp: @MainActor (AppSession) -> Void = { _ in }
        /// Presses, moves, lets go.
        let play: @MainActor (Mouse, AppSession) async throws -> Void
        /// Nil when the app did what the gesture asks; otherwise what it did instead.
        let check: @MainActor (AppSession) -> String?
    }

    static let all: [ScriptedGesture] = [
        ScriptedGesture(
            name: "drag a global slider",
            play: { mouse, _ in
                try await mouse.drag(GestureTargets.slider("Exposure"), from: .init(x: 0.5, y: 0.5), to: .init(x: 0.85, y: 0.5))
            },
            check: { app in
                let exposure = app.develop.adjustments.exposure
                // 0.85 of a track running from -5 to 5: around +3.5, and certainly positive.
                return exposure > 1 ? nil : "the exposure slider sits at \(exposure)"
            }
        ),
        ScriptedGesture(
            name: "double-click a slider to reset",
            setUp: { $0.develop.adjustments.exposure = 2 },
            play: { mouse, _ in
                try await mouse.click(GestureTargets.slider("Exposure"), at: .init(x: 0.7, y: 0.5), times: 2)
            },
            check: { app in
                let exposure = app.develop.adjustments.exposure
                return exposure == 0 ? nil : "the exposure slider sits at \(exposure), not back at zero"
            }
        ),
        ScriptedGesture(
            name: "drag a crop edge",
            setUp: { $0.develop.isCropping = true },
            play: { mouse, app in
                try await mouse.drag(in: pictureFrame(mouse, app), from: .init(x: 0, y: 0.5), to: .init(x: 0.25, y: 0.5))
            },
            check: { app in
                guard let crop = app.develop.adjustments.geometry.crop else { return "the crop is still the whole frame" }
                return crop.x > 0.1 ? nil : "the left edge is at \(crop.x)"
            }
        ),
        ScriptedGesture(
            name: "draw a level line",
            setUp: { $0.develop.tool = .level },
            play: { mouse, _ in
                try await mouse.drag(GestureTargets.canvas, from: .init(x: 0.3, y: 0.55), to: .init(x: 0.7, y: 0.45))
            },
            check: { app in
                let angle = app.develop.adjustments.geometry.straighten
                return angle != 0 ? nil : "the picture was not turned"
            }
        ),
        ScriptedGesture(
            name: "paint a brush stroke",
            setUp: { $0.develop.addLocal(.brush) },
            play: { mouse, _ in
                try await mouse.drag(GestureTargets.canvas, from: .init(x: 0.35, y: 0.45), to: .init(x: 0.6, y: 0.6), steps: 20)
            },
            check: { app in
                guard case .brush(let mask)? = app.develop.adjustments.locals.first?.mask else { return "there is no brush layer" }
                guard let stroke = mask.strokes.first else { return "nothing was painted" }
                return stroke.points.count > 2 ? nil : "the stroke holds \(stroke.points.count) points"
            }
        ),
        ScriptedGesture(
            name: "draw a healing line",
            setUp: { $0.develop.tool = .spots },
            play: { mouse, _ in
                try await mouse.drag(GestureTargets.canvas, from: .init(x: 0.4, y: 0.4), to: .init(x: 0.6, y: 0.5), steps: 20)
            },
            check: { app in
                guard let spot = app.develop.adjustments.spots.first else { return "no spot was put down" }
                return spot.isLine ? nil : "a spot was put down, but the drag drew no line"
            }
        ),
        ScriptedGesture(
            name: "drag a gradient mask",
            setUp: { $0.develop.addLocal(.linear) },
            play: { mouse, app in
                guard case .linear(let mask)? = app.develop.adjustments.locals.first?.mask else { return }
                // The handle is where the mask says it is, in the frame the tools display.
                try await mouse.drag(
                    in: pictureFrame(mouse, app),
                    from: .init(x: mask.start.x, y: mask.start.y), to: .init(x: mask.start.x, y: mask.start.y + 0.2)
                )
            },
            check: { app in
                guard case .linear(let mask)? = app.develop.adjustments.locals.first?.mask else { return "there is no gradient" }
                return mask.start.y > 0.3 ? nil : "the top of the gradient is still at \(mask.start.y)"
            }
        ),
        ScriptedGesture(
            name: "drag a radial mask",
            setUp: { $0.develop.addLocal(.radial) },
            play: { mouse, app in
                try await mouse.drag(in: pictureFrame(mouse, app), from: .init(x: 0.5, y: 0.5), to: .init(x: 0.3, y: 0.35))
            },
            check: { app in
                guard case .radial(let mask)? = app.develop.adjustments.locals.first?.mask else { return "there is no radial mask" }
                return mask.center.x < 0.45 ? nil : "the mask is still centred at \(mask.center.x)"
            }
        ),
        ScriptedGesture(
            name: "pick a white balance",
            shows: .sliders(.color),
            setUp: { $0.develop.tool = .whiteBalance },
            play: { mouse, app in
                try await mouse.click(in: pictureFrame(mouse, app), at: .init(x: 0.45, y: 0.4))
            },
            check: { app in
                // The eyedropper puts itself down once it has answered: that is the tell.
                app.develop.tool == .none ? nil : "the eyedropper took no colour"
            }
        ),
        ScriptedGesture(
            name: "drag a curve point",
            shows: .curve,
            setUp: { $0.develop.adjustments.curves.rgb.insert(.init(x: 0.5, y: 0.5)) },
            play: { mouse, _ in
                // Up is lighter, and up is towards the top of the square.
                try await mouse.drag(GestureTargets.curve, from: .init(x: 0.5, y: 0.5), to: .init(x: 0.5, y: 0.3))
            },
            check: { app in
                app.develop.adjustments.curves.rgb.isIdentity ? "the curve is still a straight line" : nil
            }
        ),
        ScriptedGesture(
            name: "drag a colour wheel",
            shows: .grading,
            play: { mouse, _ in
                try await mouse.drag(GestureTargets.wheel, from: .init(x: 0.5, y: 0.5), to: .init(x: 0.85, y: 0.5))
            },
            check: { app in
                app.develop.adjustments.grading.isNeutral ? "nothing was tinted" : nil
            }
        ),
        ScriptedGesture(
            name: "pan at 100 %",
            setUp: { $0.develop.zoomToActualSize(at: .init(x: 0.5, y: 0.5)) },
            play: { mouse, _ in
                try await mouse.drag(GestureTargets.canvas, from: .init(x: 0.5, y: 0.5), to: .init(x: 0.35, y: 0.4))
            },
            check: { app in
                guard case .actualSize(let center) = app.develop.zoom else { return "the view went back to fitting" }
                return center.x != 0.5 || center.y != 0.5 ? nil : "the picture did not move under the pointer"
            }
        ),
    ]

    /// The picture inside the canvas, in the window's own terms: where the crop handles are.
    /// This is the view's own arithmetic run twice, which proves nothing about `FitGeometry` —
    /// what it proves is that the press reaches the overlay at all, which is the question.
    private static func pictureFrame(_ mouse: Mouse, _ app: AppSession) throws -> CGRect {
        let canvas = try mouse.frame(of: GestureTargets.canvas)
        guard let size = app.develop.cropFrameSize else { throw Mouse.NoSuchTarget(name: "the picture", known: []) }
        return FitGeometry.frame(forAspect: size.width / size.height, in: canvas.size, padding: FitGeometry.padding)
            .offsetBy(dx: canvas.minX, dy: canvas.minY)
    }
}

/// Posts mouse events into the app's own window, as a hand would give them.
@MainActor
final class Mouse {
    let window: NSWindow

    init(window: NSWindow) {
        self.window = window
    }

    /// Where the mouse actually went, in the window's own terms. Printed when a gesture
    /// changes nothing: "it pressed at (812, 44)" is the difference between a broken gesture
    /// and a script pressing the wrong place, and no screenshot tells them apart faster.
    private(set) var trail: [String] = []

    func forget() { trail = [] }

    /// Whether the app is in a state to be pressed at all. A window that is not key takes no
    /// gesture, and an app that is not the active one has no key window: the first thing to
    /// look at when everything comes back dead.
    var description: String {
        "window \(Int(window.frame.width))x\(Int(window.frame.height)), content \(Int(contentHeight)) tall"
            + ", key: \(window.isKeyWindow ? "yes" : "no"), app active: \(NSApp.isActive ? "yes" : "no")"
    }

    /// SwiftUI measures from the top left of the window, an `NSEvent` from the bottom left of
    /// the content view: everything is flipped around this.
    private var contentHeight: CGFloat { window.contentView?.bounds.height ?? window.frame.height }

    /// A frame between events. The run loop has to dispatch one before the next arrives, and
    /// SwiftUI only reads a drag as a drag when its points come in apart in time.
    private static let frameInterval = Duration.milliseconds(16)
    private var events = 0

    struct NoSuchTarget: Error, CustomStringConvertible {
        let name: String
        let known: [String]

        var description: String {
            "nothing on screen is called \(name)" + (known.isEmpty ? "" : "; the window offers \(known.joined(separator: ", "))")
        }
    }

    func frame(of name: String) throws -> CGRect {
        guard let frame = GestureTargets.shared.frame(of: name) else {
            throw NoSuchTarget(name: name, known: GestureTargets.shared.names)
        }
        return frame
    }

    /// Drags across a named view. `from` and `to` are places inside it: `(0.5, 0.5)` its
    /// middle, `(0, 0.5)` its left edge.
    func drag(
        _ name: String, from: CGPoint, to: CGPoint, steps: Int = 12,
        modifiers: NSEvent.ModifierFlags = []
    ) async throws {
        try await drag(in: frame(of: name), from: from, to: to, steps: steps, modifiers: modifiers)
    }

    func drag(
        in frame: CGRect, from: CGPoint, to: CGPoint, steps: Int = 12,
        modifiers: NSEvent.ModifierFlags = []
    ) async throws {
        let path = MousePath.straight(
            from: MousePath.inWindow(frame, at: from, contentHeight: contentHeight),
            to: MousePath.inWindow(frame, at: to, contentHeight: contentHeight),
            steps: steps
        )
        trail.append("dragged \(Self.place(path[0])) → \(Self.place(path[path.count - 1])) inside \(Self.place(frame))")
        await post(.leftMouseDown, at: path[0], modifiers: modifiers, clickCount: 1)
        for point in path.dropFirst() {
            await post(.leftMouseDragged, at: point, modifiers: modifiers, clickCount: 1)
        }
        await post(.leftMouseUp, at: path[path.count - 1], modifiers: modifiers, clickCount: 1)
    }

    /// Clicks a named view, `times` in a row: two of them make a double-click.
    func click(_ name: String, at share: CGPoint, times: Int = 1) async throws {
        try await click(in: frame(of: name), at: share, times: times)
    }

    func click(in frame: CGRect, at share: CGPoint, times: Int = 1) async throws {
        let point = MousePath.inWindow(frame, at: share, contentHeight: contentHeight)
        trail.append("clicked \(Self.place(point)) \(times) times")
        for count in 1...times {
            await post(.leftMouseDown, at: point, modifiers: [], clickCount: count)
            await post(.leftMouseUp, at: point, modifiers: [], clickCount: count)
        }
    }

    private static func place(_ point: CGPoint) -> String {
        "(\(Int(point.x)), \(Int(point.y)))"
    }

    private static func place(_ rect: CGRect) -> String {
        "\(Int(rect.width))x\(Int(rect.height)) at \(place(rect.origin))"
    }

    private func post(_ type: NSEvent.EventType, at point: CGPoint, modifiers: NSEvent.ModifierFlags, clickCount: Int) async {
        events += 1
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: events, clickCount: clickCount,
            pressure: type == .leftMouseUp ? 0 : 1
        ) else { return }
        // Handed to AppKit rather than queued. Queued, an event waits for the app to be the
        // active one — and whether a process started from a terminal is allowed to come to
        // the front is not ours to decide, so a run would pass or fail by the weather. Sent,
        // it goes through the window's own dispatch, which is the same road every real click
        // takes once it has arrived.
        NSApp.sendEvent(event)
        try? await Task.sleep(for: Mouse.frameInterval)
    }
}
