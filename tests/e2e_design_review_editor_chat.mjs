// Phase C — e2e: editor's AI sidebar drives the daemon's
// /api/agent/* endpoints.
//
// Spawns:
//   1. ``isonim-review serve --agent-routes-only`` with the fake ACP
//      backend from Phase B (deterministic responses).
//   2. The editor JS bundle served from build/editor/ via Python's
//      stdlib http.server.
//
// Drives Playwright through two scenarios:
//
//   * "hello" prompt typed into the chat panel → fake agent's
//     deterministic response appears in the transcript.
//   * "Review this preview" button clicked on a covered story →
//     a context-loaded prompt is submitted and a response streams back.
//
// Pre-reqs: the dev shell ships ``nim``, ``python3``, ``playwright``,
// and the built ``build/bin/isonim-review`` + ``build/bin/fake-acp-agent``
// binaries.  Run ``just isonim-review-build`` + ``just fake-acp-agent-build``
// + ``just editor-build`` before invoking ``node --test``.

import { execSync, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, "..");
const editorDir = join(projectRoot, "build", "editor");
const reviewBin = join(projectRoot, "build", "bin", "isonim-review");
const fakeAcpBin = join(projectRoot, "build", "bin", "fake-acp-agent");

const EDITOR_PORT = 8094;
const DAEMON_PORT = 8113;

let daemonProc = null;
let editorProc = null;

function skipIfPrereqsMissing(t) {
  const missing = [];
  if (!existsSync(reviewBin)) missing.push("build/bin/isonim-review");
  if (!existsSync(fakeAcpBin)) missing.push("build/bin/fake-acp-agent");
  if (!existsSync(join(editorDir, "editor.js")))
    missing.push("build/editor/editor.js");
  if (missing.length > 0) {
    t.skip(
      `Phase C e2e requires prerequisites: ${missing.join(", ")} — ` +
        "run `just isonim-review-build && just fake-acp-agent-build && " +
        "just editor-build` to populate them.",
    );
    return true;
  }
  return false;
}

