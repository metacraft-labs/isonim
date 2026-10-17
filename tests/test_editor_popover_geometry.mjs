/** Tests the exact pure geometry function used by the production mounted popup
 * controller. No DOM/renderer or successful edit is simulated. Geometry is only
 * supplemental coverage: compiled-editor browser tests own focus, scrolling,
 * actual dimensions, top layer, source commit and disposal acceptance. */
import assert from "node:assert/strict";
import "../src/isonim/editor/views/widgets/anchored_popover.js";
const place = globalThis.__isonimPopoverGeometry;
let count = 0;
for (const viewport of [
  { x: 0, y: 0, width: 1440, height: 900 },
  { x: 0, y: 0, width: 700, height: 440 },
  { x: 130, y: 70, width: 390, height: 260 },
  { x: 0, y: 0, width: 40, height: 30 },
]) {
  for (const [x, y] of [
    [0, 0],
    [viewport.width, 0],
    [0, viewport.height],
    [viewport.width, viewport.height],
    [-900, -900],
    [9000, 9000],
  ]) {
    for (const size of [
      { width: 320, height: 480 },
      { width: 9000, height: 8000 },
      { width: 80, height: 30 },
    ]) {
      const p = place(
        {
          left: x + viewport.x,
          top: y + viewport.y,
          right: x + viewport.x + 24,
          bottom: y + viewport.y + 24,
        },
        size,
        viewport,
      );
      assert(p.left >= viewport.x && p.top >= viewport.y);
      assert(p.left + p.width <= viewport.x + viewport.width);
      assert(p.top + p.height <= viewport.y + viewport.height);
      count++;
    }
  }
}
assert.equal(
  place(
    { left: 20, top: 600, bottom: 624, right: 44 },
    { width: 320, height: 200 },
    { x: 0, y: 0, width: 900, height: 700 },
  ).top,
  394,
);
assert.equal(
  place(
    { left: 20, top: 30, bottom: 54, right: 44 },
    { width: 320, height: 200 },
    { x: 0, y: 0, width: 900, height: 700 },
  ).top,
  60,
);
console.log(`${count + 2} production geometry assertions passed`);
