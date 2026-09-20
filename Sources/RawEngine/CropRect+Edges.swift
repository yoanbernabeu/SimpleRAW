extension CropRect {
    public enum Edge: CaseIterable, Sendable {
        case top, bottom, left, right

        var isVertical: Bool { self == .left || self == .right }
        /// Whether dragging it further from the origin makes the crop larger.
        var grows: Bool { self == .right || self == .bottom }
    }

    /// The crop once `edge` has been dragged to `position`, along its axis. Free, the edge
    /// moves alone. With a locked `aspect` (width / height, normalized), the other dimension
    /// follows around the middle of the crop, and the whole stops where the frame does.
    public func resized(dragging edge: Edge, to position: Double, aspect: Double?) -> CropRect {
        // Along the dragged axis: the opposite edge stays put.
        let (start, length, middle, breadth) = edge.isVertical ? (x, width, y + height / 2, height) : (y, height, x + width / 2, width)
        let anchor = edge.grows ? start : start + length
        let room = edge.grows ? 1 - anchor : anchor
        var along = min(max((position - anchor) * (edge.grows ? 1 : -1), Self.minimumSide), room)

        var across = breadth
        if let aspect, aspect > 0 {
            // Twice the distance from the middle to the nearest side of the frame.
            let roomAcross = 2 * min(middle, 1 - middle)
            across = edge.isVertical ? along / aspect : along * aspect
            if across > roomAcross {
                across = roomAcross
                along = edge.isVertical ? across * aspect : across / aspect
            }
        }
        let origin = edge.grows ? anchor : anchor - along
        let side = aspect == nil ? (edge.isVertical ? y : x) : middle - across / 2
        return edge.isVertical
            ? CropRect(x: origin, y: side, width: along, height: across)
            : CropRect(x: side, y: origin, width: across, height: along)
    }
}
