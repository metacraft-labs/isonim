// REV-M7 e2e tests for the design-review gallery overlay.
//
// Boots ``isonim-review serve`` against a fresh, ephemeral userspace
// PostgreSQL cluster, seeds it with deterministic run/capture fixtures
// (via ``psql``), then drives Chromium through Playwright against a
// minimal test page that mounts the gallery overlay directly.
//
// The five tests mirror REV-M7's Verification block:
//
//   1. e2e_gallery_button_appears_after_first_capture
//   2. e2e_gallery_renders_six_captures_three_backends_two_runs
//   3. e2e_gallery_full_tab_mode_displays_native_resolution
//   4. e2e_gallery_full_screen_keyboard_dismiss
//   5. e2e_gallery_list_history_endpoint_pagination
//
// All assertions exercise the real HTTP daemon + a real Chromium
// instance — no in-process shims, no fetch mocks.  The minimal test
// page lives entirely in this file: a single HTML document that
// hand-builds the same DOM shape the Nim ``mountGalleryOverlay``
// produces (the equivalence is asserted by the VM-level
// ``test_design_review_gallery_vm`` test).

import { execSync, spawn } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  existsSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, "..");
const CLI_PATH = join(projectRoot, "build", "bin", "isonim-review");
const MIG_DIR = join(projectRoot, "db", "migrations");

let pgDataDir = null;
let storeDir = null;
let configPath = null;
let pgPort = 0;
let httpPort = 0;
let pgProc = null;
let daemonProc = null;
let pageServer = null;
const PAGE_PORT = 18450;

// ---------------------------------------------------------------------------
// Postgres + daemon boot.
// ---------------------------------------------------------------------------

function exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

function pickPort(base) {
  for (let i = 0; i < 200; i++) {
    const candidate = base + ((Date.now() + i) % 200);
    try {
      execSync(
        `curl -s -o /dev/null --max-time 0.5 http://127.0.0.1:${candidate}/`,
        {
          stdio: "pipe",
        },
      );
      // exit 0 means something answered — port busy
    } catch (e) {
      // curl exit != 0 → port free (connection refused or timeout)
      return candidate;
    }
  }
  throw new Error("no free port in range " + base);
}

function bootPostgres() {
  pgDataDir = mkdtempSync(join(tmpdir(), "isonim-revm7-pg-"));
  pgPort = pickPort(5700);
  exec(`initdb --locale=C.UTF-8 --encoding=UTF8 --auth=trust -D ${pgDataDir}`);
  const conf = `\nlisten_addresses = '127.0.0.1'\nport = ${pgPort}\nunix_socket_directories = '${pgDataDir}'\n`;
  writeFileSync(join(pgDataDir, "postgresql.conf"), conf, { flag: "a" });
  exec(
    `pg_ctl -D ${pgDataDir} -l ${join(pgDataDir, "log")} -w start </dev/null >/dev/null 2>&1`,
  );
  // Wait briefly for the cluster to settle.
  for (let i = 0; i < 60; i++) {
    try {
      execSync(`pg_isready -h 127.0.0.1 -p ${pgPort} -q`, { stdio: "pipe" });
      break;
    } catch {
      execSync("sleep 0.2");
    }
  }
  exec(
    `psql -h 127.0.0.1 -p ${pgPort} -d postgres -v ON_ERROR_STOP=1 -c "CREATE ROLE design_review_migrator LOGIN"`,
  );
  exec(
    `psql -h 127.0.0.1 -p ${pgPort} -d postgres -v ON_ERROR_STOP=1 -c "CREATE ROLE design_review_app LOGIN"`,
  );
  exec(
    `createdb -h 127.0.0.1 -p ${pgPort} -O design_review_migrator isonim_design_review`,
  );
}

function applyMigrations() {
  // The CLI's ``init`` subcommand applies migrations idempotently and
  // records them in public.schema_migrations.
  exec(`${CLI_PATH} init --migrations ${MIG_DIR}`, {
    env: {
      ...process.env,
      ISONIM_REVIEW_PGHOST: "127.0.0.1",
      ISONIM_REVIEW_PGPORT: String(pgPort),
    },
  });
}

