// TBAR-M6 — Playwright-driven browser e2e for the editor's
// Spec-Comment → AI Assistant chat flow.
//
// Real environment, no mocks:
//   - Real Postgres cluster (PgFixture).
//   - Real ``isonim-review serve`` daemon.
//   - Real ``editor-server.mjs`` proxy injecting the daemon URL.
//   - Real editor JS bundle via ``just editor-build``.
//
// Flow exercised:
//   1. Open the editor against the proxy + select the Task App / Inbox story.
//   2. Switch to Spec, switch mode to Comment.
//   3. Programmatically select a paragraph inside the TipTap pane
//      (Selection + Range API) so TipTap's ``selectionUpdate`` event
//      fires.
//   4. Assert ``[data-spec-comment-popover]`` appears in the DOM and
//      reports a non-"none" display style.
//   5. Type a comment into the popover's textarea.
//   6. Intercept ``POST /api/agent/prompts`` via Playwright's
//      ``page.on("request", ...)`` so we can validate the body.
//   7. Click Submit.
//   8. Assert the popover dismisses + the chat sidebar mounts in the
//      DOM (data-test-id="property-panel" reappears even though
//      surface == Spec).
//   9. Assert the intercepted prompt body carries both the selected
//      text and the user's comment (the structured "SPEC COMMENT"
//      block).
//
// The daemon and the PG cluster are spun up once for the whole file
// via ``test.before`` / ``test.after`` (mirrors TBAR-M5's e2e
// scaffolding).

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
const fakeAcpPath = join(isonimRoot, "build", "bin", "fake-acp-agent");
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

