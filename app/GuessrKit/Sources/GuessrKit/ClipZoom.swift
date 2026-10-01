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
    /// another shape; nil means the picture is the frame. `elastic` is the
    /// gesture in progress: past a limit it resists rather than stopping, and
    /// the inelastic answer is where it settles on release.
    public func zoomed(
        by factor: Double, aboutX px: Double, y py: Double, width: Double, height: Double, aspect: Double? = nil,
        elastic: Bool = false
    ) -> ClipZoom {
        let raw = scale * factor
        let s = elastic ? Self.band(raw, 1, Self.maxScale, over: 1) : min(max(raw, 1), Self.maxScale)
        let k = s / scale
        return ClipZoom(scale: s, x: px - (px - x) * k, y: py - (py - y) * k)
            .clamped(width: width, height: height, aspect: aspect, elastic: elastic)
    }

    public func panned(
        dx: Double, dy: Double, width: Double, height: Double, aspect: Double? = nil, elastic: Bool = false
    ) -> ClipZoom {
        ClipZoom(scale: scale, x: x + dx, y: y + dy).clamped(width: width, height: height, aspect: aspect, elastic: elastic)
    }

    /// Kept so no pan shows past the picture's edge: along a side the picture
    /// covers, it covers the frame; along one it doesn't, it stays centered.
    func clamped(width: Double, height: Double, aspect: Double? = nil, elastic: Bool = false) -> ClipZoom {
        let pictureWidth = aspect.map { min(width, height * $0) } ?? width
        let pictureHeight = aspect.map { min(height, width / $0) } ?? height
        let mx = max(0, (pictureWidth * scale - width) / 2)
        let my = max(0, (pictureHeight * scale - height) / 2)
        if elastic {
            return ClipZoom(scale: scale, x: Self.band(x, -mx, mx, over: width), y: Self.band(y, -my, my, over: height))
        }
        return ClipZoom(scale: scale, x: min(max(x, -mx), mx), y: min(max(y, -my), my))
    }

    /// `v` held to `lo...hi` the way a scroll view's edge holds it: past a
    /// bound it follows less the further it goes, never more than `over` out.
    static func band(_ v: Double, _ lo: Double, _ hi: Double, over dimension: Double) -> Double {
        func resist(_ past: Double) -> Double { past * dimension * 0.55 / (dimension + 0.55 * past) }
        return v < lo ? lo - resist(lo - v) : v > hi ? hi + resist(v - hi) : v
    }
}