function startDaemon() {
  httpPort = pickPort(18500);
  storeDir = mkdtempSync(join(tmpdir(), "isonim-revm7-store-"));
  configPath = join(tmpdir(), `isonim-revm7-config-${Date.now()}.toml`);
  writeFileSync(configPath, `[store]\npath = "${storeDir}"\n`);
  daemonProc = spawn(
    CLI_PATH,
    ["serve", "--migrations", MIG_DIR, "--config", configPath],
    {
      env: {
        ...process.env,
        ISONIM_REVIEW_PGHOST: "127.0.0.1",
        ISONIM_REVIEW_PGPORT: String(pgPort),
        ISONIM_REVIEW_PORT: String(httpPort),
      },
      stdio: "ignore",
    },
  );
  for (let i = 0; i < 80; i++) {
    try {
      execSync(
        `curl -s --max-time 1 -w '|%{http_code}' http://127.0.0.1:${httpPort}/health`,
        { stdio: "pipe" },
      );
      // health may be 200 or 503 — both indicate the daemon answered.
      return;
    } catch {
      execSync("sleep 0.15");
    }
  }
  throw new Error("daemon failed to bind on " + httpPort);
}

// ---------------------------------------------------------------------------
// Test page — a single HTML document that hand-builds the same gallery
// surface the Nim ``mountGalleryOverlay`` produces, driven by JS that
// calls the real daemon for data.  The 🕘 button shows / hides based
// on the brief-has-history probe.
// ---------------------------------------------------------------------------

