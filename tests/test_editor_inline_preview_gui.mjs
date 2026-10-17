/** Genuine editor-enabled Nim/SSR fixture and mounted catalog-only editor.
 * Files/compiler/HTTP/browser are real. The controlled decision peer only starts
 * the daemon: this suite asserts zero agent/source-operation calls and unchanged
 * source/catalog bytes. Direct runtime probes are supplementary declaration
 * ownership assertions, separate from physical State/Layout workflow proof.
 */
import { spawn, spawnSync } from "node:child_process";
import {
  mkdtempSync,
  cpSync,
  readFileSync,
  writeFileSync,
  mkdirSync,
  openSync,
  copyFileSync,
} from "node:fs";
import { chromium } from "../node_modules/playwright/index.mjs";
import assert from "node:assert/strict";
import path from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const root = mkdtempSync(
  path.join(process.env.ISONIM_POPUP_ARTIFACTS || tmpdir(), "catalog-inline-"),
);
const project = root + "/project",
  pub = root + "/public";
cpSync(repo + "/tests/fixtures/editor_inspector_project", project, {
  recursive: true,
});
mkdirSync(pub);
// Admit only exact literal owners in a private actual project. The manifest is
// this fixture's ownership boundary, not the product-wide property inventory.
const declarations =
  "font-size:16px; position:relative; left:10px; top:12px; display:flex; gap:6px; mix-blend-mode:normal;";
const setupSource = readFileSync(project + "/stories.nim", "utf8");
writeFileSync(
  project + "/stories.nim",
  setupSource
    .replace(
      "#action { width:120px;",
      "html, body, main { font-size:16px; font-family:monospace; }\n#schema-panel { width:24px; text-align:left; }\n#state-panel { width:24px; }\n#important-panel { width:24px !important; }\n:root { --state-width:44px !important; }\n.stylesheet-owned { width:24px !important; }\n#blocked-panel, #blocked-sibling { width:24px !important; }\n#blocked-panel { width:30px; }\n@layer admission { #layer-panel { width:24px !important; } }\n#layer-panel { width:30px; }\n@media (min-width:800px) { #responsive-panel { width:24px !important; } }\n@media (min-width:99999px) { #inactive-panel { width:24px !important; } }\n@supports (display: nonexistent-value) { #inactive-panel { width:26px !important; } }\n#action { " +
        declarations +
        " width:120px;",
    )
    .replace(
      '            button(id = "secondary-action",',
      '            p(id = "schema-panel", `data-isonim-element-id` = "schema-panel", `data-isonim-schema-key` = "component.card"): text "Actual schema node"\n            p(id = "state-panel", `data-isonim-element-id` = "state-panel", style = "width:44px"): text "Actual inline state node"\n            p(id = "state-sibling", style = "width:44px"): text "Inline sibling"\n            p(id = "important-panel", `data-isonim-element-id` = "important-panel", style = "width:44px !important"): text "Important inline"\n            p(id = "token-panel", style = "width:var(--state-width)"): text "Token inline"\n            p(id = "token-sibling", style = "width:var(--state-width)"): text "Token sibling"\n            p(id = "stylesheet-panel", class = "stylesheet-owned"): text "Stylesheet owner"\n            p(id = "stylesheet-sibling", class = "stylesheet-owned"): text "Stylesheet sibling"\n            p(id = "blocked-panel", `data-isonim-element-id` = "blocked-panel", style = "width:44px"): text "Normal inline blocked by shared important"\n            p(id = "blocked-sibling", style = "width:44px"): text "Shared important sibling"\n            p(id = "inactive-panel", `data-isonim-element-id` = "inactive-panel", style = "width:44px"): text "Inactive important rules"\n            p(id = "layer-panel", `data-isonim-element-id` = "layer-panel", style = "width:44px"): text "Layer important owner"\n            p(id = "responsive-panel", `data-isonim-element-id` = "responsive-panel", style = "width:44px"): text "Responsive important owner"\n            button(id = "secondary-action",',
    ),
);
const setupManifest = JSON.parse(
  readFileSync(project + "/.isonim/source-project.json", "utf8"),
);
setupManifest.editableStyles
  .find((row) => row.elementId === "action")
  .properties.push("left", "top", "display", "gap", "mix-blend-mode");
