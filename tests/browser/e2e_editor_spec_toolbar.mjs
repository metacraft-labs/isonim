// CHRM-M4 — Playwright-driven browser e2e for the spec-pane Edit-mode
// formatting toolbar.
//
// The test mirrors ``e2e_editor_spec_edit_mode.mjs``'s setup
// (PgFixture + ``isonim-review serve`` daemon + editor-server proxy)
// and then drives the toolbar through its canonical interactions:
//
//   1. Open the editor, select a story with a brief, switch to Spec
//      + Edit.
//   2. Assert the toolbar mounts at
//      ``[data-spec-editor-toolbar="true"]`` with the expected
//      buttons + ARIA shape.
//   3. Click each formatting button with a non-empty selection and
//      assert the resulting DOM change inside the ProseMirror host.
//   4. Drive the heading dropdown (open / pick H2 / assert ``<h2>``).
//   5. Drive the Link popover (open / type URL / Enter / assert
//      ``<a href>`` wraps the selection).
//   6. Press Ctrl+B via the keyboard pipeline and assert ``<strong>``
//      lands.
//   7. Click into a bold word and assert the toolbar's Bold button
//      reports ``aria-pressed="true"``.
//
// No mocks. Daemon = real binary; PG = real cluster spawned by
// PgFixture; proxy = the real editor-server.mjs.

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
const pgSpawnerSrc = join(
  __dirname,
  "helpers",
  "spawn_pg_for_browser_test.nim",
);
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
  const cmd = "direnv exec . just editor-build";
  exec(cmd, { cwd: isonimExamplesRoot });
  if (!existsSync(join(editorBuildDir, "editor.js"))) {
    throw new Error("editor.js was not produced by `just editor-build`");
  }
}

function buildDaemon() {
  if (existsSync(cliPath)) return;
  const cmd = "direnv exec . just isonim-review-build";
  exec(cmd, { cwd: isonimRoot });
  if (!existsSync(cliPath)) {
    throw new Error("isonim-review binary was not built");
  }
}

