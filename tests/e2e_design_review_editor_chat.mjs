// Mounted browser → production sameorigin launcher/private bootstrap → scoped
// editor RPC registration → compiled daemon → actual persistent ACP session.
// The only substituted boundary is the deterministic ACP peer: a real executable
// scripts response text instead of an external LLM. DOM, viewmodel, filesystem,
// compiler, HTTP, registration, session creation and prompt delivery remain real.
// Full Harbor REST/provider scenarios are separately registered in the chat suite.
// Launcher clean exit proves its owned daemon/provider teardown; no live ports or
// served developer assets are needed. The obsolete
// e2e_editor_review_this_preview_button_submits_context_loaded_prompt case maps
// to e2e_editor_composer_delivers_selected_context_on_same_peer_session: current
// physical real-catalogue/empty-Spec/composer actions replace removed controls.
// The owning demo is Wanderlust; the old helper fabricated an Inbox StoryRef.
// Covered/multiple-brief responsibilities remain in the registered Spec/index
// tests; this case asserts the honest empty Spec for Home / Discover.
// An owned temporary native helper uses the production deliveredContext decoder
// only to observe real peer receipts; it does not intercept or replace delivery.
// Actual PID/start-time descendants prove peer continuity; canned response text
// proves output delivery, not model memory or instructions (primer is disabled).
// Captured-record poison controls are observation/oracle checks, not transport
// mutations. Filesystem, native compiler and production context decoder are real.
// The new failure cases transparently clone only their real SSE response for
// raw wire assertions after the production reader cancels at its terminal frame.
// They await that clone to EOF before context close; this observer is not proof
// of production reader cleanup. Existing uninstrumented lifecycle cases remain.

import { spawn, execFileSync } from "node:child_process";
import {
  existsSync,
  readFileSync,
  mkdtempSync,
  writeFileSync,
  createWriteStream,
} from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { once } from "node:events";
import { createHash } from "node:crypto";
import test from "node:test";
import assert from "node:assert/strict";

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, "..");
const editorDir =
  process.env.ISONIM_CHAT_TEST_EDITOR_DIR ||
  join(projectRoot, "build", "editor");
const reviewBin = join(projectRoot, "build", "bin", "isonim-review");
const fakeAcpBin = join(projectRoot, "build", "bin", "fake-acp-agent");

const EDITOR_PORT = Number(process.env.ISONIM_CHAT_TEST_EDITOR_PORT || 0);
let editorProc = null;
let editorOrigin;
let artifacts;
let launcherExit;
let actualSessions = [];
const shutdownPolicy = JSON.parse(
  (await import("node:fs")).readFileSync(
    join(projectRoot, "tools/editor_shutdown.json"),
  ),
);
const shutdownMs =
  1000 *
  (2 * shutdownPolicy.http_request_seconds +
    shutdownPolicy.harbor_teardown_seconds +
    shutdownPolicy.supervisor_margin_seconds);
async function bounded(promise, milliseconds, label) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(
          () =>
            reject(
              new Error(
                `${label} exceeded ${milliseconds}ms; artifacts ${artifacts}`,
              ),
            ),
          milliseconds,
        );
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

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

