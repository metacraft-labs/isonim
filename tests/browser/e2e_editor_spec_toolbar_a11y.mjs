// CHRM-M4 — accessibility-focused Playwright e2e for the spec-pane
// formatting toolbar.
//
//   * Each toolbar button has a non-empty ``aria-label`` + a
//     ``title`` tooltip mentioning the keyboard shortcut.
//   * Each button is keyboard-focusable (Tab sequence reaches every
//     button in order).
//   * The heading dropdown carries the canonical ChoiceGroup
//     chevron-popup ARIA shape
//     (``aria-haspopup="listbox"`` + ``role="listbox"``).

import { execSync, spawn } from "node:child_process";
import { existsSync, mkdtempSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import net from "node:net";
import test from "node:test";
import assert from "node:assert/strict";

const __dirname = dirname(fileURLToPath(import.meta.url));
const isonimRoot = join(__dirname, "..", "..");
const isonimExamplesRoot = join(isonimRoot, "..", "isonim-examples");
const editorBuildDir = join(isonimExamplesRoot, "build", "editor");
const cliPath = join(isonimRoot, "build", "bin", "isonim-review");
const migrationsDir = join(isonimRoot, "db", "migrations");
const editorServer = join(isonimExamplesRoot, "tools", "editor-server.mjs");
const pgSpawnerBin = join(__dirname, "helpers", "spawn_pg_for_browser_test");

function exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

function pickFreePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.unref();
    srv.on("error", reject);
    srv.listen(0, "127.0.0.1", () => {
      const port = srv.address().port;
      srv.close(() => resolve(port));
    });
  });
}

function buildEditor() {
  exec("direnv exec . just editor-build", { cwd: isonimExamplesRoot });
  if (!existsSync(join(editorBuildDir, "editor.js"))) {
    throw new Error("editor.js was not produced by `just editor-build`");
  }
}

function buildDaemon() {
  if (existsSync(cliPath)) return;
  exec("direnv exec . just isonim-review-build", { cwd: isonimRoot });
  if (!existsSync(cliPath)) {
    throw new Error("isonim-review binary was not built");
  }
}

function buildPgSpawner() {
  if (existsSync(pgSpawnerBin)) return;
  exec(
    "direnv exec . nim c --hints:off tests/browser/helpers/spawn_pg_for_browser_test.nim",
    { cwd: isonimRoot },
  );
  if (!existsSync(pgSpawnerBin)) {
    throw new Error("PG spawner helper was not built");
  }
}

const FIXTURE_BRIEF_BODY = `---
briefId: render.task-app
schemaVersion: 1
kind: render
title: Task App
coversPreviews:
  - storyRef: { group: "Task App / Pages", name: "Inbox", kind: page, index: 0 }
    backends: [web]
captureViewports:
  - { width: 1920, height: 1080, label: "wide" }
reviewerSchemaVersion: 1
scoringDimensions:
  - { id: "fidelity", label: "Fidelity", weight: 1.0, scale: { min: 1, max: 10 } }
---

# Task App a11y fixture

Body for a11y testing.
`;

async function waitForUrl(url, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      execSync(`curl -s -o /dev/null --max-time 5 ${url}`, { stdio: "pipe" });
      return true;
    } catch {
      await new Promise((r) => setTimeout(r, 200));
    }
  }
  return false;
}

async function startPgCluster() {
  buildPgSpawner();
  const proc = spawn("direnv", ["exec", isonimRoot, pgSpawnerBin], {
    stdio: ["pipe", "pipe", "pipe"],
  });
  let buffered = "";
  let resolveLine, rejectLine;
  const linePromise = new Promise((res, rej) => {
    resolveLine = res;
    rejectLine = rej;
  });
  proc.stdout.on("data", (chunk) => {
    buffered += chunk.toString();
    const nl = buffered.indexOf("\n");
    if (nl >= 0) {
      const line = buffered.slice(0, nl);
      buffered = buffered.slice(nl + 1);
      try {
        const obj = JSON.parse(line);
        resolveLine(obj);
      } catch (e) {
        rejectLine(new Error("bad JSON from spawn_pg helper: " + line));
      }
    }
  });
  proc.on("error", rejectLine);
  proc.on("exit", (code) => {
    if (code !== 0 && code !== null) {
      try {
        rejectLine(new Error(`pg helper exited code=${code}`));
      } catch {}
    }
  });
  let stderrBuf = "";
  proc.stderr.on("data", (c) => {
    stderrBuf += c.toString();
  });
  const timeout = new Promise((_, rej) =>
    setTimeout(
      () =>
        rej(
          new Error(
            `pg helper did not emit port within 60s; stderr=\n${stderrBuf}`,
          ),
        ),
      60000,
    ),
  );
  const out = await Promise.race([linePromise, timeout]);
  return { proc, pgPort: out.pgPort };
}

let serverState = null;
let pgState = null;

