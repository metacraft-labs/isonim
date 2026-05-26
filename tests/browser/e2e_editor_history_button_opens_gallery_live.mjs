// CHRM-M5 Fix D — Playwright e2e: the 🕘 history button opens the
// gallery overlay on-screen in the live editor.
//
// The pre-existing test ``tests/e2e_design_review_history_button_in_real_editor.mjs``
// covers the button MOUNT + the click-toggles-data-attribute path
// against a daemon seeded with history. The user's reported bug was
// the missing visual-positioning piece: the overlay's
// ``data-gallery-host-open`` flipped to ``"true"`` but the host
// stayed ``display: none`` because the visibility predicate AND-ed
// ``open`` with ``briefHasHistory``. With no captures covering the
// active story (the default landing state), the user saw nothing
// happen on click.
//
// CHRM-M5 Fix D drops the ``briefHasHistory`` term from the
// visibility predicate and drives the host's inline ``display``
// style from the same effect. The gallery overlay already renders
// its own "No captures yet" empty state, so the user sees that
// panel instead of a hidden zero-size overlay.
//
// This test loads the live editor JS bundle (the same one
// ``just editor-build`` produces), clicks the button, and asserts:
//
//   1. ``data-gallery-host-open`` flips to ``"true"`` (the existing
//      e2e covers that against a seeded daemon; here we cover the
//      no-history common case where the user originally saw the
//      bug).
//   2. The gallery host's bounding rect is on-screen
//      (``top >= 0``, ``left >= 0``, ``width > 100``,
//      ``height > 100``).
//   3. Either at least one capture tile OR the
//      ``[data-design-review-gallery-empty]`` empty-state node is
//      visible inside the overlay — proving the user sees
//      *something* meaningful after the click.
//
// Convention: ``node --test`` (not ``npx playwright test``) — matches
// the rest of ``isonim/tests/browser/e2e_*.mjs``.

import { execSync, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";

const __dirname = dirname(fileURLToPath(import.meta.url));
const isonimRoot = join(__dirname, "..", "..");
const isonimExamplesRoot = join(isonimRoot, "..", "isonim-examples");
const editorBuildDir = join(isonimExamplesRoot, "build", "editor");

const PAGE_PORT = 18647;
let pageServer = null;
let chromium = null;
let browser = null;

function exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

function buildEditor() {
  exec("direnv exec . just editor-build", { cwd: isonimExamplesRoot });
  if (!existsSync(join(editorBuildDir, "editor.js"))) {
    throw new Error("editor.js was not produced by `just editor-build`");
  }
  if (!existsSync(join(editorBuildDir, "index.html"))) {
    throw new Error("index.html was not produced by `just editor-build`");
  }
}

function startPageServer() {
  pageServer = spawn(
    "python3",
    ["-m", "http.server", String(PAGE_PORT), "--bind", "127.0.0.1"],
    { cwd: editorBuildDir, stdio: "ignore", detached: true },
  );
  for (let i = 0; i < 60; i++) {
    try {
      execSync(
        `curl -s -o /dev/null --max-time 0.5 ` +
          `http://127.0.0.1:${PAGE_PORT}/index.html`,
        { stdio: "pipe" },
      );
      return;
    } catch {
      execSync("sleep 0.2");
    }
  }
  throw new Error("static server failed to bind on " + PAGE_PORT);
}

async function ensureBrowser() {
  if (!chromium) {
    const m = await import("playwright");
    chromium = m.chromium;
  }
  if (!browser) browser = await chromium.launch({ headless: true });
  return browser;
}

async function openEditor() {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  await page.goto(`http://127.0.0.1:${PAGE_PORT}/index.html`);
  await page.waitForSelector('[data-design-review-history-button="true"]', {
    timeout: 10000,
  });
  await page.waitForSelector('[data-design-review-gallery-host="true"]', {
    state: "attached",
    timeout: 10000,
  });
  return { ctx, page };
}

test.before(async () => {
  buildEditor();
  startPageServer();
});

test.after(async () => {
  try {
    if (browser) await browser.close();
  } catch {}
  try {
    if (pageServer) process.kill(-pageServer.pid);
  } catch {}
});

test("clicking the 🕘 button flips data-gallery-host-open to true", async () => {
  const { ctx, page } = await openEditor();
  try {
    const before = await page.evaluate(() => {
      const host = document.querySelector(
        '[data-design-review-gallery-host="true"]',
      );
      return host && host.getAttribute("data-gallery-host-open");
    });
    assert.equal(
      before,
      "false",
      "gallery host starts closed (data-gallery-host-open=false)",
    );

    // Dispatch the click directly so the test doesn't depend on
    // hit-testing — the user's bug was that the click handler ran
    // but the overlay stayed hidden, exactly the failure this
    // test pins down.
    await page.evaluate(() => {
      const btn = document.querySelector(
        '[data-design-review-history-button="true"]',
      );
      if (btn) {
        btn.dispatchEvent(new MouseEvent("click", { bubbles: true }));
      }
    });

    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-design-review-gallery-host="true"]',
        );
        return host && host.getAttribute("data-gallery-host-open") === "true";
      },
      { timeout: 5000 },
    );
  } finally {
    await ctx.close();
  }
});