for (const id of ["schema-panel", "state-panel"])
  setupManifest.editableStyles.push({
    key: "style." + id,
    elementId: id,
    storyId: "Card / default ready",
    file: "stories.nim",
    const: "cardStyles",
    selector: "#" + id,
    properties: id === "schema-panel" ? ["width", "text-align"] : ["width"],
  });
writeFileSync(
  project + "/.isonim/source-project.json",
  JSON.stringify(setupManifest),
);
// Compile genuine DSL editor provenance; never inject manufactured browser metadata.
const producer = readFileSync(project + "/build_catalog.py", "utf8");
assert(producer.includes('"nim", "c",'));
writeFileSync(
  project + "/build_catalog.py",
  producer
    .replace('"nim", "c",', '"nim", "c", "-d:isonimEditor",')
    .replace(
      '"--path:" + str(framework / "src"),',
      '"--path:" + str(framework / "src"), "--path:" + str(framework.parent / "nim-everywhere" / "src"),',
    ),
);

for (const [from, to] of [
  ["src/isonim/editor/index.html", "index.html"],
  ["build/editor-popup/editor.js", "editor.js"],
  ["node_modules/fabric/dist/index.min.js", "fabric.min.js"],
  ["node_modules/paper/dist/paper-core.min.js", "paper-core.min.js"],
  ["node_modules/svgo/dist/svgo.browser.js", "svgo.browser.js"],
])
  copyFileSync(repo + "/" + from, pub + "/" + to);