async function startEditorServerAndDaemon() {
  buildDaemon();
  buildEditor();
  pgState = await startPgCluster();
  const pgPort = pgState.pgPort;

  const workspaceRoot = mkdtempSync(join(tmpdir(), "chrm-m4-a11y-ws-"));
  const briefsRender = join(workspaceRoot, "briefs", "render");
  mkdirSync(briefsRender, { recursive: true });
  const briefPath = join(briefsRender, "task-app.md");
  writeFileSync(briefPath, FIXTURE_BRIEF_BODY);

  const storePath = join(workspaceRoot, "store");
  mkdirSync(storePath, { recursive: true });

  const daemonPort = await pickFreePort();
  const editorPort = await pickFreePort();

  const cfgPath = join(workspaceRoot, "isonim-review.toml");
  writeFileSync(
    cfgPath,
    `[store]\npath = "${storePath}"\n[workspace]\nroot = "${workspaceRoot}"\n`,
  );

  exec(
    `direnv exec ${isonimRoot} ${cliPath} init --config ${cfgPath} --migrations ${migrationsDir}`,
    {
      env: {
        ...process.env,
        ISONIM_REVIEW_PGHOST: "127.0.0.1",
        ISONIM_REVIEW_PGPORT: String(pgPort),
        ISONIM_REVIEW_PORT: String(daemonPort),
      },
    },
  );

  const daemonProc = spawn(
    "direnv",
    [
      "exec",
      isonimRoot,
      cliPath,
      "serve",
      "--migrations",
      migrationsDir,
      "--config",
      cfgPath,
    ],
    {
      env: {
        ...process.env,
        ISONIM_REVIEW_PGHOST: "127.0.0.1",
        ISONIM_REVIEW_PGPORT: String(pgPort),
        ISONIM_REVIEW_PORT: String(daemonPort),
      },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );

  let daemonOut = "";
  daemonProc.stdout.on("data", (c) => {
    daemonOut += c.toString();
  });
  daemonProc.stderr.on("data", (c) => {
    daemonOut += c.toString();
  });

  const ok = await waitForUrl(`http://127.0.0.1:${daemonPort}/health`, 10000);
  if (!ok) {
    try {
      daemonProc.kill("SIGKILL");
    } catch {}
    throw new Error(
      `daemon failed to bind on ${daemonPort}; output=\n${daemonOut}`,
    );
  }

  const proxyProc = spawn("node", [editorServer], {
    env: {
      ...process.env,
      PORT: String(editorPort),
      ISONIM_DAEMON_HOST: "127.0.0.1",
      ISONIM_DAEMON_PORT: String(daemonPort),
      EDITOR_STATIC_ROOT: editorBuildDir,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });

  const okProxy = await waitForUrl(
    `http://127.0.0.1:${editorPort}/index.html`,
    10000,
  );
  if (!okProxy) {
    try {
      proxyProc.kill("SIGKILL");
      daemonProc.kill("SIGKILL");
    } catch {}
    throw new Error(`editor-server failed to bind on ${editorPort}`);
  }

  serverState = {
    daemonProc,
    proxyProc,
    workspaceRoot,
    briefPath,
    daemonPort,
    editorPort,
    pageBase: `http://127.0.0.1:${editorPort}`,
  };
  return serverState;
}

async function shutdownServers() {
  if (serverState) {
    try {
      serverState.proxyProc.kill("SIGTERM");
    } catch {}
    try {
      serverState.daemonProc.kill("SIGTERM");
    } catch {}
    await new Promise((r) => setTimeout(r, 300));
    try {
      serverState.proxyProc.kill("SIGKILL");
    } catch {}
    try {
      serverState.daemonProc.kill("SIGKILL");
    } catch {}
    serverState = null;
  }
  if (pgState) {
    try {
      pgState.proc.stdin.end();
    } catch {}
    await new Promise((r) => setTimeout(r, 500));
    try {
      pgState.proc.kill("SIGTERM");
    } catch {}
    await new Promise((r) => setTimeout(r, 200));
    try {
      pgState.proc.kill("SIGKILL");
    } catch {}
    pgState = null;
  }
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

async function openEditor(state) {
  const b = await ensureBrowser();
  const ctx = await b.newContext();
  const page = await ctx.newPage();
  await page.goto(`${state.pageBase}/index.html`);
  await page.waitForSelector('[data-preview-surface-switch="true"]', {
    timeout: 10000,
  });
  return { ctx, page };
}

async function selectTaskAppStory(page) {
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
  await page.waitForFunction(
    () => {
      const el = document.querySelector('[data-test-id="spec-pane"]');
      if (!el) return false;
      return getComputedStyle(el).display !== "none";
    },
    { timeout: 5000 },
  );
}

async function clickEditMode(page) {
  await page.evaluate(() => {
    const chip = document.querySelector(
      '[data-toolbar-cluster="mode"] [data-choice-group-pill="2"]',
    );
    if (!chip) throw new Error("edit chip not found");
    chip.click();
  });
}

async function waitForToolbar(page) {
  await page.waitForFunction(
    () => {
      const el = document.querySelector('[data-spec-editor-toolbar="true"]');
      if (!el) return false;
      return getComputedStyle(el).display !== "none";
    },
    { timeout: 10000 },
  );
}

test.before(async () => {
  await startEditorServerAndDaemon();
  if (!serverState) {
    throw new Error("serverState not initialised");
  }
});

test.after(async () => {
  try {
    if (browser) await browser.close();
  } catch {}
  await shutdownServers();
});

test("every_toolbar_button_has_non_empty_aria_label_and_title", async () => {
  const state = serverState;
  const { ctx, page } = await openEditor(state);
  try {
    await selectTaskAppStory(page);
    await switchToSpec(page);
    await clickEditMode(page);
    await waitForToolbar(page);

    const buttons = await page.evaluate(() => {
      const out = [];
      const nodes = document.querySelectorAll(
        "[data-spec-editor-toolbar-button]",
      );
      nodes.forEach((n) => {
        out.push({
          kind: n.getAttribute("data-spec-editor-toolbar-button"),
          ariaLabel: n.getAttribute("aria-label"),
          title: n.getAttribute("title"),
          tabindex: n.getAttribute("tabindex"),
        });
      });
      return out;
    });
    assert.ok(buttons.length >= 12, "all toolbar buttons mounted");
    for (const b of buttons) {
      assert.ok(
        b.ariaLabel && b.ariaLabel.length > 0,
        `button ${b.kind} aria-label non-empty`,
      );
      // The Horizontal Rule button has no canonical keyboard
      // shortcut so its title is just the label; every other button's
      // title contains the shortcut hint "Ctrl/Cmd+...".
      if (b.kind !== "horizontal-rule") {
        assert.ok(
          b.title && b.title.includes("Ctrl/Cmd+"),
          `button ${b.kind} title carries shortcut hint (got ${b.title})`,
        );
      }
      assert.ok(
        b.tabindex === "0",
        `button ${b.kind} is focusable (tabindex=0)`,
      );
    }
  } finally {
    await ctx.close();
  }
});

test("heading_dropdown_exposes_choice_group_aria_shape", async () => {
  const state = serverState;
  const { ctx, page } = await openEditor(state);
  try {
    await selectTaskAppStory(page);
    await switchToSpec(page);
    await clickEditMode(page);
    await waitForToolbar(page);

    const info = await page.evaluate(() => {
      const trig = document.querySelector(
        '[data-spec-editor-toolbar-heading-trigger="true"]',
      );
      const pop = document.querySelector(
        '[data-spec-editor-toolbar-heading-popup="true"]',
      );
      const opts = document.querySelectorAll(
        "[data-spec-editor-toolbar-heading-option]",
      );
      return {
        triggerAriaHaspopup: trig && trig.getAttribute("aria-haspopup"),
        triggerAriaExpanded: trig && trig.getAttribute("aria-expanded"),
        popupRole: pop && pop.getAttribute("role"),
        popupAriaLabel: pop && pop.getAttribute("aria-label"),
        optionRoles: Array.from(opts).map((o) => o.getAttribute("role")),
      };
    });
    assert.equal(info.triggerAriaHaspopup, "listbox");
    // Popup starts closed.
    assert.equal(info.triggerAriaExpanded, "false");
    assert.equal(info.popupRole, "listbox");
    assert.ok(info.popupAriaLabel && info.popupAriaLabel.length > 0);
    assert.equal(info.optionRoles.length, 4);
    for (const role of info.optionRoles) {
      assert.equal(role, "option");
    }
  } finally {
    await ctx.close();
  }
});

test("tab_sequence_reaches_every_toolbar_button_in_order", async () => {
  const state = serverState;
  const { ctx, page } = await openEditor(state);
  try {
    await selectTaskAppStory(page);
    await switchToSpec(page);
    await clickEditMode(page);
    await waitForToolbar(page);

    // Focus the heading trigger first, then tab through the toolbar
    // buttons.  Asserts each button receives focus in turn.
    await page.evaluate(() => {
      const trig = document.querySelector(
        '[data-spec-editor-toolbar-heading-trigger="true"]',
      );
      if (!trig) throw new Error("heading trigger missing");
      trig.focus();
    });

    const expectedOrder = [
      "bold",
      "italic",
      "strike",
      "code",
      "link",
      "bullet-list",
      "ordered-list",
      "blockquote",
      "code-block",
      "horizontal-rule",
      "undo",
      "redo",
    ];

    const reached = [];
    for (let i = 0; i < expectedOrder.length; i++) {
      await page.keyboard.press("Tab");
      const kind = await page.evaluate(() => {
        const el = document.activeElement;
        if (!el) return null;
        return el.getAttribute("data-spec-editor-toolbar-button");
      });
      if (kind) reached.push(kind);
    }
    // Assert that all expected buttons were reached in the expected
    // order (some Tab presses may skip non-toolbar focusable elements
    // such as the heading separator, so we tolerate extra Tab presses
    // by comparing the longest common subsequence).  Here we assert
    // strict prefix-match — the toolbar's focus order should be
    // dense.
    assert.deepEqual(
      reached.slice(0, expectedOrder.length),
      expectedOrder,
      `tab sequence reached the toolbar buttons in order; got ${reached.join(",")}`,
    );
  } finally {
    await ctx.close();
  }
});
