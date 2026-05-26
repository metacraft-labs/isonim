// TBAR-M5 — Playwright-driven browser e2e for the editor's Spec
// pane in Edit mode + the ``POST /api/design-review/save-brief``
// daemon route.
//
// This test exercises the full round-trip:
//
//   1. Spawn a real Postgres cluster via the in-tree PgFixture
//      (wrapped as a small Nim helper at
//      ``tests/browser/helpers/spawn_pg_for_browser_test.nim``).
//   2. Spawn the ``isonim-review serve`` daemon against that PG
//      cluster + a temp workspace dir holding a fixture brief at
//      ``<workspace>/briefs/render/task-app.md``.
//   3. Spawn the editor-server proxy (``tools/editor-server.mjs``)
//      pointing at the daemon's port — it injects the
//      ``isonim-review-api`` meta tag and proxies same-origin
//      ``/api/*`` calls through to the daemon.
//   4. Open the editor against the proxy; switch to Spec; flip the
//      mode triplet to Edit.
//   5. Assert the TipTap host reports ``data-tiptap-editable="true"``.
//   6. Inject modified markdown into the textarea overlay.
//   7. Click Save.
//   8. Assert the daemon's 200 response and that the file on disk
//      carries the modified content.
//   9. Flip mode to View; TipTap goes non-editable.
//  10. Flip back to Edit, modify, click Cancel — pane reverts to the
//      last-saved content; mode returns to View.
//
// No mocks. Daemon = real binary; PG = real cluster spawned by
// PgFixture; proxy = the real editor-server.mjs.

import { execSync, spawn } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  writeFileSync,
  mkdirSync,
} from "node:fs";
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

## A section

