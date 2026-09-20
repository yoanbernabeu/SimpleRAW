import RawEngine
import SwiftUI

/// The HSL panel: pick a color band, then adjust its hue, saturation and luminance.
struct HSLPanelView: View {
    @Binding var adjustments: Adjustments
    let context: SliderContext
    @State private var band = ColorBandName.red

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(ColorBandName.allCases, id: \.self) { candidate in
                    Button { band = candidate } label: { swatch(for: candidate) }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .help(candidate.rawValue.capitalized)
                        .accessibilityLabel(candidate.rawValue.capitalized)
                }
            }
            ForEach(SliderSpec.hsl(band: band)) { spec in
                SliderRow(spec: spec, adjustments: $adjustments, context: context)
            }
        }
    }

    private func swatch(for candidate: ColorBandName) -> some View {
        ZStack {
            Circle()
                .fill(candidate.displayColor)
                .frame(width: 16, height: 16)
            Circle()
                .strokeBorder(.white, lineWidth: candidate == band ? 2 : 0)
                .frame(width: 22, height: 22)
            // A dot under the bands that carry edits, so none gets forgotten.
            Circle()
                .fill(.white.opacity(adjustments.hsl[candidate] == ColorBand() ? 0 : 0.8))
                .frame(width: 3, height: 3)
                .offset(y: 16)
        }
        .frame(height: 36)
        .contentShape(Rectangle())
    }
}

extension ColorBandName {
    var displayColor: Color {
        switch self {
        case .red: Color(hue: 0, saturation: 0.8, brightness: 0.9)
        case .orange: Color(hue: 30 / 360, saturation: 0.8, brightness: 0.95)
        case .yellow: Color(hue: 55 / 360, saturation: 0.8, brightness: 0.95)
        case .green: Color(hue: 120 / 360, saturation: 0.7, brightness: 0.75)
        case .aqua: Color(hue: 180 / 360, saturation: 0.7, brightness: 0.85)
        case .blue: Color(hue: 225 / 360, saturation: 0.8, brightness: 0.95)
        case .purple: Color(hue: 270 / 360, saturation: 0.7, brightness: 0.9)
        case .magenta: Color(hue: 310 / 360, saturation: 0.7, brightness: 0.9)
        }
    }
}