test("after click the gallery overlay's bounding rect is on-screen", async () => {
  const { ctx, page } = await openEditor();
  try {
    await page.evaluate(() => {
      const btn = document.querySelector(
        '[data-design-review-history-button="true"]',
      );
      if (btn) {
        btn.dispatchEvent(new MouseEvent("click", { bubbles: true }));
      }
    });
    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-design-review-gallery-host="true"]',
        );
        return host && host.getAttribute("data-gallery-host-open") === "true";
      },
      { timeout: 5000 },
    );
    // Give the reactive effect a tick to flip the inline display.
    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-design-review-gallery-host="true"]',
        );
        return host && window.getComputedStyle(host).display !== "none";
      },
      { timeout: 5000 },
    );
    const rect = await page.evaluate(() => {
      const host = document.querySelector(
        '[data-design-review-gallery-host="true"]',
      );
      if (!host) return null;
      const r = host.getBoundingClientRect();
      return {
        top: r.top,
        left: r.left,
        width: r.width,
        height: r.height,
        display: window.getComputedStyle(host).display,
      };
    });
    assert.ok(rect, "gallery host must be in the DOM after click");
    assert.notEqual(
      rect.display,
      "none",
      "gallery host's computed display must not be 'none' once open",
    );
    assert.ok(rect.top >= 0, `gallery host top must be >= 0 (got ${rect.top})`);
    assert.ok(
      rect.left >= 0,
      `gallery host left must be >= 0 (got ${rect.left})`,
    );
    assert.ok(
      rect.width > 100,
      `gallery host width must be > 100px (got ${rect.width})`,
    );
    assert.ok(
      rect.height > 100,
      `gallery host height must be > 100px (got ${rect.height})`,
    );
  } finally {
    await ctx.close();
  }
});

test("open gallery shows either tiles or the 'No captures yet' empty state", async () => {
  const { ctx, page } = await openEditor();
  try {
    await page.evaluate(() => {
      const btn = document.querySelector(
        '[data-design-review-history-button="true"]',
      );
      if (btn) {
        btn.dispatchEvent(new MouseEvent("click", { bubbles: true }));
      }
    });
    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-design-review-gallery-host="true"]',
        );
        if (!host) return false;
        if (host.getAttribute("data-gallery-host-open") !== "true")
          return false;
        if (window.getComputedStyle(host).display === "none") return false;
        // Either a tile OR the empty-state node must be in the
        // overlay descendant tree.
        const tile = host.querySelector("[data-design-review-gallery-tile]");
        const empty = host.querySelector(
          '[data-design-review-gallery-empty="true"]',
        );
        return tile !== null || empty !== null;
      },
      { timeout: 5000 },
    );
    const summary = await page.evaluate(() => {
      const host = document.querySelector(
        '[data-design-review-gallery-host="true"]',
      );
      if (!host) return { hasTile: false, hasEmpty: false };
      return {
        hasTile:
          host.querySelector("[data-design-review-gallery-tile]") !== null,
        hasEmpty:
          host.querySelector('[data-design-review-gallery-empty="true"]') !==
          null,
      };
    });
    assert.ok(
      summary.hasTile || summary.hasEmpty,
      "gallery overlay must show either tiles or the empty-state panel " +
        `(tile=${summary.hasTile}, empty=${summary.hasEmpty})`,
    );
  } finally {
    await ctx.close();
  }
});
