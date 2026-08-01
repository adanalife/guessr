// Checks the frame-pane viewport math. Run with `node test_zoom.js`
// (or `task test`).
//
// zoom.js is a plain script rather than a module, so eval in this scope is how
// the test gets at its functions — the same arrangement test_daily.js uses.
const assert = require('node:assert');
const fs = require('node:fs');

eval(fs.readFileSync(`${__dirname}/web/zoom.js`, 'utf8'));

const box = { w: 500, h: 500 };
const wide = { w: 1000, h: 500 };   // 2:1, so it fits the box on width
const square = { w: 1000, h: 1000 };
const small = { w: 200, h: 200 };   // smaller than the box, shown upscaled

// A fitted image is centred in the axis it does not fill, with no crop.
const fitted = fitView(wide, box);
assert.strictEqual(fitted.scale, 0.5);
assert.deepStrictEqual([fitted.x, fitted.y], [0, 125]);

// Zooming keeps the image point under the cursor under the cursor. That is the
// whole reason zoomAbout exists, so it is the property worth pinning.
const before = fitView(square, box);
const after = zoomAbout(before, square, box, 250, 250, 2);
const imagePointAt = (v, px) => (px - v.x) / v.scale;
assert.strictEqual(imagePointAt(before, 250), imagePointAt(after, 250));
assert.strictEqual(after.scale, 1);

// Zooming out stops at the fit scale -- the image never floats inside the pane.
assert.deepStrictEqual(zoomAbout(after, square, box, 250, 250, 0.01), before);

// Zooming in stops at 1:1 with the source pixels, past which it is only blur.
assert.strictEqual(zoomAbout(before, square, box, 250, 250, 99).scale, 1);

// ...but an image smaller than the pane is already upscaled at its fit scale,
// so it still gets room to zoom rather than being pinned there.
const tiny = fitView(small, box);
assert.strictEqual(tiny.scale, 2.5);
assert.strictEqual(zoomAbout(tiny, small, box, 250, 250, 99).scale, 5);

// Panning cannot drag the image off its own edges and expose background.
const zoomed = zoomAbout(fitView(wide, box), wide, box, 0, 0, 4);
assert.deepStrictEqual([zoomed.x, zoomed.y], [0, 0], 'top-left zoom should sit flush');
assert.deepStrictEqual(panView(zoomed, wide, box, 999, 0), zoomed, 'panned past the left edge');
assert.strictEqual(panView(zoomed, wide, box, -9999, 0).x, -500, 'panned past the right edge');

// The axis the image does not fill stays centred however hard it is dragged,
// rather than sliding to a corner.
assert.strictEqual(panView(fitted, wide, box, 0, 999).y, 125);

console.log('ok: frame fits, anchors on zoom, and clamps to its own edges');
