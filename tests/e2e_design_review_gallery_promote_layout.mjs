// REV-M8 — e2e: promote-layout end-to-end.  Drives the daemon via
// Playwright (one tab as alice, one tab as "bob" — different ?user
// query param picks the userId) to confirm a promoted workspace
// layout becomes visible to a second user.

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

let pgDataDir = null;
let pgPort = 0;
let httpPort = 0;
let storeDir = null;
let configPath = null;
let daemonProc = null;
let pageServer = null;
const PAGE_PORT = 18470;

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
  pgDataDir = mkdtempSync(join(tmpdir(), "isonim-revm8p-pg-"));
  pgPort = pickPort(5810);
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
  httpPort = pickPort(18610);
  storeDir = mkdtempSync(join(tmpdir(), "isonim-revm8p-store-"));
  configPath = join(tmpdir(), `isonim-revm8p-config-${Date.now()}.toml`);
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
  throw new Error("daemon failed to bind");
}

function pageHtml() {
  return `<!doctype html>
<html><head><meta charset="utf-8"></head>
<body>
<div id="status">init</div>
<script>
  const BASE = "http://127.0.0.1:${httpPort}";
  const params = new URLSearchParams(window.location.search);
  const briefId = params.get("brief") || "render.x";
  const userId = params.get("user") || "alice";
  function setStatus(s) { document.getElementById("status").textContent = s; }
  async function listLayouts() {
    const r = await fetch(BASE + "/api/design-review/list-layouts?briefId=" +
      encodeURIComponent(briefId) + "&userId=" + encodeURIComponent(userId));
    const arr = await r.json();
    setStatus("ok:" + JSON.stringify(arr.map(r => ({s: r.scope, n: r.name}))));
  }
  window.__listLayouts = listLayouts;
  listLayouts();
</script>
</body></html>`;
}

function startPageServer() {
  const html = pageHtml();
  const pageDir = mkdtempSync(join(tmpdir(), "isonim-revm8p-page-"));
  writeFileSync(join(pageDir, "index.html"), html);
  pageServer = spawn(
    "python3",
    ["-m", "http.server", String(PAGE_PORT), "--bind", "127.0.0.1"],
    { cwd: pageDir, stdio: "ignore", detached: true },
  );
  execSync("sleep 1");
}

let chromium = null;
let browser = null;
async function ensureBrowser() {
  if (!chromium) {
    const m = await import("playwright");
    chromium = m.chromium;
  }
  if (!browser) browser = await chromium.launch({ headless: true });
  return browser;
}

test.before(async () => {
  if (!existsSync(CLI_PATH)) throw new Error("build/bin/isonim-review missing");
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

test("e2e_promote_layout_visible_to_second_user", async () => {
  // Alice saves a user-scope layout.
  const layoutFile = join(tmpdir(), `revm8p-${Date.now()}.json`);
  writeFileSync(layoutFile, JSON.stringify({ version: 1, entries: [] }));
  const env = {
    ...process.env,
    ISONIM_REVIEW_PGHOST: "127.0.0.1",
    ISONIM_REVIEW_PGPORT: String(pgPort),
  };
  const saveOut = execSync(
    `${CLI_PATH} layouts save --brief render.x --name shared-design --layout ${layoutFile} --user alice`,
    { env, stdio: "pipe" },
  ).toString();
  const layoutId = JSON.parse(saveOut).layout_id;
  // Alice promotes it.
  execSync(
    `${CLI_PATH} layouts promote --layout-id ${layoutId} --actor alice`,
    { env, stdio: "pipe" },
  );
  // Bob opens page and lists layouts — must see the workspace row.
  const b = await ensureBrowser();
  const ctx = await b.newContext();
  const page = await ctx.newPage();
  await page.goto(`http://127.0.0.1:${PAGE_PORT}/?brief=render.x&user=bob`);
  await page.waitForFunction(
    () => document.getElementById("status").textContent.startsWith("ok:"),
    { timeout: 5000 },
  );
  const status = await page.evaluate(
    () => document.getElementById("status").textContent,
  );
  assert.ok(status.includes("workspace"), "bob sees workspace row: " + status);
  assert.ok(
    status.includes("shared-design"),
    "bob sees the promoted name: " + status,
  );
  await ctx.close();
});