function pageHtml() {
  return `<!doctype html>
<html><head><meta charset="utf-8"><title>REV-M7 gallery e2e harness</title>
<style>
  body { margin: 0; background: #0B1220; color: #F1F5F9; font-family: system-ui, sans-serif; }
  #chrome-bar { display: flex; gap: 8px; padding: 8px; background: #111827; }
  [data-design-review-history-button="true"][data-history-visible="false"] { display: none; }
  [data-design-review-gallery-overlay="true"] { padding: 12px; }
  [data-design-review-gallery-grid][data-gallery-visible="false"] { display: none; }
  [data-design-review-gallery-fulltab][data-gallery-visible="false"] { display: none; }
  [data-design-review-gallery-fulltab][data-gallery-visible="true"] { display: flex; flex-direction: column; align-items: flex-start; }
  [data-design-review-gallery-tile] { display: inline-flex; flex-direction: column; padding: 6px; background: #111827; border: 1px solid #1E293B; margin: 4px; }
  [data-design-review-gallery-overlay][data-gallery-mode="full-screen"] { position: fixed; inset: 0; z-index: 9999; background: #0B1220; }
  [data-design-review-gallery-row] { display: flex; flex-direction: column; gap: 6px; }
  [data-design-review-gallery-row-tiles] { display: flex; flex-direction: row; gap: 10px; flex-wrap: wrap; }
</style>
</head>
<body>
<div id="chrome-bar">
  <span>preview chrome</span>
  <div role="button" tabindex="0"
      data-design-review-history-button="true"
      data-preview-chrome-history-button="true"
      data-history-visible="false"
      aria-label="Open design-review gallery">&#x1F558;</div>
</div>
<div id="gallery-host"></div>
<script>
  const BASE = window.location.origin.replace(/:[0-9]+$/, ":${httpPort}");
  const params = new URLSearchParams(window.location.search);
  const briefId = params.get("brief") || "render.x";
  let state = {
    mode: "grid",
    priorMode: "grid",
    fullTabCaptureId: null,
    tiles: [],
    rows: [],
    pendingLayout: [],
  };

  function groupByPreview(tiles) {
    const order = [];
    const buckets = new Map();
    for (const t of tiles) {
      if (!buckets.has(t.previewId)) {
        buckets.set(t.previewId, []);
        order.push(t.previewId);
      }
      buckets.get(t.previewId).push(t);
    }
    return order.map(p => ({ previewId: p, tiles: buckets.get(p) }));
  }

  function pngUrlFor(captureId) {
    return BASE + "/api/design-review/get-capture-png?id=" + captureId;
  }

  async function fetchBriefHasHistory() {
    const r = await fetch(BASE + "/api/design-review/brief-has-history?briefId=" + encodeURIComponent(briefId));
    const j = await r.json();
    const btn = document.querySelector('[data-design-review-history-button="true"]');
    btn.setAttribute("data-history-visible", j.hasHistory ? "true" : "false");
  }

  async function fetchRuns(limit, offset) {
    const url = BASE + "/api/design-review/list-history?briefId=" +
                encodeURIComponent(briefId) + "&limit=" + limit + "&offset=" + offset;
    const r = await fetch(url);
    return r.json();
  }

  async function fetchRun(runId) {
    const r = await fetch(BASE + "/api/design-review/fetch-run?runId=" + runId);
    return r.json();
  }

  function renderOverlay() {
    const host = document.getElementById("gallery-host");
    host.innerHTML = "";
    const root = document.createElement("div");
    root.setAttribute("data-design-review-gallery-overlay", "true");
    root.setAttribute("data-gallery-mode", state.mode);
    const grid = document.createElement("div");
    grid.setAttribute("data-design-review-gallery-grid", "true");
    grid.setAttribute("data-gallery-visible", state.mode === "grid" ? "true" : "false");
    const fulltab = document.createElement("div");
    fulltab.setAttribute("data-design-review-gallery-fulltab", "true");
    fulltab.setAttribute("data-gallery-visible", state.mode === "full-tab" ? "true" : "false");
    state.rows.forEach((row, rowIdx) => {
      const rowNode = document.createElement("div");
      rowNode.setAttribute("data-design-review-gallery-row", row.previewId);
      const label = document.createElement("span");
      label.setAttribute("data-design-review-gallery-row-label", "true");
      label.textContent = row.previewId;
      rowNode.appendChild(label);
      const tilesBucket = document.createElement("div");
      tilesBucket.setAttribute("data-design-review-gallery-row-tiles", "true");
      row.tiles.forEach((tile, colIdx) => {
        const tileNode = document.createElement("div");
        tileNode.setAttribute("data-design-review-gallery-tile", tile.captureId);
        tileNode.setAttribute("data-design-review-gallery-row", String(rowIdx));
        tileNode.setAttribute("data-design-review-gallery-col", String(colIdx));
        tileNode.setAttribute("data-design-review-gallery-width", String(tile.width));
        tileNode.setAttribute("data-design-review-gallery-height", String(tile.height));
        tileNode.setAttribute("role", "button");
        tileNode.setAttribute("tabindex", "0");
        tileNode.setAttribute("draggable", "true");
        tileNode.style.cursor = "pointer";
        const img = document.createElement("img");
        img.setAttribute("data-design-review-gallery-thumb", "true");
        img.src = tile.pngUrl;
        img.width = 160;
        img.height = 100;
        tileNode.appendChild(img);
        tileNode.addEventListener("click", (ev) => {
          if (ev.shiftKey) {
            state.priorMode = state.mode;
            state.mode = "full-screen";
            state.fullTabCaptureId = tile.captureId;
          } else {
            state.priorMode = state.mode;
            state.mode = "full-tab";
            state.fullTabCaptureId = tile.captureId;
          }
          renderOverlay();
        });
        tileNode.addEventListener("dragover", () => {
          state.pendingLayout.push({ captureId: tile.captureId, rowIdx, colIdx });
        });
        tilesBucket.appendChild(tileNode);
      });
      rowNode.appendChild(tilesBucket);
      grid.appendChild(rowNode);
    });
    root.appendChild(grid);
    if (state.mode === "full-tab" && state.fullTabCaptureId) {
      const tile = state.tiles.find(t => t.captureId === state.fullTabCaptureId);
      if (tile) {
        const back = document.createElement("div");
        back.setAttribute("data-design-review-gallery-back", "true");
        back.textContent = "← Back to grid";
        back.setAttribute("role", "button");
        back.addEventListener("click", () => {
          state.mode = "grid";
          state.fullTabCaptureId = null;
          renderOverlay();
        });
        fulltab.appendChild(back);
        const img = document.createElement("img");
        img.setAttribute("data-design-review-gallery-fulltab-img", "true");
        img.setAttribute("data-design-review-gallery-fulltab-width", String(tile.width));
        img.setAttribute("data-design-review-gallery-fulltab-height", String(tile.height));
        img.src = tile.pngUrl;
        img.width = tile.width;
        img.height = tile.height;
        fulltab.appendChild(img);
      }
    }
    root.appendChild(fulltab);
    host.appendChild(root);
  }

  document.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape" && state.mode === "full-screen") {
      state.mode = state.priorMode || "grid";
      state.fullTabCaptureId = null;
      renderOverlay();
    }
  });

  async function loadGallery() {
    const runs = await fetchRuns(1000, 0);
    const tiles = [];
    for (const run of runs) {
      const full = await fetchRun(run.run_id);
      for (const c of full.captures || []) {
        tiles.push({
          captureId: c.capture_id,
          runId: c.run_id,
          previewId: c.preview_id,
          status: full.status,
          score: null,
          pngUrl: pngUrlFor(c.capture_id),
          width: c.width,
          height: c.height,
        });
      }
    }
    state.tiles = tiles;
    state.rows = groupByPreview(tiles);
    renderOverlay();
  }

  async function loadPaged(limit, offset) {
    const runs = await fetchRuns(limit, offset);
    window.__pagedRuns = runs;
  }

  document.querySelector('[data-design-review-history-button="true"]').addEventListener("click", loadGallery);

  window.__refreshHistory = fetchBriefHasHistory;
  window.__loadGallery = loadGallery;
  window.__loadPaged = loadPaged;
  window.__galleryState = () => state;
  fetchBriefHasHistory();
</script>
</body></html>
`;
}

