/**
 * Full GUI/native CLI integration over production mounted EditorVM, shared
 * Python launcher, compiled daemon, JSON-RPC registry and command dispatcher.
 * No mocked browser, dispatcher, filesystem or HTTP endpoints. The controlled
 * ACP peer scripts agent text and runs the real native CLI on its actual first
 * prompt to verify launch scope. Official Harbor scenarios remain EAC-M5.
 * Observe registration replies to obtain test-owned scoped credentials, never
 * store those values in screenshots/logs. Test real DOM focus/highlight and
 * visible approval controls, two independent tabs, stale revisions and retries.
 * Narrow transport fault injection holds real browser polls and drops only the
 * decision HTTP response after the real daemon persists it. This proves recovery
 * under a lost response; server dispatch, proxy, VM, filesystem and provider
 * process remain real. The barrier permits deterministic human/closure negatives.
 * Read-only RPC response diagnostics keep only methods, HTTP status, operation
 * IDs/status/error and revision; registration bodies/tokens/transcripts are excluded.
 * They observe failures without holding requests or changing waits/dispatch.
 */
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import {
  mkdtempSync,
  readFileSync,
  existsSync,
  writeFileSync,
  createWriteStream,
  unlinkSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "../node_modules/playwright/index.mjs";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const sourceBoundaryFiles = [
  "tests/helpers/editor_control_workspace.nim",
  "build/editor-control/editor.js",
  "build/editor-control/index.html",
].map((name) => [path.join(repo, name), readFileSync(path.join(repo, name))]);
const artifacts = mkdtempSync(path.join(tmpdir(), "isonim-control-gui-"));
const config = path.join(artifacts, "review.toml");
const providerArgs = [
  path.join(repo, "tests/helpers/editor_control_peer.py"),
  "argument with spaces",
  "",
  "punctuation: quote $()",
];
writeFileSync(
  config,
  '[agent]\nbackend = "custom"\ncommand = "python3"\nargs = ' +
    JSON.stringify(providerArgs) +
    "\nprimer_enabled = false\n",
);
const serverLog = createWriteStream(path.join(artifacts, "server.log"));
const server = spawn(
  process.env.PYTHON ?? "python3",
  [
    path.join(repo, "tools/editor_server.py"),
    "--directory",
    path.join(repo, "build/editor-control"),
    "--project-root",
    artifacts,
    "--port",
    "0",
    "--bind",
    "127.0.0.1",
    "--config",
    config,
    "--daemon-binary",
    path.join(repo, "build/bin/isonim-review"),
  ],
  {
    env: { ...process.env, CONTROL_PROBE_DIR: artifacts },
    stdio: ["ignore", "pipe", "pipe"],
  },
);
server.stderr.pipe(serverLog);
let origin;
const startup = new Promise((resolve, reject) => {
  let text = "";
  server.stdout.on("data", (chunk) => {
    text += chunk;
    const match = text.match(/Editor listening on (http:\/\/[^\s]+)\//);
    if (match) {
      origin = match[1];
      resolve();
    }
  });
  server.once("exit", (code) =>
    reject(new Error(`Launcher exited ${code}; artifacts ${artifacts}`)),
  );
  setTimeout(
    () => reject(new Error(`Launcher startup timeout; ${artifacts}`)),
    30000,
  ).unref();
});
let browser;
const controlDiagnostics = [];
const observedPageErrors = [];
const pollActivity = new WeakMap();
function cli(scope, args, expected = 0) {
  const result = spawnSync(
    path.join(repo, "build/bin/isonim"),
    ["editor", ...args],
    {
      env: {
        ...process.env,
        ISONIM_EDITOR_ENDPOINT: origin,
        ISONIM_EDITOR_WORKSPACE: scope.workspace,
        ISONIM_EDITOR_INSTANCE: scope.instance,
        ISONIM_EDITOR_EPOCH: scope.epoch,
        ISONIM_EDITOR_TOKEN: scope.controlToken,
      },
      encoding: "utf8",
      timeout: 10000,
    },
  );
  assert.equal(
    result.status,
    expected,
    `CLI status ${result.status} expected ${expected}: ${result.stdout} ${result.stderr}`,
  );
  return JSON.parse(result.stdout);
}
async function registered(page) {
  const polls = new Map();
  pollActivity.set(page, polls);
  page.on("request", (request) => {
    if (
      !request.url().endsWith("/api/editor/rpc") ||
      request.postDataJSON()?.method !== "editor.poll"
    )
      return;
    let complete;
    const finished = new Promise((resolve) => {
      complete = resolve;
    });
    polls.set(request, { finished, complete });
  });
  const finished = (request) => {
    const pending = polls.get(request);
    if (pending) {
      pending.complete();
      polls.delete(request);
    }
  };
  page.on("requestfinished", finished);
  page.on("requestfailed", finished);
  const reply = page.waitForResponse(
    (r) =>
      r.url().endsWith("/api/editor/rpc") &&
      r.request().postDataJSON()?.method === "editor.register",
  );
  const [registrationResponse] = await Promise.all([reply, page.goto(origin)]);
  const data = await registrationResponse.json();
  assert(data.result, "Browser registration failed");
  const scope = data.result;
  await page.waitForSelector('[data-editor-control-focus="composer"]');
  for (let index = 0; index < 50; index++) {
    const state = cli(scope, ["state"]);
    if (state.instance === scope.instance) return scope;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("Instance did not publish production state");
}
function request(scope, method, params, token = scope.controlToken) {
  return fetch(origin + "/api/editor/rpc", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-IsoNim-Control": token },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method,
      params: {
        workspace: scope.workspace,
        instance: scope.instance,
        epoch: scope.epoch,
        ...params,
      },
    }),
  }).then((r) => r.json());
}
async function settled(scope) {
  // View changes can reload preview documents and asynchronously publish their
  // actual layer/focus state. Observe three production poll intervals before
  // deliberately issuing the next command; never retry a failed mutation.
  let previous = -1,
    stable = 0;
  for (let attempt = 0; attempt < 30; attempt++) {
    const state = cli(scope, ["state"]);
    stable = state.revision === previous ? stable + 1 : 0;
    if (stable >= 3) return state;
    previous = state.revision;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error("Production view revision did not settle");
}
async function holdInitialDelivery(page) {
  let release;
  const barrier = new Promise((resolve) => {
    release = resolve;
  });
  const held = new Set();
  const handler = async (route) => {
    if (route.request().postDataJSON()?.method === "editor.poll") {
      held.add(route.request());
      await barrier;
    }
    await route.continue();
  };
  await page.route("**/api/editor/rpc", handler);
  await Promise.all(
    [...pollActivity.get(page)]
      .filter(([request]) => !held.has(request))
      .map(([, pending]) => pending.finished),
  );
  await page.evaluate(() => Promise.resolve());
  return async () => {
    release();
    await page.unrouteAll({ behavior: "wait" });
  };
}
async function loseDecisionResponse(
  page,
  operationId,
  approve,
  beforeRecovery = async () => {},
) {
  let releasePoll, decisionResolved, decisionRejected;
  const pollBarrier = new Promise((resolve) => {
    releasePoll = resolve;
  });
  const decisionFinished = new Promise((resolve, reject) => {
    decisionResolved = resolve;
    decisionRejected = reject;
  });
  const faultErrors = [];
  const heldPolls = new Set();
  let decisionTimer;
  let dropped = false;
  let faultStarted = false;
  let phase = "installing";
  const handler = async (route) => {
    try {
      const body = route.request().postDataJSON();
      if (body.method === "editor.poll") {
        heldPolls.add(route.request());
        await pollBarrier;
      }
      if (
        body.method === "editor.approve" &&
        body.params.operationId === operationId &&
        !faultStarted
      ) {
        faultStarted = true;
        phase = "fetching real decision";
        const response = await route.fetch();
        const reply = await response.json();
        assert.equal(
          reply.result.status,
          approve ? "approved" : "rejected",
          "Real daemon persisted the decision",
        );
        assert.equal(reply.result.approvalDecision, approve);
        phase = "running recovery boundary";
        await beforeRecovery();
        await route.abort("connectionfailed");
        dropped = true;
        phase = "response dropped";
        releasePoll();
        decisionResolved();
      } else await route.continue();
    } catch (error) {
      faultErrors.push(error);
      releasePoll();
      decisionRejected(error);
    }
  };
  await page.route("**/api/editor/rpc", handler);
  try {
    decisionTimer = setTimeout(
      () =>
        decisionRejected(
          new Error(
            `Decision ${operationId} did not reach its barrier (${phase})`,
          ),
        ),
      10000,
    );
    const trigger = (async () => {
      phase = "draining earlier polls";
      // Drain requests started before interception; their late responses must
      // not race the deliberate human/closure recovery barrier.
      await Promise.all(
        [...pollActivity.get(page)]
          .filter(([request]) => !heldPolls.has(request))
          .map(([, pending]) => pending.finished),
      );
      await page.evaluate(() => Promise.resolve());
      phase = "clicking decision";
      await page
        .locator(
          `[data-editor-control-${approve ? "approve" : "reject"}="${operationId}"]`,
        )
        .click({ timeout: 3000 });
    })();
    await Promise.all([trigger, decisionFinished]);
    assert(
      dropped,
      "Decision response was dropped after actual native daemon processing",
    );
  } finally {
    clearTimeout(decisionTimer);
    releasePoll();
    // Native CLI waits run synchronously in this harness. Remove interception
    // first so Chromium can deliver subsequent polls independently of Node.
    await page.unrouteAll({ behavior: "wait" });
    assert.deepEqual(
      faultErrors,
      [],
      "All fault-injection handlers must finish without ignored background errors",
    );
  }
}
try {
  await startup;
  const browserEnv = { ...process.env };
  delete browserEnv.LD_LIBRARY_PATH;
  browser = await chromium.launch({
    headless: true,
    env: browserEnv,
    executablePath:
      process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ??
      "/nix/store/1id5xlj91r8d5cj5ks4a5byrxdvr4b50-chromium-143.0.7499.192/bin/chromium",
  });
  const first = await browser.newPage({
    viewport: { width: 1500, height: 1000 },
  });
  const second = await browser.newPage({
    viewport: { width: 1500, height: 1000 },
  });
  const pageErrors = [];
  first.on("pageerror", (error) => {
    pageErrors.push(error.message);
    console.error("Browser runtime:", error.message);
  });
  second.on("pageerror", (error) => {
    pageErrors.push(error.message);
    console.error("Browser runtime:", error.message);
  });
  // Read-only failure diagnostics; retain no request headers or credentials.
  for (const page of [first, second]) {
    page.on("pageerror", (error) => observedPageErrors.push(error.message));
    page.on("response", async (response) => {
      if (!response.url().endsWith("/api/editor/rpc")) return;
      const method = response.request().postDataJSON()?.method;
      if (method === "editor.register") return;
      try {
        const body = await response.json(),
          result = body.result;
        controlDiagnostics.push({
          method,
          httpStatus: response.status(),
          error: body.error?.message,
          revision: result?.revision,
          commands: Array.isArray(result?.commands)
            ? result.commands.map((row) => ({
                operationId: row.operationId,
                status: row.status,
                error: row.error,
              }))
            : undefined,
        });
      } catch (error) {
        controlDiagnostics.push({
          method,
          httpStatus: response.status(),
          responseError: error.message,
        });
      }
    });
  }
  const a = await registered(first),
    b = await registered(second);
  assert.notEqual(a.instance, b.instance);
  const baselineB = cli(b, ["state"]);
  const state = cli(a, ["state"]);
  assert(!state.capabilities.includes("create-story"));
  assert(state.capabilities.includes("focus"));
  assert(state.capabilities.includes("highlight"));
  assert.equal(cli(a, ["instances"]).length, 1);
  const pageStory = state.stories.find((story) => story.kind === "skPage");
  assert(pageStory, "Real workspace needs page story");
  const opened = cli(a, [
    "open-story",
    pageStory.id,
    "--command-id",
    "open1",
    "--wait",
  ]);
  assert.equal(opened.status, "applied");
  assert.equal(cli(a, ["state"]).storyId, pageStory.id);
  assert.equal(
    cli(b, ["state"]).storyId,
    baselineB.storyId,
    "Another tab must remain unchanged",
  );
  const preview = first
    .locator(".editor-preview iframe")
    .filter({ visible: true })
    .first();
  await preview.waitFor({ state: "visible" });
  const frame = await preview.contentFrame();
  await frame.locator("body").waitFor();
  assert(
    (await frame.locator("body").innerText()).trim().length > 0,
    "Actual preview content is required",
  );
  await settled(a);
  const capabilities = cli(a, ["capabilities"]);
  assert.deepEqual(
    capabilities.filter((name) => name.startsWith("capture-")),
    ["capture-preview"],
    "Discovery must advertise a command executable by the actual CLI and RPC",
  );
  const captureCommand = capabilities.find((name) =>
    name.startsWith("capture-"),
  );
  async function verifyMountedCapture(operation) {
    assert.equal(operation.status, "applied");
    const capture = operation.result;
    assert.equal(capture.ready, true);
    assert.equal(capture.format, "text/html");
    assert.equal(capture.storyId, pageStory.id);
    assert.equal(
      capture.documentHtml,
      "<!doctype html>\n" +
        (await frame.locator("html").evaluate((node) => node.outerHTML)),
      "Capture returns the actual mounted preview document",
    );
    const mounted = await preview.evaluate((node) => ({
      width: node.clientWidth,
      height: node.clientHeight,
    }));
    assert.deepEqual({ width: capture.width, height: capture.height }, mounted);
    const identity = await frame
      .locator('meta[name="isonim-rendered-generation"]')
      .getAttribute("content");
    assert.equal(capture.previewGeneration, Number(identity));
    assert(capture.width > 0 && capture.height > 0);
  }
  await verifyMountedCapture(
    cli(a, [captureCommand, "--command-id", "discoveredCaptureCli", "--wait"]),
  );
  const captureState = await settled(a);
  const rpcCapture = await request(a, "editor.command", {
    command: captureCommand,
    commandId: "discoveredCaptureRpc",
    expectedRevision: captureState.revision,
  });
  assert(
    rpcCapture.result,
    "Actual RPC accepts the advertised capture operation",
  );
  await verifyMountedCapture(cli(a, ["wait", rpcCapture.result.operationId]));
  const composer = first.locator('[data-editor-control-focus="composer"]');
  const focus = cli(a, [
    "focus",
    "composer",
    "--command-id",
    "focus1",
    "--wait",
  ]);
  assert.equal(focus.status, "applied");
  assert(
    await composer.evaluate(
      (node) => node.ownerDocument.activeElement === node,
    ),
    "Actual composer focus",
  );
  const retried = cli(a, [
    "focus",
    "composer",
    "--command-id",
    "focus1",
    "--expected-revision",
    String(focus.request.expectedRevision),
    "--wait",
  ]);
  assert.equal(
    retried.revision,
    focus.revision,
    "Lost ACK retry must not apply again",
  );
  assert.equal(
    cli(a, ["viewport", "tablet", "--command-id", "focus1"], 6).error,
    "command_id_collision",
  );
  await settled(a);
  // Select real preview content via its existing production bridge to populate
  // stable element IDs; subsequent selection/highlighting goes through real CLI.
  cli(a, ["command", "comment", "--command-id", "comment1", "--wait"]);
  const target = frame.locator("[data-isonim-element-id]").first();
  await target.waitFor({ state: "visible" });
  await target.click({ position: { x: 8, y: 8 } });
  await new Promise((resolve) => setTimeout(resolve, 400));
  const elements = cli(a, ["elements"]);
  assert(elements.length > 0, "Production iframe bridge must publish layers");
  const id = await target.getAttribute("data-isonim-element-id");
  assert(
    elements.some((element) => element.id === id),
    "CLI must see actual DOM stable identity",
  );
  await settled(a);
  cli(a, ["focus", "composer", "--command-id", "focus2", "--wait"]);
  const select = cli(a, [
    "select",
    id,
    "--highlight",
    "--command-id",
    "select1",
    "--wait",
  ]);
  assert.equal(select.status, "applied");
  assert.equal(cli(a, ["state"]).selection, id);
  assert(
    await composer.evaluate(
      (node) => node.ownerDocument.activeElement === node,
    ),
    "Default select preserves focus",
  );
  assert.equal(
    await target.getAttribute("data-editor-agent-highlight"),
    "true",
  );
  const selectionFocus = cli(a, [
    "select",
    id,
    "--focus",
    "--highlight",
    "--command-id",
    "selectfocus",
    "--wait",
  ]);
  assert.equal(selectionFocus.status, "applied");
  assert(
    await target.evaluate((node) => node.ownerDocument.activeElement === node),
    "Explicit select focus applies in actual preview",
  );
  const preference = first.locator("[data-editor-control-approval]");
  await preference.check();
  await settled(a);
  await frame.locator("#first").focus();
  await settled(a);
  const beforeApproval = cli(a, ["state"]);
  assert(
    await frame
      .locator("#first")
      .evaluate((node) => node.ownerDocument.activeElement === node),
  );
  const queued = cli(a, ["viewport", "phone", "--command-id", "approve1"]);
  assert.equal(queued.status, "queued");
  await first
    .locator('[data-editor-control-approve="approve1"]')
    .waitFor({ state: "visible" });
  assert.equal(
    cli(a, ["state"]).viewport,
    beforeApproval.viewport,
    "Pending request cannot mutate",
  );
  assert.equal(
    cli(a, ["wait", "approve1", "--timeout-ms", "120"], 5).operation.status,
    "pending",
  );
  assert(
    (
      await request(a, "editor.approve", {
        operationId: "approve1",
        approve: true,
      })
    ).error,
    "Agent cannot self-approve",
  );
  cli(a, ["viewport", "tablet", "--command-id", "otherPending"]);
  await first
    .locator('[data-editor-control-reject="otherPending"]')
    .waitFor({ state: "visible" });
  await loseDecisionResponse(first, "approve1", true, async () => {
    // The user changes their decision while the first response is lost. The
    // real conflicting RPC must not revoke this or unrelated pending proposals.
    await first.locator('[data-editor-control-reject="approve1"]').click();
  });
  const recovered = cli(a, ["wait", "approve1"]);
  assert.equal(recovered.status, "applied");
  assert.deepEqual(
    cli(a, [
      "viewport",
      "phone",
      "--command-id",
      "approve1",
      "--expected-revision",
      String(queued.request.expectedRevision),
      "--wait",
    ]),
    recovered,
    "Recovered approval applies once and retries preserve the final result",
  );
  assert.equal(cli(a, ["state"]).viewport, "phone");
  await settled(a);
  assert.equal(
    cli(a, ["wait", "otherPending", "--timeout-ms", "120"], 5).operation.status,
    "pending",
  );
  await first.locator('[data-editor-control-reject="otherPending"]').click();
  assert.equal(cli(a, ["wait", "otherPending"], 4).error, "denied");
  cli(a, ["viewport", "tablet", "--command-id", "reject1"]);
  await first
    .locator('[data-editor-control-reject="reject1"]')
    .waitFor({ state: "visible" });
  const rejectionState = cli(a, ["state"]);
  await loseDecisionResponse(first, "reject1", false, async () => {
    await preference.uncheck();
  });
  assert.equal(cli(a, ["wait", "reject1"], 4).status, "rejected");
  await first
    .locator('[data-editor-control-reject="reject1"]')
    .waitFor({ state: "hidden" });
  assert.equal(
    cli(a, ["state"]).viewport,
    rejectionState.viewport,
    "Denied recovery cannot execute after policy becomes automatic",
  );
  await preference.check();
  await settled(a);
  // Pending operation must revalidate a human-initiated real state change.
  cli(a, ["viewport", "desktop", "--command-id", "stale1"]);
  await first
    .locator('[data-editor-control-approve="stale1"]')
    .waitFor({ state: "visible" });
  await loseDecisionResponse(first, "stale1", true, async () => {
    await composer.click();
    await composer.fill("human draft retained");
  });
  assert.equal(cli(a, ["wait", "stale1"], 6).error, "revision_conflict");
  assert.equal(await composer.inputValue(), "human draft retained");
  // Focus moving between controls in an already focused iframe does not
  // bubble through the editor root. Its real document listener must invalidate
  // the queued revision too.
  await frame.locator("#first").focus();
  await settled(a);
  const beforeInnerFocus = cli(a, ["state"]);
  cli(a, ["viewport", "desktop", "--command-id", "iframe-stale"]);
  await first
    .locator('[data-editor-control-approve="iframe-stale"]')
    .waitFor({ state: "visible" });
  await frame.locator("#second").focus();
  await new Promise((resolve) => setTimeout(resolve, 300));
  assert.notEqual(cli(a, ["state"]).revision, beforeInnerFocus.revision);
  await first.locator('[data-editor-control-approve="iframe-stale"]').click();
  assert.equal(cli(a, ["wait", "iframe-stale"], 6).error, "revision_conflict");
  assert.equal(cli(a, ["state"]).viewport, beforeInnerFocus.viewport);
  const cross = await request(
    b,
    "editor.command",
    {
      command: "viewport",
      viewport: "desktop",
      commandId: "cross",
      expectedRevision: 0,
    },
    a.controlToken,
  );
  assert.equal(cross.error.message, "credential_scope_mismatch");
  // Real malformed HTTP envelope cannot kill the daemon or affect another tab.
  for (const raw of ["null", "[]", '{"jsonrpc":"2.0","id":1}']) {
    const result = await fetch(origin + "/api/editor/rpc", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: raw,
    }).then((r) => r.json());
    assert.equal(result.error.code, -32600);
  }
  assert.equal(cli(b, ["state"]).instance, b.instance);
  // Actual mounted chat -> createSession -> provider -> native CLI environment.
  for (const [page, scope] of [
    [first, a],
    [second, b],
  ]) {
    let releaseInitial = null,
      beforeInitial;
    const gatePath = path.join(artifacts, "queue-gate-" + scope.instance);
    if (page === second) writeFileSync(gatePath, "hold");
    const input = page.locator('[data-editor-control-focus="composer"]');
    await input.fill("verify scoped control environment");
    await page
      .getByRole("button", { name: "Send agent prompt", exact: true })
      .click();
    if (page === second) {
      const waitingPath = path.join(artifacts, "waiting-" + scope.instance);
      for (
        let attempt = 0;
        attempt < 100 && !existsSync(waitingPath);
        attempt++
      )
        await new Promise((resolve) => setTimeout(resolve, 50));
      assert(
        existsSync(waitingPath),
        "Real provider must reach scripted queue barrier",
      );
      beforeInitial = await settled(scope);
      releaseInitial = await holdInitialDelivery(page);
      unlinkSync(gatePath);
    }
    const probePath = path.join(artifacts, "probe-" + scope.instance + ".json");
    for (let attempt = 0; attempt < 100 && !existsSync(probePath); attempt++)
      await new Promise((resolve) => setTimeout(resolve, 100));
    assert(existsSync(probePath), "Actual provider must execute scoped CLI");
    const probeResult = JSON.parse(readFileSync(probePath, "utf8"));
    assert.equal(probeResult.cliStatus, 0);
    assert.equal(probeResult.state.workspace, scope.workspace);
    assert.equal(probeResult.state.instance, scope.instance);
    assert.equal(probeResult.bootstrapPresent, false);
    assert.equal(probeResult.tokenPresent, true);
    assert.deepEqual(probeResult.args, providerArgs.slice(1));
    assert.equal(probeResult.proposalStatus, 0);
    if (page === first) {
      const approval = page.locator(
        `[data-editor-control-approve="${probeResult.operationId}"]`,
      );
      await approval.waitFor({ state: "visible" });
      assert(
        (
          await page.locator("[data-editor-control-history]").innerText()
        ).includes("This conversation:"),
      );
      const originTab = await page
        .locator('[data-ai-assistant-tab][aria-selected="true"]')
        .getAttribute("data-ai-assistant-tab");
      await page.locator("[data-ai-assistant-new-chat]").click();
      assert.equal(
        await approval.count(),
        0,
        "Chat A approval must not appear as a proposal from chat B",
      );
      await page.locator(`[data-ai-assistant-tab="${originTab}"]`).click();
      await approval.waitFor({ state: "visible" });
    }
    if (page === first) {
      const beforeClosedRecovery = cli(scope, ["state"]);
      await loseDecisionResponse(
        page,
        probeResult.operationId,
        true,
        async () => {
          await page.locator("[data-agent-close]").click();
          await page
            .locator(
              `[data-editor-control-approve="${probeResult.operationId}"]`,
            )
            .waitFor({ state: "hidden" });
        },
      );
      await settled(scope);
      assert.equal(
        cli(scope, ["state"]).viewport,
        beforeClosedRecovery.viewport,
        "Revoked approved delivery cannot mutate",
      );
      const closed = await request(
        scope,
        "editor.approve",
        { operationId: probeResult.operationId, approve: true },
        scope.browserToken,
      );
      assert.equal(closed.result.status, "rejected");
      assert.equal(closed.result.error, "conversation_closed");
      const drained = await request(
        scope,
        "editor.poll",
        {},
        scope.browserToken,
      );
      assert(
        !drained.result.commands.some(
          (operation) => operation.operationId === probeResult.operationId,
        ),
        "Acknowledged close notification must stop redelivering",
      );
    } else {
      let terminal;
      try {
        const queued = (
          await request(scope, "editor.poll", {}, scope.browserToken)
        ).result.commands.find(
          (operation) => operation.operationId === probeResult.operationId,
        );
        assert.equal(
          queued.status,
          "queued",
          "Actual provider CLI command must be revoked before any browser delivery",
        );
        assert.equal(
          queued.request.expectedRevision,
          beforeInitial.revision,
          "Queued command has the settled real VM revision; denial alone prevents execution",
        );
        // A DOM click dispatches the asynchronous close request. Observe its
        // actual successful completion before inspecting persisted revocation;
        // initial command delivery remains held throughout this barrier.
        const closeReply = page.waitForResponse(
          (response) =>
            response.url().endsWith("/api/agent/close") &&
            response.request().method() === "POST",
        );
        const [closed] = await Promise.all([
          closeReply,
          page.locator("[data-agent-close]").click(),
        ]);
        assert.equal(closed.status(), 200);
        assert.deepEqual(await closed.json(), { closed: true });
        terminal = (
          await request(scope, "editor.poll", {}, scope.browserToken)
        ).result.commands.find(
          (operation) => operation.operationId === probeResult.operationId,
        );
        assert.equal(terminal.error, "conversation_closed");
      } finally {
        await releaseInitial();
      }
      await settled(scope);
      const afterInitial = cli(scope, ["state"]);
      assert.equal(
        afterInitial.revision,
        beforeInitial.revision,
        "Revocation alone prevents execution; actual target revision remains valid",
      );
      assert.equal(
        afterInitial.viewport,
        beforeInitial.viewport,
        "Unseen revoked command cannot execute under automatic policy",
      );
      for (const [file, before] of sourceBoundaryFiles)
        assert.deepEqual(
          readFileSync(file),
          before,
          "Revoked delivery cannot change project source or compiled output",
        );
      const drained = await request(
        scope,
        "editor.poll",
        {},
        scope.browserToken,
      );
      assert(
        !drained.result.commands.some(
          (operation) => operation.operationId === probeResult.operationId,
        ),
      );
      const repeat = await request(
        scope,
        "editor.ack",
        { operation: terminal },
        scope.browserToken,
      );
      assert.equal(repeat.result.error, "conversation_closed");
      const contradictory = { ...terminal, status: "applied" };
      delete contradictory.error;
      assert.equal(
        (
          await request(
            scope,
            "editor.ack",
            { operation: contradictory },
            scope.browserToken,
          )
        ).result.error,
        "conversation_closed",
      );
      assert(
        !(
          await request(scope, "editor.poll", {}, scope.browserToken)
        ).result.commands.some(
          (operation) => operation.operationId === probeResult.operationId,
        ),
      );
    }
    await page
      .locator(`[data-editor-control-approve="${probeResult.operationId}"]`)
      .waitFor({ state: "hidden" });
  }
  await first.close();
  await new Promise((resolve) => setTimeout(resolve, 500));
  assert.equal(cli(a, ["state"], 3).error, "disconnected_instance");
  assert.equal(cli(b, ["state"]).instance, b.instance);
  // Host unmount while the tab remains open must revoke the instance too;
  // detached VMs cannot continue polling/applying or re-register themselves.
  await second
    .locator("[data-shell-row]")
    .evaluate((row) => row.parentElement.remove());
  await new Promise((resolve) => setTimeout(resolve, 1000));
  assert.equal(cli(b, ["state"], 3).error, "disconnected_instance");
  await new Promise((resolve) => setTimeout(resolve, 500));
  assert.equal(
    cli(b, ["viewport", "phone", "--command-id", "detached"], 3).error,
    "disconnected_instance",
  );
  assert.deepEqual(pageErrors, []);
  writeFileSync(
    path.join(artifacts, "results.json"),
    JSON.stringify(
      {
        status: "passed",
        cases: 25,
        browserVersion: browser.version(),
        instanceCount: 2,
        credentialsRecorded: false,
      },
      null,
      2,
    ),
  );
  console.log(`Editor GUI/CLI acceptance passed; artifacts ${artifacts}`);
} catch (error) {
  writeFileSync(
    path.join(artifacts, "failure-diagnostics.json"),
    JSON.stringify(
      {
        failure: error.message,
        pageErrors: observedPageErrors,
        responses: controlDiagnostics,
      },
      null,
      2,
    ),
  );
  console.error(
    `Failure diagnostics ${path.join(artifacts, "failure-diagnostics.json")}`,
  );
  throw error;
} finally {
  if (browser) await browser.close();
  server.kill("SIGTERM");
  await new Promise((resolve) => {
    if (server.exitCode !== null) resolve();
    else server.once("exit", resolve);
  });
  serverLog.end();
}
