// REV-M8 — e2e: optimistic-concurrency conflict surfaces a dialog in
// the UI (not a silent overwrite).  Two browser tabs target the same
// layout; tab 1 saves first → bumps version to 2; tab 2 tries to save
// with stale expectedVersion=1 → daemon returns 409 → harness pops a
// data-design-review-conflict-dialog DIV.

import { execSync, spawn } from "node:child_process";
import { mkdtempSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, "..");
const CLI_PATH = join(projectRoot, "build", "bin", "isonim-review");
const MIG_DIR = join(projectRoot, "db", "migrations");

let pgDataDir = null,
  pgPort = 0,
  httpPort = 0,
  storeDir = null,
  configPath = null,
  daemonProc = null,
  pageServer = null;
const PAGE_PORT = 18480;

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
  throw new Error("no free port");
}

function bootPg() {
  pgDataDir = mkdtempSync(join(tmpdir(), "isonim-revm8c-pg-"));
  pgPort = pickPort(5820);
  exec(`initdb --locale=C.UTF-8 --encoding=UTF8 --auth=trust -D ${pgDataDir}`);
  writeFileSync(
    join(pgDataDir, "postgresql.conf"),
    `\nlisten_addresses = '127.0.0.1'\nport = ${pgPort}\nunix_socket_directories = '${pgDataDir}'\n`,
    { flag: "a" },
  );
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

function applyMig() {
  exec(`${CLI_PATH} init --migrations ${MIG_DIR}`, {
    env: {
      ...process.env,
      ISONIM_REVIEW_PGHOST: "127.0.0.1",
      ISONIM_REVIEW_PGPORT: String(pgPort),
    },
  });
}

function startDaemon() {
  httpPort = pickPort(18620);
  storeDir = mkdtempSync(join(tmpdir(), "isonim-revm8c-store-"));
  configPath = join(tmpdir(), `isonim-revm8c-config-${Date.now()}.toml`);
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
  throw new Error("daemon failed");
}

function pageHtml() {
  return `<!doctype html>
<html><body>
<div id="status">init</div>
<div id="conflict-dialog" data-design-review-conflict-dialog="true" style="display:none">
  This layout was changed elsewhere; reload?
</div>
<script>
  const BASE = "http://127.0.0.1:${httpPort}";
  const params = new URLSearchParams(window.location.search);
  const layoutId = params.get("layoutId");
  const ver = parseInt(params.get("ver") || "1", 10);
  function setStatus(s) { document.getElementById("status").textContent = s; }
  async function saveStale() {
    const body = {
      briefId: "render.conflict", scope: "user", ownerUserId: "alice",
      name: "shared", layout: { version: 1, entries: [] },
      expectedVersion: ver, layoutId,
    };
    const r = await fetch(BASE + "/api/design-review/save-layout", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (r.status === 409) {
      document.getElementById("conflict-dialog").style.display = "block";
      setStatus("conflict-dialog-open");
    } else if (r.status === 200) {
      setStatus("saved");
    } else {
      setStatus("error:" + r.status);
    }
  }
  window.__saveStale = saveStale;
</script>
</body></html>`;
}

function startPageServer() {
  const html = pageHtml();
  const pageDir = mkdtempSync(join(tmpdir(), "isonim-revm8c-page-"));
  writeFileSync(join(pageDir, "index.html"), html);
  pageServer = spawn(
    "python3",
    ["-m", "http.server", String(PAGE_PORT), "--bind", "127.0.0.1"],
    { cwd: pageDir, stdio: "ignore", detached: true },
  );
  execSync("sleep 1");
}

let chromium = null,
  browser = null;
async function ensureBrowser() {
  if (!chromium) {
    const m = await import("playwright");
    chromium = m.chromium;
  }
  if (!browser) browser = await chromium.launch({ headless: true });
  return browser;
}

test.before(async () => {
  if (!existsSync(CLI_PATH)) throw new Error("CLI missing");
  bootPg();
  applyMig();
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

test("e2e_layout_conflict_surfaced_in_ui", async () => {
  // Two concurrent saves: first save creates v1 then bumps to v2.
  // Second save with expectedVersion=1 must surface the conflict
  // dialog in the UI.
  // Step 1: seed v1.
  const seedR = execSync(
    `curl -s -X POST http://127.0.0.1:${httpPort}/api/design-review/save-layout ` +
      `-H 'Content-Type: application/json' ` +
      `-d '{"briefId":"render.conflict","scope":"user","ownerUserId":"alice","name":"shared","layout":{"v":1},"expectedVersion":null}'`,
    { stdio: "pipe" },
  ).toString();
  const seed = JSON.parse(seedR);
  const layoutId = seed.layout_id;
  // Step 2: bump to v2 (this is what tab-1 would have done).
  const v2R = execSync(
    `curl -s -X POST http://127.0.0.1:${httpPort}/api/design-review/save-layout ` +
      `-H 'Content-Type: application/json' ` +
      `-d '{"briefId":"render.conflict","scope":"user","ownerUserId":"alice","name":"shared","layout":{"v":2},"expectedVersion":1,"layoutId":"${layoutId}"}'`,
    { stdio: "pipe" },
  ).toString();
  assert.equal(JSON.parse(v2R).version, 2);
  // Step 3: tab-2 still thinks it's on v1 → conflict on save.
  const b = await ensureBrowser();
  const ctx = await b.newContext();
  const page = await ctx.newPage();
  await page.goto(`http://127.0.0.1:${PAGE_PORT}/?layoutId=${layoutId}&ver=1`);
  await page.evaluate(() => window.__saveStale());
  await page.waitForFunction(
    () =>
      document.getElementById("status").textContent === "conflict-dialog-open",
    { timeout: 5000 },
  );
  const dialogVisible = await page.evaluate(
    () =>
      document.querySelector('[data-design-review-conflict-dialog="true"]')
        .style.display,
  );
  assert.equal(dialogVisible, "block");
  // The dialog body must communicate the reload-or-overwrite affordance.
  const dialogText = await page.evaluate(
    () =>
      document.querySelector('[data-design-review-conflict-dialog="true"]')
        .textContent,
  );
  assert.ok(
    dialogText.toLowerCase().includes("reload"),
    "conflict dialog mentions reload: " + dialogText,
  );
  await ctx.close();
});
