import GuessrKit
import Testing

@Test func zoomingKeepsThePinchedSpotUnderTheFingers() {
    let z = ClipZoom().zoomed(by: 2, aboutX: 50, y: -20, width: 400, height: 225)
    // Unzoomed, the content point under (50, -20) is (50, -20) itself; a
    // screen point is the pan plus the content point times the scale.
    #expect(z.scale == 2)
    #expect(z.x + 50 * z.scale == 50)
    #expect(z.y + -20 * z.scale == -20)
}

@Test func zoomStopsAtTheFrameAndAtMaxScale() {
    let z = ClipZoom().zoomed(by: 0.5, aboutX: 10, y: 10, width: 400, height: 225)
    #expect(z == ClipZoom())
    #expect(ClipZoom().zoomed(by: 99, aboutX: 0, y: 0, width: 400, height: 225).scale == ClipZoom.maxScale)
}

@Test func panningStopsAtTheEdges() {
    let z = ClipZoom(scale: 2).panned(dx: 1000, dy: -1000, width: 400, height: 200)
    #expect(z.x == 200)
    #expect(z.y == -100)
    #expect(ClipZoom().panned(dx: 30, dy: 30, width: 400, height: 200) == ClipZoom())
}

@Test func aFittedPictureStaysCenteredUntilItCoversTheFrame() {
    // A 2:1 picture fitted across a 400×800 frame is 400×200.
    let twice = ClipZoom(scale: 2).panned(dx: 1000, dy: 1000, width: 400, height: 800, aspect: 2)
    #expect(twice.x == 200)
    #expect(twice.y == 0)
    let past = ClipZoom(scale: 5).panned(dx: 0, dy: -1000, width: 400, height: 800, aspect: 2)
    #expect(past.y == -100)
}