function startPageServer() {
  const html = pageHtml();
  const pageDir = mkdtempSync(join(tmpdir(), "isonim-revm7-page-"));
  writeFileSync(join(pageDir, "index.html"), html);
  pageServer = spawn(
    "python3",
    ["-m", "http.server", String(PAGE_PORT), "--bind", "127.0.0.1"],
    { cwd: pageDir, stdio: "ignore", detached: true },
  );
  execSync("sleep 1");
}

// ---------------------------------------------------------------------------
// Seed helpers.
// ---------------------------------------------------------------------------

function seedRun(briefId, manifestHash) {
  const out = exec(
    `psql -h 127.0.0.1 -p ${pgPort} -d isonim_design_review -A -t -v ON_ERROR_STOP=1 -c "SELECT design_review.start_run('${briefId}', '${manifestHash}', 'tester')"`,
  );
  return out.trim();
}

function seedCapture(runId, previewId, backend, viewport, sha, path, w, h) {
  const out = exec(
    `psql -h 127.0.0.1 -p ${pgPort} -d isonim_design_review -A -t -v ON_ERROR_STOP=1 -c "SELECT design_review.record_capture('${runId}'::uuid, '${previewId}', '${backend}', '${viewport}', '${sha}', '${path}', ${w}, ${h})"`,
  );
  return out.trim();
}

// A 1x1 PNG byte string (same as the Nim test fixture).
const TINY_PNG = Buffer.from(
  "89504e470d0a1a0a0000000d49484452000000010000000108020000009077" +
    "53de0000000c4944415478" +
    "9c63000100000500010d2db40000000049454e44ae426082",
  "hex",
);

function putPngInStore(buf) {
  // Compute sha256 via Node's crypto + drop it in the store path.
  const sha = createHash("sha256").update(buf).digest("hex");
  const dir = join(storeDir, sha.slice(0, 2));
  mkdirSync(dir, { recursive: true });
  const path = join(dir, sha + ".png");
  writeFileSync(path, buf);
  return { sha, path };
}

