/** Real production composition/native launcher/project files/Nim compiler and
 * preview. No bootstrap, persistence, source adapter, renderer or HTTP endpoint
 * is mocked. The controlled ACP peer permits private daemon startup only; no
 * model prompt runs. The production HMR model handle is observed for integer
 * history and pending state. Compiler expectations use explicit fixture values
 * and an independent browser CSS reference. Core interactions, undo and redo
 * use physical pointer/keyboard events; no model mutation or transport result
 * is fabricated.
 */
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import {
  mkdtempSync,
  cpSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
  copyFileSync,
  openSync,
  existsSync,
  chmodSync,
} from "node:fs";
import path from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { chromium } from "../node_modules/playwright/index.mjs";
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const root = mkdtempSync(
  path.join(process.env.ISONIM_POPUP_ARTIFACTS || tmpdir(), "selection-keys-"),
);
const project = root + "/project",
  pub = root + "/public";
mkdirSync(pub);
cpSync(repo + "/tests/fixtures/editor_inspector_project", project, {
  recursive: true,
});
const keys = [
  "background-color",
  "color",
  "outline-color",
  "border-top-color",
  "border-right-color",
  "border-bottom-color",
  "border-left-color",
];
const originals = [
  "#102030",
  "#203040",
  "#304050",
  "#405060",
  "#506070",
  "#607080",
  "#708090",
];
const replacements = [
  "#112131",
  "#213141",
  "#314151",
  "#415161",
  "#516171",
  "#617181",
  "#718191",
];
let authored = readFileSync(project + "/stories.nim", "utf8");
const declarations = keys.map((key, i) => key + ":" + originals[i]).join(";");
authored = authored.replace(
  "background-color:#112233; color:#FFFFFF;",
  declarations +
    ";border-width:2px;border-style:solid;outline-width:2px;outline-style:solid;",
);
authored = authored.replace(
  "background-color:#334455; color:#FFFFFF;",
  "background-color:#8899aa;color:#99aabb;border-color:#aabbcc;border-width:2px;border-style:solid;outline-color:#bbccdd;",
);
authored = authored.replace(
  "main:",
  'main:\n          button(id = "inline-color", `data-isonim-element-id` = "inline-color", background_color = "#c1d2e3"): text "Inline owner"',
);
writeFileSync(project + "/stories.nim", authored);
writeFileSync(
  project + "/build_catalog.py",
  readFileSync(project + "/build_catalog.py", "utf8").replace(
    '"c", "--hints:off"',
    '"c", "-d:isonimEditor", "--path:" + str(framework.parent / "nim-everywhere/src"), "--hints:off"',
  ),
);
const manifest = JSON.parse(
  readFileSync(project + "/.isonim/source-project.json", "utf8"),
);
manifest.editableStyles[0].properties.push(
  ...keys.filter((key) => !manifest.editableStyles[0].properties.includes(key)),
);
manifest.editableStyles[1].properties.push("border-color", "outline-color");
writeFileSync(
  project + "/.isonim/source-project.json",
  JSON.stringify(manifest, null, 2),
);
const composition = root + "/selection_editor.nim";
writeFileSync(
  composition,
  readFileSync(repo + "/examples/source_project/editor.nim", "utf8").replace(
    "foundationTokens = @[",
    "foundationTokens = @[" +
      keys
        .map(
          (key, i) =>
            'FoundationTokenEntry(key: "color/key' +
            i +
            '", kind: ftkSemanticColor, value: "' +
            replacements[i] +
            '"),',
        )
        .join("\n"),
  ),
);
const env = { ...process.env, ISONIM_SOURCE_FRAMEWORK: repo };
function build(command, args, label) {
  const result = spawnSync(command, args, {
    cwd: repo,
    env,
    encoding: "utf8",
    timeout: 70000,
  });
  writeFileSync(root + "/" + label + ".log", result.stdout + result.stderr);
  assert.equal(result.status, 0, result.stdout + result.stderr);
}
build("python3", [repo + "/tools/build_source_catalog.py", project], "catalog");
build(
  "nim",
  [
    "js",
    "--path:src",
    "--path:.",
    "--path:../nim-everywhere/src",
    "--path:../isonim-render-serve/src",
    "--path:../nim-acp/src",
    "--path:../nim-agent-harbor/src",
    "--path:../nim-agents/src",
    "-o:" + pub + "/editor.js",
    composition,
  ],
  "production-editor",
);
for (const [from, to] of [
  ["src/isonim/editor/index.html", "index.html"],
  ["node_modules/fabric/dist/index.min.js", "fabric.min.js"],
  ["node_modules/paper/dist/paper-core.min.js", "paper-core.min.js"],
  ["node_modules/svgo/dist/svgo.browser.js", "svgo.browser.js"],
])
  copyFileSync(repo + "/" + from, pub + "/" + to);