function buildFakeAcpAgent() {
  if (existsSync(fakeAcpPath)) return;
  const cmd = "direnv exec . just fake-acp-agent-build";
  exec(cmd, { cwd: isonimRoot });
  if (!existsSync(fakeAcpPath)) {
    throw new Error("fake-acp-agent binary was not built");
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

# Task App spec body

The inbox surface shows tasks grouped by project.

## Sections

- Outstanding work
- Recently completed
- Archive
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
  buildFakeAcpAgent();
  buildEditor();
  pgState = await startPgCluster();
  const pgPort = pgState.pgPort;

  const workspaceRoot = mkdtempSync(join(tmpdir(), "tbar-m6-ws-"));
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
        // TBAR-M6 — point the daemon's ACP backend at the fake-acp
        // agent so the chat session POST + the prompt SSE round-trip
        // succeed end-to-end without requiring a real Claude binary
        // on the test host.  The fake-acp agent echoes the prompt
        // through a deterministic session/update + end stream which
        // is enough for the editor's chat pipeline to record the
        // user message + observe the prompt POST land.
        ISONIM_ACP_AGENT_CMD: fakeAcpPath,
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
    daemonOutRef: () => daemonOut,
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

async function clickCommentMode(page) {
  // The View / Comment / Edit chip group lives in the chrome bar's
  // ``mode`` toolbar cluster. CHRM-M2 migrated the cluster to the
  // ChoiceGroup widget, so the pill is addressed positionally:
  // Comment is index 1.
  await page.evaluate(() => {
    const chip = document.querySelector(
      '[data-toolbar-cluster="mode"] [data-choice-group-pill="1"]',
    );
    if (!chip) throw new Error("comment chip not found");
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

test("e2e_spec_comment_popover_appears_on_text_selection", async () => {
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

    await clickCommentMode(page);

    await page.waitForFunction(
      () => {
        const root = document.querySelector("[data-spec-pane-mode]");
        return root && root.getAttribute("data-spec-pane-mode") === "comment";
      },
      { timeout: 5000 },
    );

    // Programmatically select a paragraph inside the TipTap surface.
    // The ProseMirror DOM nests <p> tags directly under .ProseMirror;
    // we pick the first non-empty paragraph after the H1 title.  The
    // ``selectionUpdate`` event fires synchronously on TipTap's view
    // when ``Selection.setBaseAndExtent`` lands.
    const selectedText = await page.evaluate(() => {
      const pm = document.querySelector(
        '[data-spec-pane-tiptap-host="true"] .ProseMirror',
      );
      if (!pm) throw new Error("ProseMirror surface missing");
      let target = null;
      for (const node of pm.querySelectorAll("p")) {
        if ((node.textContent || "").trim().length > 0) {
          target = node;
          break;
        }
      }
      if (!target) throw new Error("no paragraph to select");
      const range = document.createRange();
      range.selectNodeContents(target);
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
      // TipTap listens on the document's ``selectionchange`` event in
      // the ProseMirror view -- forcing a focus on the editable surface
      // ensures TipTap routes the selection back through its state.
      target.dispatchEvent(new Event("focus", { bubbles: true }));
      // Drive TipTap's selection via the exposed editor handle if
      // available (the e2e hook exposed by TBAR-M5b).  Falling back to
      // the DOM Range/Selection above covers the case where the hook
      // isn't yet attached.
      try {
        const ed = window.__isonimSpecPaneEditor;
        if (ed && ed.commands && ed.commands.setTextSelection) {
          const view = ed.view;
          // Find the start + end document positions of the paragraph
          // by walking ProseMirror's doc and matching the target's
          // text content.
          const wantedText = (target.textContent || "").trim();
          let from = -1,
            to = -1;
          view.state.doc.descendants((node, pos) => {
            if (from >= 0) return false;
            if (node.isTextblock && node.textContent.trim() === wantedText) {
              from = pos + 1;
              to = pos + 1 + node.content.size;
              return false;
            }
            return true;
          });
          if (from >= 0) {
            ed.commands.setTextSelection({ from, to });
            ed.commands.focus();
          }
        }
      } catch (e) {
        // Ignore — the popover should still trigger via the DOM path.
      }
      return (target.textContent || "").trim();
    });

    assert.ok(
      selectedText.length > 0,
      "selected paragraph carries non-empty text",
    );

    // Wait for the popover to appear.  The mount sits at shellRoot
    // and is identified by the ``data-spec-comment-popover`` attr.
    await page.waitForFunction(
      () => {
        const el = document.querySelector("[data-spec-comment-popover]");
        if (!el) return false;
        return getComputedStyle(el).display !== "none";
      },
      { timeout: 5000 },
    );

    const popoverInfo = await page.evaluate(() => {
      const el = document.querySelector("[data-spec-comment-popover]");
      if (!el) return null;
      return {
        display: getComputedStyle(el).display,
        previewText:
          el.querySelector("[data-spec-comment-popover-preview]")
            ?.textContent || "",
      };
    });
    assert.ok(popoverInfo, "popover element exists");
    assert.notEqual(popoverInfo.display, "none");
    assert.ok(
      popoverInfo.previewText.length > 0,
      "popover preview echoes selected text",
    );
  } finally {
    await ctx.close();
  }
});

test("e2e_spec_comment_submit_opens_chat_and_posts_prompt", async () => {
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

    await clickCommentMode(page);
    await page.waitForFunction(
      () => {
        const root = document.querySelector("[data-spec-pane-mode]");
        return root && root.getAttribute("data-spec-pane-mode") === "comment";
      },
      { timeout: 5000 },
    );

    // Programmatically select a paragraph + drive TipTap's selection.
    await page.evaluate(() => {
      const pm = document.querySelector(
        '[data-spec-pane-tiptap-host="true"] .ProseMirror',
      );
      if (!pm) throw new Error("ProseMirror surface missing");
      let target = null;
      for (const node of pm.querySelectorAll("p")) {
        if ((node.textContent || "").trim().length > 0) {
          target = node;
          break;
        }
      }
      if (!target) throw new Error("no paragraph to select");
      const range = document.createRange();
      range.selectNodeContents(target);
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
      try {
        const ed = window.__isonimSpecPaneEditor;
        if (ed && ed.commands && ed.commands.setTextSelection) {
          const view = ed.view;
          const wantedText = (target.textContent || "").trim();
          let from = -1,
            to = -1;
          view.state.doc.descendants((node, pos) => {
            if (from >= 0) return false;
            if (node.isTextblock && node.textContent.trim() === wantedText) {
              from = pos + 1;
              to = pos + 1 + node.content.size;
              return false;
            }
            return true;
          });
          if (from >= 0) {
            ed.commands.setTextSelection({ from, to });
            ed.commands.focus();
          }
        }
      } catch {}
    });

    await page.waitForSelector("[data-spec-comment-popover]", {
      state: "attached",
      timeout: 5000,
    });

    // Intercept the prompt POST so we can inspect its body.
    const promptRequests = [];
    page.on("request", (req) => {
      const u = req.url();
      if (u.endsWith("/api/agent/prompts") && req.method() === "POST") {
        let body = null;
        try {
          body = req.postData();
        } catch {}
        promptRequests.push({ url: u, body });
      }
    });
    const sessionRequests = [];
    page.on("request", (req) => {
      const u = req.url();
      if (u.endsWith("/api/agent/sessions") && req.method() === "POST") {
        sessionRequests.push({ url: u });
      }
    });

    // Type the user comment.
    await page.evaluate(() => {
      const ta = document.querySelector("[data-spec-comment-popover-input]");
      if (!ta) throw new Error("popover textarea missing");
      ta.focus();
      ta.value = "Why is the inbox split into three sections?";
      ta.dispatchEvent(new Event("input", { bubbles: true }));
    });

    // Click Submit.
    await page.evaluate(() => {
      const btn = document.querySelector("[data-spec-comment-popover-submit]");
      if (!btn) throw new Error("submit button missing");
      btn.click();
    });

    // Wait for the popover to dismiss (success path).
    await page.waitForFunction(
      () => {
        const el = document.querySelector("[data-spec-comment-popover]");
        if (!el) return true; // unmounted - acceptable
        return getComputedStyle(el).display === "none";
      },
      { timeout: 8000 },
    );

    // Wait for the chat sidebar to be mounted in the DOM.  Even
    // though surface == sSpec, the spec-comment override flips the
    // chat panel back into the shell row.
    await page.waitForSelector('[data-test-id="property-panel"]', {
      state: "attached",
      timeout: 5000,
    });

    // The chat sidebar's transcript MUST carry the user-message
    // bubble that ``sendAgentPrompt`` injected — that's the visible
    // proof the structured "SPEC COMMENT" payload landed in the
    // chat.
    const transcript = await page.evaluate(() => {
      const panel = document.querySelector('[data-test-id="property-panel"]');
      if (!panel) return "";
      return panel.innerText || panel.textContent || "";
    });
    const dump = (msg) =>
      `${msg}; transcript[0..1200]=${transcript.slice(0, 1200)}`;
    assert.ok(
      transcript.indexOf("SPEC COMMENT") >= 0,
      dump("chat transcript missing SPEC COMMENT marker"),
    );
    assert.ok(
      transcript.indexOf("Why is the inbox split into three sections?") >= 0,
      dump("chat transcript missing user comment"),
    );
    // The selected paragraph is the first non-empty <p> after the
    // brief's title; for the baked-in render.task-app brief that's
    // the "What You're Reviewing" paragraph that describes the demo.
    assert.ok(
      transcript.indexOf("Task App") >= 0 ||
        transcript.indexOf("showcase apps") >= 0 ||
        transcript.indexOf("full-editor screenshots") >= 0,
      dump("chat transcript missing selected text excerpt"),
    );

    // Wait for the daemon to receive both the session-creation POST
    // and the prompt POST.  ``page.on("request", ...)`` captures
    // outbound POSTs as they're dispatched, so we just need to give
    // the fake-acp agent a beat to finish the round-trip.
    const deadline = Date.now() + 8000;
    while (Date.now() < deadline) {
      if (sessionRequests.length > 0 && promptRequests.length > 0) break;
      await new Promise((r) => setTimeout(r, 100));
    }
    assert.ok(
      sessionRequests.length >= 1,
      `expected at least one POST to /api/agent/sessions, got: ${JSON.stringify(sessionRequests)}`,
    );
    assert.ok(
      promptRequests.length >= 1,
      `expected at least one POST to /api/agent/prompts, got: ${JSON.stringify(promptRequests)}`,
    );

    // The prompt POST body MUST carry the structured "SPEC COMMENT"
    // block with both the selected text excerpt and the user's
    // comment.  This is the wire-level proof that TBAR-M6's chat
    // submission protocol reached the daemon intact.
    const body = promptRequests[0].body || "";
    assert.ok(
      body.indexOf("SPEC COMMENT") >= 0,
      `prompt body missing SPEC COMMENT marker; body=${body.slice(0, 300)}`,
    );
    assert.ok(
      body.indexOf("Why is the inbox split into three sections?") >= 0,
      `prompt body missing user comment; body=${body.slice(0, 300)}`,
    );
    assert.ok(
      body.indexOf("Task App") >= 0 ||
        body.indexOf("showcase apps") >= 0 ||
        body.indexOf("full-editor screenshots") >= 0,
      `prompt body missing selected text excerpt; body=${body.slice(0, 400)}`,
    );
  } finally {
    await ctx.close();
  }
});
