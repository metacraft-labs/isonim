/** Read actual production search focus, paint and viewport geometry. No focus,
 * DOM, CSS or browser mocks. Mounted/capture negative controls remove the real
 * ring temporarily and restore it; keyboard and RPC use the same CSS rule. */
import assert from "node:assert/strict";
export function sidebarSearchFocusEvidence() {
  const input = document.querySelector('[data-sidebar-search="true"]');
  const field = input?.closest('[data-sidebar-search-field="true"]');
  if (!input || !field) return { active: false };
  const style = getComputedStyle(field),
    box = field.getBoundingClientRect();
  const rgb = (value) => (value.match(/[\d.]+/g) || []).slice(0, 3).map(Number);
  const luminance = (values) =>
    values
      .map((v) => {
        v /= 255;
        return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
      })
      .reduce((sum, v, i) => sum + v * [0.2126, 0.7152, 0.0722][i], 0);
  const a = luminance(rgb(style.outlineColor)),
    b = luminance(rgb(style.backgroundColor));
  return {
    active: document.activeElement === input,
    outlineStyle: style.outlineStyle,
    outlineWidth: parseFloat(style.outlineWidth),
    outlineOffset: parseFloat(style.outlineOffset),
    outlineColor: style.outlineColor,
    backgroundColor: style.backgroundColor,
    contrast: (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05),
    box: {
      top: box.top,
      bottom: box.bottom,
      left: box.left,
      right: box.right,
      width: box.width,
      height: box.height,
    },
    viewport: { width: innerWidth, height: innerHeight },
  };
}
export function requireSidebarSearchFocus(evidence) {
  assert.equal(evidence.active, true, "actual sidebar search activeElement");
  assert.equal(
    evidence.outlineStyle,
    "solid",
    "visible sidebar search focus ring",
  );
  assert(evidence.outlineWidth >= 2, "sidebar search ring at least 2px");
  assert(evidence.contrast >= 3, "sidebar search ring contrasts with field");
  const { box, viewport } = evidence,
    pad = evidence.outlineWidth + Math.max(0, evidence.outlineOffset);
  assert(
    box.width > 0 &&
      box.height > 0 &&
      box.left - pad >= 0 &&
      box.top - pad >= 0 &&
      box.right + pad <= viewport.width &&
      box.bottom + pad <= viewport.height,
    "whole sidebar search focus ring inside viewport",
  );
  return evidence;
}