const config = root + "/agent.toml";
writeFileSync(
  config,
  '[agent]\nbackend="custom"\ncommand="python3"\nargs=' +
    JSON.stringify([repo + "/tests/helpers/editor_control_peer.py"]) +
    "\nprimer_enabled=false\n",
);
const proof = {
  head: spawnSync("git", ["rev-parse", "HEAD"], {
    cwd: repo,
    encoding: "utf8",
  }).stdout.trim(),
  cases: [],
  errors: [],
  agentRequests: [],
  sourceRequests: [],
};
const record = (name) => {
  proof.cases.push(name);
  writeFileSync(root + "/proof.json", JSON.stringify(proof, null, 2));
};
const launch = () =>
  spawn(
    "python3",
    [
      repo + "/tools/editor_server.py",
      "--directory",
      pub,
      "--project-root",
      project,
      "--port",
      "0",
      "--bind",
      "127.0.0.1",
      "--config",
      config,
      "--daemon-binary",
      repo + "/build/bin/isonim-review",
    ],
    { env, stdio: ["ignore", "pipe", openSync(root + "/server.log", "a")] },
  );
let server = launch(),
  browser,
  browserServer,
  origin;
async function startup() {
  return new Promise((resolve, reject) => {
    let text = "";
    server.stdout.on("data", (chunk) => {
      text += chunk;
      const match = text.match(/Editor listening on (http:\/\/[^\s]+)\//);
      if (match) resolve(match[1]);
    });
    server.once("exit", (code) =>
      reject(Error("Private server exited " + code)),
    );
    setTimeout(
      () => reject(Error("Private startup exceeded70s")),
      70000,
    ).unref();
  });
}
async function shutdownOwned() {
  const listing = spawnSync("ps", ["-eo", "pid=,ppid="], { encoding: "utf8" });
  assert.equal(listing.status, 0, listing.stderr);
  const rows = listing.stdout
    .trim()
    .split("\n")
    .map((line) => line.trim().split(/\s+/).map(Number));
  const owned = new Set([server.pid]);
  let added = true;
  while (added) {
    added = false;
    for (const [pid, parent] of rows)
      if (owned.has(parent) && !owned.has(pid)) {
        owned.add(pid);
        added = true;
      }
  }
  const children = [...owned].filter((pid) => pid !== server.pid);
  assert(
    children.length > 0,
    "Actual private native daemon must be owned before shutdown",
  );
  const exited = new Promise((resolve, reject) => {
    server.once("exit", (code, signal) => resolve({ code, signal }));
    setTimeout(
      () => reject(Error("Private shutdown exceeded70s")),
      70000,
    ).unref();
  });
  server.kill("SIGTERM");
  const result = await exited;
  assert.equal(result.code, 143);
  assert.equal(result.signal, null);
  const alive = (pid) => {
    try {
      process.kill(pid, 0);
      return true;
    } catch (error) {
      if (error.code === "ESRCH") return false;
      throw error;
    }
  };
  for (let step = 0; step < 150 && children.some(alive); step++)
    await new Promise((resolve) => setTimeout(resolve, 200));
  assert(
    children.every((pid) => !alive(pid)),
    "Artifact-owned daemon/worker descendants must terminate",
  );
  return { ...result, children };
}
try {
  origin = await startup();
  const chromeEnv = { ...process.env };
  delete chromeEnv.LD_LIBRARY_PATH;
  browserServer = await chromium.launchServer({
    headless: true,
    env: chromeEnv,
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE,
  });
  browser = await chromium.connect(browserServer.wsEndpoint());
  const page = await browser.newPage({
    viewport: { width: 1440, height: 1000 },
  });
  page.setDefaultTimeout(30000);
  function observe(target) {
    target.on("pageerror", (error) => proof.errors.push(error.message));
    target.on("request", (request) => {
      const name = new URL(request.url()).pathname;
      if (name.startsWith("/api/agent/"))
        proof.agentRequests.push(request.url());
      if (name === "/api/editor/source/operation")
        proof.sourceRequests.push(request.postDataJSON());
    });
  }
  observe(page);
  async function select(target = page) {
    await target
      .locator('[data-toolbar-cluster="mode"] [aria-label="Edit"]')
      .click();
    await target.locator('[data-scene-graph-row="action"]').waitFor();
    await target.locator('[data-scene-graph-row="action"]').click();
    const header = target.locator(
      '[data-inspector-section-header="selection-colors"]',
    );
    if ((await header.getAttribute("aria-expanded")) === "false")
      await header.click();
  }
  async function open(target = page) {
    const registration = target.waitForResponse(
      (response) =>
        response.url().endsWith("/api/editor/rpc") &&
        response.request().postDataJSON()?.method === "editor.register",
    );
    const [registrationResponse] = await Promise.all([
      registration,
      target.goto(origin),
    ]);
    const scope = (await registrationResponse.json()).result;
    assert(scope);
    await target.waitForFunction(
      () => globalThis.__isonimEditorVm?.sourceAdapterReady?.value === true,
    );
    await target.waitForResponse(
      (response) =>
        response.url().endsWith("/api/editor/rpc") &&
        response.request().postDataJSON()?.method === "editor.poll" &&
        response
          .request()
          .postDataJSON()
          ?.params?.state?.stories?.some(
            (story) => story.id === "Card / default ready",
          ),
    );
    const result = spawnSync(
      repo + "/build/bin/isonim",
      [
        "editor",
        "open-story",
        "Card / default ready",
        "--command-id",
        "binding-open-" + Date.now(),
        "--wait",
      ],
      {
        cwd: repo,
        env: {
          ...env,
          ISONIM_EDITOR_ENDPOINT: origin,
          ISONIM_EDITOR_WORKSPACE: scope.workspace,
          ISONIM_EDITOR_INSTANCE: scope.instance,
          ISONIM_EDITOR_EPOCH: scope.epoch,
          ISONIM_EDITOR_TOKEN: scope.controlToken,
        },
        encoding: "utf8",
        timeout: 70000,
      },
    );
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.equal(JSON.parse(result.stdout).status, "applied");
    await select(target);
  }
  const sidecar = project + "/.isonim/bindings.json";
  const files = () => ({
      source: readFileSync(project + "/stories.nim", "utf8"),
      catalog: readFileSync(project + "/.isonim/catalog.json", "utf8"),
    }),
    metadata = () => JSON.parse(readFileSync(sidecar, "utf8"));
  const history = () =>
    page.evaluate(() => ({
      undo: globalThis.__isonimEditorVm.inspector.undoStack.value.length,
      redo: globalThis.__isonimEditorVm.inspector.redoStack.value.length,
      pending: window.__isonimEditor.pendingSourceEdits(),
    }));
  async function saved(target = page) {
    await target.waitForFunction(
      () =>
        !globalThis.__isonimEditorVm.sourceBindingMetadataDirty.value &&
        !globalThis.__isonimEditorVm.sourceBindingMetadataSaving &&
        !globalThis.__isonimEditorVm.sourceProjectBuildInFlight,
    );
  }
  const sourceEdits = () =>
    proof.sourceRequests.filter((r) => !r.operationId.includes("-bindings-"))
      .length;
  const original = files();
  await open();
  async function pointerAt(locator) {
    await locator.scrollIntoViewIfNeeded();
    const box = await locator.boundingBox();
    assert(box && box.width > 0 && box.height > 0);
    await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  }
  const row = (key) =>
    page.locator('[data-selection-color-property="' + key + '"]');
  const capture = () =>
    page.evaluate(() => ({
      selected: globalThis.__isonimEditorVm.inspector.selectedElement.value,
      properties:
        globalThis.__isonimEditorVm.inspector.selectedElement.value.properties.map(
          (p) => ({
            ...p,
            name:
              typeof p.name === "string"
                ? p.name
                : String.fromCharCode(...p.name),
            value:
              typeof p.value === "string"
                ? p.value
                : String.fromCharCode(...p.value),
          }),
        ),
      css: [...document.querySelectorAll("iframe")]
        .filter(
          (f) =>
            f.getClientRects().length &&
            f.contentWindow?.__isonimSelectedElement,
        )
        .map((f) => {
          const sheet = f.contentDocument.getElementById(
              "isonim-editor-selection-paint-style",
            )?.sheet,
            disabled = sheet?.disabled;
          if (sheet) sheet.disabled = true;
          try {
            return Object.fromEntries(
              [
                "background-color",
                "color",
                "border-color",
                "outline-color",
                "border-top-color",
                "border-right-color",
                "border-bottom-color",
                "border-left-color",
              ].map((k) => [
                k,
                f.contentWindow
                  .getComputedStyle(f.contentWindow.__isonimSelectedElement)
                  .getPropertyValue(k),
              ]),
            );
          } finally {
            if (sheet) sheet.disabled = disabled;
          }
        }),
      rows: [...document.querySelectorAll("[data-selection-color-row]")].map(
        (n) => ({
          property: n.dataset.selectionColorProperty,
          text: n.textContent,
          disabled: n
            .querySelector("[data-selection-color-bind]")
            ?.getAttribute("aria-disabled"),
        }),
      ),
    }));
  proof.initial = await capture();
  writeFileSync(
    root + "/initial-metadata.json",
    JSON.stringify(proof.initial, null, 2),
  );
  if (process.env.ISONIM_SELECTION_BASELINE === "1") {
    record("baseline actual compiled metadata and mounted rows captured");
    console.log(JSON.stringify(proof.initial.rows));
  } else {
    for (const key of keys) {
      assert(
        proof.initial.properties.some((p) => p.name === key),
        "actual selected property " + key,
      );
      assert.equal(await row(key).count(), 1);
      assert.equal(
        await row(key)
          .locator("[data-selection-color-bind]")
          .getAttribute("aria-disabled"),
        "false",
      );
    }
    record(
      "seven distinct actual stylesheet owners expose writable Selection Colors rows",
    );
    async function keyboardChoose(token) {
      const search = page.locator(
        '[data-variable-picker-open="true"] [data-variable-picker-search]',
      );
      await search.focus();
      await page.keyboard.type(token);
      await page
        .locator(
          '[data-variable-picker-open="true"] [data-variable-picker-row="' +
            token +
            '"]',
        )
        .waitFor();
      for (
        let step = 0;
        step < 12 &&
        (await page.evaluate(() =>
          document.activeElement.getAttribute("data-variable-picker-row"),
        )) !== token;
        step++
      )
        await page.keyboard.press("Tab");
      assert.equal(
        await page.evaluate(() =>
          document.activeElement.getAttribute("data-variable-picker-row"),
        ),
        token,
      );
      await page.keyboard.press("Enter");
    }
    async function cssPreview(key, hex) {
      await page.waitForFunction(
        ([key, hex]) =>
          [...document.querySelectorAll("iframe")].some((f) => {
            if (!f.getClientRects().length) return false;
            const el = f.contentDocument?.querySelector("#action");
            if (!el) return false;
            const sheet = f.contentDocument.getElementById(
              "isonim-editor-selection-paint-style",
            )?.sheet;
            const disabled = sheet?.disabled;
            if (sheet) sheet.disabled = true;
            try {
              const ref = f.contentDocument.createElement("div");
              ref.style.setProperty(key, hex);
              f.contentDocument.body.append(ref);
              const expected = f.contentWindow
                .getComputedStyle(ref)
                .getPropertyValue(key);
              ref.remove();
              return (
                f.contentWindow.getComputedStyle(el).getPropertyValue(key) ===
                expected
              );
            } finally {
              if (sheet) sheet.disabled = disabled;
            }
          }),
        [key, hex],
      );
    }
    let expected = original.source;
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i],
        r = row(key),
        before = files(),
        h = await history(),
        requests = sourceEdits();
      if (i % 2 === 0) await r.locator("[data-selection-color-bind]").click();
      else {
        await r.locator("[data-selection-color-bind]").focus();
        await page.keyboard.press("Enter");
      }
      const option = page.locator(
        '[data-variable-picker-open="true"] [data-variable-picker-row="color/key' +
          i +
          '"]',
      );
      if (i % 2 === 0) await option.click();
      else await keyboardChoose("color/key" + i);
      await r
        .locator('[data-variable-chip-key="color/key' + i + '"]')
        .waitFor();
      await saved();
      assert.deepEqual(files(), before);
      assert.deepEqual(await history(), h);
      assert.equal(sourceEdits(), requests);
      assert(
        metadata().variableBindings.some(
          (b) => b.propertyName === key && b.variableKey === "color/key" + i,
        ),
      );
      record(
        key + " physical picker bind persists sidecar without source/history",
      );
      // Reload the genuine production session and use rehydrated row handlers.
      await open();
      await row(key)
        .locator('[data-variable-chip-key="color/key' + i + '"]')
        .waitFor();
      const unlinkH = await history();
      assert.deepEqual(unlinkH, { undo: 0, redo: 0, pending: 0 });
      const detach = row(key).locator("[data-variable-chip-detach]");
      if (i % 2 === 0) {
        await row(key).locator("[data-variable-chip]").hover();
        await detach.click();
      } else {
        await row(key).locator("[data-variable-chip-chevron]").focus();
        await page.keyboard.press("Shift+Tab");
        assert(await detach.evaluate((n) => n === document.activeElement));
        await page.keyboard.press("Space");
      }
      await row(key)
        .locator("[data-variable-chip]")
        .waitFor({ state: "detached" });
      await saved();
      expected = expected.replace(
        key + ":" + originals[i],
        key + ":" + replacements[i],
      );
      assert.equal(
        files().source,
        expected,
        "exact native source bytes " + key,
      );
      assert.notEqual(files().catalog, before.catalog);
      assert(files().catalog.includes(key + ":" + replacements[i]));
      assert.equal((await history()).undo, unlinkH.undo + 1);
      assert.equal((await history()).redo, 0);
      assert.equal((await history()).pending, 0);
      assert.equal(sourceEdits(), requests + 1);
      assert.equal(metadata().variableBindings.length, 0);
      await cssPreview(key, replacements[i]);
      record(
        key +
          " physical unlink compiles exact literal/catalog/preview with one request/history and no binding",
      );
      // Physical shortcuts dispatch the production undo/redo command after leaving text fields.
      await page.locator('[data-scene-graph-row="action"]').click();
      await page.keyboard.press("ControlOrMeta+z");
      await saved();
      await page.waitForFunction(
        (n) =>
          globalThis.__isonimEditorVm.inspector.undoStack.value.length === n,
        unlinkH.undo,
      );
      assert.equal(files().source, before.source);
      assert.equal((await history()).redo, 1);
      await cssPreview(key, originals[i]);
      await page.keyboard.press("ControlOrMeta+Shift+z");
      await saved();
      await page.waitForFunction(
        (n) =>
          globalThis.__isonimEditorVm.inspector.undoStack.value.length === n,
        unlinkH.undo + 1,
      );
      assert.equal(files().source, expected);
      assert.equal((await history()).redo, 0);
      assert.equal(sourceEdits(), requests + 3);
      await cssPreview(key, replacements[i]);
      record(key + " physical undo redo recompile exact bytes");
      const noOp = {
        files: files(),
        history: await history(),
        compiles: readFileSync(
          project + "/.isonim/compiler-timings.jsonl",
          "utf8",
        ),
      };
      if (i % 2 === 0) {
        await row(key).locator("[data-selection-color-bind]").focus();
        await page.keyboard.press("Space");
        await keyboardChoose("color/key" + i);
      } else {
        await row(key).locator("[data-selection-color-bind]").click();
        await page
          .locator(
            '[data-variable-picker-open="true"] [data-variable-picker-row="color/key' +
              i +
              '"]',
          )
          .click();
      }
      await row(key).locator("[data-variable-chip]").waitFor();
      await saved();
      if (i % 2 === 0) {
        await row(key).locator("[data-variable-chip-chevron]").focus();
        await page.keyboard.press("Shift+Tab");
        await page.keyboard.press("Enter");
      } else {
        await row(key).locator("[data-variable-chip]").hover();
        await row(key).locator("[data-variable-chip-detach]").click();
      }
      await row(key)
        .locator("[data-variable-chip]")
        .waitFor({ state: "detached" });
      await saved();
      assert.deepEqual(files(), noOp.files);
      assert.deepEqual(await history(), noOp.history);
      assert.equal(
        readFileSync(project + "/.isonim/compiler-timings.jsonl", "utf8"),
        noOp.compiles,
      );
      record(key + " equal-literal unlink preserves bytes/compiler/history");
    }
    await open();
    assert.equal(files().source, expected);
    assert.equal(
      await page.locator("[data-selection-color-linked-chip]").count(),
      0,
    );
    record(
      "real reload preserves all seven compiled literals and durable unlink metadata",
    );
    await page.locator('[data-scene-graph-row="secondary-action"]').click();
    const ambiguous = page
      .locator("[data-selection-color-row]")
      .filter({ has: page.locator("[data-selection-color-reason]") });
    await ambiguous.first().waitFor();
    const refused = {
      files: files(),
      history: await history(),
      sidecar: readFileSync(sidecar, "utf8"),
      requests: sourceEdits(),
    };
    proof.ambiguous = await capture();
    assert(
      proof.ambiguous.rows.some(
        (r) => r.property === "" && r.text.includes("multiple properties"),
      ),
    );
    const bind = ambiguous.first().locator("[data-selection-color-bind]");
    assert.equal(await bind.getAttribute("aria-disabled"), "true");
    await pointerAt(bind);
    await bind.focus();
    await page.keyboard.press("Enter");
    assert.equal(
      await page.locator('[data-variable-picker-open="true"]').count(),
      0,
    );
    assert.deepEqual(files(), refused.files);
    assert.deepEqual(await history(), refused.history);
    assert.equal(readFileSync(sidecar, "utf8"), refused.sidecar);
    assert.equal(sourceEdits(), refused.requests);
    assert.deepEqual(await capture(), proof.ambiguous);
    record(
      "actual equal border shorthand/longhands refuse pointer and keyboard without mutation",
    );
    await page.locator('[data-scene-graph-row="inline-color"]').click();
    await row("background-color").waitFor();
    const nativeInline = {
      files: files(),
      history: await history(),
      sidecar: readFileSync(sidecar, "utf8"),
      requests: sourceEdits(),
    };
    proof.nativeInline = await capture();
    const inlineBind = row("background-color").locator(
      "[data-selection-color-bind]",
    );
    assert.equal(await inlineBind.getAttribute("aria-disabled"), "true");
    assert((await row("background-color").innerText()).includes("Read-only"));
    await pointerAt(inlineBind);
    await inlineBind.focus();
    await page.keyboard.press("Enter");
    assert.equal(
      await page.locator('[data-variable-picker-open="true"]').count(),
      0,
    );
    assert.deepEqual(files(), nativeInline.files);
    assert.deepEqual(await history(), nativeInline.history);
    assert.equal(readFileSync(sidecar, "utf8"), nativeInline.sidecar);
    assert.equal(sourceEdits(), nativeInline.requests);
    assert.deepEqual(await capture(), proof.nativeInline);
    record(
      "genuine compiled inline provenance remains readonly and refuses pointer/keyboard binding",
    );
  }
  assert.deepEqual(proof.errors, []);
  assert.deepEqual(proof.agentRequests, []);
  console.log("Selection keys production GUI passed:", proof.cases.length);
} catch (error) {
  proof.failure = error.stack;
  throw error;
} finally {
  if (browser) await browser.close();
  if (browserServer) await browserServer.close();
  try {
    proof.serverExit = await shutdownOwned();
  } finally {
    writeFileSync(root + "/proof.json", JSON.stringify(proof, null, 2));
    console.log("Selection keys artifacts: " + root);
  }
}
