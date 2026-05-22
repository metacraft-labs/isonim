// TBAR-M4 — Playwright-driven browser e2e for the editor's Spec
// pane in View mode.
//
// Boots Chromium against the real editor bundle produced by
// ``just editor-build`` in ``isonim-examples``. The test:
//
//   1. Rebuilds the editor bundle so the test reflects the current
//      ``shell.nim`` / ``spec_pane.nim`` / vendor source.
//   2. Starts a static file server pointing at ``build/editor/``.
//   3. Loads the editor and pins the active story to
//      ``Task App / Pages / Inbox`` (which the brief index maps to
//      the ``render.task-app`` brief — the milestone's canonical
//      brief).
//   4. Flips the surface to Spec via the TBAR-M3 segmented control.
//   5. Asserts the rendered DOM contains the markdown rendered to
//      HTML — H1 (the brief's title prepended by shell.nim), H2
//      (multiple section headers in the body), a list, and a code
//      block.
//   6. Asserts the pane is NOT editable in View mode — typing into
//      the pane does not mutate the H1 text.
//
// This file runs via ``node --test`` — the same pattern the rest of
// ``tests/browser/e2e_*.mjs`` files use. ``npx playwright test`` is
// reserved for ``tests/browser/specs/*.spec.ts``.

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

const PAGE_PORT = 18525;
let pageServer = null;
let chromium = null;
let browser = null;

function exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

