import SwiftUI
import Testing
@testable import SimpleRAWUI

@MainActor
@Suite struct BindingTests {
    @Test func anOptionalIsPresentedWhileItHoldsSomething() {
        var name: String? = "Street"
        let optional = Binding(get: { name }, set: { name = $0 })
        let isPresented = Binding(isPresent: optional)
        #expect(isPresented.wrappedValue)
        isPresented.wrappedValue = true
        #expect(name == "Street")
        isPresented.wrappedValue = false
        #expect(name == nil && !isPresented.wrappedValue)
    }

    @Test func aReadOnlyOptionalIsDismissedByItsOwner() {
        var message: String? = "Disk full"
        let isPresented = Binding(isPresent: message, onDismiss: { message = nil })
        #expect(isPresented.wrappedValue)
        isPresented.wrappedValue = false
        #expect(message == nil && !isPresented.wrappedValue)
    }
}
