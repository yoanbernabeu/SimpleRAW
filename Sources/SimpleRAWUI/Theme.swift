import CoreImage
import SwiftUI

/// The few visual decisions of the app, in one place, so that every screen agrees.
enum Theme {
    /// The one accent of the app: a warm amber, legible on dark, that does not fight the photo.
    static let accent = Color(red: 1.0, green: 0.66, blue: 0.22)
    /// Warnings and erasing: close to the accent, distinct from it.
    static let warning = Color(red: 1.0, green: 0.45, blue: 0.25)
    /// Behind the photo: neutral and dark, so that it never tints what the eye judges.
    static let canvas = Color(white: canvasWhite)
    /// The same, for the Metal view, which paints it itself.
    static let canvasColor = CIColor(red: canvasWhite, green: canvasWhite, blue: canvasWhite)
    private static let canvasWhite = 0.07
    static let panel = Color(white: 0.115)
    static let control = Color.white.opacity(0.07)
    static let hairline = Color.white.opacity(0.08)
    /// Behind a thumbnail: a step above the canvas; another when hovered, another when selected.
    static let tile = Color(white: 0.14)
    static let tileHovered = Color(white: 0.17)
    static let tileSelected = Color(white: 0.20)
    /// Color labels: muted enough to sit next to a photo, distinct enough to be told apart.
    static let labelRed = Color(red: 0.93, green: 0.33, blue: 0.31)
    static let labelYellow = Color(red: 0.96, green: 0.80, blue: 0.27)
    static let labelGreen = Color(red: 0.36, green: 0.78, blue: 0.45)
    static let labelBlue = Color(red: 0.33, green: 0.60, blue: 0.96)
    static let labelPurple = Color(red: 0.69, green: 0.45, blue: 0.92)
    /// A mark laid over a picture: dark enough to read on a bright sky.
    static let badge = Color.black.opacity(0.55)
    static let onBadge = Color.white
    /// The dashes of a drop zone at rest: a hairline would not read as an invitation.
    static let dropZone = Color.white.opacity(0.22)
    /// The smallest comfortable target for a pointer.
    static let minimumTarget: CGFloat = 24
    /// The empty part of a slider: visible enough to show how far the knob can go.
    static let sliderTrack = Color.white.opacity(0.16)
    static let sliderTick = Color.white.opacity(0.28)
    static let knob = Color(white: 0.92)
    /// What the two ends of the white balance sliders mean.
    static let temperatureTrack = [Color(red: 0.25, green: 0.5, blue: 1), Color(red: 1, green: 0.85, blue: 0.3)]
    static let tintTrack = [Color(red: 0.3, green: 0.85, blue: 0.35), Color(red: 0.95, green: 0.3, blue: 0.85)]

    /// Text of the inspector: labels, and the smaller print under them. Nothing goes below 10 pt.
    static let labelSize: CGFloat = 11.5
    static let smallSize: CGFloat = 10.5

    static let panelWidth: CGFloat = 292
    /// The Settings window: one width, and a height per tab.
    static let settingsWidth: CGFloat = 560
    static let librarySettingsHeight: CGFloat = 250
    static let backupSettingsHeight: CGFloat = 680
    static let cornerRadius: CGFloat = 7
}

extension View {
    /// Small caps used for every section title, in the inspector and elsewhere.
    func sectionTitleStyle() -> some View {
        font(.system(size: 10.5, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
    }
}