async function startEditor(providerEnv = {}) {
  actualSessions = [];
  artifacts = mkdtempSync(join(tmpdir(), "isonim-http-chat-"));
  const config = join(artifacts, "review.toml");
  writeFileSync(
    config,
    '[agent]\nbackend = "custom"\ncommand = ' +
      JSON.stringify(fakeAcpBin) +
      "\nargs = []\nprimer_enabled = false\n",
  );
  const log = createWriteStream(join(artifacts, "server.log"));
  editorProc = spawn(
    "python3",
    [
      join(projectRoot, "tools/editor_server.py"),
      "--directory",
      editorDir,
      "--project-root",
      artifacts,
      "--port",
      String(EDITOR_PORT),
      "--bind",
      "127.0.0.1",
      "--config",
      config,
      "--daemon-binary",
      reviewBin,
    ],
    {
      cwd: projectRoot,
      env: {
        ...process.env,
        FAKE_ACP_REPLY: "M4_HTTP_HELLO_REPLY",
        ...providerEnv,
      },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  launcherExit = once(editorProc, "exit");
  editorProc.stderr.pipe(log);
  console.log(`HTTP chat artifacts ${artifacts}`);
  await bounded(
    new Promise((resolve, reject) => {
      let output = "";
      editorProc.stdout.on("data", (chunk) => {
        output += chunk;
        const match = output.match(/Editor listening on (http:\/\/[^\s]+)\//);
        if (match) {
          editorOrigin = match[1];
          resolve();
        }
      });
      launcherExit.then(([code, signal]) =>
        reject(new Error(`Launcher startup exit ${code}/${signal}`)),
      );
    }),
    30000,
    "Production launcher startup",
  );
}
async function stopEditor() {
  if (!editorProc) return;
  const processToStop = editorProc;
  editorProc = null;
  if (processToStop.exitCode === null && processToStop.signalCode === null)
    processToStop.kill("SIGTERM");
  const [code, signal] = await bounded(
    launcherExit,
    shutdownMs,
    "Owned launcher/daemon/provider shutdown",
  );
  assert.equal(signal, null, "launcher must perform normal owned teardown");
  // shutdown_signals deliberately raises SystemExit(128 + SIGTERM); its
  // owned_process scope separately rejects any nonzero native daemon exit.
  assert.equal(code, 143, "launcher must complete its handled SIGTERM scope");
  const log = readFileSync(join(artifacts, "server.log"), "utf8");
  assert.match(
    log,
    /isonim-review serve: exiting cleanly/,
    "native daemon must exit cleanly",
  );
  assert.doesNotMatch(
    log,
    /exceeded shutdown budget|did not exit cleanly|closure is unconfirmed/,
  );
  for (const session of actualSessions) {
    const lines = log.split("\n");
    assert.ok(
      lines.some(
        (line) =>
          line.includes("agent client shutdown begin") &&
          line.includes("sessionId=" + session),
      ),
      "the actual created provider session must begin shutdown",
    );
    assert.ok(
      lines.some(
        (line) =>
          line.includes("agent client shutdown end") &&
          line.includes("sessionId=" + session),
      ),
      "the actual created provider session must finish shutdown",
    );
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
    const chromiumEnv = { ...process.env };
    // Chromium owns its Nix closure; the compiler shell's dynamic-library path
    // must not replace that closure's libc/ALSA dependencies.
    delete chromiumEnv.LD_LIBRARY_PATH;
    browser = await chromium.launch({
      env: chromiumEnv,
      headless: true,
      timeout: 30000,
      ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE
        ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE }
        : {}),
    });
  }
  return browser;
}

async function openEditor(observeWire = false) {
  const b = await ensureBrowser();
  const context = await b.newContext({
    viewport: { width: 1440, height: 900 },
  });
  try {
    const page = await context.newPage();
    if (observeWire)
      await page.addInitScript(() => {
        const actualFetch = window.fetch.bind(window);
        // Observe an unchanged clone of the real response, because production
        // correctly cancels its own reader at the terminal frame and DevTools may
        // then discard response.text(). No response/request is substituted.
        window.fetch = (...args) =>
          actualFetch(...args).then((response) => {
            if (new URL(response.url).pathname === "/api/agent/prompts")
              window.__chatAdmissionWire = response
                .clone()
                .text()
                .catch((error) => {
                  window.__chatAdmissionError = String(error);
                  return null;
                });
            return response;
          });
      });
    const registered = page.waitForResponse(
      (response) =>
        new URL(response.url()).pathname === "/api/editor/rpc" &&
        response.request().postDataJSON()?.method === "editor.register",
      { timeout: 30000 },
    );
    const evidence = [];
    page.on("pageerror", (error) =>
      evidence.push({ pageError: error.message }),
    );
    page.on("response", (response) => {
      const pathname = new URL(response.url()).pathname;
      if (pathname.startsWith("/api/agent/"))
        evidence.push({ path: pathname, status: response.status() });
    });
    page.on("requestfailed", (request) =>
      evidence.push({
        path: new URL(request.url()).pathname,
        error: request.failure()?.errorText,
      }),
    );
    context.on("close", () =>
      writeFileSync(
        join(artifacts, "browser-evidence.json"),
        JSON.stringify(evidence, null, 2),
      ),
    );
    await page.goto(editorOrigin);
    const registration = await (await registered).json();
    assert.ok(
      registration.result,
      "actual scoped browser registration must succeed",
    );
    return { page, context };
  } catch (error) {
    try {
      await bounded(
        context.close(),
        30000,
        "Failed editor startup context shutdown",
      );
    } catch (cleanup) {
      throw new AggregateError(
        [error, cleanup],
        "Editor startup and owned context cleanup failed",
      );
    }
    throw error;
  }
}

test("e2e_editor_chat_panel_hello_streams_response_from_daemon", async (t) => {
  if (skipIfPrereqsMissing(t)) return;
  try {
    await startEditor();
    const { page, context } = await openEditor();
    try {
      const input = page.locator("textarea[aria-label='Agent prompt']");
      await input.waitFor({ state: "visible", timeout: 10_000 });
      await input.fill("hello");
      const sendBtn = page.locator("[aria-label='Send agent prompt']");
      const panel = page.locator(".editor-chat[data-chat-local-id]");
      const localId = await panel.getAttribute("data-chat-local-id");
      const createdPromise = page.waitForResponse(
        (response) =>
          new URL(response.url()).pathname === "/api/agent/sessions" &&
          response.request().method() === "POST",
        { timeout: 30000 },
      );
      const promptPromise = page.waitForRequest(
        (request) =>
          new URL(request.url()).pathname === "/api/agent/prompts" &&
          request.method() === "POST",
        { timeout: 30000 },
      );
      const delivered = Promise.all([createdPromise, promptPromise]);
      // Handle both waits immediately: a missing route must fail within its
      // original deadline without leaving an unhandled/dangling request wait.
      delivered.catch(() => {});
      await sendBtn.click();
      const [created, promptRequest] = await delivered;
      assert.equal(created.status(), 200);
      const session = await created.json();
      assert.ok(session.sessionId, "daemon must create an actual session");
      actualSessions.push(session.sessionId);
      const submitted = promptRequest.postDataJSON();
      assert.equal(submitted.sessionId, session.sessionId);
      assert.equal(submitted.messages[0].content[0].text, "hello");
      const user = panel.locator(
        '[data-chat-role="arUser"][data-chat-turn="1"] [data-chat-markdown="paragraph"]',
      );
      await user.waitFor({ state: "visible", timeout: 10_000 });
      assert.deepEqual(await user.allTextContents(), ["hello"]);
      const assistant = panel.locator(
        '[data-chat-role="arAssistant"][data-chat-turn="1"] [data-chat-markdown="paragraph"]',
      );
      await page.waitForFunction(
        () =>
          Array.from(
            document.querySelectorAll(
              '.editor-chat [data-chat-role="arAssistant"] [data-chat-markdown="paragraph"]',
            ),
          ).some((node) => node.textContent === "M4_HTTP_HELLO_REPLY"),
        null,
        { timeout: 10_000 },
      );
      assert.deepEqual(await assistant.allTextContents(), [
        "M4_HTTP_HELLO_REPLY",
      ]);
      assert.equal(await assistant.isVisible(), true);
      assert.equal(await panel.getAttribute("data-chat-local-id"), localId);
      assert.equal(
        await page
          .locator(`[data-ai-assistant-tab="${localId}"]`)
          .getAttribute("aria-selected"),
        "true",
      );
    } finally {
      await bounded(context.close(), 30000, "Owned editor context shutdown");
    }
  } finally {
    await stopEditor();
  }
});

test("e2e_editor_composer_delivers_selected_context_on_same_peer_session", async () => {
  assert.ok(
    existsSync(reviewBin) &&
      existsSync(fakeAcpBin) &&
      existsSync(join(editorDir, "editor.js")),
    "Required built runtime must exist",
  );
  const receipts = mkdtempSync(join(tmpdir(), "isonim-chat-context-"));
  const peerLog = join(receipts, "peer.jsonl");
  const decoderSource = join(receipts, "decode_context.nim");
  const decoder = join(receipts, "decode-context");
  writeFileSync(
    decoderSource,
    `import std/json
import isonim/editor/design_review/context_budget
let input = parseJson(stdin.readAll())
echo $deliveredContext(input["wire"], input["previous"])
`,
  );
  execFileSync(
    "nim",
    [
      "c",
      "--hints:off",
      "--path:" + join(projectRoot, "src"),
      "--nimcache:" + join(receipts, "decoder-cache"),
      "--out:" + decoder,
      decoderSource,
    ],
    { cwd: projectRoot, timeout: 30000 },
  );
  const decode = (wire, previous) =>
    JSON.parse(
      execFileSync(decoder, [], {
        input: JSON.stringify({ wire, previous }),
        encoding: "utf8",
        timeout: 10000,
      }),
    );
  const peerRecords = () =>
    readFileSync(peerLog, "utf8")
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line));
  function ownedPeer() {
    const rows = execFileSync("ps", ["-eo", "pid=,ppid=,lstart=,args="], {
      encoding: "utf8",
      env: { ...process.env, LC_ALL: "C" },
      timeout: 10000,
    })
      .split("\n")
      .map((line) => line.match(/^\s*(\d+)\s+(\d+)\s+(.{24})\s+(.+)$/))
      .filter(Boolean)
      .map((match) => ({
        pid: Number(match[1]),
        parent: Number(match[2]),
        started: match[3],
        args: match[4],
      }));
    const owned = new Set([editorProc.pid]);
    for (let size = -1; size !== owned.size; ) {
      size = owned.size;
      for (const row of rows) if (owned.has(row.parent)) owned.add(row.pid);
    }
    const peers = rows.filter(
      (row) =>
        owned.has(row.pid) &&
        (row.args === fakeAcpBin || row.args.startsWith(fakeAcpBin + " ")),
    );
    assert.equal(
      peers.length,
      1,
      "Exactly one real ACP executable is owned by this launcher",
    );
    return peers[0];
  }
  function assertDelivery(records, submitted, sessionId) {
    const created = records.filter((row) => row.source === "role_instructions");
    const prompts = records.filter((row) => row.source === "fake_acp");
    assert.equal(
      created.length,
      1,
      "One actual session/new must reach the peer",
    );
    assert.equal(created[0].sessionId, sessionId);
    assert.equal(
      prompts.length,
      2,
      "Both actual session/prompt requests must reach the peer",
    );
    const admissions = records.filter((row) => !Object.hasOwn(row, "source"));
    assert.equal(
      admissions.length,
      2,
      "Both daemon admission summaries remain accounted",
    );
    assert.equal(
      records.length,
      5,
      "No unknown receipts or duplicate delivery",
    );
    for (let i = 0; i < admissions.length; i++) {
      const row = admissions[i];
      assert.deepEqual(
        Object.keys(row).sort(),
        [
          "sessionId",
          "promptBlocks",
          "textBlocks",
          "imageBlocks",
          "blocks",
        ].sort(),
      );
      assert.equal(row.sessionId, sessionId);
      assert.equal(row.promptBlocks, 3);
      assert.equal(row.textBlocks, 3);
      assert.equal(row.imageBlocks, 0);
      assert.equal(row.blocks.length, 3);
      for (const block of row.blocks) {
        assert.deepEqual(Object.keys(block).sort(), ["textLen", "type"]);
        assert.equal(block.type, "text");
        assert.ok(Number.isInteger(block.textLen) && block.textLen > 0);
      }
      assert.equal(
        row.blocks[0].textLen,
        Buffer.byteLength(submitted[i].messages[0].content[0].text, "utf8"),
      );
    }
    let previous = {};
    for (let i = 0; i < prompts.length; i++) {
      const row = prompts[i],
        request = submitted[i];
      assert.equal(
        row.sessionId,
        sessionId,
        "Actual peer session must match browser admission",
      );
      assert.equal(
        row.textBlocks,
        3,
        "User, editor and project context blocks must be delivered",
      );
      const label = "EDITOR CONTEXT:\n";
      assert.equal(
        row.promptText.split(label).length,
        2,
        "One labelled real editor context block",
      );
      const offset = row.promptText.indexOf(label);
      assert.equal(
        row.promptText.slice(0, offset).trim(),
        request.messages[0].content[0].text,
        "The peer must receive the exact physically submitted prompt",
      );
      const body = row.promptText.slice(offset + label.length);
      const project = body.indexOf("PROJECT CONTEXT:");
      assert.ok(project > 0, "Real project context follows editor context");
      const wire = JSON.parse(body.slice(0, project).trim());
      assert.ok(wire && typeof wire === "object" && !Array.isArray(wire));
      if ("fromContext" in wire) {
        assert.equal(
          wire.fromContext,
          createHash("sha1")
            .update(JSON.stringify(previous))
            .digest("hex")
            .toUpperCase(),
          "Envelope must identify the exact prior admitted delivered context",
        );
        assert.ok(
          wire.current &&
            typeof wire.current === "object" &&
            !Array.isArray(wire.current),
        );
        assert.ok(
          Object.keys(wire).every((key) =>
            [
              "fromContext",
              "current",
              "boundedInherited",
              "protectedV1",
              "protectedV2",
            ].includes(key),
          ),
        );
        assert.ok(!("protectedV1" in wire && "protectedV2" in wire));
      } else if ("completeContext" in wire) {
        assert.deepEqual(Object.keys(wire), ["completeContext"]);
        assert.ok(
          wire.completeContext &&
            typeof wire.completeContext === "object" &&
            !Array.isArray(wire.completeContext),
        );
      } else {
        assert.deepEqual(
          Object.keys(wire).sort(),
          Object.keys(request.context).sort(),
        );
      }
      const resolved = decode(wire, previous);
      assert.deepEqual(
        resolved,
        request.context,
        "Exact complete browser context must reach the real peer",
      );
      previous = resolved;
    }
  }
  try {
    await startEditor({ FAKE_ACP_CONTENT_LOG: peerLog });
    const { page, context } = await openEditor();
    try {
      const errors = [];
      page.on("pageerror", (error) => errors.push(error.message));
      await page
        .getByRole("button", { name: "Focus Pages category", exact: true })
        .click();
      const group = page.getByRole("button", {
        name: "Toggle Pages stories",
        exact: true,
      });
      await group.waitFor({ state: "visible", timeout: 10000 });
      if ((await group.getAttribute("aria-expanded")) !== "true")
        await group.click();
      const story = page.locator('[data-story-row="Pages/Home / Discover"]');
      await story.click();
      assert.equal(await story.getAttribute("aria-current"), "true");
      await page
        .locator(
          '[data-toolbar-cluster="mode"] [data-choice-group-label="Spec"]',
        )
        .click();
      const spec = page.locator('[data-preview-spec-pane="true"]');
      await spec.waitFor({ state: "visible", timeout: 10000 });
      assert.equal(
        await spec
          .locator("[data-spec-pane-mode]")
          .getAttribute("data-spec-pane-mode"),
        "edit",
      );
      const tiptap = spec.locator("[data-spec-pane-tiptap-host]");
      await page.waitForFunction(
        () =>
          document
            .querySelector("[data-spec-pane-tiptap-host]")
            ?.getAttribute("data-tiptap-editable") === "true",
        null,
        { timeout: 10000 },
      );
      assert.equal(
        (await tiptap.textContent()).trim(),
        "# Spec\n\nNo brief available for the selected story.",
      );
      const panel = page.locator(".editor-chat[data-chat-local-id]");
      const input = panel.locator("textarea[aria-label='Agent prompt']");
      const send = panel.locator("[aria-label='Send agent prompt']");
      await input.waitFor({ state: "visible", timeout: 10000 });
      const localId = await panel.getAttribute("data-chat-local-id");
      assert.ok(localId);
      const submitted = [],
        sessions = [];
      page.on("response", (response) => {
        if (
          new URL(response.url()).pathname === "/api/agent/sessions" &&
          response.request().method() === "POST"
        )
          sessions.push(response);
      });
      const prompts = [
        "Review the selected Home / Discover page and its current editor context.",
        "Continue this Home / Discover page review in the same conversation.",
      ];
      let sessionId, peer;
      for (let turn = 0; turn < prompts.length; turn++) {
        await input.click();
        await input.pressSequentially(prompts[turn]);
        const delivered = page.waitForRequest(
          (request) =>
            new URL(request.url()).pathname === "/api/agent/prompts" &&
            request.method() === "POST",
          { timeout: 30000 },
        );
        delivered.catch(() => {});
        await send.click();
        const request = (await delivered).postDataJSON();
        submitted.push(request);
        assert.equal(request.messages[0].content[0].text, prompts[turn]);
        assert.deepEqual(request.context.selectedStory, {
          group: "Pages",
          name: "Home / Discover",
          kind: 3,
          index: 0,
        });
        assert.equal(request.context.backend, "absAcp");
        assert.equal(request.context.platform, "pbWeb");
        for (const field of [
          "accumulatedEdits",
          "sourceMap",
          "renderedComponentTree",
          "availableTailwindClasses",
          "themeTokens",
          "activeThemeContext",
        ])
          assert.ok(field in request.context);
        if (turn === 0) {
          assert.equal(sessions.length, 1);
          assert.equal(sessions[0].status(), 200);
          sessionId = (await sessions[0].json()).sessionId;
          assert.ok(sessionId);
          actualSessions.push(sessionId);
        }
        assert.equal(request.sessionId, sessionId);
        const assistant = panel.locator(
          `[data-chat-role="arAssistant"][data-chat-turn="${turn + 1}"] [data-chat-markdown="paragraph"]`,
        );
        await assistant.waitFor({ state: "visible", timeout: 10000 });
        await page.waitForFunction(
          (n) =>
            Array.from(
              document.querySelectorAll(
                `[data-chat-role="arAssistant"][data-chat-turn="${n}"] [data-chat-markdown="paragraph"]`,
              ),
            ).some((node) => node.textContent === "M4_HTTP_HELLO_REPLY"),
          turn + 1,
          { timeout: 10000 },
        );
        assert.deepEqual(await assistant.allTextContents(), [
          "M4_HTTP_HELLO_REPLY",
        ]);
        assert.deepEqual(
          await panel
            .locator(
              `[data-chat-role="arUser"][data-chat-turn="${turn + 1}"] [data-chat-markdown="paragraph"]`,
            )
            .allTextContents(),
          [prompts[turn]],
        );
        await page.waitForFunction(
          () =>
            document
              .querySelector("[aria-label='Send agent prompt']")
              ?.getAttribute("aria-disabled") === "false",
          null,
          { timeout: 10000 },
        );
        assert.equal(await input.inputValue(), "");
        assert.equal(await panel.getAttribute("data-chat-local-id"), localId);
        assert.equal(
          await page
            .locator(`[data-ai-assistant-tab="${localId}"]`)
            .getAttribute("aria-selected"),
          "true",
        );
        const identity = ownedPeer();
        if (turn === 0) peer = identity;
        else
          assert.deepEqual(
            identity,
            peer,
            "Same actual peer PID/start time across both turns",
          );
        const mounted = await page.evaluate(() => {
          const vm = globalThis.__isonimEditorVm;
          const text = (value) => {
            if (typeof value === "string" && value.length > 0) return value;
            if (
              !(Array.isArray(value) || value instanceof Uint8Array) ||
              value.length === 0 ||
              !Array.from(value).every(
                (byte) => Number.isInteger(byte) && byte >= 0 && byte <= 255,
              )
            ) {
              throw new Error("Malformed or missing mounted session ID");
            }
            return new TextDecoder("utf-8", { fatal: true }).decode(
              Uint8Array.from(value),
            );
          };
          const localId = text(vm.activeChatId.value);
          const session = vm.chats.value.find(
            (row) => text(row.id) === localId,
          );
          if (!session) throw new Error("Active mounted session is missing");
          return {
            localId,
            backendId: text(session.vm.controlConversationId.value),
          };
        });
        assert.equal(mounted.localId, localId);
        assert.equal(mounted.backendId, sessionId);
      }
      assert.equal(
        sessions.length,
        1,
        "Second turn must reuse the actual backend session",
      );
      const records = peerRecords();
      assertDelivery(records, submitted, sessionId);
      // Observation/oracle controls poison actual receipts, not transport.
      for (const poison of ["context", "session", "prompt", "anchor"]) {
        const changed = structuredClone(records);
        const row = changed.filter((item) => item.source === "fake_acp")[
          poison === "anchor" ? 1 : 0
        ];
        if (poison === "context")
          row.promptText = row.promptText.replace(
            '"Home / Discover"',
            '"Wrong story"',
          );
        if (poison === "session") row.sessionId = "wrong-session";
        if (poison === "prompt")
          row.promptText = "not delivered" + row.promptText;
        if (poison === "anchor") {
          const label = "EDITOR CONTEXT:\n",
            offset = row.promptText.indexOf(label) + label.length;
          const end = row.promptText.indexOf("PROJECT CONTEXT:", offset);
          const wire = JSON.parse(row.promptText.slice(offset, end).trim());
          assert.ok(
            "fromContext" in wire,
            "This real follow-up exercises the anchored envelope",
          );
          wire.fromContext = "0000000000000000000000000000000000000000";
          row.promptText =
            row.promptText.slice(0, offset) +
            JSON.stringify(wire) +
            row.promptText.slice(end);
        }
        assert.notDeepEqual(
          changed,
          records,
          "Control must change actual evidence",
        );
        assert.throws(
          () => assertDelivery(changed, submitted, sessionId),
          undefined,
          `${poison} control must fail the exact delivery oracle`,
        );
      }
      assert.deepEqual(errors, []);
      const log = readFileSync(join(artifacts, "server.log"), "utf8");
      assert.equal(
        log
          .split("\n")
          .filter(
            (line) =>
              line.includes("agent session created") &&
              line.includes("sessionId=" + sessionId),
          ).length,
        1,
      );
      assert.equal(
        log
          .split("\n")
          .filter(
            (line) =>
              line.includes("agent prompt submitted") &&
              line.includes("sessionId=" + sessionId),
          ).length,
        2,
      );
      writeFileSync(
        join(artifacts, "context-proof.json"),
        JSON.stringify(
          {
            sessionId,
            localId,
            peer,
            submitted,
            records,
            errors,
            receiptDirectory: receipts,
          },
          null,
          2,
        ),
      );
    } finally {
      await bounded(context.close(), 30000, "Owned editor context shutdown");
    }
  } finally {
    await stopEditor();
  }
});