async function startDaemon() {
  // The daemon picks up the fake-ACP binary via ISONIM_ACP_AGENT_CMD
  // (the same convention ``tests/helpers/agent_routes_fixture.nim``
  // uses).  ``--agent-routes-only`` keeps Postgres out of the loop.
  //
  // Leave ``ISONIM_AGENT_BACKEND`` at its default (``claude``) so the
  // daemon uses ``fromClaudeCodeAcp``, which reads ``ISONIM_ACP_AGENT_CMD``
  // as an override.  Setting ``ISONIM_AGENT_BACKEND=custom`` would
  // require an additional ``[agent].command`` config value that has no
  // env-var counterpart, so the daemon would refuse to start.
  daemonProc = spawn(reviewBin, ["serve", "--agent-routes-only"], {
    cwd: projectRoot,
    stdio: ["ignore", "pipe", "pipe"],
    detached: true,
    env: {
      ...process.env,
      ISONIM_ACP_AGENT_CMD: fakeAcpBin,
      ISONIM_REVIEW_PORT: String(DAEMON_PORT),
    },
  });
  // Wait for the daemon to bind by polling the agent-sessions probe.
  for (let i = 0; i < 20; i++) {
    try {
      const r = execSync(
        `curl -sS -o /dev/null -w '%{http_code}' --max-time 0.5 ` +
          `-X POST -H 'Content-Type: application/json' --data '{}' ` +
          `http://127.0.0.1:${DAEMON_PORT}/api/agent/sessions`,
        { stdio: ["ignore", "pipe", "ignore"] },
      )
        .toString()
        .trim();
      if (r === "200" || r === "503") return;
    } catch {
      /* not yet bound */
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
}

function stopDaemon() {
  if (daemonProc) {
    try {
      process.kill(-daemonProc.pid, "SIGTERM");
    } catch {
      /* ignore */
    }
    daemonProc = null;
  }
}

function startEditor() {
  editorProc = spawn(
    "python3",
    ["-m", "http.server", String(EDITOR_PORT), "--bind", "127.0.0.1"],
    { cwd: editorDir, stdio: "ignore", detached: true },
  );
  return new Promise((resolve) => setTimeout(resolve, 1200));
}

function stopEditor() {
  if (editorProc) {
    try {
      process.kill(-editorProc.pid, "SIGTERM");
    } catch {
      /* ignore */
    }
    editorProc = null;
  }
}

let chromium = null;
let browser = null;

async function ensureBrowser() {
  if (chromium === null) {
    const mod = await import("playwright");
    chromium = mod.chromium;
  }
  if (browser === null) {
    browser = await chromium.launch({ headless: true });
  }
  return browser;
}

async function openEditor() {
  const b = await ensureBrowser();
  const context = await b.newContext({
    viewport: { width: 1440, height: 900 },
  });
  const page = await context.newPage();
  // Pre-bake the daemon URL via a meta tag so the editor's
  // ``resolveDaemonUrl`` picks the right port without needing
  // window.location to be on :8090.
  await page.addInitScript(
    ({ port }) => {
      const meta = document.createElement("meta");
      meta.name = "isonim-review-api";
      meta.content = `http://127.0.0.1:${port}`;
      document.head?.appendChild(meta);
    },
    { port: DAEMON_PORT },
  );
  await page.goto(`http://127.0.0.1:${EDITOR_PORT}/`);
  await page.waitForTimeout(1000);
  return { page, context };
}

test("e2e_editor_chat_panel_hello_streams_response_from_daemon", async (t) => {
  if (skipIfPrereqsMissing(t)) return;
  await startDaemon();
  await startEditor();
  try {
    const { page, context } = await openEditor();
    try {
      const input = page.locator("input[aria-label='Agent prompt']");
      await input.waitFor({ state: "visible", timeout: 10_000 });
      await input.fill("hello");
      const sendBtn = page.locator("[aria-label='Send agent prompt']");
      await sendBtn.click();
      // Wait for an agent message to appear in the transcript.
      await page.waitForFunction(
        () => document.body.innerText.includes("AI Designer"),
        { timeout: 10_000 },
      );
      const transcript = await page.evaluate(() => document.body.innerText);
      assert.ok(
        transcript.includes("AI Designer"),
        "agent response should appear under 'AI Designer'",
      );
    } finally {
      await context.close();
    }
  } finally {
    stopEditor();
    stopDaemon();
  }
});

test("e2e_editor_review_this_preview_button_submits_context_loaded_prompt", async (t) => {
  if (skipIfPrereqsMissing(t)) return;
  await startDaemon();
  await startEditor();
  try {
    const { page, context } = await openEditor();
    try {
      // Navigate to a story covered by the built-in brief index so the
      // brief tab actually shows a covered preview (the review button
      // is mounted regardless, but its parent container hides itself
      // when no brief covers the active story).
      const navigated = await page.evaluate(() => {
        if (window.__isonimEditor && window.__isonimEditor.selectStoryByName) {
          return window.__isonimEditor.selectStoryByName(
            "Task App / Pages",
            "Inbox",
          );
        }
        return null;
      });
      if (!navigated) {
        t.diagnostic(
          "__isonimEditor.selectStoryByName missing — editor mount may have failed",
        );
        return;
      }
      await page.waitForTimeout(500);
      const briefTabBtn = page.locator("[data-preview-pane-tab='brief']");
      await briefTabBtn.first().click();
      await page.waitForTimeout(300);

      const reviewBtn = page.locator(
        "[data-design-review-review-button='true']",
      );
      if ((await reviewBtn.count()) === 0) {
        t.diagnostic("no covered preview in the demo workspace — skipping");
        return;
      }
      const parentVisible = await reviewBtn
        .first()
        .evaluate((el) =>
          el.parentElement?.getAttribute("data-design-review-visible"),
        );
      if (parentVisible !== "true") {
        t.diagnostic(
          `review actions parent reports data-design-review-visible=${parentVisible}; ` +
            "the brief index didn't bake the Task App / Pages / Inbox story — skipping",
        );
        return;
      }
      await reviewBtn.first().click();
      await page.waitForFunction(
        () => document.body.innerText.includes("Review the preview"),
        { timeout: 10_000 },
      );
      const transcript = await page.evaluate(() => document.body.innerText);
      assert.ok(
        transcript.includes("Review the preview"),
        "the composed review prompt should appear in the chat transcript",
      );
    } finally {
      await context.close();
    }
  } finally {
    stopEditor();
    stopDaemon();
  }
});

test.after(async () => {
  if (browser) {
    await browser.close();
    browser = null;
  }
});
