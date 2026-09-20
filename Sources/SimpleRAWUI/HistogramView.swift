import RawEngine
import SwiftUI

/// RGB histogram with additive channels (overlaps read as the mixed color, white where all
/// three agree) and a marker on each side that lights up when that end clips.
struct HistogramView: View {
    let histogram: Histogram?
    /// Shows clipping on the picture; the markers are its switch.
    var showsClipping: Binding<Bool> = .constant(false)

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.35))
            if let histogram {
                ZStack {
                    channel(histogram.red, color: .red)
                    channel(histogram.green, color: .green)
                    channel(histogram.blue, color: .blue)
                }
                .padding(.horizontal, 4)
                .padding(.top, 10)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                HStack {
                    clippingMarker(isOn: histogram.clipsShadows, help: "Shadows are clipped")
                    Spacer()
                    clippingMarker(isOn: histogram.clipsHighlights, help: "Highlights are clipped")
                }
                .padding(5)
                .contentShape(Rectangle())
                .onTapGesture { showsClipping.wrappedValue.toggle() }
                .help("Show clipping on the picture (J)")
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent.opacity(showsClipping.wrappedValue ? 0.8 : 0), lineWidth: 1))
        .frame(height: 74)
        .accessibilityLabel("Histogram")
    }

    private func channel(_ bins: [Float], color: Color) -> some View {
        HistogramShape(bins: bins)
            .fill(color.opacity(0.75))
            .blendMode(.plusLighter)
    }

    private func clippingMarker(isOn: Bool, help: String) -> some View {
        Circle()
            .fill(isOn ? Theme.warning : Color.white.opacity(0.15))
            .frame(width: 6, height: 6)
            .help(help)
    }
}

struct HistogramShape: Shape {
    let bins: [Float]

    func path(in rect: CGRect) -> Path {
        guard bins.count > 1 else { return Path() }
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for (index, bin) in bins.enumerated() {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(bins.count - 1)
            // A square root keeps the quiet parts of the distribution readable next to a spike.
            let height = rect.height * CGFloat(bin.squareRoot())
            path.addLine(to: CGPoint(x: x, y: rect.maxY - height))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
