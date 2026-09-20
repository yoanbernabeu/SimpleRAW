import SwiftUI

extension Binding where Value == Bool {
    /// Whether an optional holds something, for alerts and sheets driven by one: true while
    /// it does, and setting it to false empties it (or does what `onDismiss` says instead).
    init<Wrapped: Sendable>(isPresent optional: Binding<Wrapped?>) {
        self.init(get: { optional.wrappedValue != nil }, set: { if !$0 { optional.wrappedValue = nil } })
    }

    /// The same for an optional that is only read: `onDismiss` is what empties it.
    ///
    /// A `Binding` holds `@Sendable` closures, and these read state of the main actor.
    /// SwiftUI reads and writes a binding while drawing, so on the main actor: said outright
    /// rather than hopped to, which would answer a frame late.
    @MainActor
    init<Wrapped>(
        isPresent value: @escaping @autoclosure @MainActor @Sendable () -> Wrapped?,
        onDismiss: @escaping @MainActor @Sendable () -> Void
    ) {
        self.init(
            get: { MainActor.assumeIsolated { value() != nil } },
            set: { if !$0 { MainActor.assumeIsolated(onDismiss) } }
        )
    }
}