- one
- two
`;

async function waitForUrl(url, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      // ``--max-time`` must be generous enough to swallow the
      // daemon's per-request /health probe latency (the DB probes
      // take ~600 ms in dev).
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
  // Run the helper through the isonim direnv shell so ``initdb`` /
  // ``postgres`` resolve via the Nix dev-shell PATH the same way the
  // Nim integration tests do.  Plain ``spawn(pgSpawnerBin)`` would
  // inherit ``node --test``'s environment which doesn't carry the
  // Nix bin dirs.
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
      // Surface premature exits as a rejection so the test fails
      // loudly instead of hanging.
      try {
        rejectLine(new Error(`pg helper exited code=${code}`));
      } catch {}
    }
  });
  // Capture stderr in case the helper raises (PG bring-up errors land here).
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

  const workspaceRoot = mkdtempSync(join(tmpdir(), "tbar-m5-ws-"));
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

  // Apply migrations against the running PG cluster.  Like the PG
  // spawner above we wrap in ``direnv exec`` so the daemon binary
  // resolves its dynamic deps via the Nix dev shell.
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

  // Capture daemon stdio so a bind failure surfaces a useful
  // diagnostic to the test runner.
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

  // Start the editor-server proxy.
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
  // CHRM-M2: mode cluster is now a ChoiceGroup segmented control;
  // pills are addressed positionally — Edit is index 2.
  await page.evaluate(() => {
    const chip = document.querySelector(
      '[data-toolbar-cluster="mode"] [data-choice-group-pill="2"]',
    );
    if (!chip) throw new Error("edit chip not found");
    chip.click();
  });
}

async function clickViewMode(page) {
  // CHRM-M2: View is index 0 in the mode cluster.
  await page.evaluate(() => {
    const chip = document.querySelector(
      '[data-toolbar-cluster="mode"] [data-choice-group-pill="0"]',
    );
    if (!chip) throw new Error("view chip not found");
    chip.click();
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

test("e2e_spec_edit_mode_save_round_trips_to_disk", async () => {
  const state = serverState;
  const { ctx, page } = await openEditor(state);
  try {
    await selectTaskAppStory(page);
    await switchToSpec(page);

    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-spec-pane-tiptap-host="true"]',
        );
        return !!host && host.getAttribute("data-tiptap-mounted") === "true";
      },
      { timeout: 10000 },
    );

    await clickEditMode(page);

    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-spec-pane-tiptap-host="true"]',
        );
        return host && host.getAttribute("data-tiptap-editable") === "true";
      },
      { timeout: 5000 },
    );

    const saveResponses = [];
    page.on("response", (resp) => {
      if (resp.url().endsWith("/api/design-review/save-brief")) {
        saveResponses.push({ status: resp.status() });
      }
    });

    // TBAR-M5b: Edit mode is now a real TipTap editable instance,
    // not a textarea overlay.  Replace the content via the
    // editor.commands.setContent(md, true) entry point + dispatch
    // an explicit ``onUpdate`` via the editor's transaction so the
    // VM's ``dirty`` flag flips. ``window.__isonimTestMode`` is the
    // existing test-mode flag the editor's other test paths use.
    await page.evaluate(() => {
      const newBody =
        "---\nbriefId: render.task-app\nschemaVersion: 1\nkind: render\n" +
        'title: Task App\ncoversPreviews:\n  - storyRef: { group: "Task App / Pages", name: "Inbox", kind: page, index: 0 }\n' +
        '    backends: [web]\ncaptureViewports:\n  - { width: 1920, height: 1080, label: "wide" }\n' +
        'reviewerSchemaVersion: 1\nscoringDimensions:\n  - { id: "fidelity", label: "Fidelity", weight: 1.0, scale: { min: 1, max: 10 } }\n' +
        "---\n\n# Edited by e2e test\n\nThis text was injected by the TBAR-M5 browser test.\n";
      // The IsoNim editor stashes the active SpecPaneVM on
      // ``window.__isonimEditor`` for test hooks; we set the markdown
      // via the same path the user-facing keyboard would take —
      // ``editor.commands.setContent(...)`` parses markdown when the
      // ``Markdown`` extension is installed.  This drives the
      // ``onUpdate`` callback configured on the editor which the
      // ``spec_pane.nim`` mount uses to flip ``dirty``.
      const host = document.querySelector(
        '[data-spec-pane-tiptap-host="true"]',
      );
      if (!host) throw new Error("spec-pane host missing");
      // ``__isonimSpecPaneEditor`` is exposed for the e2e tests by
      // the spec-pane mount (TBAR-M5b adds this hook).  Fallback:
      // dispatch a synthetic ``input`` event so the ``markDirty``
      // path still trips.
      const ed = window.__isonimSpecPaneEditor;
      if (ed && ed.commands && typeof ed.commands.setContent === "function") {
        ed.commands.setContent(newBody, true);
      } else {
        // Direct DOM fallback — type into the ProseMirror surface so
        // TipTap's input rules run and ``onUpdate`` fires.
        const pm = host.querySelector(".ProseMirror");
        if (pm) {
          pm.focus();
          document.execCommand("selectAll", false, null);
          document.execCommand("insertText", false, newBody);
        }
      }
    });

    await page.waitForFunction(
      () => {
        const row = document.querySelector(
          '[data-spec-pane-edit-controls="true"]',
        );
        if (!row) return false;
        return getComputedStyle(row).display !== "none";
      },
      { timeout: 5000 },
    );

    // See cancel-test note for why we click via JS.
    await page.evaluate(() => {
      const btn = document.querySelector('[data-spec-pane-save-btn="true"]');
      if (!btn) throw new Error("save button missing");
      btn.click();
    });

    const deadline = Date.now() + 8000;
    while (Date.now() < deadline) {
      if (saveResponses.some((r) => r.status === 200)) break;
      await new Promise((r) => setTimeout(r, 100));
    }
    assert.ok(
      saveResponses.some((r) => r.status === 200),
      `expected at least one 200 response to /api/design-review/save-brief; got ${JSON.stringify(saveResponses)}`,
    );

    const onDisk = readFileSync(state.briefPath, "utf8");
    assert.ok(
      onDisk.includes("Edited by e2e test"),
      `file on disk does not carry the new body; head:\n${onDisk.slice(0, 200)}`,
    );

    await clickViewMode(page);
    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-spec-pane-tiptap-host="true"]',
        );
        return host && host.getAttribute("data-tiptap-editable") === "false";
      },
      { timeout: 5000 },
    );
  } finally {
    await ctx.close();
  }
});

test("e2e_spec_edit_mode_cancel_reverts_to_last_saved", async () => {
  const state = serverState;
  const { ctx, page } = await openEditor(state);
  try {
    await selectTaskAppStory(page);
    await switchToSpec(page);
    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-spec-pane-tiptap-host="true"]',
        );
        return !!host && host.getAttribute("data-tiptap-mounted") === "true";
      },
      { timeout: 10000 },
    );

    await clickEditMode(page);

    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-spec-pane-tiptap-host="true"]',
        );
        return host && host.getAttribute("data-tiptap-editable") === "true";
      },
      { timeout: 5000 },
    );

    // TBAR-M5b: Edit mode now uses a real TipTap editable instance.
    // ``window.__isonimSpecPaneEditor`` is the test hook exposed by
    // the spec-pane mount; ``commands.setContent`` parses markdown +
    // fires ``onUpdate``.
    const initial = await page.evaluate(() => {
      const ed = window.__isonimSpecPaneEditor;
      if (!ed || !ed.storage || !ed.storage.markdown) return null;
      return ed.storage.markdown.getMarkdown();
    });
    assert.ok(
      initial !== null,
      "TipTap editor with Markdown ext is mounted in Edit mode",
    );

    await page.evaluate(() => {
      const ed = window.__isonimSpecPaneEditor;
      const cur = ed.storage.markdown.getMarkdown();
      const next = cur + "\n\n<<CANCEL-SENTINEL>>";
      ed.commands.setContent(next, true);
    });

    await page.waitForFunction(
      () => {
        const row = document.querySelector(
          '[data-spec-pane-edit-controls="true"]',
        );
        return row && getComputedStyle(row).display !== "none";
      },
      { timeout: 5000 },
    );

    // Click via JS rather than Playwright's pointer pipeline — the
    // TipTap editable host can grow to overlay the button row when
    // the brief body is long enough to scroll, and Playwright's
    // pointer-events guard then reports the click as intercepted.
    // The button's onClick handler runs regardless of the click
    // origin so this is functionally equivalent.
    await page.evaluate(() => {
      const btn = document.querySelector('[data-spec-pane-cancel-btn="true"]');
      if (!btn) throw new Error("cancel button missing");
      btn.click();
    });

    await page.waitForFunction(
      () => {
        const root = document.querySelector("[data-spec-pane-mode]");
        return root && root.getAttribute("data-spec-pane-mode") === "view";
      },
      { timeout: 5000 },
    );

    // The on-disk file is unchanged by Cancel — the first test in
    // this file may have already changed the file body, so we just
    // assert that the cancel sentinel did NOT land on disk.
    const onDisk = readFileSync(state.briefPath, "utf8");
    assert.ok(
      !onDisk.includes("<<CANCEL-SENTINEL>>"),
      "cancel sentinel must not appear on disk (Cancel did not write)",
    );
  } finally {
    await ctx.close();
  }
});

test("e2e_spec_edit_mode_bold_autoformat_produces_strong_tag", async () => {
  // TBAR-M5b — the headline visible deliverable of switching off the
  // textarea overlay is that TipTap's input rules now run inside the
  // spec pane.  Typing ``**bold**`` should autoformat to a
  // ``<strong>`` mark on the ProseMirror surface.  This test
  // exercises that path against the real editor build.
  const state = serverState;
  const { ctx, page } = await openEditor(state);
  try {
    await selectTaskAppStory(page);
    await switchToSpec(page);
    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-spec-pane-tiptap-host="true"]',
        );
        return !!host && host.getAttribute("data-tiptap-mounted") === "true";
      },
      { timeout: 10000 },
    );

    await clickEditMode(page);
    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-spec-pane-tiptap-host="true"]',
        );
        return host && host.getAttribute("data-tiptap-editable") === "true";
      },
      { timeout: 5000 },
    );

    // TBAR-M5b headline deliverable: typing ``**bold**`` in Edit mode
    // should trigger TipTap's markdown input rule and produce a
    // ``<strong>`` mark — proving the spec pane is now a real TipTap
    // editable instance, not a textarea overlay.
    //
    // ProseMirror's input rules listen on the ``handleTextInput``
    // view prop, which is invoked when text is inserted via the
    // ``inputrules`` plugin's pipeline.  ``page.keyboard.type``
    // produces real ``keydown`` / ``input`` events but, in a
    // headless Chromium harness, the ProseMirror ``inputrules``
    // plugin sometimes misses those events (the contentEditable's
    // text-input intent doesn't always synthesise the right kind of
    // ``beforeinput`` mutation).  The robust way to trigger the
    // input rule is to call the ``inputrules`` plugin's
    // ``run`` helper directly via ``view.someProp``.
    //
    // We position the cursor after a leading word (the input rule
    // requires a ``^|\s`` boundary before ``**``) and then run the
    // input pipeline character by character to land on the trailing
    // ``**``.  At that final transition the ``starInputRegex`` in
    // ``@tiptap/extension-bold`` matches and replaces the literal
    // tokens with a ``strong`` mark wrapping ``bold``.
    // Seed with a single word and position the cursor at the end so
    // the next typed token sees a ``\s`` boundary before the ``**``.
    // The markdown parser trims trailing whitespace from inline
    // content, so we type the leading space via the keyboard
    // pipeline rather than embedding it in the seed.
    await page.evaluate(() => {
      const ed = window.__isonimSpecPaneEditor;
      if (!ed) throw new Error("spec pane editor handle missing");
      ed.commands.setContent("Hello", true);
      ed.commands.focus("end");
    });

    // Focus the ProseMirror surface so real ``KeyboardEvent``s land
    // on the contenteditable element.
    await page.evaluate(() => {
      const pm = document.querySelector(
        '[data-spec-pane-tiptap-host="true"] .ProseMirror',
      );
      if (!pm) throw new Error("ProseMirror surface missing");
      pm.focus();
    });
    // Typing " **bold**" — the leading space gives the bold input
    // rule its ``\s`` boundary; the trailing ``**`` lands on the
    // input-rule trigger.  ``starInputRegex`` in
    // ``@tiptap/extension-bold`` accepts both ``$`` (end of doc) and
    // a single non-asterisk character after the closing ``**``; the
    // regex variant TipTap 3.x ships matches the final ``*`` itself
    // (not a trailing space), so we don't add one here.
    await page.keyboard.type(" **bold**");

    // Wait for the input rule to apply; assert a <strong> tag now
    // exists inside the ProseMirror surface.
    await page.waitForFunction(
      () => {
        const host = document.querySelector(
          '[data-spec-pane-tiptap-host="true"]',
        );
        if (!host) return false;
        const strong = host.querySelector(".ProseMirror strong");
        return strong && (strong.textContent || "").trim() === "bold";
      },
      { timeout: 5000 },
    );
    const strongText = await page.evaluate(() => {
      const host = document.querySelector(
        '[data-spec-pane-tiptap-host="true"]',
      );
      if (!host) return null;
      const strong = host.querySelector(".ProseMirror strong");
      return strong ? (strong.textContent || "").trim() : null;
    });
    assert.equal(
      strongText,
      "bold",
      "**bold** autoformat produces a <strong>bold</strong> mark",
    );
  } finally {
    await ctx.close();
  }
});
