// Viewport math for the frame pane: where the frame sits and how big it is,
// as a {scale, x, y} applied to one CSS transform.
//
// Pure functions in their own module so the clamping and the zoom anchoring can
// be checked in node, the same arrangement daily.js uses for the play window.
//
// Coordinates are box pixels with the origin at the pane's top-left corner;
// `frame` and `box` are {w, h} in natural and CSS pixels respectively. The
// frame is a <video>, so its natural size is the source resolution rather than
// anything on screen.

// The scale at which the frame just fits inside the box.
export function fitScale(frame, box) {
  return Math.min(box.w / frame.w, box.h / frame.h);
}

// Keeps the frame covering the box while it is larger, and centred when it is
// not — so a drag can never leave a strip of background showing.
function clampOffset(drawn, boxLen, offset) {
  if (drawn <= boxLen) return (boxLen - drawn) / 2;
  return Math.min(0, Math.max(boxLen - drawn, offset));
}

function clampView(view, frame, box) {
  return {
    scale: view.scale,
    x: clampOffset(frame.w * view.scale, box.w, view.x),
    y: clampOffset(frame.h * view.scale, box.h, view.y),
  };
}

export function fitView(frame, box) {
  return clampView({ scale: fitScale(frame, box), x: 0, y: 0 }, frame, box);
}

export function panView(view, frame, box, dx, dy) {
  return clampView({ scale: view.scale, x: view.x + dx, y: view.y + dy }, frame, box);
}

// Scales about (px, py) so the point under the cursor — or under the centre of
// a pinch — stays where it is.
export function zoomAbout(view, frame, box, px, py, factor) {
  const fit = fitScale(frame, box);
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
  }, frame, box);
}
