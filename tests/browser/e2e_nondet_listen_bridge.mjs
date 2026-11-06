// The nondet listen bridge, in headless Chromium (PSZ-M3, editor-psz).
//
// Two behaviours of the bridge that the editor shell relies on:
//
//   * e2e_nondet_listen_element_fires: a listener registered through
//     previewListenOn with an event name fires for a dispatched event of that
//     name, on an element target. The name must reach the browser as the event
//     type; a name passed through a Nim closure once reached the bridge encoded,
//     and no listener ever fired.
//   * e2e_nondet_listen_frame_document_delivers: a listener on the device
//     frame's document, a non-element target, registers without throwing and
//     delivers its event. The bridge's target-id lookup once called getAttribute
//     on every target.
//
// Mocks: none. The page is the fixture in tests/browser/nondet_listen_fixture
// (built here with nim js), the DOM and the event dispatch are Chromium's, and
// the listeners are the real bridge. The events are real Event objects
// dispatched by the test. The frame is a real srcdoc iframe.
//
// Run with (from the isonim root, inside the dev shell):
//   cd tests/browser && PLAYWRIGHT_CHROMIUM_EXECUTABLE="$(command -v chromium)" \
//     node --test e2e_nondet_listen_bridge.mjs

import { execSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";

const here = dirname(fileURLToPath(import.meta.url));
const isonimRoot = join(here, "..", "..");
const outDir = join(isonimRoot, "build", "nondet_listen_fixture");
const bundle = join(outDir, "main.js");
const pageFile = join(outDir, "index.html");

let browser = null;

test.before(async () => {
  mkdirSync(outDir, { recursive: true });
  execSync(
    `nim js --path:src --path:. --path:../nim-everywhere/src ` +
      `--path:../isonim-render-serve/src --path:../nim-acp/src ` +
      `--path:../nim-agent-harbor/src --path:../nim-agents/src ` +
      `-o:${bundle} tests/browser/nondet_listen_fixture/main.nim`,
    { cwd: isonimRoot, stdio: "pipe" },
  );
  writeFileSync(pageFile, `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>nondet listen</title></head>
<body>
  <div id="target"></div>
  <iframe id="frame" srcdoc="<p>frame</p>"></iframe>
  <script src="main.js"></script>
</body></html>`);
  const { chromium } = await import("@playwright/test");
  browser = await chromium.launch({
    headless: true,
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || undefined,
  });
});

test.after(async () => {
  if (browser) await browser.close();
});

async function openFixture() {
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (err) => errors.push(String(err && err.message || err)));
  await page.goto(pathToFileURL(pageFile).href);
  // The frame's document is in place once its srcdoc has loaded.
  await page.waitForFunction(() => {
    const f = document.getElementById("frame");
    return !!(f && f.contentDocument && f.contentDocument.readyState === "complete");
  }, null, { timeout: 15000 });
  return { ctx, page, errors };
}

test("e2e_nondet_listen_element_fires_for_its_event_name", async () => {
  const { ctx, page, errors } = await openFixture();
  try {
    const registered = await page.evaluate(() => {
      try { window.listenOnElement(); return null; } catch (e) { return String(e); }
    });
    assert.equal(registered, null, "registering the element listener must not throw");

    // A different event type must not reach the pointermove listener.
    await page.locator("#target").dispatchEvent("pointerup");
    assert.deepEqual(await page.evaluate(() => window.__calls || []), [],
      "a pointerup must not fire a pointermove listener");

    await page.locator("#target").dispatchEvent("pointermove");
    assert.deepEqual(await page.evaluate(() => window.__calls || []),
      ["element:pointermove"], "the listener fires once for its own event name");
    assert.deepEqual(errors, [], "no page error while the listener runs");
  } finally {
    await ctx.close();
  }
});

test("e2e_nondet_listen_frame_document_delivers", async () => {
  const { ctx, page, errors } = await openFixture();
  try {
    // The frame's document is not an element: registering on it must not throw.
    const registered = await page.evaluate(() => {
      try { window.listenOnFrameDocument(); return null; } catch (e) { return String(e); }
    });
    assert.equal(registered, null,
      "registering a listener on the frame document (a non-element target) must not throw");

    await page.evaluate(() => {
      const doc = document.getElementById("frame").contentDocument;
      doc.dispatchEvent(new Event("pointermove"));
    });
    assert.deepEqual(await page.evaluate(() => window.__calls || []),
      ["frame-document:pointermove"],
      "the frame-document listener delivers its event");
    assert.deepEqual(errors, [], "no page error from the frame-document listener");
  } finally {
    await ctx.close();
  }
});
