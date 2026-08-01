// Viewport math for the frame pane: where the image sits and how big it is,
// as a {scale, x, y} applied to one CSS transform.
//
// Pure functions in their own file so the clamping and the zoom anchoring can
// be checked in node, the same arrangement daily.js uses for the draw.
//
// Coordinates are box pixels with the origin at the pane's top-left corner;
// `img` and `box` are {w, h} in natural and CSS pixels respectively.

// The scale at which the image just fits inside the box.
function fitScale(img, box) {
  return Math.min(box.w / img.w, box.h / img.h);
}

// Keeps the image covering the box while it is larger, and centred when it is
// not — so a drag can never leave a strip of background showing.
function clampOffset(drawn, boxLen, offset) {
  if (drawn <= boxLen) return (boxLen - drawn) / 2;
  return Math.min(0, Math.max(boxLen - drawn, offset));
}

function clampView(view, img, box) {
  return {
    scale: view.scale,
    x: clampOffset(img.w * view.scale, box.w, view.x),
    y: clampOffset(img.h * view.scale, box.h, view.y),
  };
}

function fitView(img, box) {
  return clampView({ scale: fitScale(img, box), x: 0, y: 0 }, img, box);
}

function panView(view, img, box, dx, dy) {
  return clampView({ scale: view.scale, x: view.x + dx, y: view.y + dy }, img, box);
}

// Scales about (px, py) so the image point under the cursor — or under the
// centre of a pinch — stays where it is.
function zoomAbout(view, img, box, px, py, factor) {
  const fit = fitScale(img, box);
  // Past 1:1 with the source pixels there is nothing further to see. A box
  // wider than the frame already shows it upscaled, though, so always leave
  // some room to zoom rather than pinning those screens at their fit scale.
  const max = Math.max(1, fit * 2);
  const scale = Math.min(max, Math.max(fit, view.scale * factor));
  const k = scale / view.scale;
  return clampView({
    scale,
    x: px - (px - view.x) * k,
    y: py - (py - view.y) * k,
  }, img, box);
}
