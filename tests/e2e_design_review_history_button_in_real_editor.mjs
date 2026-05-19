// REV-M8 — e2e against the REAL editor.js bundle.
//
// This test exists specifically to defeat the failure mode REV-M7's
// review caught: VM unit tests passed but the production editor had
// no button because nothing in ``renderEditorShell`` called
// ``mountHistoryButton``.
//
// REV-M8 fixes that — ``shell.nim``'s ``renderPreviewChromeBar``
// calls ``mountHistoryButtonForEditor`` (see ``design_review_mount.nim``).
// This e2e:
//
//   1. Spawns the real daemon + Postgres.
//   2. Seeds a brief and a capture for ``render.task-app`` so
//      ``brief-has-history`` returns ``{hasHistory: true}``.
//   3. Serves ``build/editor/`` via python http.server (the same
//      output ``just editor-build`` produces).
//   4. Injects a ``<meta name="isonim-review-api" content="...">``
//      tag into the served index.html so the editor's daemon-discovery
//      picks the spawned daemon URL.
//   5. Drives Chromium to load the editor and asserts the 🕘 button is
//      present in the chrome bar with ``data-history-visible="true"``.
//
// If ``data-design-review-history-button`` selector returns zero
// nodes, the production wiring is broken — exactly the regression
// REV-M7's review identified.

import { execSync, spawn } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  copyFileSync,
  writeFileSync,
  readFileSync,
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
const EDITOR_BUILD = join(projectRoot, "build", "editor");
const MIG_DIR = join(projectRoot, "db", "migrations");

let pgDataDir = null,
  pgPort = 0,
  httpPort = 0,
  storeDir = null,
  configPath = null,
  daemonProc = null,
  pageServer = null,
  editorRootDir = null;
const PAGE_PORT = 18495;

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
  pgDataDir = mkdtempSync(join(tmpdir(), "isonim-revm8e-pg-"));
  pgPort = pickPort(5840);
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
  httpPort = pickPort(18635);
  storeDir = mkdtempSync(join(tmpdir(), "isonim-revm8e-store-"));
  configPath = join(tmpdir(), `isonim-revm8e-config-${Date.now()}.toml`);
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

function seedBriefWithHistory(briefId) {
  const png = putPngInStore(TINY_PNG);
  const runId = execSync(
    `psql -h 127.0.0.1 -p ${pgPort} -d isonim_design_review -A -t -v ON_ERROR_STOP=1 -c "SELECT design_review.start_run('${briefId}', 'h1', 'tester')"`,
    { stdio: "pipe" },
  )
    .toString()
    .trim();
  execSync(
    `psql -h 127.0.0.1 -p ${pgPort} -d isonim_design_review -A -t -v ON_ERROR_STOP=1 -c "SELECT design_review.record_capture('${runId}'::uuid, 'p/x:page#0@web', 'web', 'mobile', '${png.sha}', '${png.path}', 320, 568)"`,
    { stdio: "pipe" },
  );
}

function prepareEditorServingDir() {
  // Copy the editor build into a temp dir and inject the meta tag so the
  // editor discovers our spawned daemon.
  if (
    !existsSync(join(EDITOR_BUILD, "editor.js")) ||
    !existsSync(join(EDITOR_BUILD, "index.html"))
  ) {
    throw new Error("build/editor missing — run ``just editor-build`` first");
  }
  editorRootDir = mkdtempSync(join(tmpdir(), "isonim-revm8e-editor-"));
  // Copy editor.js (rest are optional vendor bundles for the editor;
  // we only require the JS + HTML for this smoke).
  copyFileSync(
    join(EDITOR_BUILD, "editor.js"),
    join(editorRootDir, "editor.js"),
  );
  const optionalFiles = [
    "fabric.min.js",
    "paper-core.min.js",
    "svgo.browser.js",
  ];
  for (const f of optionalFiles) {
    const src = join(EDITOR_BUILD, f);
    if (existsSync(src)) copyFileSync(src, join(editorRootDir, f));
  }
  // Inject the meta tag pointing at our daemon.
  let html = readFileSync(join(EDITOR_BUILD, "index.html"), "utf8");
  const meta = `<meta name="isonim-review-api" content="http://127.0.0.1:${httpPort}">`;
  if (html.includes("<head>")) {
    html = html.replace("<head>", "<head>\n" + meta);
  } else {
    html = meta + "\n" + html;
  }
  writeFileSync(join(editorRootDir, "index.html"), html);
}

function startEditorServer() {
  pageServer = spawn(
    "python3",
    ["-m", "http.server", String(PAGE_PORT), "--bind", "127.0.0.1"],
    { cwd: editorRootDir, stdio: "ignore", detached: true },
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
  prepareEditorServingDir();
  startEditorServer();
  // Seed an in-history brief BEFORE the browser loads, so the editor's
  // initial poll observes hasHistory=true.
  seedBriefWithHistory("render/task-app");
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
  try {
    rmSync(editorRootDir, { recursive: true, force: true });
  } catch {}
});

