import Foundation

/// How far a clip is zoomed into and where it has been panned to, in points
/// off the frame's centre. The app's pinch and drag feed it; it is the web's
/// `zoom.js` for a picture that always fills its frame.
public struct ClipZoom: Sendable, Equatable {
    public var scale = 1.0
    public var x = 0.0
    public var y = 0.0

    /// Past 4× a phone is showing the clip's own pixels as blocks.
    public static let maxScale = 4.0

    public init(scale: Double = 1, x: Double = 0, y: Double = 0) {
        (self.scale, self.x, self.y) = (scale, x, y)
    }

    /// Scaled by `factor` about the point `(px, py)`, measured from the
    /// frame's centre, so the spot under the fingers stays under them.
    /// `aspect` is the picture's shape when it is fitted inside a frame of
    /// another shape; nil means the picture is the frame.
    public func zoomed(
        by factor: Double, aboutX px: Double, y py: Double, width: Double, height: Double, aspect: Double? = nil
    ) -> ClipZoom {
        let s = min(max(scale * factor, 1), Self.maxScale)
        let k = s / scale
        return ClipZoom(scale: s, x: px - (px - x) * k, y: py - (py - y) * k)
            .clamped(width: width, height: height, aspect: aspect)
    }

    public func panned(dx: Double, dy: Double, width: Double, height: Double, aspect: Double? = nil) -> ClipZoom {
        ClipZoom(scale: scale, x: x + dx, y: y + dy).clamped(width: width, height: height, aspect: aspect)
    }

    /// Kept so no pan shows past the picture's edge: along a side the picture
    /// covers, it covers the frame; along one it doesn't, it stays centered.
    func clamped(width: Double, height: Double, aspect: Double? = nil) -> ClipZoom {
        let pictureWidth = aspect.map { min(width, height * $0) } ?? width
        let pictureHeight = aspect.map { min(height, width / $0) } ?? height
        let mx = max(0, (pictureWidth * scale - width) / 2)
        let my = max(0, (pictureHeight * scale - height) / 2)
        return ClipZoom(scale: scale, x: min(max(x, -mx), mx), y: min(max(y, -my), my))
    }
}
