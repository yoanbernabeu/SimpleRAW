import SwiftUI

/// The keys of the library that are not single letters or digits, which `KeyRouter` handles
/// everywhere: arrows, Return, Space, Escape and ⌘A. A pure function, so that every rule is
/// tested; the grid and the loupe only hand their key presses to it.
enum LibraryKeyMap {
    static func command(
        key: KeyEquivalent, characters: String, modifiers: EventModifiers, isLoupeOpen: Bool, isComparing: Bool = false
    ) -> AppCommand? {
        // Arrow keys arrive with modifiers of their own (the numeric pad, the function flag):
        // only the ones a shortcut is made of are looked at.
        let modifiers = modifiers.intersection([.command, .shift, .option, .control])
        if modifiers == .command {
            // One or two photos are on screen: selecting them all would rate them all.
            return characters.lowercased() == "a" && !isLoupeOpen && !isComparing ? .selectAll : nil
        }
        guard modifiers.isEmpty else { return nil }
        switch key {
        case .leftArrow: return .moveSelection(.left)
        case .rightArrow: return .moveSelection(.right)
        case .upArrow: return .moveSelection(.up)
        case .downArrow: return .moveSelection(.down)
        case .return: return .openSelection
        case .space: return .toggleLoupe
        // Escape leaves whichever of the two is on screen; both go back to the grid.
        case .escape: return isLoupeOpen || isComparing ? .closeLoupe : nil
        default: return nil
        }
    }
}

extension AppSession {
    /// What `onKeyPress` of the grid and of the loupe both do.
    func handle(_ press: KeyPress) -> KeyPress.Result {
        guard let command = LibraryKeyMap.command(
            key: press.key, characters: press.characters, modifiers: press.modifiers,
            isLoupeOpen: library.isLoupeOpen, isComparing: library.isComparing
        ) else { return .ignored }
        perform(command)
        return .handled
    }
}