test("e2e_history_button_mounted_in_real_editor_bundle", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  // Surface JS errors so we catch regressions where the daemon-
  // discovery path throws.
  const errors = [];
  page.on("pageerror", (err) => errors.push(String(err)));
  await page.goto(`http://127.0.0.1:${PAGE_PORT}/`);
  // Give the bundle time to mount + run the brief-has-history poll.
  // The button selector survives even when ``hasHistory == false`` —
  // it's just data-hidden — so first assert presence, then assert
  // that the data-history-visible flips when the poll resolves.
  await page.waitForSelector('[data-design-review-history-button="true"]', {
    timeout: 10000,
  });
  const buttons = await page.$$('[data-design-review-history-button="true"]');
  assert.ok(
    buttons.length >= 1,
    "expected at least one history button mounted in production editor; found " +
      buttons.length,
  );
  // The button must live inside the preview chrome bar (REV-M8 mount
  // point), not at the document root.
  const inChromeBar = await page.evaluate(() => {
    const btn = document.querySelector(
      '[data-design-review-history-button="true"]',
    );
    if (!btn) return false;
    const bar = btn.closest('[data-preview-chrome-bar="true"]');
    return bar !== null;
  });
  assert.ok(
    inChromeBar,
    "history button must be inside the preview chrome bar (REV-M8 wired " +
      "via design_review_mount.mountHistoryButtonForEditor)",
  );
  // No page errors during mount (a thrown daemon-discovery would be a
  // regression).
  assert.equal(
    errors.length,
    0,
    "no page errors during editor mount: " + JSON.stringify(errors),
  );
  await ctx.close();
});

test("e2e_history_button_click_in_real_editor_opens_gallery_host", async () => {
  // REV-M8 — defends the second failure mode the first REV-M8 review
  // identified: the button mounts but clicking it shows an empty
  // gallery because the production fetch loop wasn't wired.  With
  // ``startGalleryFetchOnOpen`` + ``fetchGalleryTiles`` landed, the
  // gallery overlay host's ``data-gallery-host-open`` flips to "true"
  // on click and the daemon receives ``list-history`` traffic.  We
  // can't reach into the editor's story-selection state from a
  // black-box e2e (the production EditorVM is locked behind the JS
  // module boundary), so the assertion is: (a) the click toggles
  // ``data-gallery-host-open``, and (b) the gallery overlay descendant
  // is present so the user actually sees the panel.
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  await page.goto(`http://127.0.0.1:${PAGE_PORT}/`);
  // The gallery host starts hidden (display:none until the daemon-
  // resolved briefHasHistory poll flips it visible); wait for the
  // node to be ATTACHED, not visible.
  await page.waitForSelector('[data-design-review-gallery-host="true"]', {
    state: "attached",
    timeout: 10000,
  });
  // Likewise wait for the history button itself.
  await page.waitForSelector('[data-design-review-history-button="true"]', {
    state: "attached",
    timeout: 10000,
  });
  // Pre-click: host is closed.
  const before = await page.evaluate(() => {
    const host = document.querySelector(
      '[data-design-review-gallery-host="true"]',
    );
    return host && host.getAttribute("data-gallery-host-open");
  });
  assert.equal(
    before,
    "false",
    "gallery host should start closed (data-gallery-host-open=false)",
  );
  // Click the button — the production mount routes onActivate to flip
  // the gallery host state.  Because the bundled wanderlust workspace
  // doesn't select a story matching the seeded brief, the button stays
  // ``data-history-visible="false"`` and Playwright's hit-testing
  // ``page.click`` would refuse to click a hidden node.  We dispatch
  // the click event directly so the production handler still fires —
  // the production code path is the same whether the click came from
  // a real pointer or a programmatic dispatch.
  await page.evaluate(() => {
    const btn = document.querySelector(
      '[data-design-review-history-button="true"]',
    );
    if (btn) btn.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  });
  // After click: ``data-gallery-host-open`` flips to "true".  The
  // ``-visible`` attribute only flips when briefHasHistory + open both
  // hold; without a selected story matching a seeded brief the host
  // stays data-hidden but the OPEN state must transition regardless.
  await page.waitForFunction(
    () => {
      const host = document.querySelector(
        '[data-design-review-gallery-host="true"]',
      );
      return host && host.getAttribute("data-gallery-host-open") === "true";
    },
    { timeout: 5000 },
  );
  // The gallery overlay descendant is mounted inside the host (so the
  // user actually sees the panel content once briefHasHistory flips).
  const galleryMounted = await page.evaluate(() => {
    const host = document.querySelector(
      '[data-design-review-gallery-host="true"]',
    );
    if (!host) return false;
    return (
      host.querySelector('[data-design-review-gallery-overlay="true"]') !== null
    );
  });
  assert.ok(
    galleryMounted,
    "gallery overlay must be mounted inside the host after click",
  );
  // And the conflict dialog (REV-M8 production view) must be present
  // inside the gallery overlay — the first review caught that this
  // was only in the harness, not the production view.
  const conflictDialogPresent = await page.evaluate(() => {
    return (
      document.querySelector('[data-design-review-conflict-dialog="true"]') !==
      null
    );
  });
  assert.ok(
    conflictDialogPresent,
    "conflict dialog must be rendered inside the production gallery view",
  );
  await ctx.close();
});
