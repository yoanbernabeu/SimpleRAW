import CoreGraphics
import RawEngine

/// What a press on the crop overlay takes hold of. In view coordinates.
enum CropHitTest {
    enum Target: Equatable {
        case corner(CropRect.Corner)
        case edge(CropRect.Edge)
        case inside
    }

    /// How close to a corner a press must be to grab it, in points; edges take half of it.
    static let cornerDistance: CGFloat = 28

    static func target(at location: CGPoint, in rect: CGRect) -> Target? {
        // Handles shrink with the crop, so that its middle can always be grabbed to move it.
        let reach = min(cornerDistance, min(rect.width, rect.height) / 3)
        let corners: [(CropRect.Corner, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)), (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)), (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
        ]
        if let corner = corners.first(where: { hypot($0.1.x - location.x, $0.1.y - location.y) <= reach }) {
            return .corner(corner.0)
        }
        let edgeReach = reach / 2
        let alongX = (rect.minX...rect.maxX).contains(location.x), alongY = (rect.minY...rect.maxY).contains(location.y)
        if alongX, abs(location.y - rect.minY) <= edgeReach { return .edge(.top) }
        if alongX, abs(location.y - rect.maxY) <= edgeReach { return .edge(.bottom) }
        if alongY, abs(location.x - rect.minX) <= edgeReach { return .edge(.left) }
        if alongY, abs(location.x - rect.maxX) <= edgeReach { return .edge(.right) }
        return rect.contains(location) ? .inside : nil
    }
}