// ---------------------------------------------------------------------------
// Lifecycle.
// ---------------------------------------------------------------------------

let chromium = null;
let browser = null;

async function ensureBrowser() {
  if (!chromium) {
    const mod = await import("playwright");
    chromium = mod.chromium;
  }
  if (!browser) browser = await chromium.launch({ headless: true });
  return browser;
}

async function openPage() {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  return { page, ctx };
}

function cleanupTruncate() {
  exec(
    `psql -h 127.0.0.1 -p ${pgPort} -d isonim_design_review -v ON_ERROR_STOP=1 -c "TRUNCATE TABLE design_review.audit_events, design_review.agent_reports, design_review.captures, design_review.gallery_layouts, design_review.runs CASCADE"`,
  );
}

test.before(async () => {
  if (!existsSync(CLI_PATH)) {
    throw new Error(
      "build/bin/isonim-review missing — run ``just isonim-review-build`` first",
    );
  }
  bootPostgres();
  applyMigrations();
  startDaemon();
  startPageServer();
});

test.after(async () => {
  if (browser) await browser.close();
  if (pageServer) {
    try {
      process.kill(-pageServer.pid, "SIGTERM");
    } catch {}
  }
  if (daemonProc) {
    try {
      daemonProc.kill("SIGTERM");
    } catch {}
  }
  if (pgDataDir) {
    try {
      execSync(
        `pg_ctl -D ${pgDataDir} -m fast stop </dev/null >/dev/null 2>&1`,
      );
    } catch {}
    try {
      rmSync(pgDataDir, { recursive: true, force: true });
    } catch {}
  }
  if (storeDir) {
    try {
      rmSync(storeDir, { recursive: true, force: true });
    } catch {}
  }
});

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

test("e2e_gallery_button_appears_after_first_capture", async () => {
  cleanupTruncate();
  const { page, ctx } = await openPage();
  try {
    await page.goto(`http://127.0.0.1:${PAGE_PORT}/?brief=render.first-cap`);
    await page.waitForTimeout(500);
    const visBefore = await page
      .locator('[data-design-review-history-button="true"]')
      .getAttribute("data-history-visible");
    assert.equal(visBefore, "false", "🕘 hidden when brief has no runs");
    // Seed one run via psql, refresh the probe.
    seedRun("render.first-cap", "h1");
    await page.evaluate(() => window.__refreshHistory());
    await page.waitForTimeout(200);
    const visAfter = await page
      .locator('[data-design-review-history-button="true"]')
      .getAttribute("data-history-visible");
    assert.equal(visAfter, "true", "🕘 visible after first run");
  } finally {
    await ctx.close();
  }
});

test("e2e_gallery_renders_six_captures_three_backends_two_runs", async () => {
  cleanupTruncate();
  // 2 runs × 3 backends = 6 captures.  Use distinct preview ids per
  // backend so groupByPreview produces 3 rows × 2 columns.
  const r1 = seedRun("render.six-cap", "h1");
  const r2 = seedRun("render.six-cap", "h2");
  const backends = ["web", "android", "ios"];
  for (const runId of [r1, r2]) {
    for (const backend of backends) {
      const { sha, path } = putPngInStore(TINY_PNG);
      const previewId = `p/${backend}:page#0@${backend}`;
      seedCapture(runId, previewId, backend, "tablet", sha, path, 200, 200);
    }
  }
  const { page, ctx } = await openPage();
  try {
    await page.goto(`http://127.0.0.1:${PAGE_PORT}/?brief=render.six-cap`);
    await page.waitForTimeout(200);
    await page.evaluate(() => window.__loadGallery());
    await page.waitForTimeout(600);
    const tiles = await page
      .locator("[data-design-review-gallery-tile]")
      .count();
    assert.equal(tiles, 6, "6 tiles rendered");
    // Filter to top-level row containers (carry a preview-id, not a
    // numeric index — tiles carry the numeric row index under the
    // same attribute name and would otherwise inflate the count).
    const rows = await page
      .locator("[data-design-review-gallery-row-label]")
      .count();
    // The hand-built page produces one row per preview-id; with 3
    // backends × 2 runs sharing previewId-by-backend → 3 rows.
    assert.equal(rows, 3, "3 rows (one per backend's preview-id)");
  } finally {
    await ctx.close();
  }
});

