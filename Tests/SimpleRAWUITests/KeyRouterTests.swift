import Foundation
import Testing
@testable import SimpleRAWUI

/// Single keys drive the app, as in every photo tool. They are routed in one place, and that
/// place steps aside while text is being typed.
@Suite struct KeyRouterTests {
    private func command(_ characters: String, mode: AppSession.Mode = .develop, tool: Tool = .none, shift: Bool = false, typing: Bool = false) -> AppCommand? {
        KeyRouter.command(for: KeyRouter.Key(characters: characters, isShiftDown: shift), mode: mode, tool: tool, isTypingText: typing)
    }

    /// Regression: renaming a layer "Ciel" opened the crop tool, and a "g" went back to the library.
    @Test(arguments: ["c", "m", "s", "z", "g", "b", "0", "5", "p", "x", "u", "\u{1B}"])
    func nothingHappensWhileTextIsBeingTyped(characters: String) {
        #expect(command(characters, typing: true) == nil)
        #expect(command(characters, mode: .library, typing: true) == nil)
    }

    @Test func toolsToggleInDevelop() {
        #expect(command("c") == .setTool(.crop))
        #expect(command("c", tool: .crop) == .setTool(.none))
        #expect(command("m") == .setTool(.local) && command("s") == .setTool(.spots))
        #expect(command("C") == .setTool(.crop))
    }

    @Test func theEyedropperHasItsKey() {
        #expect(command("w") == .setTool(.whiteBalance))
        #expect(command("w", tool: .whiteBalance) == .setTool(.none))
        #expect(command("\u{1B}", tool: .whiteBalance) == .setTool(.none))
    }

    /// Escape gives up what a tool was doing; it must never validate it.
    @Test func escapeLeavesATool() {
        #expect(command("\u{1B}", tool: .crop) == .cancelTool)
        #expect(command("\u{1B}", tool: .local) == .setTool(.none))
        #expect(command("\u{1B}") == nil)
    }

    /// The level is a gesture inside the crop tool: L picks it up and puts it down, Escape
    /// puts it down rather than giving up the framing, and it is not offered anywhere else.
    @Test func theLevelLivesInsideTheCropTool() {
        #expect(command("l", tool: .crop) == .setTool(.level))
        #expect(command("l", tool: .level) == .setTool(.crop))
        #expect(command("\u{1B}", tool: .level) == .setTool(.crop))
        #expect(command("l") == nil && command("l", tool: .local) == nil)
        // The keys of the crop tool still work while the level is out.
        #expect(command("x", tool: .level) == .flag(.rejected, advance: false))
    }

    /// `\` is the convention, but it takes three keys on a French keyboard: B does the same.
    @Test func beforeAfterHasAKeyEveryKeyboardCanReach() {
        #expect(command("\\") == .toggleOriginal && command("b") == .toggleOriginal)
    }

    @Test func clippingHasItsKey() {
        #expect(command("j") == .toggleClipping)
        #expect(command("j", mode: .library) == nil)
    }

    @Test func zoomAndNavigation() {
        #expect(command("z") == .toggleZoom)
        #expect(command("g") == .showLibrary)
        #expect(command("g", mode: .library) == nil)
    }

    /// Culling without leaving the picture: the same keys as in the grid.
    @Test func ratingAndFlaggingWorkInBothModes() {
        for mode in [AppSession.Mode.library, .develop] {
            #expect(command("4", mode: mode) == .rate(4, advance: false))
            #expect(command("0", mode: mode) == .rate(0, advance: false))
            #expect(command("p", mode: mode) == .flag(.picked, advance: false))
            #expect(command("x", mode: mode) == .flag(.rejected, advance: false))
            #expect(command("u", mode: mode) == .flag(.none, advance: false))
            #expect(command("7", mode: mode) == .label(.yellow))
        }
    }

    /// With shift, the next photo comes up by itself: one keystroke per picture.
    @Test func shiftAdvancesToTheNextPhoto() {
        #expect(command("P", shift: true) == .flag(.picked, advance: true))
        #expect(command("X", shift: true) == .flag(.rejected, advance: true))
    }

    @Test func toolsDoNotFireWhileAnotherToolNeedsTheKeys() {
        // Cropping needs the whole frame: a stray "z" must not zoom out of it. Rating keys still work.
        #expect(command("z", tool: .crop) == nil)
        #expect(command("3", tool: .local) == .rate(3, advance: false))
    }

    /// A dust spot or the edge of a face is worked on at 100 %, not on the fitted picture.
    @Test func zoomingWorksInsideTheLocalTools() {
        for tool in [Tool.local, .spots, .whiteBalance] {
            #expect(command("z", tool: tool) == .toggleZoom)
        }
    }

    @Test func theMaskVeilHasAKeyInTheMaskTool() {
        #expect(command("o", tool: .local) == .toggleMaskOverlay)
        #expect(command("o") == nil)
    }

    @Test func xTurnsTheRatioWhileCroppingAndRejectsOtherwise() {
        #expect(command("x", tool: .crop) == .turnCropAspect)
        #expect(command("x") == .flag(.rejected, advance: false))
        #expect(command("x", mode: .library) == .flag(.rejected, advance: false))
    }

    @Test func unknownKeysAreLeftToTheSystem() {
        #expect(command("q") == nil && command("") == nil)
    }
}
