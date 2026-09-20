import AppKit
import Catalog
import Foundation

/// What a key can ask of the app.
public enum AppCommand: Equatable, Sendable {
    case setTool(Tool)
    /// Give up what the tool was doing, and leave it.
    case cancelTool
    case toggleOriginal
    case toggleZoom
    case toggleClipping
    /// Keeps the red veil of the selected mask on, or lets it go again.
    case toggleMaskOverlay
    /// In the crop tool: the ratio turns from landscape to portrait.
    case turnCropAspect
    case showLibrary
    case rate(Int, advance: Bool)
    case flag(Flag, advance: Bool)
    /// `nil` takes the label off.
    case label(ColorLabel?)
    /// The library: arrows, Return, ⌘A, and the loupe (Space, Escape).
    case moveSelection(LibrarySession.MoveDirection)
    case openSelection
    case selectAll
    case toggleLoupe
    case closeLoupe
    /// Two photos side by side, to choose between them.
    case toggleComparing
}

/// Single keys drive the app, as in every photo tool. They are decided here and nowhere else:
/// a pure function, so that every rule is tested, and one that steps aside while text is
/// being typed. Scattered `keyboardShortcut`s without a modifier did not: renaming a layer
/// "Ciel" opened the crop tool.
enum KeyRouter {
    struct Key: Equatable, Sendable {
        let characters: String
        let isShiftDown: Bool
    }

    private static let escape = "\u{1B}"
    private static let labels: [String: ColorLabel] = ["6": .red, "7": .yellow, "8": .green, "9": .blue]

    /// The key that sets a label, for menus to show. Purple has none, as in other photo tools.
    static func key(for label: ColorLabel) -> String? {
        labels.first { $0.value == label }?.key
    }

    static func command(for key: Key, mode: AppSession.Mode, tool: Tool, isTypingText: Bool) -> AppCommand? {
        guard !isTypingText else { return nil }
        let character = key.characters.lowercased()

        // While cropping, X turns the ratio, as in every photo tool: nobody rejects a photo
        // in the middle of framing it.
        if mode == .develop, tool == .crop, character == "x" { return .turnCropAspect }

        // The level is a gesture inside the crop tool: L picks it up and puts it down, and
        // Escape puts it down rather than giving up the whole framing.
        if mode == .develop, tool == .crop || tool == .level {
            if character == "l" { return .setTool(tool == .level ? .crop : .level) }
            if tool == .level, character == escape { return .setTool(.crop) }
        }

        // Culling keys are the same everywhere: in the grid, and on the picture itself.
        if let rating = Int(character), (0...5).contains(rating), character.count == 1 {
            return .rate(rating, advance: key.isShiftDown)
        }
        if let label = labels[character] { return .label(label) }
        switch character {
        case "p": return .flag(.picked, advance: key.isShiftDown)
        case "x": return .flag(.rejected, advance: key.isShiftDown)
        case "u": return .flag(.none, advance: key.isShiftDown)
        default: break
        }

        // C compares two photos in the grid, and is the crop tool on a picture.
        guard mode == .develop else { return character == "c" ? .toggleComparing : nil }
        switch character {
        case "c": return .setTool(tool == .crop ? .none : .crop)
        case "m": return .setTool(tool == .local ? .none : .local)
        case "s": return .setTool(tool == .spots ? .none : .spots)
        case "w": return .setTool(tool == .whiteBalance ? .none : .whiteBalance)
        case escape: return tool == .none ? nil : (tool == .crop ? .cancelTool : .setTool(.none))
        case "g": return .showLibrary
        // `\` is the convention; B is what a keyboard without a direct backslash can reach.
        case "\\", "b": return .toggleOriginal
        // Cropping needs the whole frame; everything else is worked on at 100 % too.
        case "z": return tool == .crop ? nil : .toggleZoom
        case "j": return .toggleClipping
        case "o": return tool == .local ? .toggleMaskOverlay : nil
        default: return nil
        }
    }

    /// Whether the keyboard is being used to type text, in which case keys are not commands.
    @MainActor
    static var isTypingText: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }
}
