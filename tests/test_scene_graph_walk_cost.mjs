// The scene-graph walk (src/isonim/editor/views/scene_graph_walk.nim) on a
// wide, deep preview, in real Chromium:
//
//   * every row's `domPath` is exactly what the walk's own per-element
//     `cssPath` answers outside a walk, and what the walk's original
//     algorithm (each element re-walking its ancestors, kept below as the
//     oracle) produced, so ids and paths did not change;
//   * one walk measures each element at most once and visits each sibling a
//     bounded number of times. The editor's scene-graph reader repeats the
//     walk every 700 ms; when every element re-walked its ancestors, a
//     6,000-element story cost 110,000 layout reads and 1.6 million sibling
//     steps per walk and kept the editor's main thread busy.
//
// The counts are of DOM calls, not milliseconds, so the check does not depend
// on how loaded the host is. Nothing is mocked: the walk runs on a real
// document in a real browser.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const source = readFileSync(join(root, "src/isonim/editor/views/scene_graph_walk.nim"), "utf8");
const walkJs = source.match(/const sceneGraphWalkJs\* = """\n([\s\S]*?)\n"""/)[1];

// A list of 400 rows of 12 elements each, nested three deep inside wrappers,
// a hidden subtree and the editor's own chrome, which the walk must skip.
function page() {
  const row = (i) => `<li class="row r${i % 3}" data-testid="${i % 7 === 0 ? `row-${i}` : ""}">` +
    `<span class="dot"></span><div class="text"><b>Session ${i}</b><i>note</i>` +
    `<p><span>a</span><span>b</span><em>c</em></p></div><span class="age">${i}s</span>` +
    `<button role="button">x</button></li>`;
  return `<!doctype html><html><body><main class="app"><section><div class="w">` +
    `<ul class="list">${Array.from({ length: 400 }, (_, i) => row(i)).join("")}</ul>` +
    `<div style="display:none"><span>hidden</span><span>hidden</span></div></div></section></main>` +
    `<div id="isonim-editor-hover-label">chrome</div></body></html>`;
}

test("scene graph walk: same paths, linear DOM work on a wide preview", async () => {
  const { chromium } = await import("playwright");
  const browser = await chromium.launch({
    headless: true,
    ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE } : {}),
  });
  try {
    const p = await browser.newPage();
    await p.setContent(page());
    const result = await p.evaluate((walkSource) => {
      new Function(walkSource)();
      const walk = window.__isonimSceneGraphWalk(document);
      // The original per-element algorithm, as the oracle.
      function oraclePath(el) {
        const parts = [];
        let node = el;
        while (walk.isSelectable(node)) {
          let index = 1;
          let sibling = node;
          while ((sibling = sibling.previousElementSibling)) {
            if (sibling.tagName === node.tagName) index += 1;
          }
          parts.unshift(walk.stableSelector(node) + ":nth-of-type(" + index + ")");
          node = node.parentElement;
        }
        return parts.join(" > ");
      }
      const proto = Element.prototype;
      const rect = proto.getBoundingClientRect;
      const prev = Object.getOwnPropertyDescriptor(proto, "previousElementSibling");
      const next = Object.getOwnPropertyDescriptor(proto, "nextElementSibling");
      let rects = 0, steps = 0;
      proto.getBoundingClientRect = function () { rects++; return rect.call(this); };
      Object.defineProperty(proto, "previousElementSibling", { configurable: true, get() { steps++; return prev.get.call(this); } });
      Object.defineProperty(proto, "nextElementSibling", { configurable: true, get() { steps++; return next.get.call(this); } });
      let rows;
      try {
        rows = walk.layerTree(null);
      } finally {
        proto.getBoundingClientRect = rect;
        Object.defineProperty(proto, "previousElementSibling", prev);
        Object.defineProperty(proto, "nextElementSibling", next);
      }
      const elements = document.body.querySelectorAll("*").length;
      const mismatches = [];
      for (const row of rows) {
        const el = document.querySelector(`[data-isonim-element-id="${CSS.escape(row.id)}"]`);
        if (!el) { mismatches.push(`no element for ${row.id}`); continue; }
        const outside = walk.cssPath(el);
        const oracle = oraclePath(el);
        if (row.domPath !== oracle || outside !== oracle) {
          mismatches.push(`${row.domPath} | ${outside} | ${oracle}`);
        }
      }
      return { elements, rows: rows.length, rects, steps, mismatches: mismatches.slice(0, 5),
               mismatchCount: mismatches.length, chromeListed: rows.some((r) => r.label.includes("chrome")) };
    }, walkJs);
    // 400 rows of ten boxed elements (the empty dot has no box), plus wrappers.
    assert.ok(result.rows >= 400 * 10, `the walk lists every visible element (${result.rows})`);
    assert.equal(result.chromeListed, false, "editor chrome is not a layer");
    assert.equal(result.mismatchCount, 0, `paths unchanged: ${result.mismatches.join("; ")}`);
    assert.ok(result.rects <= result.elements,
      `each element measured at most once per walk: ${result.rects} reads for ${result.elements} elements`);
    assert.ok(result.steps <= 2 * result.elements,
      `sibling steps linear in the elements: ${result.steps} for ${result.elements}`);
  } finally {
    await browser.close();
  }
});