function buildEditor() {
  // Rebuild the editor bundle + vendor copy step so the test
  // reflects the current source-tree. The build is run inside the
  // ``isonim-examples`` direnv shell so ``nim`` and the path-based
  // ``isonim`` dependency are resolved the same way ``just
  // editor-build`` runs them.
  const cmd = "direnv exec . just editor-build";
  exec(cmd, { cwd: isonimExamplesRoot });
  if (!existsSync(join(editorBuildDir, "editor.js"))) {
    throw new Error("editor.js was not produced by `just editor-build`");
  }
  if (!existsSync(join(editorBuildDir, "index.html"))) {
    throw new Error("index.html was not produced by `just editor-build`");
  }
  if (!existsSync(join(editorBuildDir, "vendor", "tiptap.umd.js"))) {
    throw new Error("vendor/tiptap.umd.js was not copied by editor-build");
  }
  if (!existsSync(join(editorBuildDir, "vendor", "xterm.umd.js"))) {
    throw new Error("vendor/xterm.umd.js was not copied by editor-build");
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
  const ctx = await b.newContext();
  const page = await ctx.newPage();
  await page.goto(`http://127.0.0.1:${PAGE_PORT}/index.html`);
  // Wait until the shell paints. The Preview/Spec segmented control
  // is the canonical TBAR-M3 sentinel.
  await page.waitForSelector('[data-preview-surface-switch="true"]', {
    timeout: 10000,
  });
  await page.waitForSelector('[data-preview-chrome-bar="true"]', {
    timeout: 10000,
  });
  return { ctx, page };
}

async function selectTaskAppStory(page) {
  // Pin the editor to the ``Task App / Pages / Inbox`` story so the
  // briefId resolver lands on ``render.task-app`` — the milestone's
  // canonical brief.
  await page.waitForFunction(
    () =>
      typeof window !== "undefined" &&
      window.__isonimEditor &&
      typeof window.__isonimEditor.selectStoryByName === "function",
    { timeout: 10000 },
  );
  await page.evaluate(() => {
    window.__isonimEditor.selectStoryByName("Task App / Pages", "Inbox");
  });
}

async function switchToSpec(page) {
  const specPill = await page.$(
    '[data-preview-surface-switch="true"] [data-choice-group-pill="1"]',
  );
  assert.ok(specPill, "Spec pill is mounted");
  await specPill.click();
  // Wait for the spec pane host to display.
  await page.waitForFunction(
    () => {
      const el = document.querySelector('[data-test-id="spec-pane"]');
      if (!el) return false;
      return getComputedStyle(el).display !== "none";
    },
    { timeout: 5000 },
  );
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

// ---------------------------------------------------------------------------
// TipTap bundle is loaded
// ---------------------------------------------------------------------------

test("e2e_spec_pane_tiptap_bundle_loads", async () => {
  const { ctx, page } = await openEditor();
  try {
    // TBAR-M5b: each library exposes a named globalThis namespace
    // assigned by the bundle's entry script (see
    // ``isonim/nix/entry-tiptap.mjs``).  The per-library Nim FFI
    // modules (``vendor/tiptap.nim`` etc.) import these via
    // ``{.importc, nodecl.}``.
    const ready = await page.evaluate(() => {
      return (
        typeof window !== "undefined" &&
        !!globalThis.TipTap &&
        !!globalThis.TipTap.Editor &&
        !!globalThis.TipTapStarterKit &&
        !!globalThis.TipTapStarterKit.StarterKit &&
        !!globalThis.TipTapMarkdown &&
        !!globalThis.TipTapMarkdown.Markdown
      );
    });
    assert.equal(
      ready,
      true,
      "globalThis.TipTap / TipTapStarterKit / TipTapMarkdown are all defined",
    );
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// Spec pane mounts TipTap and renders the brief
// ---------------------------------------------------------------------------

test("e2e_spec_pane_view_mode_renders_brief_markdown_as_html", async () => {
  const { ctx, page } = await openEditor();
  try {
    await selectTaskAppStory(page);
    await switchToSpec(page);

    // The TipTap host inside the spec pane should be marked
    // ``data-tiptap-mounted="true"`` after the mount completes.
    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-spec-pane-tiptap-host="true"]',
        );
        return !!host && host.getAttribute("data-tiptap-mounted") === "true";
      },
      { timeout: 10000 },
    );

    // The rendered DOM inside the host must contain the canonical
    // markdown features the brief carries.
    const features = await page.evaluate(() => {
      const host = document.querySelector(
        '[data-spec-pane-tiptap-host="true"]',
      );
      if (!host) return null;
      const h1s = host.querySelectorAll("h1");
      const h2s = host.querySelectorAll("h2");
      const lists = host.querySelectorAll("ul, ol");
      const codes = host.querySelectorAll("pre, code");
      const h1Text = h1s.length > 0 ? (h1s[0].textContent || "").trim() : "";
      return {
        h1Count: h1s.length,
        h2Count: h2s.length,
        listCount: lists.length,
        codeCount: codes.length,
        h1Text,
      };
    });
    assert.ok(features, "spec pane host is mounted in the DOM");
    assert.ok(
      features.h1Count >= 1,
      `expected >= 1 <h1> in spec pane, got ${features.h1Count}`,
    );
    // The shell prepends the brief's ``title`` field as an H1 so the
    // rendered surface carries the canonical title heading.
    assert.ok(features.h1Text.length > 0, "spec pane H1 text is non-empty");
    assert.ok(
      features.h1Text.toLowerCase().includes("task app"),
      `spec pane H1 mentions "Task App"; got: ${features.h1Text}`,
    );
    assert.ok(
      features.h2Count >= 2,
      `expected >= 2 <h2> in spec pane, got ${features.h2Count}`,
    );
    assert.ok(
      features.listCount >= 1,
      `expected >= 1 list (<ul>/<ol>) in spec pane, got ${features.listCount}`,
    );
    assert.ok(
      features.codeCount >= 1,
      `expected >= 1 <pre>/<code> in spec pane, got ${features.codeCount}`,
    );
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// View mode is NOT editable
// ---------------------------------------------------------------------------

test("e2e_spec_pane_view_mode_is_not_editable", async () => {
  const { ctx, page } = await openEditor();
  try {
    await selectTaskAppStory(page);
    await switchToSpec(page);

    // Wait for the TipTap mount to settle.
    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-spec-pane-tiptap-host="true"]',
        );
        return !!host && host.getAttribute("data-tiptap-mounted") === "true";
      },
      { timeout: 10000 },
    );

    // TipTap exposes its editability flag on the container via the
    // shim's ``data-tiptap-editable`` attribute. View mode mounts the
    // editor with ``editable: false`` so the attribute must read
    // ``"false"``.
    const editableAttr = await page.evaluate(() => {
      const host = document.querySelector(
        '[data-spec-pane-tiptap-host="true"]',
      );
      return host ? host.getAttribute("data-tiptap-editable") : null;
    });
    assert.equal(
      editableAttr,
      "false",
      "View-mode TipTap container reports data-tiptap-editable='false'",
    );

    // Capture the H1 text before the typing attempt.
    const before = await page.evaluate(() => {
      const h1 = document.querySelector(
        '[data-spec-pane-tiptap-host="true"] h1',
      );
      return h1 ? (h1.textContent || "").trim() : null;
    });
    assert.ok(before && before.length > 0, "H1 has content before typing");

    // Try to mutate via keyboard. We focus the host (so any keyboard
    // event would route to TipTap) and type a sentinel string. A
    // read-only TipTap editor must NOT mutate the H1 text in
    // response.
    await page.evaluate(() => {
      const host = document.querySelector(
        '[data-spec-pane-tiptap-host="true"]',
      );
      if (!host) return;
      // Try to focus the contenteditable area (read-only mode still
      // has a contenteditable=false div).
      const editable = host.querySelector(".ProseMirror");
      if (editable && editable.focus) editable.focus();
    });
    await page.keyboard.type("XXXX-MUTATION-ATTEMPT");

    // Re-read the H1 text and assert it is unchanged.
    const after = await page.evaluate(() => {
      const h1 = document.querySelector(
        '[data-spec-pane-tiptap-host="true"] h1',
      );
      return h1 ? (h1.textContent || "").trim() : null;
    });
    assert.equal(
      after,
      before,
      "View-mode H1 text is unchanged after a typing attempt",
    );
    assert.ok(
      !(after && after.includes("XXXX-MUTATION-ATTEMPT")),
      "the sentinel string did not land inside the spec pane H1",
    );
  } finally {
    await ctx.close();
  }
});
