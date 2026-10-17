/** Default native-inspector composition (catalog-only preview mode is exercised
 * separately by popup acceptance). Real mounted production inspector, native authenticated source worker, private
 * files and actual Nim compiler/SSR catalog. No UI, source, compiler, HTTP or
 * dispatcher is mocked. The configured controlled decision peer only permits
 * daemon startup; this suite sends no model prompts and asserts zero agent calls.
 * This additive matrix checks exact declared text/choices/numerics, authoring
 * units, actual source/compiler publication, browser CSS, history and reload.
 * Nonfinite and read-only negatives share the mounted writer; genuine compiler
 * failure/stale-selection controls remain in the original compounds suite.
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
  path.join(
    process.env.ISONIM_POPUP_ARTIFACTS || tmpdir(),
    "inspector-properties-",
  ),
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
  "font-family:serif; font-weight:400; font-size:16px; line-height:1.5; letter-spacing:1px; margin-bottom:2px; text-align:left; text-decoration:none; text-transform:none; list-style-type:none; border-width:2px; border-style:solid; overflow:visible;";
const currentWeights = [
  ["800", "800"],
  ["650", "650"],
  ["bolder", "bolder"],
  ["variable", "var(--weight)"],
  ["normal", "normal"],
  ["bold", "bold"],
];
const setupSource = readFileSync(project + "/stories.nim", "utf8");
writeFileSync(
  project + "/stories.nim",
  setupSource
    .replace(
      "#action { width:120px;",
      "html, body, main { font-size:16px; font-family:monospace; }\n#action { " +
        declarations +
        " width:120px;",
    )
    .replace("button(id = target,", "p(id = target,")
    .replace(
      "#reused-card {",
      currentWeights
        .map(
          ([id, value]) =>
            "#weight-" +
            id +
            " { --weight:650; font-weight:" +
            value +
            "; text-align:start; }",
        )
        .join("\n") + "\n#reused-card {",
    )
    .replace(
      "          h1: text title",
      "          h1: text title\n" +
        currentWeights
          .map(
            ([id]) =>
              '          p(id = "weight-' +
              id +
              '", `data-isonim-element-id` = "weight-' +
              id +
              '"): text "Weight ' +
              id +
              '"',
          )
          .join("\n"),
    ),
);
const setupManifest = JSON.parse(
  readFileSync(project + "/.isonim/source-project.json", "utf8"),
);
setupManifest.editableStyles
  .find((row) => row.elementId === "action")
  .properties.push(
    ...declarations
      .split(";")
      .filter((value) => value.trim())
      .map((value) => value.trim().split(":")[0]),
  );
for (const [id] of currentWeights)
  setupManifest.editableStyles.push({
    key: "style.weight-" + id,
    elementId: "weight-" + id,
    storyId: "Card / default ready",
    file: "stories.nim",
    const: "cardStyles",
    selector: "#weight-" + id,
    properties: ["font-weight", "text-align"],
  });
writeFileSync(
  project + "/.isonim/source-project.json",
  JSON.stringify(setupManifest),
);

for (const [from, to] of [
  ["src/isonim/editor/index.html", "index.html"],
  ["build/editor-inspector/editor.js", "editor.js"],
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
  await page.locator('[data-scene-graph-row="action"]').click();
  const snapshot = () =>
    page.evaluate(() => JSON.parse(window.__popupAcceptance.snapshot()));
  const source = () => readFileSync(project + "/stories.nim", "utf8");
  const catalog = () => readFileSync(project + "/.isonim/catalog.json", "utf8");
  const row = (property) =>
    page.locator('[data-property-row-css-property="' + property + '"]');
  // Independent browser CSS reference: explicit declarations, never production
  // parsing as an expected oracle. Unitless line-height's computed value is 24px.
  const reference = {
    "font-family": "serif",
    "font-weight": "400",
    "font-size": "16px",
    "line-height": "24px",
    "letter-spacing": "1px",
    "margin-bottom": "2px",
    "text-align": "left",
    "text-decoration-line": "none",
    "text-transform": "none",
    "list-style-type": "none",
    "border-top-width": "2px",
    "border-top-style": "solid",
    overflow: "visible",
  };
  let expectedSource = source(),
    count = 0;
  async function published(expectedCount) {
    await page.waitForFunction(
      (count) => {
        const state = JSON.parse(window.__popupAcceptance.snapshot());
        return (
          state.stage === "wesFailed" ||
          (state.stage === "wesClean" && state.undoCount === count)
        );
      },
      expectedCount,
      { timeout: 70000 },
    );
    const state = await snapshot();
    proof.lastState = state;
    writeFileSync(root + "/last-state.json", JSON.stringify(state, null, 2));
    assert.equal(
      state.stage,
      "wesClean",
      "Native writer/compiler must publish successfully",
    );
    const published = JSON.parse(catalog()).stories.find(
      (story) => story.group + " / " + story.name === state.story,
    );
    assert(published);
    const css = [
      ...published.documentHtml.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g),
    ].map((match) => match[1]);
    assert(css.length);
    await page.waitForFunction(
      (css) =>
        [...document.querySelectorAll("iframe")].some(
          (frame) =>
            frame.getClientRects().length &&
            frame.contentDocument?.querySelector("#action") &&
            css.every((value) =>
              [...frame.contentDocument.querySelectorAll("style")].some(
                (style) => style.textContent === value,
              ),
            ),
        ),
      css,
    );
    assert.equal(state.selected, "action");
  }
  async function checkPreview() {
    for (const [property, value] of Object.entries(reference)) {
      try {
        await page.waitForFunction(
          ([property, value]) => {
            const frame = [...document.querySelectorAll("iframe")].find(
              (frame) =>
                frame.getClientRects().length &&
                frame.contentDocument?.querySelector("#action"),
            );
            return (
              frame &&
              frame.contentWindow
                .getComputedStyle(
                  frame.contentDocument.querySelector("#action"),
                )
                .getPropertyValue(property) === value
            );
          },
          [property, value],
        );
      } catch (error) {
        proof.previewFailure = {
          property,
          expected: value,
          actual: await page.evaluate(
            (property) =>
              [...document.querySelectorAll("iframe")]
                .filter(
                  (frame) =>
                    frame.getClientRects().length &&
                    frame.contentDocument?.querySelector("#action"),
                )
                .map((frame) => ({
                  computed: frame.contentWindow
                    .getComputedStyle(
                      frame.contentDocument.querySelector("#action"),
                    )
                    .getPropertyValue(property),
                  selected:
                    frame.contentDocument.querySelector("#action").outerHTML,
                  body: frame.contentWindow.getComputedStyle(
                    frame.contentDocument.body,
                  ).fontSize,
                  root: frame.contentWindow.getComputedStyle(
                    frame.contentDocument.documentElement,
                  ).fontSize,
                  styles: [
                    ...frame.contentDocument.querySelectorAll("style"),
                  ].map((style) => style.textContent),
                })),
            property,
          ),
        };
        writeFileSync(
          root + "/preview-failure.json",
          JSON.stringify(proof.previewFailure, null, 2),
        );
        throw error;
      }
    }
  }
  async function edit(
    property,
    oldValue,
    newValue,
    perform,
    computedProperty = property,
    computedValue = newValue,
  ) {
    const requests = proof.sourceRequests.length,
      beforeCatalog = catalog();
    await perform(row(property));
    const start = expectedSource.indexOf("#action {"),
      end = expectedSource.indexOf("}", start) + 1;
    const declaration = property + ":" + oldValue + ";";
    assert(expectedSource.slice(start, end).includes(declaration));
    expectedSource =
      expectedSource.slice(0, start) +
      expectedSource
        .slice(start, end)
        .replace(declaration, property + ":" + newValue + ";") +
      expectedSource.slice(end);
    await published(++count);
    assert.equal(source(), expectedSource);
    assert.equal(proof.sourceRequests.length, requests + 1);
    assert.notEqual(catalog(), beforeCatalog);
    reference[computedProperty] = computedValue;
    await checkPreview();
    if (
      [
        "font-size",
        "line-height",
        "letter-spacing",
        "margin-bottom",
        "border-width",
      ].includes(property)
    ) {
      const unit = newValue.match(/(rem|em|px|%)$/)?.[1] || "";
      assert.equal(
        await row(property).locator("[data-property-row-input]").inputValue(),
        unit ? newValue.slice(0, -unit.length) : newValue,
      );
      assert.equal(
        (
          await row(property).locator("[data-property-row-unit]").textContent()
        ).trim(),
        unit,
      );
    }
    record(
      property +
        " exact source / real compiler publication / preview / one history command",
    );
  }
  const typed = (value) => async (target) => {
    const input = target.locator("[data-property-row-input]");
    await input.click();
    await input.press("ControlOrMeta+A");
    await page.keyboard.type(value);
    await input.press("Enter");
    await input.press("Tab");
  };
  const choice = (index, keyboard) => async (target) => {
    const trigger = target.locator("[data-choice-group-trigger]");
    await trigger.scrollIntoViewIfNeeded();
    await trigger.click();
    if (keyboard) {
      await target.locator('[data-choice-group-option="0"]').focus();
      for (let i = 0; i < index; i++) await page.keyboard.press("ArrowDown");
      await page.keyboard.press("Enter");
    } else
      await target
        .locator('[data-choice-group-option="' + index + '"]')
        .click();
  };
  const scrub = (dx) => async (target) => {
    const handle = target.locator("[data-property-row-field-label]");
    await handle.scrollIntoViewIfNeeded();
    const box = await handle.boundingBox();
    assert(box);
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width / 2 + dx, box.y + box.height / 2);
    await page.mouse.up();
  };
  for (const section of ["typography", "stroke"]) {
    const header = page.locator(
      '[data-inspector-section-header="' + section + '"]',
    );
    if ((await header.getAttribute("aria-expanded")) === "false")
      await header.click();
  }
  await checkPreview();
  assert.equal(await row("line-height").locator("input").inputValue(), "1.5");
  // Inspect actual uncommon numeric/relative/token owners without substituting a
  // default. Normal/bold are equivalent to the menu's400/700 and selecting them
  // is a no-op: the authored aliases must survive exactly.
  const passiveSource = source(),
    passiveCatalog = catalog(),
    passiveRequests = proof.sourceRequests.length,
    passiveHistory = (await snapshot()).undoCount;
  for (const [id, value] of currentWeights) {
    await page.locator('[data-scene-graph-row="weight-' + id + '"]').click();
    const target = row("font-weight"),
      trigger = target.locator("[data-choice-group-trigger]");
    assert.equal(
      await row("text-align")
        .locator("[data-choice-group-trigger-label]")
        .innerText(),
      "start",
    );
    const computedWeight = {
      800: "800",
      650: "650",
      bolder: "700",
      variable: "650",
      normal: "400",
      bold: "700",
    }[id];
    await page.waitForFunction(
      ([id, value]) => {
        const frame = [...document.querySelectorAll("iframe")].find(
          (frame) =>
            frame.getClientRects().length &&
            frame.contentDocument?.querySelector("#weight-" + id),
        );
        return (
          frame &&
          frame.contentWindow.getComputedStyle(
            frame.contentDocument.querySelector("#weight-" + id),
          ).fontWeight === value
        );
      },
      [id, computedWeight],
    );
    assert.equal(
      await target.locator("[data-choice-group-trigger-label]").innerText(),
      id === "normal" ? "Regular" : id === "bold" ? "Bold" : value,
    );
    await trigger.click();
    assert.equal(await target.locator("[data-choice-group-option]").count(), 6);
    assert.equal(
      await target.getAttribute("data-property-row-readonly"),
      "false",
    );
    assert.equal(
      await target
        .locator('[data-choice-group-option][aria-selected="true"]')
        .count(),
      id === "normal" || id === "bold" ? 1 : 0,
    );
    if (id === "normal" || id === "bold") {
      await target
        .locator(
          '[data-choice-group-option="' + (id === "normal" ? 2 : 5) + '"]',
        )
        .click();
    } else {
      await target.locator('[data-choice-group-option="0"]').focus();
      await page.keyboard.press("Escape");
    }
    assert.equal(source(), passiveSource);
    assert.equal(catalog(), passiveCatalog);
    assert.equal(proof.sourceRequests.length, passiveRequests);
    assert.equal((await snapshot()).undoCount, passiveHistory);
  }
  await page.locator('[data-scene-graph-row="action"]').click();
  record(
    "actual800/650/bolder/variable values display truthfully; normal/bold no-op aliases preserve exact source/catalog/history",
  );

  await edit("font-family", "serif", "monospace", typed("monospace"));
  await edit("font-family", "monospace", "serif", async (target) => {
    const input = target.locator("[data-property-row-input]");
    await input.click();
    await input.press("ControlOrMeta+A");
    await page.keyboard.type("serif");
    await row("font-weight").locator("[data-property-row-field-label]").click();
  });
  await edit("font-family", "serif", "monospace", typed("monospace"));
  await edit("font-weight", "400", "500", choice(3, true));
  await edit("font-weight", "500", "600", choice(4, false));
  reference["line-height"] = "27px";
  await edit("font-size", "16px", "18px", scrub(1));
  reference["line-height"] = "30px";
  await edit("font-size", "18px", "20px", typed("10*2px"));
  // Real admitted authoring units project into the field and survive scrubs;
  // the browser's independent computed CSS remains pixels.
  reference["line-height"] = "24px";
  await edit("font-size", "20px", "1em", typed("1em"), "font-size", "16px");
  reference["line-height"] = "48px";
  await edit("font-size", "1em", "2em", scrub(0.5), "font-size", "32px");
  await edit("font-size", "2em", "2rem", typed("2rem"), "font-size", "32px");
  reference["line-height"] = "72px";
  await edit("font-size", "2rem", "3rem", scrub(0.5), "font-size", "48px");
  reference["line-height"] = "48px";
  await edit("font-size", "3rem", "200%", typed("200%"), "font-size", "32px");
  reference["line-height"] = "60px";
  await edit("font-size", "200%", "250%", scrub(25), "font-size", "40px");
  reference["line-height"] = "30px";
  await edit("font-size", "250%", "20px", typed("20px"));
  await edit("line-height", "1.5", "2", typed("2"), "line-height", "40px");
  await edit("line-height", "2", "3", scrub(0.5), "line-height", "60px");
  await edit("line-height", "3", "150%", typed("150%"), "line-height", "30px");
  await edit("line-height", "150%", "200%", scrub(25), "line-height", "40px");
  await edit(
    "line-height",
    "200%",
    "1.5em",
    typed("1.5em"),
    "line-height",
    "30px",
  );
  await edit(
    "line-height",
    "1.5em",
    "2.5em",
    scrub(0.5),
    "line-height",
    "50px",
  );
  await edit("line-height", "2.5em", "3em", typed("3"), "line-height", "60px");
  await edit("letter-spacing", "1px", "3px", scrub(1));
  await edit("letter-spacing", "3px", "2px", typed("2px"));
  await edit("margin-bottom", "2px", "4px", scrub(1));
  await edit("margin-bottom", "4px", "6px", typed("3*2px"));
  await edit("text-align", "left", "center", choice(1, false));
  await edit("text-align", "center", "right", choice(2, true));
  await edit(
    "text-decoration",
    "none",
    "underline",
    choice(1, true),
    "text-decoration-line",
    "underline",
  );
  await edit(
    "text-decoration",
    "underline",
    "line-through",
    choice(2, false),
    "text-decoration-line",
    "line-through",
  );
  await edit("text-transform", "none", "uppercase", choice(1, false));
  await edit("text-transform", "uppercase", "lowercase", choice(2, true));
  await edit("list-style-type", "none", "disc", choice(1, true));
  await edit("list-style-type", "disc", "decimal", choice(2, false));
  await edit("border-width", "2px", "4px", scrub(1), "border-top-width", "4px");
  await edit(
    "border-width",
    "4px",
    "3px",
    typed("3px"),
    "border-top-width",
    "3px",
  );
  await edit(
    "border-style",
    "solid",
    "dashed",
    choice(1, true),
    "border-top-style",
    "dashed",
  );
  await edit(
    "border-style",
    "dashed",
    "dotted",
    choice(2, false),
    "border-top-style",
    "dotted",
  );
  await edit("overflow", "visible", "hidden", choice(1, false));
  await edit("overflow", "hidden", "scroll", choice(2, true));
  const finalSource = source(),
    finalCatalog = catalog(),
    finalPreview = { ...reference },
    finalRequests = proof.sourceRequests.length;
  await page.evaluate(() => window.__popupAcceptance.history(false));
  await published(--count);
  assert.equal(
    source(),
    finalSource.replace("overflow:scroll;", "overflow:hidden;"),
  );
  reference.overflow = "hidden";
  await checkPreview();
  await page.evaluate(() => window.__popupAcceptance.history(true));
  await published(++count);
  assert.equal(source(), finalSource);
  reference.overflow = "scroll";
  await checkPreview();
  assert.equal(proof.sourceRequests.length, finalRequests + 2);
  record(
    "native undo redo recompile exact source and restore all section previews",
  );
  await page.reload();
  await page.waitForFunction(() => !!window.__popupAcceptance);
  await page
    .locator('[data-toolbar-cluster="mode"] [aria-label="Edit"]')
    .click();
  await page.locator('[data-scene-graph-row="action"]').click();
  await checkPreview();
  assert.equal(source(), finalSource);
  assert.equal(catalog(), finalCatalog);
  record(
    "fresh browser reload reads real compiled catalog and exact persisted declarations",
  );
  const strokeAfterReload = page.locator(
    '[data-inspector-section-header="stroke"]',
  );
  if ((await strokeAfterReload.getAttribute("aria-expanded")) === "false")
    await strokeAfterReload.click();
  // Unsupported input and permission refusal leave actual bytes/catalog/preview.
  const before = await snapshot(),
    requests = proof.sourceRequests.length;
  await typed("NaN")(row("border-width"));
  assert.equal(source(), finalSource);
  assert.equal(catalog(), finalCatalog);
  assert.equal(proof.sourceRequests.length, requests);
  await checkPreview();
  assert.equal((await snapshot()).undoCount, before.undoCount);
  await page.evaluate(() => window.__popupAcceptance.readOnly(true));
  await typed("5px")(row("border-width"));
  assert.equal(source(), finalSource);
  assert.equal(catalog(), finalCatalog);
  assert.equal(proof.sourceRequests.length, requests);
  await checkPreview();
  assert.equal(await row("border-width").locator("input").inputValue(), "3");
  record(
    "nonfinite and readonly refusal retain source/catalog/preview/control/history",
  );
  assert.deepEqual(proof.errors, []);
  assert.deepEqual(proof.agentRequests, []);
  writeFileSync(root + "/proof.json", JSON.stringify(proof, null, 2));
  console.log(
    "Inspector ordinary properties GUI passed:",
    root,
    proof.cases.length,
  );
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