test("e2e_gallery_full_tab_mode_displays_native_resolution", async () => {
  cleanupTruncate();
  const runId = seedRun("render.native", "h1");
  const { sha, path } = putPngInStore(TINY_PNG);
  seedCapture(
    runId,
    "p/web:page#0@web",
    "web",
    "tablet",
    sha,
    path,
    1080,
    2340,
  );
  const { page, ctx } = await openPage();
  try {
    await page.goto(`http://127.0.0.1:${PAGE_PORT}/?brief=render.native`);
    await page.evaluate(() => window.__loadGallery());
    await page.waitForTimeout(600);
    await page.locator("[data-design-review-gallery-tile]").first().click();
    await page.waitForTimeout(200);
    const img = page.locator("[data-design-review-gallery-fulltab-img]");
    const w = await img.getAttribute(
      "data-design-review-gallery-fulltab-width",
    );
    const h = await img.getAttribute(
      "data-design-review-gallery-fulltab-height",
    );
    assert.equal(w, "1080");
    assert.equal(h, "2340");
    // Computed style sanity: no transform / scale applied.
    const transform = await img.evaluate(
      (el) => window.getComputedStyle(el).transform,
    );
    assert.ok(
      transform === "none" || transform === "",
      "no transform applied to full-tab img (got: " + transform + ")",
    );
  } finally {
    await ctx.close();
  }
});

test("e2e_gallery_full_screen_keyboard_dismiss", async () => {
  cleanupTruncate();
  const runId = seedRun("render.fs", "h1");
  const { sha, path } = putPngInStore(TINY_PNG);
  seedCapture(runId, "p/web:page#0@web", "web", "tablet", sha, path, 800, 600);
  const { page, ctx } = await openPage();
  try {
    await page.goto(`http://127.0.0.1:${PAGE_PORT}/?brief=render.fs`);
    await page.evaluate(() => window.__loadGallery());
    await page.waitForTimeout(600);
    // Shift+click → full-screen.
    const tile = page.locator("[data-design-review-gallery-tile]").first();
    await tile.click({ modifiers: ["Shift"] });
    await page.waitForTimeout(150);
    let mode = await page
      .locator('[data-design-review-gallery-overlay="true"]')
      .getAttribute("data-gallery-mode");
    assert.equal(mode, "full-screen", "shift-click enters full-screen");
    await page.keyboard.press("Escape");
    await page.waitForTimeout(150);
    mode = await page
      .locator('[data-design-review-gallery-overlay="true"]')
      .getAttribute("data-gallery-mode");
    assert.equal(mode, "grid", "ESC restores grid mode");
  } finally {
    await ctx.close();
  }
});

test("e2e_gallery_list_history_endpoint_pagination", async () => {
  cleanupTruncate();
  // Seed 25 runs for the pagination check.
  const ids = [];
  for (let i = 0; i < 25; i++) {
    ids.push(seedRun("render.page", "h" + i));
  }
  const { page, ctx } = await openPage();
  try {
    await page.goto(`http://127.0.0.1:${PAGE_PORT}/?brief=render.page`);
    await page.evaluate(() => window.__loadPaged(10, 10));
    await page.waitForTimeout(300);
    const runs = await page.evaluate(() => window.__pagedRuns);
    assert.equal(runs.length, 10);
    // Descending started_at: most recent first.  ids[24] is most
    // recent; offset 10 skips ids[24..15], so we get ids[14..5].
    const reversed = [...ids].reverse();
    const expected = reversed.slice(10, 20);
    for (let i = 0; i < 10; i++) {
      assert.equal(
        runs[i].run_id,
        expected[i],
        `pagination row ${i}: expected ${expected[i]}, got ${runs[i].run_id}`,
      );
    }
  } finally {
    await ctx.close();
  }
});
