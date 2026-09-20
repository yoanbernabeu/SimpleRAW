import SwiftUI

/// How a panel makes a change that is a step of its own in the undo history: a reset button,
/// a checkbox, a double-click. Panels only know a binding to the settings, not the session:
/// the develop view hands them `DevelopSession.perform` through the environment.
///
/// Continuous gestures need nothing: they become a step when they settle.
struct DiscreteEdit {
    private let perform: @MainActor (() -> Void) -> Void

    /// Outside of a develop view (previews, tests of a panel) the change is simply made.
    init(_ perform: @escaping @MainActor (() -> Void) -> Void = { $0() }) {
        self.perform = perform
    }

    @MainActor
    func callAsFunction(_ change: () -> Void) {
        perform(change)
    }
}

extension EnvironmentValues {
    @Entry var discreteEdit = DiscreteEdit()
}