for (const newerDraft of [false, true]) {
  test(`EAC-M6 real provider error before output preserves ${newerDraft ? "newer in-flight draft" : "exact submitted draft"}`, async () => {
    assert.ok(
      existsSync(reviewBin) &&
        existsSync(fakeAcpBin) &&
        existsSync(join(editorDir, "editor.js")),
      "Required built runtime",
    );
    try {
      await startEditor({
        FAKE_ACP_STOP_REASON_ERROR_AT: "1",
        FAKE_ACP_SLOW_PROMPT_MS: "1000",
      });
      const { page, context } = await openEditor(true);
      try {
        const input = page.locator("textarea[aria-label='Agent prompt']");
        const send = page.locator("[aria-label='Send agent prompt']");
        await input.waitFor();
        const draft = "  exact rejected draft\nsecond line  ";
        await input.fill(draft);
        const creation = page.waitForResponse(
          (r) => new URL(r.url()).pathname === "/api/agent/sessions",
        );
        const prompt = page.waitForResponse(
          (r) => new URL(r.url()).pathname === "/api/agent/prompts",
        );
        const submitted = page.waitForRequest(
          (r) => new URL(r.url()).pathname === "/api/agent/prompts",
        );
        await send.click();
        const session = await (await creation).json();
        actualSessions.push(session.sessionId);
        const request = (await submitted).postDataJSON();
        assert.equal(request.messages[0].content[0].text, draft.trim());
        assert.equal(request.context.backend, "absAcp");
        for (const field of [
          "accumulatedEdits",
          "sourceMap",
          "renderedComponentTree",
          "availableTailwindClasses",
          "themeTokens",
          "activeThemeContext",
          "platform",
        ])
          assert(field in request.context);
        if (newerDraft) await input.fill("newer unsent draft");
        const response = await prompt;
        assert.equal(response.status(), 200);
        const stream = await bounded(
          page.evaluate(() => window.__chatAdmissionWire),
          30000,
          "Observed real SSE reader EOF",
        );
        assert.equal(
          typeof stream,
          "string",
          "Clone observer must reach real response EOF",
        );
        const frames = stream
          .trim()
          .split(/\r?\n\r?\n/)
          .map((frame) => {
            const lines = frame.split(/\r?\n/);
            return {
              event: lines.find((line) => line.startsWith("event: "))?.slice(7),
              data: JSON.parse(
                lines
                  .filter((line) => line.startsWith("data: "))
                  .map((line) => line.slice(6))
                  .join("\n"),
              ),
            };
          });
        assert.deepEqual(
          frames
            .filter((frame) => frame.event === "end")
            .map((frame) => frame.data),
          [{ stopReason: "error" }],
          "Actual provider error completion must be the exact terminal reason",
        );
        assert.equal(frames.at(-1).event, "end");
        assert.equal(
          frames.filter(
            (frame) =>
              frame.event === "session/update" &&
              ["message_chunk", "tool_call", "tool_call_update"].includes(
                frame.data.kind,
              ),
          ).length,
          0,
          "Provider failed before initialized output/tool acknowledgement",
        );
        assert.doesNotMatch(
          stream,
          /event: admitted/,
          "Failed completion before output cannot admit this turn",
        );
        await page.waitForFunction(
          () =>
            document
              .querySelector("[aria-label='Send agent prompt']")
              ?.getAttribute("aria-disabled") === "false",
        );
        assert.equal(
          await input.inputValue(),
          newerDraft ? "newer unsent draft" : draft,
        );
        assert.equal(
          await page.locator('[data-chat-role="arAssistant"]').count(),
          0,
          "No invented provider response",
        );
      } finally {
        await bounded(
          context.close(),
          30000,
          "Owned failed-turn browser shutdown",
        );
      }
    } finally {
      await stopEditor();
    }
  });
}

test.after(async () => {
  if (browser) {
    await bounded(browser.close(), 30000, "Owned browser shutdown");
    browser = null;
  }
});