function buildPgSpawner() {
  if (existsSync(pgSpawnerBin)) return;
  const cmd =
    "direnv exec . nim c --hints:off tests/browser/helpers/spawn_pg_for_browser_test.nim";
  exec(cmd, { cwd: isonimRoot });
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

# Task App original body

Initial content the editor will overwrite.
`;

async function waitForUrl(url, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      execSync(`curl -s -o /dev/null --max-time 5 ${url}`, {
        stdio: "pipe",
      });
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
  proc.on("exit", (code, signal) => {
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

  const workspaceRoot = mkdtempSync(join(tmpdir(), "chrm-m4-ws-"));
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
    { timeout: 5000 },
  );
}

async function waitForTiptapMounted(page) {
  await page.waitForFunction(
    () => {
      const host = document.querySelector(
        '[data-spec-pane-tiptap-host="true"]',
      );
      return !!host && host.getAttribute("data-tiptap-mounted") === "true";
    },
    { timeout: 10000 },
  );
}

async function waitForEditable(page) {
  await page.waitForFunction(
    () => {
      const host = document.querySelector(
        '[data-spec-pane-tiptap-host="true"]',
      );
      return host && host.getAttribute("data-tiptap-editable") === "true";
    },
    { timeout: 5000 },
  );
}

async function clickToolbarButton(page, kindAttr) {
  await page.evaluate((kind) => {
    const btn = document.querySelector(
      `[data-spec-editor-toolbar-button="${kind}"]`,
    );
    if (!btn) throw new Error(`toolbar button ${kind} not found`);
    btn.click();
  }, kindAttr);
}

async function selectAllInEditor(page) {
  await page.evaluate(() => {
    const ed = window.__isonimSpecPaneEditor;
    if (!ed) throw new Error("spec pane editor handle missing");
    ed.commands.setContent("Hello world", true);
    ed.commands.focus("all");
    ed.commands.selectAll();
  });
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

test("toolbar_mounts_in_edit_mode_with_canonical_buttons", async () => {
  const state = serverState;
  const { ctx, page } = await openEditor(state);
  try {
    await selectTaskAppStory(page);
    await switchToSpec(page);
    await waitForTiptapMounted(page);
    await clickEditMode(page);
    await waitForEditable(page);
    await waitForToolbar(page);

    // Assert each canonical formatting button is present + has the
    // expected ARIA shape.
    const expectedButtons = [
      ["bold", "Bold", "Ctrl/Cmd+B"],
      ["italic", "Italic", "Ctrl/Cmd+I"],
      ["strike", "Strikethrough", "Ctrl/Cmd+Shift+X"],
      ["code", "Inline code", "Ctrl/Cmd+E"],
      ["link", "Link", "Ctrl/Cmd+K"],
      ["bullet-list", "Bullet list", "Ctrl/Cmd+Shift+8"],
      ["ordered-list", "Numbered list", "Ctrl/Cmd+Shift+7"],
      ["blockquote", "Blockquote", "Ctrl/Cmd+Shift+B"],
      ["code-block", "Code block", "Ctrl/Cmd+Alt+C"],
      ["horizontal-rule", "Horizontal rule", null],
      ["undo", "Undo", "Ctrl/Cmd+Z"],
      ["redo", "Redo", "Ctrl/Cmd+Shift+Z"],
    ];

    for (const [kind, label, shortcut] of expectedButtons) {
      const info = await page.evaluate((kindVal) => {
        const btn = document.querySelector(
          `[data-spec-editor-toolbar-button="${kindVal}"]`,
        );
        if (!btn) return null;
        return {
          role: btn.getAttribute("role"),
          ariaLabel: btn.getAttribute("aria-label"),
          ariaPressed: btn.getAttribute("aria-pressed"),
          title: btn.getAttribute("title"),
        };
      }, kind);
      assert.ok(info, `toolbar button ${kind} is mounted`);
      assert.equal(info.role, "button", `${kind} role is button`);
      assert.equal(info.ariaLabel, label, `${kind} aria-label`);
      assert.ok(
        info.ariaPressed === "true" || info.ariaPressed === "false",
        `${kind} carries aria-pressed`,
      );
      if (shortcut) {
        assert.ok(
          info.title && info.title.includes(shortcut),
          `${kind} tooltip mentions ${shortcut} (got ${info.title})`,
        );
      }
    }

    // Heading dropdown ARIA shape.
    const headingInfo = await page.evaluate(() => {
      const trig = document.querySelector(
        '[data-spec-editor-toolbar-heading-trigger="true"]',
      );
      const popup = document.querySelector(
        '[data-spec-editor-toolbar-heading-popup="true"]',
      );
      return trig && popup
        ? {
            triggerHaspopup: trig.getAttribute("aria-haspopup"),
            popupRole: popup.getAttribute("role"),
          }
        : null;
    });
    assert.ok(headingInfo, "heading dropdown is mounted");
    assert.equal(headingInfo.triggerHaspopup, "listbox");
    assert.equal(headingInfo.popupRole, "listbox");
  } finally {
    await ctx.close();
  }
});

test("clicking_bold_with_selection_wraps_in_strong", async () => {
  const state = serverState;
  const { ctx, page } = await openEditor(state);
  try {
    await selectTaskAppStory(page);
    await switchToSpec(page);
    await waitForTiptapMounted(page);
    await clickEditMode(page);
    await waitForEditable(page);
    await waitForToolbar(page);

    await selectAllInEditor(page);
    await clickToolbarButton(page, "bold");

    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-spec-pane-tiptap-host="true"]',
        );
        if (!host) return false;
        return !!host.querySelector(".ProseMirror strong");
      },
      { timeout: 5000 },
    );
    const strongCount = await page.evaluate(() => {
      const host = document.querySelector(
        '[data-spec-pane-tiptap-host="true"]',
      );
      if (!host) return 0;
      return host.querySelectorAll(".ProseMirror strong").length;
    });
    assert.ok(strongCount >= 1, "clicking Bold produces a <strong> tag");
  } finally {
    await ctx.close();
  }
});

test("clicking_italic_with_selection_wraps_in_em", async () => {
  const state = serverState;
  const { ctx, page } = await openEditor(state);
  try {
    await selectTaskAppStory(page);
    await switchToSpec(page);
    await waitForTiptapMounted(page);
    await clickEditMode(page);
    await waitForEditable(page);
    await waitForToolbar(page);

    await selectAllInEditor(page);
    await clickToolbarButton(page, "italic");

    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-spec-pane-tiptap-host="true"]',
        );
        if (!host) return false;
        return !!host.querySelector(".ProseMirror em");
      },
      { timeout: 5000 },
    );
  } finally {
    await ctx.close();
  }
});

test("heading_dropdown_h2_wraps_block_in_h2", async () => {
  const state = serverState;
  const { ctx, page } = await openEditor(state);
  try {
    await selectTaskAppStory(page);
    await switchToSpec(page);
    await waitForTiptapMounted(page);
    await clickEditMode(page);
    await waitForEditable(page);
    await waitForToolbar(page);

    await selectAllInEditor(page);

    // Open heading dropdown + pick H2 (index 2).
    await page.evaluate(() => {
      const trig = document.querySelector(
        '[data-spec-editor-toolbar-heading-trigger="true"]',
      );
      if (!trig) throw new Error("heading trigger missing");
      trig.click();
    });
    await page.waitForFunction(
      () => {
        const pop = document.querySelector(
          '[data-spec-editor-toolbar-heading-popup="true"]',
        );
        return pop && pop.getAttribute("data-popup-open") === "true";
      },
      { timeout: 5000 },
    );
    await page.evaluate(() => {
      const opt = document.querySelector(
        '[data-spec-editor-toolbar-heading-option="2"]',
      );
      if (!opt) throw new Error("H2 option missing");
      opt.click();
    });

    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-spec-pane-tiptap-host="true"]',
        );
        if (!host) return false;
        return !!host.querySelector(".ProseMirror h2");
      },
      { timeout: 5000 },
    );
  } finally {
    await ctx.close();
  }
});

test("bullet_list_button_wraps_block_in_ul", async () => {
  const state = serverState;
  const { ctx, page } = await openEditor(state);
  try {
    await selectTaskAppStory(page);
    await switchToSpec(page);
    await waitForTiptapMounted(page);
    await clickEditMode(page);
    await waitForEditable(page);
    await waitForToolbar(page);

    await selectAllInEditor(page);
    await clickToolbarButton(page, "bullet-list");

    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-spec-pane-tiptap-host="true"]',
        );
        if (!host) return false;
        const ul = host.querySelector(".ProseMirror ul");
        return ul && ul.querySelector("li");
      },
      { timeout: 5000 },
    );
  } finally {
    await ctx.close();
  }
});

test("code_block_button_wraps_block_in_pre_code", async () => {
  const state = serverState;
  const { ctx, page } = await openEditor(state);
  try {
    await selectTaskAppStory(page);
    await switchToSpec(page);
    await waitForTiptapMounted(page);
    await clickEditMode(page);
    await waitForEditable(page);
    await waitForToolbar(page);

    await selectAllInEditor(page);
    await clickToolbarButton(page, "code-block");

    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-spec-pane-tiptap-host="true"]',
        );
        if (!host) return false;
        return !!host.querySelector(".ProseMirror pre code");
      },
      { timeout: 5000 },
    );
  } finally {
    await ctx.close();
  }
});

test("link_button_opens_popover_and_url_wraps_selection_in_anchor", async () => {
  const state = serverState;
  const { ctx, page } = await openEditor(state);
  try {
    await selectTaskAppStory(page);
    await switchToSpec(page);
    await waitForTiptapMounted(page);
    await clickEditMode(page);
    await waitForEditable(page);
    await waitForToolbar(page);

    await selectAllInEditor(page);
    await clickToolbarButton(page, "link");

    await page.waitForFunction(
      () => {
        const pop = document.querySelector(
          '[data-spec-editor-toolbar-link-popover="true"]',
        );
        return pop && pop.getAttribute("data-popover-open") === "true";
      },
      { timeout: 5000 },
    );

    await page.evaluate(() => {
      const input = document.querySelector(
        '[data-spec-editor-toolbar-link-input="true"]',
      );
      if (!input) throw new Error("link input missing");
      input.focus();
      input.value = "https://example.com/path";
      // Dispatch ``input`` so the VM signal mirrors the typed value.
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    await page.evaluate(() => {
      const btn = document.querySelector(
        '[data-spec-editor-toolbar-link-submit="true"]',
      );
      if (!btn) throw new Error("link submit missing");
      btn.click();
    });

    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-spec-pane-tiptap-host="true"]',
        );
        if (!host) return false;
        const a = host.querySelector(".ProseMirror a[href]");
        return a && a.getAttribute("href").includes("example.com");
      },
      { timeout: 5000 },
    );
  } finally {
    await ctx.close();
  }
});

test("keyboard_shortcut_cmd_b_produces_strong_tag", async () => {
  const state = serverState;
  const { ctx, page } = await openEditor(state);
  try {
    await selectTaskAppStory(page);
    await switchToSpec(page);
    await waitForTiptapMounted(page);
    await clickEditMode(page);
    await waitForEditable(page);
    await waitForToolbar(page);

    // Use the editor handle to set content + select all so the
    // shortcut has something to apply against.
    await page.evaluate(() => {
      const ed = window.__isonimSpecPaneEditor;
      ed.commands.setContent("Shortcut sample", true);
      ed.commands.focus("end");
      ed.commands.selectAll();
    });

    // Focus the ProseMirror surface so ``Meta+B`` lands on the
    // contenteditable element + TipTap's keymap fires.
    await page.evaluate(() => {
      const pm = document.querySelector(
        '[data-spec-pane-tiptap-host="true"] .ProseMirror',
      );
      if (!pm) throw new Error("ProseMirror surface missing");
      pm.focus();
    });

    await page.keyboard.press("Meta+b");
    // Some platforms / headless builds emit Control+b instead.
    await page.keyboard.press("Control+b");

    // At least one of the two presses must produce a <strong> mark.
    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-spec-pane-tiptap-host="true"]',
        );
        if (!host) return false;
        return !!host.querySelector(".ProseMirror strong");
      },
      { timeout: 5000 },
    );
  } finally {
    await ctx.close();
  }
});

test("active_state_bold_button_reflects_caret_inside_strong", async () => {
  const state = serverState;
  const { ctx, page } = await openEditor(state);
  try {
    await selectTaskAppStory(page);
    await switchToSpec(page);
    await waitForTiptapMounted(page);
    await clickEditMode(page);
    await waitForEditable(page);
    await waitForToolbar(page);

    // Seed a doc with a bold word and place the caret inside it.
    await page.evaluate(() => {
      const ed = window.__isonimSpecPaneEditor;
      ed.commands.setContent("This is **emphasised** text", true);
      // Move caret to inside "emphasised" — character offset 12 lands
      // inside the bolded word.
      ed.commands.focus(12);
    });

    await page.waitForFunction(
      () => {
        const btn = document.querySelector(
          '[data-spec-editor-toolbar-button="bold"]',
        );
        return btn && btn.getAttribute("aria-pressed") === "true";
      },
      { timeout: 5000 },
    );
  } finally {
    await ctx.close();
  }
});
