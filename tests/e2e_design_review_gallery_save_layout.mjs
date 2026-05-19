// REV-M8 — e2e test: save / list / load layouts via the real
// ``isonim-review serve`` daemon driven by Playwright against a
// thin harness page.
//
// The harness page mounts the same DOM shape ``mountGalleryOverlay``
// produces (its equivalence with the production ui-DSL output is
// asserted by ``test_design_review_gallery_vm.test_gallery_view_mounts_under_mock_renderer``)
// and binds a Save button to POST ``/api/design-review/save-layout``.
//
// Two tests:
//   * e2e_drag_rearrange_persists_after_reload — drag tile, save,
//     reload, observe persistence.
//   * e2e_cli_layouts_save_and_load — drive the ``isonim-review
//     layouts save`` + ``isonim-review layouts ls`` CLI against the
//     same DB the daemon is serving from.

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
const PAGE_PORT = 18460;

function exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

function pickPort(base) {
  for (let i = 0; i < 200; i++) {
    const candidate = base + ((Date.now() + i) % 200);
    try {
      execSync(
        `curl -s -o /dev/null --max-time 0.5 http://127.0.0.1:${candidate}/`,
        { stdio: "pipe" },
      );
    } catch {
      return candidate;
    }
  }
  throw new Error("no free port " + base);
}

function bootPostgres() {
  pgDataDir = mkdtempSync(join(tmpdir(), "isonim-revm8-pg-"));
  pgPort = pickPort(5800);
  exec(`initdb --locale=C.UTF-8 --encoding=UTF8 --auth=trust -D ${pgDataDir}`);
  const conf = `\nlisten_addresses = '127.0.0.1'\nport = ${pgPort}\nunix_socket_directories = '${pgDataDir}'\n`;
  writeFileSync(join(pgDataDir, "postgresql.conf"), conf, { flag: "a" });
  exec(
    `pg_ctl -D ${pgDataDir} -l ${join(pgDataDir, "log")} -w start </dev/null >/dev/null 2>&1`,
  );
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
  exec(`${CLI_PATH} init --migrations ${MIG_DIR}`, {
    env: {
      ...process.env,
      ISONIM_REVIEW_PGHOST: "127.0.0.1",
      ISONIM_REVIEW_PGPORT: String(pgPort),
    },
  });
}

function startDaemon() {
  httpPort = pickPort(18600);
  storeDir = mkdtempSync(join(tmpdir(), "isonim-revm8-store-"));
  configPath = join(tmpdir(), `isonim-revm8-config-${Date.now()}.toml`);
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
      return;
    } catch {
      execSync("sleep 0.15");
    }
  }
  throw new Error("daemon failed to bind " + httpPort);
}

function pageHtml() {
  return `<!doctype html>
<html><head><meta charset="utf-8"><title>REV-M8 layout e2e</title></head>
<body>
<div id="status">init</div>
<button id="save-btn" data-design-review-save-layout="true">Save layout</button>
<div id="conflict-dialog" data-design-review-conflict-dialog="true" style="display:none">
  Conflict! <button id="reload-btn">Reload</button>
</div>
<div id="gallery-host"></div>
<script>
  const BASE = "http://127.0.0.1:${httpPort}";
  const briefId = "render.task-app";
  const userId = "alice";
  let state = {
    layoutId: null, version: 0,
    pendingLayout: [{ captureId: "cap-a", row: 0, col: 0 },
                    { captureId: "cap-b", row: 0, col: 1 }],
    isDirty: false,
  };
  function setStatus(s) { document.getElementById("status").textContent = s; }
  async function saveLayout() {
    const body = {
      briefId, scope: "user", ownerUserId: userId,
      name: "default",
      layout: { version: 1, entries: state.pendingLayout },
      expectedVersion: state.layoutId ? state.version : null,
      layoutId: state.layoutId || undefined,
    };
    const r = await fetch(BASE + "/api/design-review/save-layout", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const j = await r.json();
    if (r.status === 200) {
      state.layoutId = j.layout_id;
      state.version = j.version;
      state.isDirty = false;
      setStatus("saved:v" + state.version);
    } else if (r.status === 409) {
      document.getElementById("conflict-dialog").style.display = "block";
      setStatus("conflict");
    } else {
      setStatus("error:" + r.status);
    }
  }
  async function loadLayout() {
    const r = await fetch(BASE + "/api/design-review/list-layouts?briefId=" +
      encodeURIComponent(briefId) + "&userId=" + encodeURIComponent(userId));
    const arr = await r.json();
    if (arr.length > 0) {
      const row = arr[0];
      state.layoutId = row.layout_id;
      state.version = row.version;
      state.pendingLayout = (row.layout && row.layout.entries) || [];
      setStatus("loaded:v" + state.version + ":" + state.pendingLayout.length + ":" +
        JSON.stringify(state.pendingLayout));
    } else {
      setStatus("loaded:empty");
    }
  }
  function dragTo(captureId, row, col) {
    let found = false;
    for (const e of state.pendingLayout) {
      if (e.captureId === captureId) {
        e.row = row; e.col = col; found = true; break;
      }
    }
    if (!found) state.pendingLayout.push({ captureId, row, col });
    state.isDirty = true;
  }
  document.getElementById("save-btn").addEventListener("click", saveLayout);
  window.__loadLayout = loadLayout;
  window.__dragTo = dragTo;
  window.__state = () => state;
  window.__saveLayout = saveLayout;
  loadLayout();
</script>
</body></html>`;
}

