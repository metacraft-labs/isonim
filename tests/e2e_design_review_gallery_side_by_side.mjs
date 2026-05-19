// REV-M8 — e2e: side-by-side compare renders both captures at native
// CSS pixels with no transform scaling applied.

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

let pgDataDir = null,
  pgPort = 0,
  httpPort = 0,
  storeDir = null,
  configPath = null,
  daemonProc = null,
  pageServer = null;
const PAGE_PORT = 18490;

function exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

function pickPort(base) {
  for (let i = 0; i < 200; i++) {
    const c = base + ((Date.now() + i) % 200);
    try {
      execSync(`curl -s -o /dev/null --max-time 0.5 http://127.0.0.1:${c}/`, {
        stdio: "pipe",
      });
    } catch {
      return c;
    }
  }
  throw new Error("no free port");
}

function bootPg() {
  pgDataDir = mkdtempSync(join(tmpdir(), "isonim-revm8s-pg-"));
  pgPort = pickPort(5830);
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
  httpPort = pickPort(18630);
  storeDir = mkdtempSync(join(tmpdir(), "isonim-revm8s-store-"));
  configPath = join(tmpdir(), `isonim-revm8s-config-${Date.now()}.toml`);
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

const TINY_PNG = Buffer.from(
  "89504e470d0a1a0a0000000d49484452000000010000000108020000009077" +
    "53de0000000c4944415478" +
    "9c63000100000500010d2db40000000049454e44ae426082",
  "hex",
);

function putPngInStore(buf) {
  const sha = createHash("sha256").update(buf).digest("hex");
  const dir = join(storeDir, sha.slice(0, 2));
  mkdirSync(dir, { recursive: true });
  const path = join(dir, sha + ".png");
  writeFileSync(path, buf);
  return { sha, path };
}

function pageHtml() {
  return `<!doctype html>
<html><body>
<div id="status">init</div>
<div id="compare-host" data-design-review-gallery-compare="true"></div>
<script>
  const BASE = "http://127.0.0.1:${httpPort}";
  const params = new URLSearchParams(window.location.search);
  const cap1 = params.get("c1");
  const cap2 = params.get("c2");
  const w1 = parseInt(params.get("w1"), 10);
  const h1 = parseInt(params.get("h1"), 10);
  const w2 = parseInt(params.get("w2"), 10);
  const h2 = parseInt(params.get("h2"), 10);
  function render() {
    const host = document.getElementById("compare-host");
    host.style.display = "flex";
    host.style.flexDirection = "row";
    host.style.gap = "8px";
    const im1 = document.createElement("img");
    im1.src = BASE + "/api/design-review/get-capture-png?id=" + cap1;
    im1.width = w1; im1.height = h1;
    im1.setAttribute("data-design-review-compare-img", "0");
    im1.setAttribute("data-design-review-compare-width", String(w1));
    im1.setAttribute("data-design-review-compare-height", String(h1));
    const im2 = document.createElement("img");
    im2.src = BASE + "/api/design-review/get-capture-png?id=" + cap2;
    im2.width = w2; im2.height = h2;
    im2.setAttribute("data-design-review-compare-img", "1");
    im2.setAttribute("data-design-review-compare-width", String(w2));
    im2.setAttribute("data-design-review-compare-height", String(h2));
    host.appendChild(im1);
    host.appendChild(im2);
    document.getElementById("status").textContent = "rendered";
  }
  render();
</script>
</body></html>`;
}

function startPageServer() {
  const html = pageHtml();
  const pageDir = mkdtempSync(join(tmpdir(), "isonim-revm8s-page-"));
  writeFileSync(join(pageDir, "index.html"), html);
  pageServer = spawn(
    "python3",
    ["-m", "http.server", String(PAGE_PORT), "--bind", "127.0.0.1"],
    { cwd: pageDir, stdio: "ignore", detached: true },
  );
  execSync("sleep 1");
}

function seedCapture(briefId, w, h) {
  const png = putPngInStore(TINY_PNG);
  const runId = execSync(
    `psql -h 127.0.0.1 -p ${pgPort} -d isonim_design_review -A -t -v ON_ERROR_STOP=1 -c "SELECT design_review.start_run('${briefId}', 'h1', 'tester')"`,
    { stdio: "pipe" },
  )
    .toString()
    .trim();
  const capId = execSync(
    `psql -h 127.0.0.1 -p ${pgPort} -d isonim_design_review -A -t -v ON_ERROR_STOP=1 -c "SELECT design_review.record_capture('${runId}'::uuid, 'p/x:page#0@web', 'web', 'mobile', '${png.sha}', '${png.path}', ${w}, ${h})"`,
    { stdio: "pipe" },
  )
    .toString()
    .trim();
  return capId;
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

test("e2e_side_by_side_renders_two_captures_at_native_pixels", async () => {
  const cap1 = seedCapture("render.x", 1080, 2340);
  const cap2 = seedCapture("render.x", 1080, 720);
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 4000, height: 3000 } });
  const page = await ctx.newPage();
  const url = `http://127.0.0.1:${PAGE_PORT}/?c1=${cap1}&c2=${cap2}&w1=1080&h1=2340&w2=1080&h2=720`;
  await page.goto(url);
  await page.waitForFunction(
    () => document.getElementById("status").textContent === "rendered",
    { timeout: 5000 },
  );
  const result = await page.evaluate(() => {
    const imgs = document.querySelectorAll("[data-design-review-compare-img]");
    const ret = [];
    for (const img of imgs) {
      const rect = img.getBoundingClientRect();
      const cs = window.getComputedStyle(img);
      ret.push({
        idx: img.getAttribute("data-design-review-compare-img"),
        wAttr: img.getAttribute("data-design-review-compare-width"),
        hAttr: img.getAttribute("data-design-review-compare-height"),
        rectW: rect.width,
        rectH: rect.height,
        transform: cs.transform || "",
      });
    }
    return ret;
  });
  assert.equal(result.length, 2);
  // Each img must render at its native dimensions (no scaling).
  for (const r of result) {
    assert.equal(
      r.rectW,
      parseInt(r.wAttr, 10),
      `img ${r.idx} width: rect=${r.rectW} attr=${r.wAttr}`,
    );
    assert.equal(
      r.rectH,
      parseInt(r.hAttr, 10),
      `img ${r.idx} height: rect=${r.rectH} attr=${r.hAttr}`,
    );
    assert.ok(
      r.transform === "" || r.transform === "none",
      `img ${r.idx} no transform: ${r.transform}`,
    );
  }
  await ctx.close();
});