const build = spawnSync(
  "python3",
  [repo + "/tools/build_source_catalog.py", project],
  {
    env: { ...process.env, ISONIM_SOURCE_FRAMEWORK: repo },
    encoding: "utf8",
    timeout: 70000,
  },
);
writeFileSync(root + "/catalog-build.log", build.stdout + build.stderr);
assert.equal(build.status, 0, build.stdout + build.stderr);
const proof = {
  project,
  head:
    process.env.ISONIM_TEST_HEAD ||
    spawnSync("git", ["rev-parse", "HEAD"], {
      cwd: repo,
      encoding: "utf8",
    }).stdout.trim(),
  sourceState:
    process.env.ISONIM_TEST_SOURCE_STATE || "C4a authored working copy",
  nativeSha256: createHash("sha256")
    .update(readFileSync(repo + "/build/bin/isonim-review"))
    .digest("hex"),
  bundleSha256: createHash("sha256")
    .update(readFileSync(pub + "/editor.js"))
    .digest("hex"),
  cases: [],
  errors: [],
  agentRequests: [],
  sourceRequests: [],
  httpTimings: [],
  previewTimings: [],
};
const record = (name) => {
  proof.cases.push(name);
  writeFileSync(root + "/proof-partial.json", JSON.stringify(proof, null, 2));
};
const config = root + "/agent.toml";
writeFileSync(
  config,
  '[agent]\nbackend="custom"\ncommand="python3"\nargs=' +
    JSON.stringify([repo + "/tests/helpers/editor_control_peer.py"]) +
    "\nprimer_enabled=false\n",
);
const server = spawn(
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
  {
    env: { ...process.env, ISONIM_SOURCE_FRAMEWORK: repo },
    stdio: ["ignore", "pipe", openSync(root + "/server.log", "w")],
  },
);
let browser, browserServer;
try {
  const origin = await new Promise((resolve, reject) => {
    let text = "";
    server.stdout.on("data", (data) => {
      text += data;
      const match = text.match(/Editor listening on (http:\/\/[^\s]+)\//);
      if (match) resolve(match[1]);
    });
    server.once("exit", (code) => reject(Error("Server exited " + code)));
    setTimeout(() => reject(Error("Server startup timeout")), 70000).unref();
  });
  const chromeEnv = { ...process.env };
  delete chromeEnv.LD_LIBRARY_PATH;
  browserServer = await chromium.launchServer({
    headless: true,
    env: chromeEnv,
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE,
  });
  browser = await chromium.connect(browserServer.wsEndpoint());
  const page = await browser.newPage({
    viewport: { width: 1440, height: 900 },
  });
  page.setDefaultTimeout(30000);
  page.on("pageerror", (error) => proof.errors.push(error.message));
  page.on("request", (request) => {
    const url = new URL(request.url());
    if (url.pathname.startsWith("/api/agent/"))
      proof.agentRequests.push(url.pathname);
    if (url.pathname === "/api/editor/source/operation")
      proof.sourceRequests.push(request.postDataJSON());
  });
  await page.goto(origin);
  await page.waitForFunction(() => !!window.__popupAcceptance);
  await page
    .locator('[data-toolbar-cluster="mode"] [aria-label="Edit"]')
    .click();
  const snapshot = () =>
    page.evaluate(() => JSON.parse(window.__popupAcceptance.snapshot()));
  const source = () => readFileSync(project + "/stories.nim", "utf8"),
    catalog = () => readFileSync(project + "/.isonim/catalog.json", "utf8");
  let selected = "action",
    expectedSource = source(),
    count = 0;
  const body = (section) =>
    page.locator('[data-inspector-section-body="' + section + '"]');
  const row = (property, section) =>
    body(section).locator(
      '[data-property-row-css-property="' + property + '"]',
    );
  async function select(id) {
    selected = id;
    await page.locator('[data-scene-graph-row="' + id + '"]').click();
    await page.waitForFunction(
      (id) => JSON.parse(window.__popupAcceptance.snapshot()).selected === id,
      id,
    );
  }
  async function open(section) {
    const h = page.locator('[data-inspector-section-header="' + section + '"]');
    if ((await h.getAttribute("aria-expanded")) === "false") await h.click();
  }
  async function published(n) {
    await page.waitForFunction(
      (n) => {
        const v = JSON.parse(window.__popupAcceptance.snapshot());
        return (
          v.stage === "wesFailed" ||
          (v.stage === "wesClean" && v.undoCount === n)
        );
      },
      n,
      { timeout: 70000 },
    );
    const v = await snapshot();
    proof.lastState = v;
    assert.equal(v.stage, "wesClean");
    assert.equal(v.selected, selected);
    const story = JSON.parse(catalog()).stories.find(
      (story) => story.group + " / " + story.name === v.story,
    );
    const css = [
      ...story.documentHtml.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g),
    ].map((m) => m[1]);
    assert(css.length);
    await page.waitForFunction(
      ([css, id]) =>
        [...document.querySelectorAll("iframe")].some(
          (f) =>
            f.getClientRects().length &&
            f.contentDocument?.querySelector("#" + id) &&
            css.every((value) =>
              [...f.contentDocument.querySelectorAll("style")].some(
                (s) => s.textContent === value,
              ),
            ),
        ),
      [css, selected],
    );
  }
  const reference = {
    left: "10px",
    top: "12px",
    height: "48px",
    gap: "6px",
    "mix-blend-mode": "normal",
    "padding-bottom": "3px",
    "padding-left": "4px",
    "border-bottom-right-radius": "3px",
    "border-bottom-left-radius": "4px",
    "padding-top": "16px",
    "padding-right": "2px",
    "border-top-left-radius": "16px",
    "border-top-right-radius": "2px",
  };
  async function computed(values = reference) {
    for (const [property, value] of Object.entries(values)) {
      await page.waitForFunction(
        ([id, property, value]) => {
          const f = [...document.querySelectorAll("iframe")].find(
            (f) =>
              f.getClientRects().length &&
              f.contentDocument?.querySelector("#" + id),
          );
          return (
            f &&
            f.contentWindow
              .getComputedStyle(f.contentDocument.querySelector("#" + id))
              .getPropertyValue(property) === value
          );
        },
        [selected, property, value],
      );
    }
  }
  const typed = (value) => async (target) => {
    const i = target.locator("[data-property-row-input]");
    await i.click();
    await i.press("ControlOrMeta+A");
    await page.keyboard.type(value);
    await i.press("Enter");
    await i.press("Tab");
  };
  const scrub = (dx) => async (target) => {
    const h = target.locator("[data-property-row-field-label]");
    await h.scrollIntoViewIfNeeded();
    const b = await h.boundingBox();
    assert(b);
    await page.mouse.move(b.x + b.width / 2, b.y + b.height / 2);
    await page.mouse.down();
    await page.mouse.move(b.x + b.width / 2 + dx, b.y + b.height / 2);
    await page.mouse.up();
  };
  const choose = (index, keyboard) => async (target) => {
    await target.locator("[data-choice-group-trigger]").click();
    if (keyboard) {
      await target.locator('[data-choice-group-option="0"]').focus();
      for (let i = 0; i < index; i++) await page.keyboard.press("ArrowDown");
      await page.keyboard.press("Enter");
    } else
      await target
        .locator('[data-choice-group-option="' + index + '"]')
        .click();
  };
  async function edit(
    property,
    section,
    oldValue,
    value,
    action,
    values = reference,
  ) {
    const requests = proof.sourceRequests.length,
      oldCatalog = catalog();
    await action(row(property, section));
    const start = expectedSource.indexOf("#" + selected + " {"),
      end = expectedSource.indexOf("}", start) + 1;
    assert(
      expectedSource
        .slice(start, end)
        .includes(property + ":" + oldValue + ";"),
    );
    expectedSource =
      expectedSource.slice(0, start) +
      expectedSource
        .slice(start, end)
        .replace(
          property + ":" + oldValue + ";",
          property + ":" + value + ";",
        ) +
      expectedSource.slice(end);
    await published(++count);
    assert.equal(source(), expectedSource);
    assert.notEqual(catalog(), oldCatalog);
    assert.equal(proof.sourceRequests.length, requests + 1);
    values[property] = value;
    await computed(values);
    record(
      selected +
        " " +
        property +
        " exact native source/compiler/preview one request/history command",
    );
  }
  await select("state-panel");
  await open("layout");
  await open("state");
  const stateRow = body("state").locator(
    '[data-state-list] [data-property-row-css-property="width"]',
  );
  assert.equal(await stateRow.count(), 1);
  assert.equal(
    await stateRow.getAttribute("data-property-row-readonly"),
    "false",
  );
  const initialSource = source(),
    initialCatalog = catalog();
  async function actual() {
    return page.evaluate(() => {
      const f = [...document.querySelectorAll("iframe")].find(
        (f) =>
          f.getClientRects().length &&
          f.contentDocument?.querySelector("#state-panel"),
      );
      const doc = f.contentDocument;
      const result = {};
      for (const id of [
        "state-panel",
        "state-sibling",
        "important-panel",
        "token-panel",
        "token-sibling",
        "stylesheet-panel",
        "stylesheet-sibling",
      ]) {
        const e = doc.querySelector("#" + id);
        result[id] = {
          inline: e.style.getPropertyValue("width"),
          priority: e.style.getPropertyPriority("width"),
          computed: f.contentWindow.getComputedStyle(e).width,
        };
      }
      result.rules = [...doc.styleSheets]
        .flatMap((s) => [...s.cssRules])
        .filter((r) => r.selectorText)
        .map((r) => ({
          selector: r.selectorText,
          width: r.style.getPropertyValue("width"),
          priority: r.style.getPropertyPriority("width"),
          token: r.style.getPropertyValue("--state-width"),
          tokenPriority: r.style.getPropertyPriority("--state-width"),
        }));
      return result;
    });
  }
  async function intact() {
    assert.equal(source(), initialSource);
    assert.equal(catalog(), initialCatalog);
    assert.equal(proof.sourceRequests.length, 0);
    assert.equal(proof.agentRequests.length, 0);
    const v = await actual();
    assert.equal(v["state-sibling"].computed, "44px");
    assert.equal(
      v.rules.find((r) => r.selector === "#state-panel").width,
      "24px",
    );
    assert.equal(
      v.rules.find((r) => r.selector === "#important-panel").width,
      "24px",
    );
    assert.equal(
      v.rules.find((r) => r.selector === "#important-panel").priority,
      "important",
    );
    return v;
  }
  async function accepted(value, n) {
    await page.waitForFunction(
      (n) => JSON.parse(window.__popupAcceptance.snapshot()).undoCount === n,
      n,
    );
    await computed({ width: value });
    const snap = await snapshot();
    assert.equal(snap.selected, selected);
    assert.equal(snap.properties.find((p) => p.name === "width").value, value);
    assert.equal(snap.undoCount, n);
    await intact();
  }
  await computed({ width: "44px" });
  proof.initial = { snapshot: await snapshot(), actual: await actual() };
  await typed("48px")(row("width", "layout"));
  await accepted("48px", 1);
  assert.equal((await actual())["state-panel"].inline, "48px");
  record(
    "physical Layout local edit updates actual winning inline and isolates lower stylesheet/sibling",
  );
  const input = stateRow.locator("[data-property-row-input]");
  await input.click();
  await input.press("ControlOrMeta+A");
  await input.evaluate((n) => (window.__stateOriginalInput = n));
  await page.keyboard.type("50px");
  assert.deepEqual(
    await input.evaluate((n) => ({
      connected: window.__stateOriginalInput.isConnected,
      same: n === window.__stateOriginalInput,
      focused: document.activeElement === n,
    })),
    { connected: true, same: true, focused: true },
  );
  assert.equal((await snapshot()).undoCount, 1);
  await computed({ width: "48px" });
  record(
    "actual State natural draft keeps connected focused input and makes no history or preview edit",
  );
  await input.press("Enter");
  proof.stateEnter = {
    snapshot: await snapshot(),
    actual: await actual(),
    input: await stateRow.locator("input").evaluate((n) => ({
      value: n.value,
      originalConnected: window.__stateOriginalInput.isConnected,
      same: n === window.__stateOriginalInput,
      focused: document.activeElement === n,
      activeTag: document.activeElement.tagName,
      selectionStart: n.selectionStart,
      selectionEnd: n.selectionEnd,
    })),
  };
  writeFileSync(
    root + "/state-enter.json",
    JSON.stringify(proof.stateEnter, null, 2),
  );
  assert.equal(
    proof.stateEnter.snapshot.undoCount,
    2,
    "Actual State Enter must commit one edit",
  );
  assert.equal(
    proof.stateEnter.input.focused,
    true,
    "State Enter keeps a usable focused field",
  );
  assert.equal(proof.stateEnter.input.selectionStart, 4);
  assert.equal(proof.stateEnter.input.selectionEnd, 4);
  await accepted("50px", 2);
  assert.equal(await stateRow.locator("input").inputValue(), "50px");
  record(
    "actual State Enter commits one model/history/inline edit and retains usable focus/caret",
  );
  // Continue naturally in the active field, with no locator click/focus.
  await page.keyboard.press("ControlOrMeta+A");
  await page.keyboard.type("51px");
  await page.keyboard.press("Enter");
  await accepted("51px", 3);
  assert.equal(await stateRow.locator("input").inputValue(), "51px");
  assert.equal(
    await stateRow
      .locator("input")
      .evaluate((n) => document.activeElement === n),
    true,
  );
  record("actual State second keyboard edit follows Enter without refocusing");
  const blurInput = stateRow.locator("input");
  await blurInput.click();
  await blurInput.press("ControlOrMeta+A");
  await page.keyboard.type("52px");
  await page.locator('[data-inspector-section-header="state"]').click();
  await accepted("52px", 4);
  await open("state");
  record("actual State pointer focus and blur commits one edit");
  await typed("52px")(stateRow);
  assert.equal((await snapshot()).undoCount, 4);
  await computed({ width: "52px" });
  await intact();
  record("actual State unchanged Enter and blur are no-op");
  await typed("not-a-width")(stateRow);
  assert.equal((await snapshot()).undoCount, 4);
  assert.equal(await stateRow.locator("input").inputValue(), "52px");
  await computed({ width: "52px" });
  await intact();
  record(
    "actual State validation refusal restores control and preserves history/source/preview",
  );
  const cancel = stateRow.locator("input");
  await cancel.click();
  await cancel.press("ControlOrMeta+A");
  await page.keyboard.type("60px");
  await cancel.press("Escape");
  await cancel.press("Tab");
  assert.equal(await stateRow.locator("input").inputValue(), "52px");
  assert.equal((await snapshot()).undoCount, 4);
  await computed({ width: "52px" });
  await intact();
  record("actual State Escape restores draft with no edit");
  // The existing hook triggers the real public undo/redo command. Physical edit
  // and browser outcomes above/below are independent; no source adapter is mocked.
  await page.evaluate(() => window.__popupAcceptance.history(false));
  await accepted("51px", 3);
  assert.equal(await stateRow.locator("input").inputValue(), "51px");
  record("real State undo command restores model/control/inline preview");
  await page.evaluate(() => window.__popupAcceptance.history(true));
  await accepted("52px", 4);
  assert.equal(await stateRow.locator("input").inputValue(), "52px");
  record("real State redo command restores model/control/inline preview");
  // Real preview remount replays pending declarations through the same resolver.
  await page.evaluate(() => window.__popupAcceptance.activeView(false));
  await page.evaluate(() => window.__popupAcceptance.activeView(true));
  await select("state-panel");
  await computed({ width: "52px" });
  await intact();
  assert.equal(
    (await snapshot()).properties.find((p) => p.name === "width").value,
    "52px",
  );
  assert.equal((await snapshot()).undoCount, 4);
  await open("state");
  await open("layout");
  assert.equal(await stateRow.locator("input").inputValue(), "52px");
  assert.equal(
    await row("width", "layout").locator("input").inputValue(),
    "52",
  );
  proof.pending = await page.evaluate(() => window.__isonimPreviewDeclarations);
  assert.equal(proof.pending["state-panel|width"].scope, "sskLocalInstance");
  record(
    "pending local preview remount preserves scope plus model/history/State and Layout controls",
  );
  await select("important-panel");
  await open("layout");
  await typed("48px")(row("width", "layout"));
  await accepted("48px", 5);
  assert.equal((await actual())["important-panel"].inline, "48px");
  assert.equal((await actual())["important-panel"].priority, "important");
  record(
    "physical local important inline edit retains original importance and lower rule",
  );
  await page.evaluate(() => window.__popupAcceptance.history(false));
  await accepted("44px", 4);
  assert.equal((await actual())["important-panel"].priority, "important");
  await page.evaluate(() => window.__popupAcceptance.history(true));
  await accepted("48px", 5);
  assert.equal((await actual())["important-panel"].priority, "important");
  record("important inline undo and redo retain original priority");
  // Supplementary resolver probes in the SAME genuine compiled document verify
  // shared token and stylesheet paths; they are not physical commit proof.
  const resolver = async (id, value, scope) =>
    page.evaluate(
      ([id, value, scope]) => {
        const f = [...document.querySelectorAll("iframe")].find(
          (f) =>
            f.getClientRects().length &&
            f.contentDocument?.querySelector("#state-panel"),
        );
        return f.contentWindow.__isonimSetDeclaration(
          id,
          "#" + id,
          "width",
          value,
          scope,
        );
      },
      [id, value, scope],
    );
  assert.equal(await resolver("token-panel", "60px", "sskSemanticToken"), true);
  let runtime = await actual();
  for (const id of ["token-panel", "token-sibling"]) {
    assert.equal(runtime[id].inline, "var(--state-width)");
    assert.equal(runtime[id].computed, "60px");
  }
  assert.equal(runtime.rules.find((r) => r.selector === ":root").token, "60px");
  assert.equal(
    runtime.rules.find((r) => r.selector === ":root").tokenPriority,
    "important",
  );
  assert.equal((await snapshot()).undoCount, 5);
  await intact();
  record(
    "supplementary shared root-token runtime preserves both inline var use-sites and token importance",
  );
  assert.equal(
    await resolver("stylesheet-panel", "48px", "sskSharedClass"),
    true,
  );
  runtime = await actual();
  for (const id of ["stylesheet-panel", "stylesheet-sibling"]) {
    assert.equal(runtime[id].inline, "");
    assert.equal(runtime[id].computed, "48px");
  }
  assert.equal(
    runtime.rules.find((r) => r.selector === ".stylesheet-owned").priority,
    "important",
  );
  await intact();
  record(
    "supplementary shared stylesheet runtime preserves declaration importance and shared use-sites",
  );
  // A later normal rule must not hide an earlier shared important owner.
  await select("blocked-panel");
  await open("layout");
  await computed({ width: "24px" });
  const blockedRow = row("width", "layout");
  const beforeBlocked = {
    snapshot: await snapshot(),
    source: source(),
    catalog: catalog(),
    pending: await page.evaluate(() =>
      JSON.stringify(window.__isonimPreviewDeclarations),
    ),
  };
  const importantState = () =>
    page.evaluate(() => {
      const f = [...document.querySelectorAll("iframe")].find(
        (f) =>
          f.getClientRects().length &&
          f.contentDocument?.querySelector("#blocked-panel"),
      );
      const doc = f.contentDocument;
      return {
        nodes: ["blocked-panel", "blocked-sibling"].map((id) => {
          const e = doc.querySelector("#" + id);
          return {
            id,
            inline: e.style.cssText,
            computed: f.contentWindow.getComputedStyle(e).width,
          };
        }),
        rules: [...doc.styleSheets]
          .flatMap((s) => [...s.cssRules])
          .filter((r) => r.selectorText?.includes("#blocked-"))
          .map((r) => r.cssText),
      };
    });
  // Physical pointer movement changes hover; compare all remaining model state.
  const editState = (state) => {
    const { hover, ...rest } = state;
    return rest;
  };
  const beforeCSS = await importantState();
  assert.deepEqual(
    beforeCSS.nodes.map((n) => n.computed),
    ["24px", "24px"],
  );
  const localChoices = blockedRow.locator(
    '[data-source-scope-kind="sskLocalInstance"]',
  );
  assert.equal(await localChoices.count(), 2);
  for (const flag of await localChoices.evaluateAll((nodes) =>
    nodes.map((n) => ({
      editable: n.getAttribute("data-source-scope-editable"),
      disabled: n.getAttribute("aria-disabled"),
    })),
  )) {
    assert.equal(flag.editable, "false");
    assert.equal(flag.disabled, "true");
  }
  assert.equal(
    await blockedRow.getAttribute("data-property-row-readonly"),
    "true",
  );
  assert.equal(await blockedRow.locator("input").inputValue(), "24");
  const refusalMessage = blockedRow.locator(
    '[data-property-row-message-visible="true"]',
  );
  await refusalMessage.waitFor({ state: "visible" });
  assert.match(
    await refusalMessage.textContent(),
    /important stylesheet.*local editing is unavailable/,
  );
  await typed("48px")(blockedRow);
  assert.equal(await blockedRow.locator("input").inputValue(), "24");
  assert.deepEqual(await importantState(), beforeCSS);
  assert.deepEqual(
    editState(await snapshot()),
    editState(beforeBlocked.snapshot),
  );
  assert.equal(source(), beforeBlocked.source);
  assert.equal(catalog(), beforeBlocked.catalog);
  assert.equal(
    await page.evaluate(() =>
      JSON.stringify(window.__isonimPreviewDeclarations),
    ),
    beforeBlocked.pending,
  );
  assert.equal(proof.sourceRequests.length, 0);
  const transactionRefusal = JSON.parse(
    await page.evaluate(() =>
      window.__popupAcceptance.attemptCatalogOnlyProperty("width", "48px"),
    ),
  );
  assert.equal(transactionRefusal.ok, false);
  assert.match(transactionRefusal.message, /important stylesheet/);
  assert.deepEqual(
    editState(await snapshot()),
    editState(beforeBlocked.snapshot),
  );
  assert.equal(
    await page.evaluate(() =>
      JSON.stringify(window.__isonimPreviewDeclarations),
    ),
    beforeBlocked.pending,
  );
  assert.deepEqual(await importantState(), beforeCSS);
  // Direct resolver/replay entry must enforce the same refusal, not only rows.
  const directBlocked = await page.evaluate(() => {
    const f = [...document.querySelectorAll("iframe")].find(
      (f) =>
        f.getClientRects().length &&
        f.contentDocument?.querySelector("#blocked-panel"),
    );
    return f.contentWindow.__isonimSetDeclaration(
      "blocked-panel",
      "#blocked-panel",
      "width",
      "48px",
      "sskLocalInstance",
    );
  });
  assert.equal(directBlocked, false);
  assert.deepEqual(await importantState(), beforeCSS);
  assert.deepEqual(
    editState(await snapshot()),
    editState(beforeBlocked.snapshot),
  );
  proof.localImportant = {
    before: beforeCSS,
    after: await importantState(),
    state: await snapshot(),
    sourceUnchanged: source() === beforeBlocked.source,
    catalogUnchanged: catalog() === beforeBlocked.catalog,
    pendingUnchanged:
      (await page.evaluate(() =>
        JSON.stringify(window.__isonimPreviewDeclarations),
      )) === beforeBlocked.pending,
    message: await refusalMessage.textContent(),
  };
  writeFileSync(
    root + "/local-important-refusal.json",
    JSON.stringify(proof.localImportant, null, 2),
  );
  record(
    "physical Local important-shared refusal preserves model/control/history/journal/pending/source/catalog/CSS/sibling; direct resolver refuses",
  );
  await select("layer-panel");
  await open("layout");
  await computed({ width: "24px" });
  const layerRow = row("width", "layout");
  assert.equal(
    await layerRow.getAttribute("data-property-row-readonly"),
    "true",
  );
  const layerBefore = editState(await snapshot());
  const layerCSS = () =>
    page.evaluate(() => {
      const f = [...document.querySelectorAll("iframe")].find(
        (f) =>
          f.getClientRects().length &&
          f.contentDocument?.querySelector("#layer-panel"),
      );
      const e = f.contentDocument.querySelector("#layer-panel");
      return {
        inline: e.style.cssText,
        computed: f.contentWindow.getComputedStyle(e).width,
        rules: [...f.contentDocument.styleSheets]
          .flatMap((s) => [...s.cssRules])
          .filter((r) => r.cssText.includes("#layer-panel"))
          .map((r) => r.cssText),
      };
    });
  const layerOriginal = await layerCSS();
  await typed("48px")(layerRow);
  assert.deepEqual(await layerCSS(), layerOriginal);
  assert.deepEqual(editState(await snapshot()), layerBefore);
  assert.equal(await layerRow.locator("input").inputValue(), "24");
  assert.equal(source(), initialSource);
  assert.equal(catalog(), initialCatalog);
  assert.equal(
    await page.evaluate(() =>
      JSON.stringify(window.__isonimPreviewDeclarations),
    ),
    beforeBlocked.pending,
  );
  record(
    "physical Local refusal sees active important layer before later normal rule and preserves all edit state",
  );
  await select("inactive-panel");
  await open("layout");
  await computed({ width: "44px" });
  assert.equal(
    await row("width", "layout").getAttribute("data-property-row-readonly"),
    "false",
  );
  await typed("48px")(row("width", "layout"));
  await accepted("48px", 6);
  record(
    "inactive media and supports important declarations do not refuse valid local inline edit",
  );
  await select("responsive-panel");
  await open("layout");
  await computed({ width: "24px" });
  const responsiveRow = row("width", "layout");
  assert.equal(
    await responsiveRow.getAttribute("data-property-row-readonly"),
    "true",
  );
  const responsiveBefore = editState(await snapshot());
  writeFileSync(
    root + "/viewport-toolbar.html",
    await page
      .locator("[data-preview-viewport-strip]:visible")
      .evaluate((n) => n.outerHTML),
  );
  await page
    .locator(
      '[data-preview-viewport-strip-host] [data-choice-group-label="Phone"]:visible',
    )
    .click();
  await computed({ width: "44px" });
  await page.waitForFunction(
    () =>
      document
        .querySelector(
          '[data-inspector-section-body="layout"] [data-property-row-css-property="width"]',
        )
        .getAttribute("data-property-row-readonly") === "false",
  );
  assert.equal(
    await responsiveRow.locator("input").getAttribute("readonly"),
    null,
  );
  assert.equal((await snapshot()).selected, "responsive-panel");
  assert.deepEqual(editState(await snapshot()), responsiveBefore);
  await page
    .locator(
      '[data-preview-viewport-strip-host] [data-choice-group-label="Desktop"]:visible',
    )
    .click();
  await computed({ width: "24px" });
  await page.waitForFunction(
    () =>
      document
        .querySelector(
          '[data-inspector-section-body="layout"] [data-property-row-css-property="width"]',
        )
        .getAttribute("data-property-row-readonly") === "true",
  );
  assert.deepEqual(editState(await snapshot()), responsiveBefore);
  assert.equal(source(), initialSource);
  assert.equal(catalog(), initialCatalog);
  assert.equal(proof.sourceRequests.length, 0);
  record(
    "actual viewport toolbar refreshes Local important capability blocked-to-allowed-to-blocked without reselection or edit mutation",
  );
  proof.final = { snapshot: await snapshot(), actual: await actual() };
  assert.deepEqual(proof.errors, []);
  assert.deepEqual(proof.agentRequests, []);
  writeFileSync(root + "/proof.json", JSON.stringify(proof, null, 2));
  console.log("Catalog inline GUI passed:", root, proof.cases.length);
} finally {
  if (browser) await browser.close();
  if (browserServer) await browserServer.close();
  server.kill("SIGTERM");
  await new Promise((resolve) => {
    if (server.exitCode !== null) return resolve();
    server.once("exit", resolve);
    setTimeout(() => {
      server.kill("SIGKILL");
      resolve();
    }, 15000).unref();
  });
  writeFileSync(root + "/proof-final.json", JSON.stringify(proof, null, 2));
}