function startPageServer() {
  const html = pageHtml();
  const pageDir = mkdtempSync(join(tmpdir(), "isonim-revm8-page-"));
  writeFileSync(join(pageDir, "index.html"), html);
  pageServer = spawn(
    "python3",
    ["-m", "http.server", String(PAGE_PORT), "--bind", "127.0.0.1"],
    { cwd: pageDir, stdio: "ignore", detached: true },
  );
  execSync("sleep 1");
}

function cleanupTruncate() {
  exec(
    `psql -h 127.0.0.1 -p ${pgPort} -d isonim_design_review -v ON_ERROR_STOP=1 -c "TRUNCATE TABLE design_review.audit_events, design_review.agent_reports, design_review.captures, design_review.gallery_layouts, design_review.runs CASCADE"`,
  );
}

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

test.before(async () => {
  if (!existsSync(CLI_PATH))
    throw new Error(
      "build/bin/isonim-review missing — run ``just isonim-review-build``",
    );
  bootPostgres();
  applyMigrations();
  startDaemon();
  startPageServer();
});

test.after(async () => {
  try {
    if (browser) await browser.close();
  } catch {}
  try {
    if (daemonProc) daemonProc.kill("SIGTERM");
  } catch {}
  try {
    if (pageServer) process.kill(-pageServer.pid);
  } catch {}
  try {
    exec(`pg_ctl -D ${pgDataDir} stop -m fast`);
  } catch {}
  try {
    rmSync(pgDataDir, { recursive: true, force: true });
  } catch {}
  try {
    rmSync(storeDir, { recursive: true, force: true });
  } catch {}
});

test("e2e_drag_rearrange_persists_after_reload", async () => {
  cleanupTruncate();
  const b = await ensureBrowser();
  const ctx = await b.newContext();
  const page = await ctx.newPage();
  await page.goto(`http://127.0.0.1:${PAGE_PORT}/`);
  // Wait for initial load (no layout → "loaded:empty").
  await page.waitForFunction(
    () => document.getElementById("status").textContent.startsWith("loaded:"),
    { timeout: 5000 },
  );
  // Drag tile A from (0,0) → (2,1).
  await page.evaluate(() => window.__dragTo("cap-a", 2, 1));
  // Click save.
  await page.click('[data-design-review-save-layout="true"]');
  await page.waitForFunction(
    () => document.getElementById("status").textContent.startsWith("saved:"),
    { timeout: 5000 },
  );
  // Reload page (new browser context to mimic editor reload).
  await page.reload();
  await page.waitForFunction(
    () => document.getElementById("status").textContent.startsWith("loaded:"),
    { timeout: 5000 },
  );
  const finalStatus = await page.evaluate(
    () => document.getElementById("status").textContent,
  );
  // After reload the loaded layout must report cap-a at row 2.
  assert.ok(
    finalStatus.includes("cap-a"),
    "loaded layout has cap-a: " + finalStatus,
  );
  assert.ok(finalStatus.includes('"row":2'), "row=2 persisted: " + finalStatus);
  await ctx.close();
});

test("e2e_cli_layouts_save_and_load", async () => {
  cleanupTruncate();
  // Drop a layout file and run the CLI against the same DB.
  const layoutFile = join(tmpdir(), `revm8-layout-${Date.now()}.json`);
  writeFileSync(layoutFile, JSON.stringify({ version: 1, entries: [] }));
  const env = {
    ...process.env,
    ISONIM_REVIEW_PGHOST: "127.0.0.1",
    ISONIM_REVIEW_PGPORT: String(pgPort),
  };
  const out = execSync(
    `${CLI_PATH} layouts save --brief render.task-app --name foo --layout ${layoutFile} --user alice`,
    { env, stdio: "pipe" },
  ).toString();
  assert.ok(out.includes("layout_id"), "save output has layout_id: " + out);
  const lsOut = execSync(
    `${CLI_PATH} layouts ls --brief render.task-app --user alice`,
    { env, stdio: "pipe" },
  ).toString();
  assert.ok(lsOut.includes("foo"), "ls output includes 'foo': " + lsOut);
});
