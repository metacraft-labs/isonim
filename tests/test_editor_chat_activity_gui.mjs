/**
 * Production mounted full-editor chat behavior and layout. A test-only entry
 * injects normalized external events and admission outcomes to make stream timing
 * deterministic; EditorVM, reducer, renderer, DOM, keyboard, scroll and previews
 * are real. This is presentation coverage, not a substitute for the registered
 * real REST/official scenario integration. No browser/VM/RPC mocks.
 * A local control-host fixture explicitly substitutes connected transport state;
 * its negative case retains genuine disconnected rejection before actual approval.
 * Admission starts after the visible production preview is complete and its
 * primary/secondary DOM identities appear in the real parent-side scene graph
 * (shell.nim polls at 300ms/700ms). Fonts and two normal frames settle before
 * admission; no revision polling, mutation retry or expected-revision rebasing.
 * Stored-operation diagnostics are read-only and never resolve pending work.
 * The toolbar negative control disables only its CSS size-container to expose
 * the retained original full strip at narrow width; it proves the bounds guard
 * rejects the original clipped controls, then restores the production container.
 * Geometry checks wait for font layout and two browser animation frames because
 * the real chat view follows output in requestAnimationFrame. This observes its
 * scheduled scroll; it does not scroll, focus, modify DOM or relax visible bounds.
 * A forwarding scrollIntoView observer records actual delegated destinations for
 * selection/unmount microtask races; it calls the unchanged browser implementation
 * and is restored in finally. It does not substitute navigation or scroll layout.
 * The additive code-reading fixture is shared with native/executed-JS tests.
 * Its long-tool scenario injects genuine public tool_use/tool_result DTO timing
 * through the real Harbor parser/projection/codec/reducer and mounted view;
 * independent literal code expectations cover excerpt growth and late-tail updates.
 * Synthetic restored-transcript replacement/removal uses the real activity signal
 * to exercise lifecycle kinds that append-only provider chunks cannot produce;
 * it adds no provider discriminator or fake browser control.
 * Assert stable turn/tool nodes, unsafe text, IME, drafts/tabs, focus/selection, scrollback,
 * narrow/wide overflow and composer/preview reachability; capture named states.
 * Layers search uses the real iframe DOM walk, shared InspectorVM and header input.
 * It checks collapsed descendants, no matches, selection/expansion preservation,
 * and independence from storyboard search without injecting a synthetic tree.
 */
import assert from "node:assert/strict";
import {
  sidebarSearchFocusEvidence,
  requireSidebarSearchFocus,
} from "../tools/chat-focus-guard.mjs";
import {
  horizontalChatGuard,
  oldClippedChatControl,
} from "../tools/chat-horizontal-guard.mjs";
import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "../node_modules/playwright/index.mjs";
const codeReadingScenario = JSON.parse(
  readFileSync(
    new URL("./scenarios/chat-activity/code-reading.json", import.meta.url),
  ),
);
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const artifacts = mkdtempSync(path.join(tmpdir(), "isonim-chat-activity-"));
const server = spawn(
  "python3",
  [
    "-u",
    "-m",
    "http.server",
    "0",
    "--bind",
    "127.0.0.1",
    "--directory",
    path.join(repo, "build/editor-chat"),
  ],
  { stdio: ["ignore", "pipe", "pipe"] },
);
let origin;
let serverText = "";
const startup = new Promise((resolve, reject) => {
  server.stdout.on("data", (chunk) => {
    serverText += chunk;
    const match = serverText.match(/port (\d+)/);
    if (match) {
      origin = `http://127.0.0.1:${match[1]}`;
      resolve();
    }
  });
  server.once("exit", (code) => reject(new Error(`server exited ${code}`)));
  setTimeout(() => reject(new Error("startup timeout")), 10000).unref();
});
let browser;
let count = 0;
const record = (name) => {
  count++;
  process.stdout.write(`PASS ${name}\n`);
};
// Observe concrete initial mount completion, rather than the helper's existence:
// __chatTest is published synchronously before iframe load and scene-graph scan.
async function mountedReady(page, name) {
  await page.waitForFunction(
    () => {
      if (
        !window.__chatTest ||
        document.readyState !== "complete" ||
        document.fonts.status !== "loaded"
      )
        return false;
      const frames = Array.from(
        document.querySelectorAll('iframe[data-page-project-frame="true"]'),
      ).filter(
        (frame) => frame.getClientRects().length && frame.offsetParent !== null,
      );
      if (frames.length !== 1) return false;
      const doc = frames[0].contentDocument;
      if (
        !doc ||
        doc.readyState !== "complete" ||
        doc.fonts.status !== "loaded"
      )
        return false;
      const state = JSON.parse(window.__chatTest.controlState());
      return ["primary", "secondary"].every(
        (id) =>
          doc.querySelector(`[data-isonim-element-id="${id}"]`) &&
          state.elements.some((row) => row.id === id),
      );
    },
    null,
    { timeout: 5000 },
  );
  const ready = await page.evaluate(async () => {
    const frameTimes = await new Promise((resolve) =>
      requestAnimationFrame((first) =>
        requestAnimationFrame((second) => resolve([first, second])),
      ),
    );
    const frame = Array.from(
      document.querySelectorAll('iframe[data-page-project-frame="true"]'),
    ).find(
      (frame) => frame.getClientRects().length && frame.offsetParent !== null,
    );
    return {
      frameTimes,
      documentReadyState: document.readyState,
      fontStatus: document.fonts.status,
      previewReadyState: frame.contentDocument.readyState,
      previewFontStatus: frame.contentDocument.fonts.status,
      state: JSON.parse(window.__chatTest.controlState()),
    };
  });
  writeFileSync(
    path.join(artifacts, `mounted-ready-${name}.json`),
    JSON.stringify(ready, null, 2),
  );
  return ready;
}
async function controlDiagnostic(page, id, phase) {
  const actual = JSON.parse(
    await page.evaluate((id) => window.__chatTest.controlDiagnostics(id), id),
  );
  actual.phase = phase;
  writeFileSync(
    path.join(artifacts, `control-${id}-${phase}.json`),
    JSON.stringify(actual, null, 2),
  );
  return actual;
}

try {
  await startup;
  browser = await chromium.launch({
    headless: true,
    executablePath:
      process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ??
      "/nix/store/1id5xlj91r8d5cj5ks4a5byrxdvr4b50-chromium-143.0.7499.192/bin/chromium",
    env: { ...process.env, LD_LIBRARY_PATH: "" },
    args: ["--no-sandbox"],
  });
  const page = await browser.newPage({
    viewport: { width: 1440, height: 900 },
  });
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  // Separate mounted host: direct admission uses the real shared controller,
  // then the actual chat Approve button applies only after transport is ready.
  const controlPage = await browser.newPage({
    viewport: { width: 1440, height: 900 },
  });
  await controlPage.goto(origin);
  await controlPage.waitForFunction(() => window.__chatTest);
  await controlPage.evaluate(() => window.__chatTest.localApprovals(false));
  await controlPage
    .getByRole("checkbox", { name: "Require approval for agent navigation" })
    .check();
  await mountedReady(controlPage, "disconnected-approval");
  const controlBefore = JSON.parse(
    await controlPage.evaluate(() => window.__chatTest.controlState()),
  );
  const admitted = JSON.parse(
    await controlPage.evaluate(() => {
      const state = JSON.parse(window.__chatTest.controlState());
      return window.__chatTest.control(
        JSON.stringify({
          commandId: "fixture-disconnected",
          command: "open-story",
          storyId: state.stories.find((row) => row.name === "Details").id,
        }),
      );
    }),
  );
  const admittedEvidence = await controlDiagnostic(
    controlPage,
    "fixture-disconnected",
    "admitted",
  );
  assert.equal(admitted.status, "pending", JSON.stringify(admittedEvidence));
  assert.deepEqual(admittedEvidence.operation, admitted);
  const denied = JSON.parse(
    await controlPage.evaluate(() =>
      window.__chatTest.approval("fixture-disconnected", true),
    ),
  );
  assert.equal(denied.error, "disconnected_instance");
  assert.equal(
    JSON.parse(
      await controlPage.evaluate(() => window.__chatTest.controlState()),
    ).storyId,
    controlBefore.storyId,
  );
  const pendingRow = controlPage.locator(
    '[data-editor-control-operation="fixture-disconnected"]',
  );
  assert.equal(
    await pendingRow.getAttribute("data-operation-status"),
    "pending",
  );
  await controlPage.evaluate(() => window.__chatTest.localApprovals(true));
  const beforeClick = await controlDiagnostic(
    controlPage,
    "fixture-disconnected",
    "before-click",
  );
  await controlPage
    .locator('[data-editor-control-approve="fixture-disconnected"]')
    .click();
  const afterClick = await controlDiagnostic(
    controlPage,
    "fixture-disconnected",
    "after-click",
  );
  assert.equal(
    await pendingRow.getAttribute("data-operation-status"),
    "applied",
    JSON.stringify({ admitted, beforeClick, afterClick }),
  );
  assert.equal(afterClick.operation.status, "applied");
  const controlAfter = JSON.parse(
    await controlPage.evaluate(() => window.__chatTest.controlState()),
  );
  assert.equal(
    controlAfter.storyId,
    controlBefore.stories.find((row) => row.name === "Details").id,
  );
  await controlPage.close();
  record(
    "local transport boundary preserves disconnected rejection and real mounted approval",
  );
  const reloadPage = await browser.newPage({
    viewport: { width: 1440, height: 900 },
  });
  await reloadPage.goto(origin);
  await mountedReady(reloadPage, "workspace-reload-scope");
  await reloadPage.evaluate(() => window.__chatTest.backend(true));
  const originalScope = JSON.parse(
    await reloadPage.evaluate(() => window.__chatTest.controlState()),
  );
  const originalConversation = JSON.parse(
    await reloadPage.evaluate(() => window.__chatTest.state()),
  );
  const refused = JSON.parse(
    await reloadPage.evaluate(() => window.__chatTest.remount(true)),
  );
  assert.equal(refused.sameVM, true);
  assert.equal(refused.workspace, originalScope.workspace);
  assert.equal(refused.instance, originalScope.instance);
  assert.equal(refused.adapterReady, true);
  assert.equal(refused.stage, "wesFailed");
  const afterRefusal = JSON.parse(
    await reloadPage.evaluate(() => window.__chatTest.controlState()),
  );
  for (const field of [
    "workspace",
    "instance",
    "storyId",
    "selection",
    "permissions",
    "view",
    "mode",
    "viewport",
    "approvalRequired",
    "capabilities",
    "conversations",
  ])
    assert.deepEqual(
      afterRefusal[field],
      originalScope[field],
      `foreign hot bundle preserves ${field}`,
    );
  assert.deepEqual(afterRefusal.stories, originalScope.stories);
  assert(
    afterRefusal.buildDiagnostics.some((item) =>
      item.message.includes("Cannot refresh workspace"),
    ),
  );
  assert.deepEqual(
    JSON.parse(await reloadPage.evaluate(() => window.__chatTest.state())),
    originalConversation,
  );
  const refreshError = reloadPage.locator('[data-save-error="true"]');
  assert(
    await refreshError.isVisible(),
    "rejected hot bundle has a visible diagnostic",
  );
  assert(
    (await refreshError.textContent()).includes(
      "Cannot refresh workspace 'foreign-project'",
    ),
  );
  const recoveredForeign = JSON.parse(
    await reloadPage.evaluate(() => window.__chatTest.recoverBuild()),
  );
  assert.equal(recoveredForeign.stage, "wesFailed");
  assert(
    await refreshError.isVisible(),
    "asynchronous bundle completion cannot erase scope refusal",
  );
  const refreshed = JSON.parse(
    await reloadPage.evaluate(() => window.__chatTest.remount(false)),
  );
  assert.equal(refreshed.sameVM, true);
  assert.equal(refreshed.workspace, originalScope.workspace);
  assert.equal(refreshed.instance, originalScope.instance);
  assert.equal(refreshed.adapterReady, true);
  assert.equal(refreshed.stage, "wesClean");
  assert.equal(await refreshError.isVisible(), false);
  await reloadPage.evaluate(() => window.__chatTest.seedSaveFailure());
  assert(
    (await refreshError.textContent()).includes(
      "Existing source write refusal.",
    ),
  );
  await reloadPage.evaluate(() => window.__chatTest.remount(true));
  await reloadPage.evaluate(() => window.__chatTest.recoverBuild());
  const savePreserved = JSON.parse(
    await reloadPage.evaluate(() => window.__chatTest.remount(false)),
  );
  assert.equal(savePreserved.stage, "wesFailed");
  assert(await refreshError.isVisible());
  assert(
    (await refreshError.textContent()).includes(
      "Existing source write refusal.",
    ),
    "valid same-scope refresh preserves the earlier source failure",
  );
  await reloadPage.evaluate(() => window.__chatTest.recoverBuild());
  assert(
    (await refreshError.textContent()).includes(
      "Existing source write refusal.",
    ),
  );
  await reloadPage.close();
  record(
    "production hot bundle rejects foreign workspace and retains mounted adapter scope",
  );
  for (const [width, height] of [
    [1440, 900],
    [1024, 768],
  ]) {
    const layersPage = await browser.newPage({ viewport: { width, height } });
    await layersPage.goto(origin);
    await mountedReady(layersPage, `layers-search-${width}`);
    const layers = layersPage.getByRole("region", {
      name: "Layers",
      exact: true,
    });
    const search = layers.getByRole("textbox", {
      name: "Search layers",
      exact: true,
    });
    assert(await search.isVisible(), "Layers header exposes search");
    assert.equal(await search.getAttribute("placeholder"), "Search layers");
    assert.equal(
      await search.evaluate((el) => el.ownerDocument.activeElement === el),
      false,
    );
    assert.deepEqual(
      await search.evaluate((el) => {
        const css = getComputedStyle(
          el.closest('[data-sidebar-search-field="layers"]'),
        );
        return [
          css.borderTopStyle,
          css.borderTopWidth,
          css.borderTopColor,
          css.backgroundColor,
        ];
      }),
      ["solid", "1px", "rgb(42, 44, 58)", "rgb(26, 27, 38)"],
      "unfocused Layers search paints a bounded input box",
    );
    await layersPage.screenshot({
      path: path.join(artifacts, `layers-unfocused-${width}.png`),
      fullPage: true,
    });
    assert.equal(
      await layers.getByText("Scene graph", { exact: true }).count(),
      0,
    );
    const initial = JSON.parse(
      await layersPage.evaluate(() => window.__chatTest.controlState()),
    );
    const root = initial.elements.find((row) => row.parentId === "");
    assert(root, "real preview walker published a root");
    const row = (id) => layers.locator(`[data-scene-graph-row="${id}"]`);
    await layers.locator(`[data-scene-graph-twisty="${root.id}"]`).click();
    assert.equal(
      await row("primary").count(),
      0,
      "collapsed descendants are hidden",
    );
    await search.fill("  PRIMARY ACTION  ");
    assert.equal(
      await row("primary").count(),
      1,
      "case-insensitive leaf-label search reveals collapsed descendant",
    );
    assert.equal(
      await row("secondary").count(),
      0,
      "non-matching leaf is excluded",
    );
    assert(
      await search.evaluate((el) => el.ownerDocument.activeElement === el),
      "filtering preserves input focus",
    );
    assert.equal(
      await row(root.id).count(),
      1,
      "matching leaf retains its real ancestor path",
    );
    assert.equal(
      await row(root.id).getAttribute("aria-expanded"),
      "true",
      "search visibly reveals the ancestor",
    );
    assert.equal(
      await row("primary").getAttribute("aria-expanded"),
      null,
      "leaf has no expansion state",
    );
    await search.press("Tab");
    assert(
      await row(root.id).evaluate(
        (el) => el.ownerDocument.activeElement === el,
      ),
      "Tab reaches the first displayed ancestor without a redundant scrollport stop",
    );
    await layersPage.keyboard.press("ArrowRight");
    assert(
      await row("primary").evaluate(
        (el) => el.ownerDocument.activeElement === el,
      ),
      "Right navigates to the revealed matching child",
    );
    await layersPage.keyboard.press("Shift+Tab");
    assert(
      await row(root.id).evaluate(
        (el) => el.ownerDocument.activeElement === el,
      ),
      "reverse Tab visits the displayed ancestor",
    );
    await layersPage.keyboard.press("Shift+Tab");
    assert(
      await search.evaluate((el) => el.ownerDocument.activeElement === el),
      "keyboard returns to Layers search",
    );
    assert.deepEqual(
      await search.evaluate((el) => {
        const css = getComputedStyle(
          el.closest('[data-sidebar-search-field="layers"]'),
        );
        return [css.outlineStyle, css.outlineWidth, css.outlineColor];
      }),
      ["solid", "2px", "rgb(59, 130, 246)"],
      "keyboard focus paints the shared bounded search field border",
    );
    assert.equal(
      JSON.parse(
        await layersPage.evaluate(() => window.__chatTest.controlState()),
      ).selection,
      initial.selection,
      "typing does not mutate selection",
    );
    await search.fill("button");
    assert.equal(await row("primary").count(), 1);
    assert.equal(
      await row("secondary").count(),
      1,
      "tag search includes both buttons",
    );
    await search.fill("no-such-layer");
    assert.equal(await layers.locator("[data-scene-graph-row]").count(), 0);
    assert(
      await layers.getByText("No matching layers", { exact: true }).isVisible(),
    );
    assert(await search.isVisible(), "empty results retain search");
    await search.fill("");
    assert.equal(await row(root.id).count(), 1);
    assert.equal(
      await row("primary").count(),
      0,
      "clearing preserves the previous collapsed state",
    );
    await row(root.id).focus();
    await layersPage.keyboard.press("ArrowRight");
    assert.equal(
      await row("primary").count(),
      1,
      "Right expands a saved collapsed ancestor",
    );
    assert.equal(await row(root.id).getAttribute("aria-expanded"), "true");
    await layersPage.keyboard.press("ArrowLeft");
    assert.equal(
      await row("primary").count(),
      0,
      "Left collapses without selecting",
    );
    assert.equal(
      JSON.parse(
        await layersPage.evaluate(() => window.__chatTest.controlState()),
      ).selection,
      initial.selection,
    );
    await layersPage.keyboard.press("ArrowRight");
    await layersPage.keyboard.press("ArrowDown");
    const firstChild = initial.elements.find(
      (item) => item.parentId === root.id,
    );
    assert(
      firstChild && firstChild.id !== "primary",
      "real heading precedes the primary action",
    );
    assert(
      await row(firstChild.id).evaluate(
        (el) => el.ownerDocument.activeElement === el,
      ),
      "Down visits the actual first displayed child",
    );
    await layersPage.keyboard.press("ArrowDown");
    assert(
      await row("primary").evaluate(
        (el) => el.ownerDocument.activeElement === el,
      ),
      "Down next visits the actual primary action",
    );
    await layersPage.keyboard.press("Enter");
    assert.equal(
      JSON.parse(
        await layersPage.evaluate(() => window.__chatTest.controlState()),
      ).selection,
      "primary",
      "Enter selects the real matching layer",
    );
    assert(
      await row("primary").evaluate(
        (el) => el.ownerDocument.activeElement === el,
      ),
      "activation retains focus after the row rebuild",
    );
    await layersPage.keyboard.press("ArrowDown");
    assert(
      await row("secondary").evaluate(
        (el) => el.ownerDocument.activeElement === el,
      ),
    );
    await layersPage.keyboard.press("Space");
    assert.equal(
      JSON.parse(
        await layersPage.evaluate(() => window.__chatTest.controlState()),
      ).selection,
      "secondary",
      "Space selects a distinct actual layer",
    );
    await row("primary").evaluate((el) =>
      el.addEventListener(
        "click",
        () => document.querySelector("[data-layer-search]").focus(),
        { once: true },
      ),
    );
    await row("primary").focus();
    await layersPage.keyboard.press("Enter");
    assert.equal(
      JSON.parse(
        await layersPage.evaluate(() => window.__chatTest.controlState()),
      ).selection,
      "primary",
    );
    assert(
      await search.evaluate((el) => el.ownerDocument.activeElement === el),
      "activation preserves an explicitly changed user focus",
    );
    await layersPage.waitForTimeout(50);
    assert(
      await search.evaluate((el) => el.ownerDocument.activeElement === el),
      "no deferred fallback steals newer focus",
    );

    await layersPage
      .getByRole("textbox", { name: "Search stories", exact: true })
      .fill("Home");
    await search.fill("secondary");
    assert.equal(await row("secondary").count(), 1);
    assert.equal(
      await layersPage
        .getByRole("textbox", { name: "Search stories", exact: true })
        .inputValue(),
      "Home",
      "layer filtering preserves storyboard query",
    );
    await search.fill("");
    await layersPage.close();
    record(`Layers header search through real preview hierarchy at ${width}`);
  }
  // Real mounted hidden/visible documents have the same element IDs. Commands
  // must affect the visible production page, without touching the retained hidden
  // document; this is the negative control for URL-order frame selection.
  for (const [width, panelWidth] of [
    [1440, 420],
    [1024, 240],
  ]) {
    const previewPage = await browser.newPage({
      viewport: { width, height: 900 },
    });
    await previewPage.goto(origin);
    await previewPage.waitForFunction(() => window.__chatTest);
    await previewPage.evaluate((value) => {
      window.__chatTest.width(value);
      window.__chatTest.localApprovals(true);
    }, panelWidth);
    await previewPage
      .getByRole("checkbox", { name: "Require approval for agent navigation" })
      .uncheck();
    await mountedReady(previewPage, `visible-preview-${width}`);
    const visible = previewPage.locator(
      'iframe[data-page-project-frame="true"]:visible',
    );
    assert.equal(await visible.count(), 1);
    const visibleElement = await visible.elementHandle();
    const visibleFrame = await visibleElement.contentFrame();
    assert(visibleFrame);
    const hiddenFrame = previewPage
      .frames()
      .find(
        (frame) =>
          frame !== previewPage.mainFrame() && frame.url() === "about:srcdoc",
      );
    assert(
      hiddenFrame && hiddenFrame !== visibleFrame,
      "old first-srcdoc selection identifies another document",
    );
    const hiddenElement = await hiddenFrame.frameElement();
    assert.equal(
      await hiddenElement.isVisible(),
      false,
      "retained duplicate document is hidden",
    );
    const hiddenPrimary = hiddenFrame.locator(
      '[data-isonim-element-id="primary"]',
    );
    assert.equal(await hiddenPrimary.count(), 1);
    for (const [command, target, focus] of [
      ["select", "primary", true],
      ["highlight", "secondary", false],
    ]) {
      const before = JSON.parse(
        await previewPage.evaluate(() => window.__chatTest.controlState()),
      );
      const result = JSON.parse(
        await previewPage.evaluate(
          (request) => window.__chatTest.control(JSON.stringify(request)),
          {
            commandId: `visible-${width}-${command}`,
            command,
            target,
            focus,
            highlight: true,
          },
        ),
      );
      assert.equal(result.status, "applied");
      const node = visibleFrame.locator(`[data-isonim-element-id="${target}"]`);
      assert.equal(
        await node.getAttribute("data-editor-agent-highlight"),
        "true",
      );
      assert.equal(
        await node.evaluate((el) => getComputedStyle(el).outlineWidth),
        "2px",
      );
      const after = JSON.parse(
        await previewPage.evaluate(() => window.__chatTest.controlState()),
      );
      if (command === "select") {
        assert(
          await node.evaluate((el) => el.ownerDocument.activeElement === el),
        );
        assert.equal(after.selection, "primary");
      } else {
        assert.equal(
          after.selection,
          before.selection,
          "highlight alone preserves existing primary selection",
        );
        assert(
          await visibleFrame
            .locator('[data-isonim-element-id="primary"]')
            .evaluate((el) => el.ownerDocument.activeElement === el),
          "highlight alone preserves focus",
        );
      }
      assert.equal(after.highlight, target);
      assert.equal(
        await hiddenFrame
          .locator(`[data-isonim-element-id="${target}"]`)
          .getAttribute("data-editor-agent-highlight"),
        null,
        "hidden duplicate remains untouched",
      );
      assert.equal(
        await hiddenPrimary.evaluate(
          (el) => el.ownerDocument.activeElement === el,
        ),
        false,
      );
    }
    await previewPage.close();
    record(
      `visible production preview identity and hidden negative at ${width}`,
    );
  }
  // Read the actual mounted colors and real shared control admission. The
  // existing local transport fixture supplies connection timing only; keyboard,
  // focus paint, revision guards and DOM remain production implementations.
  for (const [width, height, rail] of [
    [1440, 900, 420],
    [1024, 768, 240],
  ]) {
    const designPage = await browser.newPage({ viewport: { width, height } });
    await designPage.goto(origin);
    await designPage.waitForFunction(() => window.__chatTest);
    await designPage.evaluate((rail) => {
      window.__chatTest.width(rail);
      window.__chatTest.localApprovals(true);
    }, rail);
    await mountedReady(designPage, `navigation-design-${width}`);
    const approval = designPage.getByRole("checkbox", {
      name: "Require approval for agent navigation",
      exact: true,
    });
    const help = designPage.locator(
      '[data-editor-control-approval-help="true"]',
    );
    const manual = designPage.getByText(
      "Manual Edit mode opens the source-backed inspector in this same sidebar space.",
      { exact: true },
    );
    const hint = designPage.getByText("tap to insert", { exact: true });
    assert.equal(
      await help.innerText(),
      "Turn off to let the agent focus, select, and highlight items automatically.",
    );
    assert.equal(
      await approval.getAttribute("aria-describedby"),
      await help.getAttribute("id"),
    );
    async function readable(node) {
      assert(await node.isVisible());
      const colors = await node.evaluate((el) => {
        const css = getComputedStyle(el),
          box = el.getBoundingClientRect();
        let background = el;
        while (
          background &&
          getComputedStyle(background).backgroundColor === "rgba(0, 0, 0, 0)"
        )
          background = background.parentElement;
        const rgb = (value) =>
          (value.match(/[\d.]+/g) || []).slice(0, 3).map(Number);
        const lum = (values) =>
          values
            .map((v) => {
              v /= 255;
              return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
            })
            .reduce((sum, v, i) => sum + v * [0.2126, 0.7152, 0.0722][i], 0);
        const foreground = css.color,
          bg = getComputedStyle(background).backgroundColor,
          a = lum(rgb(foreground)),
          b = lum(rgb(bg));
        return {
          foreground,
          background: bg,
          contrast: (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05),
          fontSize: css.fontSize,
          opacity: css.opacity,
          inside:
            box.width > 0 &&
            box.height > 0 &&
            box.left >= 0 &&
            box.top >= 0 &&
            box.right <= innerWidth &&
            box.bottom <= innerHeight,
        };
      });
      assert(colors.inside, JSON.stringify(colors));
      assert.equal(colors.opacity, "1");
      assert(colors.contrast >= 4.5, JSON.stringify(colors));
      return colors;
    }
    const contrast = {
      manual: await readable(manual),
      hint: await readable(hint),
      support: await readable(help),
    };
    const search = designPage.locator('[data-sidebar-search="true"]');
    const composer = designPage.getByRole("textbox", { name: "Agent prompt" });
    await composer.fill("Retained draft while agent navigates");
    await composer.focus();
    await approval.check();
    assert(await approval.isChecked());
    assert.equal(await approval.getAttribute("aria-checked"), "true");
    await composer.focus();
    const before = JSON.parse(
      await designPage.evaluate(() => window.__chatTest.controlState()),
    );
    const pending = JSON.parse(
      await designPage.evaluate(
        (id) =>
          window.__chatTest.control(
            JSON.stringify({
              commandId: id,
              command: "focus",
              target: "sidebar-search",
            }),
          ),
        `design-pending-${width}`,
      ),
    );
    assert.equal(pending.status, "pending");
    assert(await composer.evaluate((el) => document.activeElement === el));
    const waiting = JSON.parse(
      await designPage.evaluate(() => window.__chatTest.controlState()),
    );
    assert.equal(waiting.focus, before.focus);
    assert.equal(waiting.selection, before.selection);
    assert.equal(waiting.highlight, before.highlight);
    await designPage
      .locator(`[data-editor-control-reject="design-pending-${width}"]`)
      .click();
    assert.equal(
      await designPage
        .locator(`[data-editor-control-operation="design-pending-${width}"]`)
        .getAttribute("data-operation-status"),
      "rejected",
    );
    assert.equal(
      JSON.parse(
        await designPage.evaluate(() => window.__chatTest.controlState()),
      ).focus,
      before.focus,
    );
    await approval.uncheck();
    assert.equal(await approval.isChecked(), false);
    assert.equal(await approval.getAttribute("aria-checked"), "false");
    const applied = JSON.parse(
      await designPage.evaluate(
        (id) =>
          window.__chatTest.control(
            JSON.stringify({
              commandId: id,
              command: "focus",
              target: "sidebar-search",
            }),
          ),
        `design-focus-${width}`,
      ),
    );
    assert.equal(applied.status, "applied");
    const rpcFocus = requireSidebarSearchFocus(
      await designPage.evaluate(sidebarSearchFocusEvidence),
    );
    const field = await designPage
      .locator('[data-sidebar-search-field="true"]')
      .elementHandle();
    const original = await field.getAttribute("style");
    let missingRing;
    try {
      await field.evaluate((el) =>
        el.style.setProperty("outline", "none", "important"),
      );
      missingRing = await designPage.evaluate(sidebarSearchFocusEvidence);
      assert.equal(missingRing.active, true);
      assert.throws(
        () => requireSidebarSearchFocus(missingRing),
        /visible sidebar search focus ring/,
      );
    } finally {
      await field.evaluate((el, value) => {
        if (value === null) el.removeAttribute("style");
        else el.setAttribute("style", value);
      }, original);
      await field.dispose();
    }
    requireSidebarSearchFocus(
      await designPage.evaluate(sidebarSearchFocusEvidence),
    );
    await search.press("Tab");
    const blurred = await designPage.evaluate(sidebarSearchFocusEvidence);
    assert.equal(blurred.active, false);
    assert.equal(blurred.outlineStyle, "none");
    await designPage.keyboard.press("Shift+Tab");
    const keyboardFocus = requireSidebarSearchFocus(
      await designPage.evaluate(sidebarSearchFocusEvidence),
    );
    assert.equal(
      await composer.inputValue(),
      "Retained draft while agent navigates",
    );
    const after = JSON.parse(
      await designPage.evaluate(() => window.__chatTest.controlState()),
    );
    assert.equal(after.selection, before.selection);
    assert.equal(after.highlight, before.highlight);
    writeFileSync(
      path.join(artifacts, `navigation-focus-intro-${width}.json`),
      JSON.stringify(
        {
          contrast,
          pending,
          applied,
          rpcFocus,
          missingRing,
          blurred,
          keyboardFocus,
        },
        null,
        2,
      ),
    );
    await designPage.close();
    record(
      `navigation preference semantics, RPC and keyboard focus paint, blur and readable guidance at ${width}`,
    );
  }
  // Genuine controller outcomes begin with a collapsed Pages tree. No fixture
  // pre-expansion: only a successfully applied open-story may reveal Details.
  for (const [width, height, rail] of [
    [1440, 900, 420],
    [1024, 768, 240],
  ]) {
    const nav = await browser.newPage({ viewport: { width, height } });
    await nav.goto(origin);
    await nav.waitForFunction(() => window.__chatTest);
    await nav.evaluate((rail) => {
      window.__chatTest.width(rail);
      window.__chatTest.localApprovals(true);
    }, rail);
    await mountedReady(nav, `navigation-outcomes-${width}`);
    const composer = nav.getByRole("textbox", { name: "Agent prompt" });
    await composer.fill("Keep my draft through navigation");
    const preference = nav.getByRole("checkbox", {
      name: "Require approval for agent navigation",
      exact: true,
    });
    await preference.check();
    const before = JSON.parse(
      await nav.evaluate(() => window.__chatTest.controlState()),
    );
    const details = nav.locator('[data-story-row="Pages/Details"]');
    assert.equal(
      await details.isVisible(),
      false,
      "actual initial collapsed Pages hides destination",
    );
    const command = async (request) =>
      JSON.parse(
        await nav.evaluate(
          (request) => window.__chatTest.control(JSON.stringify(request)),
          request,
        ),
      );
    const destination = before.stories.find(
      (story) => story.name === "Details",
    ).id;
    const search = nav.getByRole("textbox", {
      name: "Search stories",
      exact: true,
    });
    await search.fill("Home");
    await search.press("End");
    assert(
      await search.evaluate(
        (el) =>
          document.activeElement === el &&
          el.selectionStart === 4 &&
          el.selectionEnd === 4,
      ),
      "ordinary search typing preserves caret and focus",
    );
    const pending = await command({
      commandId: `outcomes-reject-${width}`,
      command: "open-story",
      storyId: destination,
    });
    assert.equal(pending.status, "pending");
    assert.equal(await details.isVisible(), false);
    assert.equal(await search.inputValue(), "Home");
    const actions = nav.locator(
      `[data-editor-control-actions="outcomes-reject-${width}"]`,
    );
    const approve = actions.getByRole("button", {
      name: "Approve",
      exact: true,
    });
    const reject = actions.getByRole("button", { name: "Reject", exact: true });
    const geometry = await actions.evaluate((el) => {
      const group = el.getBoundingClientRect();
      return [...el.querySelectorAll("button")].map((button) => {
        const rect = button.getBoundingClientRect(),
          css = getComputedStyle(button);
        return {
          width: rect.width,
          height: rect.height,
          top: rect.top,
          inside: rect.left >= group.left && rect.right <= group.right,
          background: css.backgroundColor,
          color: css.color,
          fontSize: css.fontSize,
        };
      });
    });
    assert.equal(geometry.length, 2);
    assert.equal(geometry[0].top, geometry[1].top);
    for (const box of geometry) {
      assert(
        box.height >= 32 && box.width >= 60 && box.inside,
        JSON.stringify(geometry),
      );
      assert.equal(box.fontSize, "12px");
      assert.notEqual(box.background, "rgb(239, 239, 239)");
    }
    await approve.focus();
    await nav.keyboard.press("Tab");
    assert(await reject.evaluate((el) => document.activeElement === el));
    await nav.keyboard.press("Enter");
    assert.equal(
      await nav
        .locator(`[data-editor-control-operation="outcomes-reject-${width}"]`)
        .getAttribute("data-operation-status"),
      "rejected",
    );
    assert.equal(await details.isVisible(), false);
    assert.equal(await search.inputValue(), "Home");
    assert.equal(
      JSON.parse(await nav.evaluate(() => window.__chatTest.controlState()))
        .storyId,
      before.storyId,
    );
    assert.equal(
      (
        await command({
          commandId: `outcomes-stale-${width}`,
          command: "open-story",
          storyId: destination,
        })
      ).status,
      "pending",
    );
    assert.equal(
      (
        await command({
          commandId: `outcomes-viewport-${width}`,
          command: "viewport",
          viewport: "tablet",
        })
      ).status,
      "pending",
    );
    await nav
      .locator(`[data-editor-control-approve="outcomes-viewport-${width}"]`)
      .click();
    await nav
      .locator(`[data-editor-control-approve="outcomes-stale-${width}"]`)
      .click();
    const failed = nav.locator(
      `[data-editor-control-operation="outcomes-stale-${width}"]`,
    );
    assert.equal(await failed.getAttribute("data-operation-status"), "failed");
    assert.equal(
      await failed
        .locator('[data-editor-control-failure="revision_conflict"]')
        .innerText(),
      "The editor changed after this request. Ask the agent to make a fresh request.",
    );
    assert.equal(await details.isVisible(), false);
    assert.equal(await search.inputValue(), "Home");
    assert.equal(
      JSON.parse(await nav.evaluate(() => window.__chatTest.controlState()))
        .storyId,
      before.storyId,
    );
    assert.equal(
      (
        await command({
          commandId: `outcomes-approve-${width}`,
          command: "open-story",
          storyId: destination,
        })
      ).status,
      "pending",
    );
    await nav
      .locator(`[data-editor-control-approve="outcomes-approve-${width}"]`)
      .focus();
    await nav.keyboard.press("Enter");
    await details.waitFor({ state: "visible" });
    assert.equal(await details.getAttribute("aria-current"), "true");
    const visibleDestination = await details.evaluate((el) => {
      const row = el.getBoundingClientRect(),
        sidebar = el.closest("[data-editor-sidebar]").getBoundingClientRect();
      return {
        inside:
          row.width > 0 &&
          row.height > 0 &&
          row.left >= sidebar.left &&
          row.right <= sidebar.right &&
          row.top >= sidebar.top &&
          row.bottom <= sidebar.bottom,
      };
    });
    assert(
      visibleDestination.inside,
      "selected destination is inside the actual sidebar clip",
    );
    const state = JSON.parse(
      await nav.evaluate(() => window.__chatTest.controlState()),
    );
    assert.equal(state.storyId, destination);
    assert.equal(
      await composer.inputValue(),
      "Keep my draft through navigation",
    );
    assert.equal(state.selection, before.selection);
    assert.equal(state.highlight, before.highlight);
    await preference.uncheck();
    await nav
      .getByRole("button", { name: "Toggle Pages section", exact: true })
      .click();
    assert.equal(
      await details.isVisible(),
      false,
      "ordinary user collapse stays collapsed",
    );
    await search.fill("Home");
    assert.equal(await search.inputValue(), "Home");
    assert.equal(await details.isVisible(), false);
    await composer.focus();
    const automatic = await command({
      commandId: `outcomes-auto-${width}`,
      command: "open-story",
      storyId: destination,
    });
    assert.equal(automatic.status, "applied");
    assert.equal(await search.inputValue(), "");
    await details.waitFor({ state: "visible" });
    assert.equal(await details.getAttribute("aria-current"), "true");
    assert(
      await composer.evaluate((el) => document.activeElement === el),
      "automatic reveal preserves composer focus",
    );
    await search.fill("Details");
    await composer.focus();
    assert.equal(
      (
        await command({
          commandId: `matching-filter-${width}`,
          command: "open-story",
          storyId: destination,
        })
      ).status,
      "applied",
    );
    assert.equal(
      await search.inputValue(),
      "Details",
      "matching filter remains displayed",
    );
    assert(await composer.evaluate((el) => document.activeElement === el));
    await search.fill("");
    const lifecycle = await nav.evaluate(async (width) => {
      const calls = [],
        original = Element.prototype.scrollIntoView;
      Element.prototype.scrollIntoView = function (...args) {
        calls.push(this.getAttribute("data-story-row"));
        return original.apply(this, args);
      };
      const command = (id, name) => {
        const state = JSON.parse(window.__chatTest.controlState());
        return JSON.parse(
          window.__chatTest.control(
            JSON.stringify({
              commandId: id,
              command: "open-story",
              storyId: state.stories.find((s) => s.name === name).id,
            }),
          ),
        );
      };
      try {
        const a = command(`race-details-${width}`, "Details"),
          b = command(`race-home-${width}`, "Home");
        await Promise.resolve();
        const newerSelection = [...calls];
        calls.length = 0;
        const detached = command(`race-detach-${width}`, "Details");
        const shell = document.querySelector("[data-shell-row]").parentElement;
        shell.remove();
        await Promise.resolve();
        const unmounted = [...calls];
        calls.length = 0;
        window.dispatchEvent(new Event("pagehide"));
        window.__chatTest.repeatStoryReveal();
        document.body.appendChild(shell);
        await Promise.resolve();
        return {
          a,
          b,
          detached,
          newerSelection,
          unmounted,
          disposed: [...calls],
        };
      } finally {
        Element.prototype.scrollIntoView = original;
      }
    }, width);
    assert.equal(lifecycle.a.status, "applied");
    assert.equal(lifecycle.b.status, "applied");
    assert.equal(lifecycle.detached.status, "applied");
    assert.deepEqual(lifecycle.newerSelection, ["Pages/Home"]);
    assert.deepEqual(lifecycle.unmounted, []);
    assert.deepEqual(lifecycle.disposed, []);
    await nav.reload();
    await nav.waitForFunction(() => window.__chatTest);
    await mountedReady(nav, `navigation-remount-${width}`);
    await nav.evaluate(() => window.__chatTest.localApprovals(true));
    assert.equal(
      (
        await command({
          commandId: `remount-${width}`,
          command: "open-story",
          storyId: destination,
        })
      ).status,
      "applied",
    );
    await nav
      .locator('[data-story-row="Pages/Details"]')
      .waitFor({ state: "visible" });
    writeFileSync(
      path.join(artifacts, `navigation-outcomes-${width}.json`),
      JSON.stringify(
        { before, pending, geometry, state, automatic, lifecycle },
        null,
        2,
      ),
    );
    await nav.close();
    record(
      `real navigation approval, rejection, stale reason, keyboard actions and visible destination at ${width}`,
    );
  }
  // Actual production toolbar, sized by the available preview column rather
  // than the browser width. All backend/mode affordances remain reachable.
  const toolbarPage = await browser.newPage({
    viewport: { width: 1440, height: 900 },
  });
  await toolbarPage.goto(origin);
  await toolbarPage.waitForFunction(() => window.__chatTest);
  async function toolbarGeometry() {
    return toolbarPage.evaluate(() => {
      const bar = document.querySelector("[data-preview-chrome-bar]");
      const b = bar.getBoundingClientRect();
      const controls = Array.from(
        bar.querySelectorAll('[role="button"]'),
      ).filter((el) => el.getClientRects().length);
      return {
        height: b.height,
        width: b.width,
        scrollWidth: bar.scrollWidth,
        controls: controls.map((el) => {
          const r = el.getBoundingClientRect();
          return {
            label: el.getAttribute("aria-label") || el.title,
            width: r.width,
            height: r.height,
            inside:
              r.width > 0 &&
              r.height > 0 &&
              r.left >= b.left &&
              r.right <= b.right &&
              r.top >= b.top &&
              r.bottom <= b.bottom,
            hit: el.contains(
              document.elementFromPoint(
                r.left + r.width / 2,
                r.top + r.height / 2,
              ),
            ),
          };
        }),
      };
    });
  }
  async function settleToolbar() {
    await toolbarPage.evaluate(async () => {
      await document.fonts.ready;
      await new Promise((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(resolve)),
      );
    });
  }
  const bar = toolbarPage.locator("[data-preview-chrome-bar]");
  const overflow = bar.locator("[data-preview-viewport-overflow]");
  const pinned = bar.locator("[data-preview-viewport-strip-host]");
  for (const [width, height, rail] of [
    [1440, 900, 420],
    [1024, 768, 240],
  ]) {
    await toolbarPage.setViewportSize({ width, height });
    await toolbarPage.evaluate((rail) => window.__chatTest.width(rail), rail);
    await settleToolbar();
    const compact = width === 1024;
    assert.equal(await pinned.isVisible(), !compact);
    const geometry = await toolbarGeometry();
    assert.equal(geometry.height, 44);
    assert(geometry.scrollWidth <= geometry.width, JSON.stringify(geometry));
    assert(
      geometry.controls.every((row) => row.inside && row.hit),
      JSON.stringify(geometry),
    );
    // Full set still exists; compacting does not remove backend/Mode choices.
    assert.deepEqual(
      await bar
        .locator('[data-toolbar-cluster="backend"] [data-choice-group-label]')
        .evaluateAll((nodes) =>
          nodes.map((n) => n.getAttribute("data-choice-group-label")),
        ),
      ["Web", "TUI", "GPUI", "Freya", "Cocoa", "Android", "iOS"],
    );
    assert.deepEqual(
      await bar
        .locator('[data-toolbar-cluster="mode"] [data-choice-group-label]')
        .evaluateAll((nodes) =>
          nodes.map((n) => n.getAttribute("data-choice-group-label")),
        ),
      ["Spec", "View", "Comment", "Edit"],
    );
    for (const slug of ["desktop", "laptop", "tablet", "phone"]) {
      if (compact) {
        await overflow.click();
        const option = bar.locator(
          `[data-preview-viewport-dropdown-option="${slug}"]`,
        );
        assert(await option.isVisible());
        await option.click();
        assert.equal(await overflow.getAttribute("aria-expanded"), "false");
      } else {
        await pinned
          .locator(
            `[data-choice-group-label="${slug[0].toUpperCase() + slug.slice(1)}"]`,
          )
          .click();
      }
      assert.equal(
        JSON.parse(
          await toolbarPage.evaluate(() => window.__chatTest.controlState()),
        ).viewport,
        slug,
      );
      if (compact)
        assert.equal(
          await bar.locator("[data-preview-viewport-current]").innerText(),
          slug[0].toUpperCase() + slug.slice(1),
        );
    }
    await overflow.click();
    const options = bar.locator(
      "[data-preview-viewport-dropdown-option]:visible",
    );
    const slugs = await options.evaluateAll((nodes) =>
      nodes.map((n) => n.getAttribute("data-preview-viewport-dropdown-option")),
    );
    assert(slugs.length > 0);
    assert.equal(slugs.includes("desktop"), compact);
    for (const slug of slugs) {
      await bar
        .locator(`[data-preview-viewport-dropdown-option="${slug}"]`)
        .click();
      assert.equal(
        JSON.parse(
          await toolbarPage.evaluate(() => window.__chatTest.controlState()),
        ).viewport,
        slug,
      );
      const selectedGeometry = await toolbarGeometry();
      assert(
        selectedGeometry.controls.every((row) => row.inside && row.hit),
        JSON.stringify({ slug, selectedGeometry }),
      );
      assert(
        selectedGeometry.scrollWidth <= selectedGeometry.width,
        JSON.stringify({ slug, selectedGeometry }),
      );
      await overflow.click();
    }
    await toolbarPage.keyboard.press("Escape");
    assert(
      await overflow.evaluate((el) => el.ownerDocument.activeElement === el),
    );
    await toolbarPage.keyboard.press("Enter");
    assert(
      await options
        .first()
        .evaluate((el) => el.ownerDocument.activeElement === el),
      "keyboard opening focuses first VISIBLE option",
    );
    const firstSlug = await options
      .first()
      .getAttribute("data-preview-viewport-dropdown-option");
    await toolbarPage.keyboard.press("ArrowDown");
    await toolbarPage.keyboard.press("ArrowUp");
    await toolbarPage.keyboard.press("Enter");
    assert.equal(
      JSON.parse(
        await toolbarPage.evaluate(() => window.__chatTest.controlState()),
      ).viewport,
      firstSlug,
    );
    assert.equal(await overflow.getAttribute("aria-expanded"), "false");
    const modes = bar.locator('[data-toolbar-cluster="mode"]');
    await modes.getByRole("button", { name: "Spec", exact: true }).click();
    assert.equal(
      JSON.parse(
        await toolbarPage.evaluate(() => window.__chatTest.controlState()),
      ).mode,
      "emSpec",
    );
    await modes.getByRole("button", { name: "View", exact: true }).click();
    assert.equal(
      JSON.parse(
        await toolbarPage.evaluate(() => window.__chatTest.controlState()),
      ).mode,
      "emView",
    );
    await settleToolbar();
    writeFileSync(
      path.join(artifacts, `preview-toolbar-${width}.json`),
      JSON.stringify({ geometry, slugs, firstSlug }, null, 2),
    );
    await toolbarPage.screenshot({
      path: path.join(artifacts, `preview-toolbar-${width}.png`),
    });
    record(
      `production toolbar visible viewport choices, keyboard and mode behavior at ${width}`,
    );
  }
  // Original full controls are retained in production. Removing the container
  // query at the real narrow column reproduces clipping, without a fake widget.
  await toolbarPage
    .locator("[data-preview-center-column]")
    .evaluate((el) => (el.style.containerType = "normal"));
  await settleToolbar();
  const oldGeometry = await toolbarGeometry();
  assert(
    oldGeometry.controls.some((row) => !row.inside),
    JSON.stringify(oldGeometry),
  );
  assert(oldGeometry.scrollWidth > oldGeometry.width);
  await toolbarPage
    .locator("[data-preview-center-column]")
    .evaluate((el) => el.style.removeProperty("container-type"));
  await settleToolbar();
  const restoredGeometry = await toolbarGeometry();
  assert(
    restoredGeometry.controls.every((row) => row.inside && row.hit),
    JSON.stringify(restoredGeometry),
  );
  writeFileSync(
    path.join(artifacts, "preview-toolbar-negative.json"),
    JSON.stringify({ oldGeometry, restoredGeometry }, null, 2),
  );
  // Resize reversibility: the original wide strip and popup-only menu return.
  await toolbarPage.setViewportSize({ width: 1440, height: 900 });
  await toolbarPage.evaluate(() => window.__chatTest.width(420));
  await settleToolbar();
  assert(await pinned.isVisible());
  await overflow.click();
  assert.equal(
    await bar
      .locator('[data-preview-viewport-dropdown-option="desktop"]')
      .isVisible(),
    false,
  );
  await toolbarPage.close();
  record("toolbar clipping negative control and resize restoration");
  await page.goto(origin);
  await page.waitForFunction(() => window.__chatTest);
  const input = page.getByRole("textbox", { name: "Agent prompt" });
  const event = (payload) =>
    page.evaluate(
      (value) => window.__chatTest.event(JSON.stringify(value)),
      payload,
    );
  const setBusy = (value) =>
    page.evaluate((value) => window.__chatTest.busy(value), value);
  const frames = () =>
    page.evaluate(
      () =>
        new Promise((resolve) =>
          requestAnimationFrame(() => requestAnimationFrame(resolve)),
        ),
    );
  const captureEvidence = [];
  async function visibleText(locator, text) {
    await locator.waitFor({ state: "visible" });
    await page.waitForFunction(
      ({ selector, text }) => {
        const element = document.querySelector(selector);
        if (!element) return false;
        const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
        let node;
        while ((node = walker.nextNode())) {
          const index = node.textContent.indexOf(text);
          if (index < 0) continue;
          const range = document.createRange();
          range.setStart(node, index);
          range.setEnd(node, index + text.length);
          const box = range.getBoundingClientRect();
          const scroll = element.closest("[data-chat-scroll]");
          const bounds = scroll?.getBoundingClientRect() ?? {
            top: 0,
            bottom: innerHeight,
            left: 0,
            right: innerWidth,
          };
          if (
            box.width > 0 &&
            box.height > 0 &&
            box.top >= bounds.top &&
            box.bottom <= bounds.bottom &&
            box.left >= bounds.left &&
            box.right <= bounds.right
          )
            return true;
        }
        return false;
      },
      {
        selector: await locator.evaluate((el) => {
          const id = "capture-" + Math.random().toString(36).slice(2);
          el.setAttribute("data-capture-anchor", id);
          return `[data-capture-anchor="${id}"]`;
        }),
        text,
      },
      { timeout: 5000 },
    );
  }
  async function followLatest() {
    const latest = page.locator("[data-chat-latest]");
    if (await latest.isVisible()) await latest.click();
    else
      await page.locator("[data-chat-scroll]").evaluate((el) => {
        el.scrollTop = el.scrollHeight;
        el.dispatchEvent(new Event("scroll"));
      });
    await page.waitForFunction(() => {
      const el = document.querySelector("[data-chat-scroll]");
      return el.scrollHeight - el.scrollTop - el.clientHeight <= 24;
    });
    await frames();
  }
  const shot = async (name, width = 420) => {
    await page.evaluate((value) => window.__chatTest.width(value), width);
    await page.waitForFunction(
      (width) =>
        Math.abs(
          document.querySelector(".editor-chat").getBoundingClientRect().width -
            width,
        ) < 30,
      width,
    );
    await frames();
    await horizontalChatGuard(page);
    if (name === "tool-heavy") {
      await page
        .locator('[data-chat-kind="tool_call"]')
        .evaluate((el) => el.scrollIntoView({ block: "start" }));
      await frames();
      const tool = page.locator('[data-chat-kind="tool_call"]');
      assert.equal(await tool.locator("details").getAttribute("open"), "");
      await visibleText(tool, "Compile story");
      await visibleText(tool, "failed");
      await visibleText(tool, "Compiler failed");
      await visibleText(tool.locator("[data-chat-detail]"), '"story":"Hero"');
      await visibleText(
        tool.locator("[data-chat-detail]"),
        "detailed diagnostic",
      );
    } else if (name === "activity-details") {
      await followLatest();
      await visibleText(
        page.locator('[data-chat-kind="diff"]'),
        "Diff · stories.nim",
      );
      await visibleText(
        page.locator('[data-chat-kind="diff"] [data-chat-detail]'),
        "- old",
      );
      await visibleText(
        page.locator('[data-chat-kind="diff"] [data-chat-detail]'),
        "+ new",
      );
      await visibleText(
        page.locator('[data-chat-kind="plan"]'),
        "Build source",
      );
      await visibleText(page.locator('[data-chat-kind="plan"]'), "Open story");
      await visibleText(
        page.locator('[data-chat-kind="llm_request"] [data-chat-detail]'),
        "Reported model",
      );
      await visibleText(
        page.locator('[data-chat-kind="llm_request"] [data-chat-detail]'),
        "120 input / 30 output tokens",
      );
    } else if (name === "waiting") {
      await followLatest();
      const question = page
        .locator('[data-chat-kind="status"]')
        .filter({ hasText: "Which variant?" });
      await visibleText(question, "Which variant?");
      await visibleText(
        question.locator("[data-chat-availability]"),
        "This editor cannot answer this request.",
      );
      assert.equal(
        await question.locator("details").getAttribute("open"),
        null,
      );
      assert.equal(await question.locator("button").count(), 0);
    } else if (name === "error") {
      await followLatest();
      const failure = page.locator('[data-chat-kind="error"]').filter({
        hasText: "The source build failed. Your draft is preserved.",
      });
      assert.equal(await failure.count(), 1);
      await visibleText(
        failure,
        "The source build failed. Your draft is preserved.",
      );
      assert.equal(await input.inputValue(), "draft while streaming");
      assert.equal(
        await page
          .getByRole("button", { name: "Close conversation" })
          .isVisible(),
        true,
      );
    } else if (name === "long-history") {
      await followLatest();
      await visibleText(
        page.locator('[data-chat-kind="review"]').last(),
        "Review item 34",
      );
      await visibleText(
        page.locator('[data-chat-role="arAssistant"]').last(),
        "Actual new assistant chunk",
      );
      await visibleText(
        page.locator('[data-chat-kind="sub_agent"]'),
        "A new child result arrived",
      );
    } else if (name === "empty") {
      await page
        .getByRole("button", { name: "Insert suggested prompt" })
        .first()
        .waitFor({ state: "visible" });
      assert.equal(await input.inputValue(), "");
    } else if (name === "streaming") {
      await followLatest();
      await visibleText(
        page.locator('[data-chat-role="arUser"]').last(),
        "line one",
      );
      await visibleText(
        page.locator('[data-chat-role="arUser"]').last(),
        "line two",
      );
      await visibleText(
        page.locator('[data-chat-markdown="heading"]'),
        "Design update",
      );
      await visibleText(
        page.locator('[data-chat-markdown="list"]'),
        "Keep the preview usable",
      );
      await visibleText(
        page.locator('[data-chat-markdown="code"]'),
        'let safe = "<script>"',
      );
      assert.equal(await input.inputValue(), "draft while streaming");
      assert.equal(
        await page
          .getByRole("button", { name: "Send agent prompt" })
          .isDisabled(),
        true,
      );
    }
    await page.screenshot({
      path: path.join(artifacts, `${name}-${width}.png`),
    });
    captureEvidence.push({ name, width, visibleDOMAssertions: true });
    record(`visible required ${name} capture at ${width}`);
  };
  // Public producer DTOs exercise normalization and the actual mounted view.
  // Isolated pages keep each request visible without altering stream admission.
  const questionCorpus = JSON.parse(
    readFileSync(
      path.join(
        repo,
        "tests/scenarios/chat-activity/public-session-events.json",
      ),
    ),
  );
  for (const width of [420, 240])
    for (const name of [
      "question",
      "question-free-form",
      "question-multi-choice",
      "question-confirmation",
    ]) {
      const questionPage = await browser.newPage({
        viewport: {
          width: width === 420 ? 1440 : 1024,
          height: width === 420 ? 900 : 768,
        },
      });
      try {
        await questionPage.goto(origin);
        await questionPage.waitForFunction(() => window.__chatTest);
        await questionPage.evaluate(
          (value) => window.__chatTest.width(value),
          width,
        );
        await mountedReady(questionPage, `question-${name}-${width}`);
        await horizontalChatGuard(questionPage);
        if (width === 240 && name === "question") {
          const restored = await oldClippedChatControl(questionPage);
          writeFileSync(
            path.join(artifacts, "horizontal-clipping-control.json"),
            JSON.stringify(
              { oldClippedStateRejected: true, restored },
              null,
              2,
            ),
          );
          record(
            "same horizontal guard rejects original tablet clipping and accepts restored layout",
          );
        }
        const draft = questionPage.getByRole("textbox", {
          name: "Agent prompt",
        });
        await draft.fill("Retained next draft");
        const payload = questionCorpus.scenes[name][0];
        await questionPage.evaluate(
          (value) => window.__chatTest.harborEvent(JSON.stringify(value)),
          payload,
        );
        const card = questionPage.locator(
          '[data-chat-source="agent_question"]',
        );
        const notice = card.locator("[data-chat-availability]");
        assert.equal(
          await notice.innerText(),
          "This editor cannot answer this request.",
        );
        assert(
          await notice.isVisible(),
          "availability visible before expansion",
        );
        assert.equal(
          await notice.evaluate((el) => el.closest("details")),
          null,
        );
        assert.equal(await card.locator("details").getAttribute("open"), null);
        // Render effects synchronously insert the card, but the production chat
        // schedules follow-output in RAF. Wait through that callback and the next
        // frame after font layout, then retain the exact whole-notice bounds check.
        // Match the existing visible-text readiness budget; missing/stuck fonts
        // fail explicitly rather than leaving an unbounded document.fonts.ready.
        await questionPage.waitForFunction(
          () => document.fonts.status === "loaded",
          null,
          { timeout: 5000 },
        );
        const readiness = await questionPage.evaluate(async () => {
          const frameTimes = await new Promise((resolve) =>
            requestAnimationFrame((first) =>
              requestAnimationFrame((second) => resolve([first, second])),
            ),
          );
          const scroll = document.querySelector("[data-chat-scroll]");
          return {
            frameTimes,
            fontStatus: document.fonts.status,
            documentReadyState: document.readyState,
            scrollTop: scroll.scrollTop,
            scrollHeight: scroll.scrollHeight,
            clientHeight: scroll.clientHeight,
          };
        });
        const box = await notice.boundingBox();
        const bounds = await questionPage
          .locator("[data-chat-scroll]")
          .boundingBox();
        const geometry = { name, width, box, bounds, readiness };
        writeFileSync(
          path.join(artifacts, `question-layout-${name}-${width}.json`),
          JSON.stringify(geometry, null, 2),
        );
        assert(
          box &&
            bounds &&
            box.y >= bounds.y &&
            box.y + box.height <= bounds.y + bounds.height,
          `notice inside visible scroll area: ${JSON.stringify(geometry)}`,
        );
        assert((await card.innerText()).includes(payload.prompt));
        assert((await card.innerText()).includes(payload.request));
        assert((await card.innerText()).includes(payload.kind));
        for (const option of payload.options)
          assert((await card.innerText()).includes(option.label));
        assert.equal(
          await card.locator("button,input,textarea,select").count(),
          0,
        );
        assert.equal(await draft.inputValue(), "Retained next draft");
        await card.locator("summary").click();
        assert(await card.locator("[data-chat-detail]").isVisible());
        assert(
          (await card.locator("[data-chat-detail]").innerText()).includes(
            payload.request,
          ),
        );
        assert.equal(await draft.inputValue(), "Retained next draft");
        record(
          `visible unavailable ${payload.kind} request at ${width}, expandable payload and draft retained`,
        );
      } finally {
        await questionPage.close();
      }
    }
  await shot("empty");
  await shot("empty", 240);
  await page
    .getByRole("button", { name: "Insert suggested prompt" })
    .first()
    .click();
  assert((await input.inputValue()).length > 0);
  await page
    .getByRole("button", { name: "Insert suggested prompt" })
    .first()
    .waitFor({ state: "visible" });
  record("suggestion only edits draft");
  await page.evaluate(() => window.__chatTest.backend(false));
  await input.fill("retry draft");
  await page.getByRole("button", { name: "Send agent prompt" }).click();
  assert.equal(await input.inputValue(), "retry draft");
  await page
    .getByRole("button", { name: "Insert suggested prompt" })
    .first()
    .waitFor({ state: "hidden" });
  record("failed admission preserves draft and dismisses suggestions");
  await page.evaluate(() => window.__chatTest.backend(true));
  await input.fill("line one");
  await input.press("Shift+Enter");
  await input.press("End");
  await input.type("line two");
  assert.equal(await input.inputValue(), "line one\nline two");
  await input.dispatchEvent("compositionstart");
  await input.press("Enter");
  assert.equal(await page.locator('[data-chat-role="arUser"]').count(), 1);
  await input.dispatchEvent("compositionend");
  await input.press("Enter");
  await page.waitForFunction(
    () => document.querySelectorAll('[data-chat-role="arUser"]').length === 2,
  );
  assert.equal(await input.inputValue(), "");
  record("multiline and IME send guard");
  await setBusy(true);
  await input.fill("draft while streaming");
  assert.equal(
    await page.getByRole("button", { name: "Send agent prompt" }).isDisabled(),
    true,
  );
  await input.press("Enter");
  assert.equal(await input.inputValue(), "draft while streaming");
  await event({
    kind: "message_chunk",
    text: '# Design update\n- Keep the preview usable\n```nim\nlet safe = "<script>"\n```',
  });
  await page.locator('[data-chat-role="arAssistant"]').waitFor();
  await input.focus();
  await event({ kind: "message_chunk", text: "\nStreaming continues" });
  assert.equal(
    await input.evaluate((el) => document.activeElement === el),
    true,
  );
  assert.equal(await input.inputValue(), "draft while streaming");
  record("streaming draft and composer focus");
  assert.equal(
    await page.locator('[data-chat-markdown="heading"]').innerText(),
    "Design update",
  );
  assert.equal(await page.locator('[data-chat-markdown="list"]').count(), 1);
  assert(
    (await page.locator('[data-chat-markdown="code"]').innerText()).includes(
      "<script>",
    ),
  );
  assert.equal(await page.locator(".editor-chat script").count(), 0);
  record("safe Markdown lists and code");
  await page.locator('[data-chat-markdown="heading"]').evaluate((el) => {
    const range = document.createRange();
    range.selectNodeContents(el);
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
  });
  const selected = await page.evaluate(() => window.getSelection().toString());
  await event({ kind: "message_chunk", text: "\nMore output" });
  assert.equal(
    await page.evaluate(() => window.getSelection().toString()),
    selected,
  );
  record("stream updates preserve transcript selection");
  await shot("streaming");
  await shot("streaming", 240);
  await event({
    kind: "tool_call",
    toolCallId: "tool-1",
    toolName: "Compile story",
    status: "running",
    toolArguments: '{"story":"Hero"}',
  });
  const tool = page.locator('[data-chat-kind="tool_call"]');
  await tool.waitFor();
  await tool.locator("summary").click();
  await event({
    kind: "tool_call_update",
    toolCallId: "tool-1",
    status: "failed",
    text: "Compiler failed\n" + "detailed diagnostic ".repeat(90),
  });
  assert.equal(await tool.count(), 1);
  assert.equal(await tool.locator("details").getAttribute("open"), "");
  assert.equal(
    await tool.locator("[data-chat-activity-status]").innerText(),
    "failed",
  );
  assert((await tool.innerText()).includes("Compiler failed"));
  record("one expandable stable tool result card");
  await event({ kind: "diff", filePath: "stories.nim", diff: "- old\n+ new" });
  await event({ kind: "plan", planEntries: ["Build source", "Open story"] });
  await event({
    kind: "llm_request",
    model: "Reported model",
    hasUsage: true,
    inputTokens: 120,
    outputTokens: 30,
  });
  await shot("tool-heavy");
  await shot("tool-heavy", 240);
  await page.locator('[data-chat-kind="diff"] summary').click();
  await page.locator('[data-chat-kind="llm_request"] summary').click();
  await shot("activity-details");
  await shot("activity-details", 240);
  await input.fill("newer in-flight draft 保持😀");
  await setBusy(true);
  const beforeBudget = JSON.parse(
    await page.evaluate(() => window.__chatTest.state()),
  );
  await event({
    kind: "status",
    sourceType: "editor_context_budget",
    text: "Backend quota rejected this turn before delivery. Retrying once with bounded optional context; exact user text and pending edits are retained.",
    presentationFields: [
      { name: "Remaining Unicode characters", value: "4260" },
      {
        name: "Optional context",
        value: "diagnostics: 1/80 records; quota truncated",
      },
    ],
  });
  const budget = page
    .locator('[data-chat-kind="status"]')
    .filter({ hasText: "Backend quota rejected this turn before delivery" });
  await budget.waitFor();
  await budget.locator("summary").click();
  assert((await budget.innerText()).includes("4260"));
  assert(
    (await budget.innerText()).includes(
      "diagnostics: 1/80 records; quota truncated",
    ),
  );
  const afterBudget = JSON.parse(
    await page.evaluate(() => window.__chatTest.state()),
  );
  assert.deepEqual(
    afterBudget,
    beforeBudget,
    "Neutral safe status cannot admit or alter draft/edits/busy state",
  );
  assert.equal(await input.inputValue(), "newer in-flight draft 保持😀");
  await shot("context-budget");
  await shot("context-budget", 240);
  await setBusy(false);
  record(
    "quota status and explicit availability render without changing admission/draft/edits",
  );
  // Reestablish the original later error scenario's user draft through the
  // actual composer. The budget scenario's newer draft was asserted above.
  await input.fill("draft while streaming");
  await event({
    kind: "status",
    sourceType: "agent_question",
    question: "Which variant?",
    text: "Which variant?",
  });
  const question = page
    .locator('[data-chat-kind="status"]')
    .filter({ hasText: "Which variant?" });
  await question.waitFor();
  await shot("waiting");
  await shot("waiting", 240);
  await event({
    kind: "error",
    text: "The source build failed. Your draft is preserved.",
  });
  await shot("error");
  await shot("error", 240);
  for (let i = 0; i < 35; i++)
    await event({
      sessionId: "scroll-session",
      eventId: `history-${i}`,
      kind: "review",
      text: `Review item ${i}\n${"Long diagnostic ".repeat(25)}`,
      filePath: "stories.nim",
      reviewSeverity: "warning",
    });
  await frames();
  const latest = page.locator("[data-chat-latest]");
  if (await latest.isVisible()) await latest.click();
  await frames();
  const scroll = page.locator("[data-chat-scroll]");
  await scroll.evaluate((el) => {
    el.scrollTop = 20;
    el.dispatchEvent(new Event("scroll"));
  });
  await frames();
  const top = await scroll.evaluate((el) => el.scrollTop);
  assert.equal(
    await latest.isVisible(),
    false,
    "scrollback precondition: no unread visible output",
  );
  await event({
    sessionId: "scroll-session",
    eventId: "input-ack",
    kind: "status",
    sourceType: "user_input",
    text: "Acknowledged input",
  });
  await frames();
  assert.equal(await page.locator("[data-chat-latest]").isVisible(), false);
  assert.equal(await scroll.evaluate((el) => el.scrollTop), top);
  record("typed input acknowledgement is not new visible output");
  await event({
    sessionId: "scroll-session",
    eventId: "history-34",
    kind: "review",
    text: `Review item 34\n${"Long diagnostic ".repeat(25)}`,
    filePath: "stories.nim",
    reviewSeverity: "warning",
  });
  await frames();
  assert.equal(await page.locator("[data-chat-latest]").isVisible(), false);
  assert.equal(await scroll.evaluate((el) => el.scrollTop), top);
  record("exact durable replay is not new visible output");
  await event({
    sessionId: "scroll-session",
    eventId: "actual-new-chunk",
    kind: "message_chunk",
    text: "Actual new assistant chunk",
  });
  await event({ kind: "sub_agent", text: "A new child result arrived" });
  await page.locator("[data-chat-latest]").waitFor({ state: "visible" });
  assert.equal(await scroll.evaluate((el) => el.scrollTop), top);
  record("scrollback stays fixed and exposes new output");
  await page.locator("[data-chat-latest]").click();
  await page.waitForFunction(() => {
    const el = document.querySelector("[data-chat-scroll]");
    return el.scrollHeight - el.scrollTop - el.clientHeight <= 24;
  });
  record("return to latest restores follow");
  await shot("long-history");
  await shot("long-history", 240);
  for (const width of [240, 420]) {
    await page.evaluate((value) => window.__chatTest.width(value), width);
    const sizes = await page.evaluate(() => {
      const input = document
        .querySelector('[aria-label="Agent prompt"]')
        .getBoundingClientRect();
      const preview = Array.from(document.querySelectorAll("iframe"))
        .map((el) => el.getBoundingClientRect())
        .find((rect) => rect.width > 0) ?? { width: 0 };
      return {
        overflow: document.documentElement.scrollWidth > innerWidth,
        composer: input.bottom <= innerHeight && input.width > 100,
        preview: preview.width,
      };
    });
    assert.equal(sizes.overflow, false);
    assert.equal(sizes.composer, true);
    assert(sizes.preview > 300, JSON.stringify(sizes));
    record(`reachable composer and usable preview at sidebar ${width}`);
  }
  const second = await page.evaluate(() => window.__chatTest.newChat());
  await page
    .getByRole("button", { name: "Insert suggested prompt" })
    .first()
    .waitFor({ state: "visible" });
  await input.fill("second chat draft");
  await page.evaluate(() => window.__chatTest.switchChat("chat-1"));
  await page.waitForSelector('[data-chat-local-id="chat-1"]');
  const actualDrafts = await page.evaluate(() => window.__chatTest.state());
  assert.equal(await input.inputValue(), "draft while streaming", actualDrafts);
  await page
    .getByRole("button", { name: "Insert suggested prompt" })
    .first()
    .waitFor({ state: "hidden" });
  assert((await page.locator("[data-chat-entry]").count()) > 30);
  await page.evaluate((value) => window.__chatTest.switchChat(value), second);
  assert.equal(await input.inputValue(), "second chat draft");
  record("independent tab draft and retained transcript");
  // Full current REST union, through production normalization/safe JSON/SSE
  // decoder and reducer. Deliberate event data is not a transport replacement.
  const corpus = JSON.parse(
    readFileSync(
      path.join(repo, "tests/fixtures/chat-session-events.json"),
      "utf8",
    ),
  );
  assert.equal(corpus.events.length, 34);
  // Actual Rust-shaped file/status DTOs traverse parser, safe wire and the
  // production reducer/view. Provider labels must not change busy admission.
  const publicCorpus = JSON.parse(
    readFileSync(
      path.join(
        repo,
        "tests/scenarios/chat-activity/public-session-events.json",
      ),
      "utf8",
    ),
  );
  for (const [width, panelWidth] of [
    [1440, 420],
    [1024, 240],
  ]) {
    const projectionPage = await browser.newPage({
      viewport: { width, height: 768 },
    });
    await projectionPage.goto(origin);
    await projectionPage.waitForFunction(() => window.__chatTest);
    await projectionPage.evaluate(
      (value) => window.__chatTest.width(value),
      panelWidth,
    );
    await projectionPage
      .getByRole("textbox", { name: "Agent prompt" })
      .fill("Retained projection draft");
    await projectionPage.evaluate(() => window.__chatTest.busy(true));
    const before = await projectionPage.evaluate(() =>
      JSON.parse(window.__chatTest.state()),
    );
    await projectionPage.evaluate(
      (payload) => window.__chatTest.harborEvent(JSON.stringify(payload)),
      publicCorpus.scenes.files[0],
    );
    await projectionPage.evaluate(
      (payload) => window.__chatTest.harborEvent(JSON.stringify(payload)),
      publicCorpus.scenes.error[0],
    );
    await projectionPage.evaluate(async () => {
      await document.fonts.ready;
      await new Promise((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(resolve)),
      );
    });
    const file = projectionPage.locator('[data-chat-source="file_edit"]');
    const description = file.locator('[data-chat-markdown="paragraph"]');
    assert.equal(
      await description.innerText(),
      "Use shared spacing and preserve the title.",
    );
    assert(await description.isVisible());
    assert.equal(
      await description.locator("xpath=ancestor::details").count(),
      0,
    );
    assert.equal(await file.locator("details").getAttribute("open"), null);
    assert(
      (await file.locator('[data-chat-fact="File"]').innerText()).includes(
        "stories/hero.nim",
      ),
    );
    assert(
      (await file.locator('[data-chat-fact="Changes"]').innerText()).includes(
        "+4 / −2 lines",
      ),
    );
    const session = projectionPage.locator('[data-chat-source="status"]');
    assert.equal(
      await session.locator("[data-chat-activity-status]").innerText(),
      "running",
    );
    const badge = session.locator("[data-chat-activity-status]");
    assert(await badge.isVisible());
    for (const content of [description, badge]) {
      const bounds = await content.evaluate((el) => {
        const b = el.getBoundingClientRect(),
          s = el.closest("[data-chat-scroll]").getBoundingClientRect();
        return {
          inside:
            b.width > 0 &&
            b.height > 0 &&
            b.left >= s.left &&
            b.right <= s.right &&
            b.top >= s.top &&
            b.bottom <= s.bottom,
          box: { left: b.left, right: b.right, top: b.top, bottom: b.bottom },
          scroll: {
            left: s.left,
            right: s.right,
            top: s.top,
            bottom: s.bottom,
          },
        };
      });
      assert(bounds.inside, JSON.stringify(bounds));
    }
    await horizontalChatGuard(projectionPage);
    const after = await projectionPage.evaluate(() =>
      JSON.parse(window.__chatTest.state()),
    );
    assert.equal(after.busy, before.busy);
    assert.equal(after.admitted, before.admitted);
    assert.equal(after.connection, "streaming");
    assert.equal(after.sessionStatus, "asLoading");
    assert.equal(after.pendingEdits.length, before.pendingEdits.length + 1);
    assert.equal(
      await projectionPage
        .getByRole("button", { name: "Send agent prompt" })
        .getAttribute("aria-disabled"),
      "true",
    );
    assert.equal(
      await projectionPage
        .getByRole("textbox", { name: "Agent prompt" })
        .inputValue(),
      "Retained projection draft",
    );
    const beforeHeartbeat = await session.count();
    await projectionPage.evaluate(
      (payload) => window.__chatTest.harborEvent(JSON.stringify(payload)),
      publicCorpus.scenes.error[0],
    );
    assert.equal(await session.count(), beforeHeartbeat);
    await projectionPage.close();
    record(
      `safe file description and reported running status preserve admission at ${panelWidth}`,
    );
  }
  // Public lifecycle reports describe the agent; the admitted reply remains
  // open until its host acknowledges completion. The footer must explain both.
  for (const [width, panelWidth] of [
    [1440, 420],
    [1024, 240],
  ]) {
    const statusPage = await browser.newPage({
      viewport: { width, height: 768 },
    });
    await statusPage.goto(origin);
    await statusPage.waitForFunction(() => window.__chatTest);
    await statusPage.evaluate(
      (value) => window.__chatTest.width(value),
      panelWidth,
    );
    const status = statusPage.locator("[data-chat-session-status]");
    const summary = statusPage.locator("[data-chat-session-summary]");
    assert.equal(
      await summary.evaluate((el) => el.getBoundingClientRect().right < 0),
      true,
    );
    assert.equal(await summary.textContent(), "Start a conversation");
    assert.equal(await status.isVisible(), true);
    assert.equal(await status.innerText(), "Start a conversation");
    const draft = statusPage.getByRole("textbox", { name: "Agent prompt" });
    await draft.fill("Retained status draft");
    await statusPage.evaluate(() => window.__chatTest.busy(true));
    const before = JSON.parse(
      await statusPage.evaluate(() => window.__chatTest.state()),
    );
    const feed = async (payload) =>
      statusPage.evaluate(
        (value) => window.__chatTest.harborEvent(JSON.stringify(value)),
        payload,
      );
    assert.equal(await status.innerText(), "Working");
    await feed(publicCorpus.scenes.question[0]);
    assert.equal(
      await status.innerText(),
      "Waiting for input\nReply still open",
    );
    await feed(publicCorpus.scenes.login[0]);
    await feed(publicCorpus.scenes.login[1]);
    assert.equal(
      await status.innerText(),
      "Sign-in required\nReply still open",
    );
    await feed({
      type: "log",
      level: "info",
      message: "Resumed authoring",
      eventId: "footer-output-1",
    });
    assert.equal(await status.innerText(), "Working");
    await feed({
      type: "log",
      level: "info",
      message: " with continued output",
      eventId: "footer-output-2",
    });
    assert.equal(await status.innerText(), "Working");
    assert.equal(
      await statusPage
        .locator('[data-chat-role="arAssistant"]')
        .last()
        .locator('[data-chat-markdown="paragraph"]')
        .innerText(),
      "Resumed authoring with continued output",
    );
    await feed(publicCorpus.scenes.question[0]);
    assert.equal(
      await status.innerText(),
      "Waiting for input\nReply still open",
    );
    await feed(publicCorpus.scenes.lifecycle[2]);
    assert.equal(await status.innerText(), "Working");
    const ended = {
      ...publicCorpus.scenes.lifecycle[3],
      eventId: "footer-end",
    };
    await feed(ended);
    assert.equal(
      await status.innerText(),
      "Agent reported completion\nReply still open",
    );
    await feed(ended);
    assert.equal(
      await status.innerText(),
      "Agent reported completion\nReply still open",
    );
    assert.equal(await summary.textContent(), await status.textContent());
    const bounds = await status.evaluate((el) => {
      const a = el.getBoundingClientRect(),
        b = el.closest(".editor-chat").getBoundingClientRect();
      return {
        visible:
          a.x >= b.x &&
          a.y >= b.y &&
          a.right <= b.right &&
          a.bottom <= b.bottom,
        clientWidth: el.clientWidth,
        scrollWidth: el.scrollWidth,
      };
    });
    assert(bounds.visible, JSON.stringify(bounds));
    assert(bounds.scrollWidth <= bounds.clientWidth, JSON.stringify(bounds));
    const after = JSON.parse(
      await statusPage.evaluate(() => window.__chatTest.state()),
    );
    for (const key of ["busy", "admitted", "connection", "sessionStatus"])
      assert.equal(after[key], before[key], key);
    assert.equal(
      await statusPage
        .getByRole("button", { name: "Send agent prompt" })
        .getAttribute("aria-disabled"),
      "true",
    );
    assert.equal(await draft.inputValue(), "Retained status draft");
    await statusPage.evaluate(() => window.__chatTest.newChat());
    assert.equal(
      await statusPage.locator("[data-chat-session-status]").innerText(),
      "Start a conversation",
    );
    await statusPage.evaluate(() => window.__chatTest.switchChat("chat-1"));
    assert.equal(
      await statusPage.locator("[data-chat-session-status]").innerText(),
      "Agent reported completion\nReply still open",
    );
    assert.equal(
      await statusPage
        .getByRole("textbox", { name: "Agent prompt" })
        .inputValue(),
      "Retained status draft",
    );
    await statusPage.evaluate(() =>
      window.__chatTest.event(JSON.stringify({ kind: "completed" })),
    );
    assert.equal(
      await statusPage.locator("[data-chat-session-status]").innerText(),
      "Finishing reply",
    );
    assert.equal(
      JSON.parse(await statusPage.evaluate(() => window.__chatTest.state()))
        .busy,
      true,
    );
    await statusPage.evaluate(() => window.__chatTest.busy(false));
    assert.equal(
      await statusPage.locator("[data-chat-session-status]").innerText(),
      "Ready for next message",
    );
    await statusPage.evaluate(() =>
      window.__chatTest.event(
        JSON.stringify({ kind: "error", text: "Connection lost" }),
      ),
    );
    assert.equal(
      await statusPage.locator("[data-chat-session-status]").innerText(),
      "Reply failed",
    );
    await statusPage.evaluate(() =>
      window.__chatTest.event(JSON.stringify({ kind: "cancelled" })),
    );
    assert.equal(
      await statusPage.locator("[data-chat-session-status]").innerText(),
      "Reply stopped",
    );
    await horizontalChatGuard(statusPage);
    await statusPage.close();
    record(
      `current agent condition and open reply remain distinct at ${panelWidth}`,
    );
  }
  // A waiting-only DTO has no correlated response operation in this editor.
  // Preserve the active reply's admission and draft while exposing that fact.
  for (const [width, panelWidth] of [
    [1440, 420],
    [1024, 240],
  ]) {
    const waitingPage = await browser.newPage({
      viewport: { width, height: 768 },
    });
    await waitingPage.goto(origin);
    await mountedReady(waitingPage, `waiting-only-${panelWidth}`);
    await waitingPage.evaluate(
      (value) => window.__chatTest.width(value),
      panelWidth,
    );
    const draft = waitingPage.getByRole("textbox", { name: "Agent prompt" });
    await draft.fill("Retained waiting draft");
    await waitingPage.evaluate(() => window.__chatTest.busy(true));
    const before = JSON.parse(
      await waitingPage.evaluate(() => window.__chatTest.state()),
    );
    const payload = publicCorpus.scenes.login[1];
    assert.equal(payload.type, "session_awaiting_input");
    await waitingPage.evaluate(
      (value) => window.__chatTest.harborEvent(JSON.stringify(value)),
      payload,
    );
    await waitingPage.evaluate(async () => {
      await document.fonts.ready;
      await new Promise((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(resolve)),
      );
    });
    const row = waitingPage.locator(
      '[data-chat-entry][data-chat-source="session_awaiting_input"]',
    );
    assert.equal(await row.count(), 1);
    assert.equal(
      await row.getByText("Waiting for input", { exact: true }).innerText(),
      "Waiting for input",
    );
    assert(
      (await row.locator('[data-chat-fact="Request"]').innerText()).includes(
        payload.request,
      ),
    );
    const notice = row.locator("[data-chat-availability]");
    assert.equal(
      await notice.innerText(),
      "Waiting for input. This editor cannot respond to this request.",
    );
    assert(await notice.isVisible());
    assert.equal(await row.locator("details").getAttribute("open"), null);
    assert(
      await notice.evaluate((el) =>
        el.parentElement.hasAttribute("data-chat-entry"),
      ),
    );
    const bounds = await notice.evaluate((el) => {
      const box = el.getBoundingClientRect(),
        scroll = el.closest("[data-chat-scroll]").getBoundingClientRect();
      return {
        inside:
          box.width > 0 &&
          box.height > 0 &&
          box.left >= scroll.left &&
          box.right <= scroll.right &&
          box.top >= scroll.top &&
          box.bottom <= scroll.bottom,
        box: {
          left: box.left,
          right: box.right,
          top: box.top,
          bottom: box.bottom,
        },
      };
    });
    assert(bounds.inside, JSON.stringify(bounds));
    await horizontalChatGuard(waitingPage);
    assert.equal(
      await row.locator("button,input,textarea,select,a").count(),
      0,
    );
    assert.equal(
      await waitingPage
        .getByRole("button", { name: "Send agent prompt" })
        .getAttribute("aria-disabled"),
      "true",
    );
    assert.equal(
      await waitingPage.locator("[data-chat-session-status]").innerText(),
      "Waiting for input\nReply still open",
    );
    await row.locator("summary").click();
    assert.notEqual(await row.locator("details").getAttribute("open"), null);
    assert(
      (await row.locator("details").innerText()).includes(payload.request),
    );
    assert.equal(await draft.inputValue(), "Retained waiting draft");
    const after = JSON.parse(
      await waitingPage.evaluate(() => window.__chatTest.state()),
    );
    assert.deepEqual(after, before);
    await waitingPage.close();
    record(
      `truthful waiting-only notice preserves admission and draft at ${panelWidth}`,
    );
  }
  // Provider-supported recovery is readable with Details closed, at both real
  // mounted rail widths. No invented login action or credential input is offered.
  for (const [width, panelWidth] of [
    [1440, 420],
    [1024, 240],
  ]) {
    const loginPage = await browser.newPage({
      viewport: { width, height: 768 },
    });
    await loginPage.goto(origin);
    await loginPage.waitForFunction(() => window.__chatTest);
    await loginPage.evaluate(
      (value) => window.__chatTest.width(value),
      panelWidth,
    );
    await loginPage
      .getByRole("textbox", { name: "Agent prompt" })
      .fill("Retained login draft");
    const loginPayload = corpus.events.find(
      (event) => event.type === "login_required",
    );
    assert(loginPayload);
    await loginPage.evaluate(
      (payload) => window.__chatTest.harborEvent(JSON.stringify(payload)),
      loginPayload,
    );
    await loginPage.evaluate(async () => {
      await document.fonts.ready;
      await new Promise((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(resolve)),
      );
    });
    const row = loginPage
      .locator("[data-chat-entry]")
      .filter({ hasText: "Provider login required" });
    const notice = row.locator("[data-chat-availability]");
    assert(
      (await row.locator('[data-chat-fact="Request"]').innerText()).includes(
        loginPayload.request,
      ),
    );
    assert(
      (await row.locator("[data-chat-facts]").innerText()).includes(
        loginPayload.provider,
      ),
    );
    assert(
      (await notice.innerText()).includes(
        "Open the matching LOGIN REQUIRED card in Agent Harbor WebUI task details or Inbox, if available. This editor cannot open sign-in. If you cannot access Harbor, ask this editor's operator to open the request.",
      ),
    );
    assert(await notice.isVisible());
    assert.equal(await row.locator("details").getAttribute("open"), null);
    const bounds = await notice.evaluate((el) => {
      const box = el.getBoundingClientRect(),
        scroll = el.closest("[data-chat-scroll]").getBoundingClientRect();
      return {
        inside:
          box.width > 0 &&
          box.height > 0 &&
          box.left >= scroll.left &&
          box.right <= scroll.right &&
          box.top >= scroll.top &&
          box.bottom <= scroll.bottom,
        box: {
          left: box.left,
          right: box.right,
          top: box.top,
          bottom: box.bottom,
        },
      };
    });
    assert(bounds.inside, JSON.stringify(bounds));
    await horizontalChatGuard(loginPage);
    assert.equal(
      await row.locator("button,input,textarea,select,a").count(),
      0,
    );
    assert.equal(
      await loginPage
        .getByRole("textbox", { name: "Agent prompt" })
        .inputValue(),
      "Retained login draft",
    );
    await loginPage.close();
    record(
      `visible supported login guidance and whole notice bounds at ${panelWidth}`,
    );
  }
  // Existing protocol timing substitution only; the real parser, safe DTO
  // projection, reducer and mounted view receive an opaque-surface negative control.
  for (const [width, panelWidth] of [
    [1440, 420],
    [1024, 240],
  ]) {
    const locationPage = await browser.newPage({
      viewport: { width, height: 768 },
    });
    await locationPage.goto(origin);
    await locationPage.waitForFunction(() => window.__chatTest);
    await locationPage.evaluate(
      (value) => window.__chatTest.width(value),
      panelWidth,
    );
    const draft = locationPage.getByRole("textbox", { name: "Agent prompt" });
    await draft.fill("Login location retained draft");
    const payload = {
      ...corpus.events.find((event) => event.type === "login_required"),
      provider: "openai",
      request: "request-visible-42",
      surface: "https://private-login.invalid/OPAQUE_LOGIN_SECRET",
    };
    await locationPage.evaluate(
      (payload) => window.__chatTest.harborEvent(JSON.stringify(payload)),
      payload,
    );
    await locationPage.evaluate(async () => {
      await document.fonts.ready;
      await new Promise((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(resolve)),
      );
    });
    const row = locationPage.locator(
      '[data-chat-entry][data-chat-source="login_required"]',
    );
    const notice = row.locator("[data-chat-availability]");
    assert(
      (await notice.innerText()).includes(
        "LOGIN REQUIRED card in Agent Harbor WebUI task details or Inbox, if available.",
      ),
    );
    assert(
      (await notice.innerText()).includes("This editor cannot open sign-in."),
    );
    assert(
      (await notice.innerText()).includes(
        "If you cannot access Harbor, ask this editor's operator to open the request.",
      ),
    );
    assert(
      (await row.locator('[data-chat-fact="Request"]').innerText()).includes(
        payload.request,
      ),
    );
    assert(
      (await row.locator('[data-chat-fact="Provider"]').innerText()).includes(
        payload.provider,
      ),
    );
    assert.equal(await row.locator("details").getAttribute("open"), null);
    for (const element of [
      notice,
      row.locator('[data-chat-fact="Request"]'),
      row.locator('[data-chat-fact="Provider"]'),
    ]) {
      assert(await element.isVisible());
      const bounds = await element.evaluate((el) => {
        const b = el.getBoundingClientRect(),
          s = el.closest("[data-chat-scroll]").getBoundingClientRect();
        return {
          inside:
            b.width > 0 &&
            b.height > 0 &&
            b.left >= s.left &&
            b.right <= s.right &&
            b.top >= s.top &&
            b.bottom <= s.bottom,
          box: { left: b.left, right: b.right, top: b.top, bottom: b.bottom },
        };
      });
      assert(bounds.inside, JSON.stringify(bounds));
    }
    assert.equal(await notice.locator("xpath=ancestor::details").count(), 0);
    assert.equal(
      await row.locator("button,input,textarea,select,a,iframe").count(),
      0,
    );
    assert.equal(
      (await locationPage.locator(".editor-chat").textContent()).includes(
        "OPAQUE_LOGIN_SECRET",
      ),
      false,
    );
    assert.equal(
      (await locationPage.locator(".editor-chat").textContent()).includes(
        "private-login.invalid",
      ),
      false,
    );
    await row.locator("summary").click();
    assert(
      (await row.locator("details").innerText()).includes(payload.request),
    );
    assert.equal(
      (await row.innerText()).includes("OPAQUE_LOGIN_SECRET"),
      false,
    );
    assert.equal(await draft.inputValue(), "Login location retained draft");
    await horizontalChatGuard(locationPage);
    await locationPage.close();
    record(
      `named Harbor login location and operator fallback without opaque surface at ${panelWidth}`,
    );
  }
  // Real per-block reading interactions on full mounted editors; event timing is
  // injected through the same documented production reducer boundary as above.
  for (const [width, height, rail] of [
    [1440, 900, 420],
    [1024, 768, 240],
  ]) {
    const readerPage = await browser.newPage({ viewport: { width, height } });
    await readerPage.goto(origin);
    await readerPage.waitForFunction(() => window.__chatTest);
    await readerPage.evaluate((rail) => window.__chatTest.width(rail), rail);
    await mountedReady(readerPage, `code-reader-${width}`);
    const firstChat = JSON.parse(
      await readerPage.evaluate(() => window.__chatTest.state()),
    ).active;
    const draft = readerPage.getByRole("textbox", { name: "Agent prompt" });
    await draft.fill("Retained code reading draft");
    await draft.focus();
    const first = '\nlet safe = "<script>保持😀"\n\necho safe';
    assert.equal(codeReadingScenario.multiple.expected[0].text, first);
    assert.equal(codeReadingScenario.multiple.expected[1].text, "echo second");
    await readerPage.evaluate(
      (event) => window.__chatTest.event(JSON.stringify(event)),
      codeReadingScenario.multiple.event,
    );
    assert(
      await draft.evaluate((el) => el.ownerDocument.activeElement === el),
      "ordinary code chunk preserves composer focus",
    );
    const buttons = readerPage.locator("[data-chat-code-expand]:visible");
    const blocks = readerPage.locator('[data-chat-markdown="code"]');
    assert.equal(await buttons.count(), 2);
    assert.equal(await blocks.count(), 2);
    assert.equal(await blocks.nth(0).textContent(), first);
    assert.equal(await blocks.nth(1).textContent(), "echo second");
    const dialog = readerPage.getByRole("dialog", { name: "Expanded code" });
    const close = readerPage.getByRole("button", {
      name: "Close code",
      exact: true,
    });
    const expanded = readerPage.locator("[data-chat-code-expanded-text]");
    await buttons.nth(0).focus();
    await buttons.nth(0).press("Enter");
    assert(await dialog.isVisible());
    assert.equal(await expanded.textContent(), first);
    assert.equal(await dialog.getAttribute("data-chat-code-language"), "nim");
    assert(await close.evaluate((el) => el.ownerDocument.activeElement === el));
    const geometry = await dialog.evaluate((el) => {
      const b = el.getBoundingClientRect(),
        code = el.querySelector("pre").getBoundingClientRect(),
        source = el
          .closest(".editor-chat")
          .querySelector('[data-chat-markdown="code"]')
          .getBoundingClientRect();
      return {
        dialog: {
          left: b.left,
          right: b.right,
          top: b.top,
          bottom: b.bottom,
          width: b.width,
          height: b.height,
        },
        code: { width: code.width, height: code.height },
        source: { width: source.width, height: source.height },
        viewport: { width: innerWidth, height: innerHeight },
        overflow: document.documentElement.scrollWidth > innerWidth,
        modal: el.matches(":modal"),
      };
    });
    assert(geometry.modal);
    assert(
      geometry.dialog.left >= 0 &&
        geometry.dialog.right <= width &&
        geometry.dialog.top >= 0 &&
        geometry.dialog.bottom <= height,
    );
    assert(
      geometry.code.width > geometry.source.width * 1.5 &&
        geometry.code.height > geometry.source.height,
      "genuinely larger reading area",
    );
    assert.equal(geometry.overflow, false);
    await close.press("Tab");
    assert(
      await expanded.evaluate((el) => el.ownerDocument.activeElement === el),
    );
    await expanded.press("Tab");
    assert(await close.evaluate((el) => el.ownerDocument.activeElement === el));
    await close.press("Shift+Tab");
    assert(
      await expanded.evaluate((el) => el.ownerDocument.activeElement === el),
    );
    await expanded.press("Escape");
    assert.equal(await dialog.isVisible(), false);
    assert(
      await buttons
        .nth(0)
        .evaluate((el) => el.ownerDocument.activeElement === el),
    );
    await buttons.nth(1).press("Space");
    assert.equal(await expanded.textContent(), "echo second");
    assert.equal(await dialog.getAttribute("data-chat-code-language"), "sh");
    await close.click();
    assert(
      await buttons
        .nth(1)
        .evaluate((el) => el.ownerDocument.activeElement === el),
    );
    await buttons.nth(0).click();
    assert.equal(await expanded.textContent(), first);
    // Appending ordinary prose updates the message without resetting code, focus
    // or selection in the reader's persistent text node.
    await expanded.evaluate((el) => {
      const range = el.ownerDocument.createRange();
      range.selectNodeContents(el);
      const sel = el.ownerDocument.defaultView.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
    });
    const selected = await readerPage.evaluate(() => getSelection().toString());
    await close.focus();
    await readerPage.evaluate(() =>
      window.__chatTest.event(
        JSON.stringify({
          kind: "message_chunk",
          text: "\nContinued explanation",
        }),
      ),
    );
    assert.equal(await expanded.textContent(), first);
    assert.equal(
      await readerPage.evaluate(() => getSelection().toString()),
      selected,
    );
    assert(await close.evaluate((el) => el.ownerDocument.activeElement === el));
    await close.press("Escape");
    // Open a currently streaming block, then complete it through real chunks.
    await readerPage.evaluate(() =>
      window.__chatTest.event(
        JSON.stringify({
          kind: "message_chunk",
          text: "\n```nim\nlet pending = 1",
        }),
      ),
    );
    const streaming = readerPage
      .locator("[data-chat-code-expand]:visible")
      .last();
    await streaming.click();
    assert.equal(await expanded.textContent(), "let pending = 1");
    await readerPage.evaluate(() =>
      window.__chatTest.event(
        JSON.stringify({ kind: "message_chunk", text: "\necho pending\n```" }),
      ),
    );
    assert.equal(await expanded.textContent(), "let pending = 1\necho pending");
    assert(await close.evaluate((el) => el.ownerDocument.activeElement === el));
    const oldTrigger = await streaming.elementHandle();
    const secondChat = await readerPage.evaluate(() =>
      window.__chatTest.newChat(),
    );
    assert.equal(
      await readerPage.locator("[data-chat-code-reader]:visible").count(),
      0,
      "conversation switch disposes prior open scope",
    );
    await oldTrigger.evaluate((el) => el.click());
    assert.equal(
      await readerPage.locator("[data-chat-code-reader]:visible").count(),
      0,
      "detached trigger cannot reopen disposed dialog",
    );
    await readerPage.evaluate(() =>
      window.__chatTest.event(
        JSON.stringify({
          kind: "message_chunk",
          text: "```nim\nIndependent conversation\n```",
        }),
      ),
    );
    await readerPage.locator("[data-chat-code-expand]:visible").click();
    assert.equal(await expanded.textContent(), "Independent conversation");
    await close.press("Escape");
    await readerPage.evaluate(
      (id) => window.__chatTest.switchChat(id),
      firstChat,
    );
    assert.equal(await draft.inputValue(), "Retained code reading draft");
    assert.equal(
      await readerPage.locator("[data-chat-code-reader]:visible").count(),
      0,
    );
    await readerPage.locator("[data-chat-code-expand]:visible").last().click();
    assert.equal(await expanded.textContent(), "let pending = 1\necho pending");
    await close.click();
    // Restored-transcript kind changes/removal exercise the production
    // reconciliation, including removal of stale triggers and focus fallback.
    const obsolete = await readerPage
      .locator("[data-chat-code-expand]:visible")
      .first()
      .elementHandle();
    await obsolete.click();
    await readerPage.evaluate(
      (text) => window.__chatTest.replaceActivityText(text),
      codeReadingScenario.replacement.prose,
    );
    assert.equal(
      await readerPage.locator("[data-chat-code-expand]").count(),
      0,
    );
    assert.equal(
      await readerPage.locator("[data-chat-code-reader]:visible").count(),
      0,
    );
    assert(
      await draft.evaluate((el) => el.ownerDocument.activeElement === el),
      "kind removal returns focus to surviving composer",
    );
    await readerPage.evaluate(
      (text) => window.__chatTest.replaceActivityText(text),
      codeReadingScenario.replacement.code,
    );
    await obsolete.evaluate((el) => el.click());
    assert.equal(
      await readerPage.locator("[data-chat-code-reader]:visible").count(),
      0,
      "replaced trigger cannot reopen a new block at same index",
    );
    await readerPage.locator("[data-chat-code-expand]:visible").click();
    assert.equal(await expanded.textContent(), "restored code");
    await readerPage.evaluate(() => window.__chatTest.removeActivityEntries());
    assert.equal(
      await readerPage.locator("[data-chat-code-reader]:visible").count(),
      0,
    );
    assert(
      await draft.evaluate((el) => el.ownerDocument.activeElement === el),
      "entry removal returns focus to surviving composer",
    );
    await obsolete.dispose();
    assert.equal(await readerPage.locator(".editor-chat script").count(), 0);
    writeFileSync(
      path.join(artifacts, `code-reader-${width}.json`),
      JSON.stringify(
        {
          geometry,
          firstChat,
          secondChat,
          exactText: first,
          streamedText: "let pending = 1\necho pending",
          keyboard: ["Enter", "Space", "Tab", "Shift+Tab", "Escape"],
          disposedTriggerGuard: true,
        },
        null,
        2,
      ),
    );
    await readerPage.close();
    record(
      `exact safe code reader association, keyboard, streaming and disposed conversation scopes at ${width}`,
    );
  }
  // Genuine public tool DTO timing drives full output, compact cards and Details.
  // Parser/projection/reducer/DOM stay real, including growth across the excerpt.
  for (const [width, height, rail] of [
    [1440, 900, 420],
    [1024, 768, 240],
  ]) {
    const toolPage = await browser.newPage({ viewport: { width, height } });
    await toolPage.goto(origin);
    await toolPage.waitForFunction(() => window.__chatTest);
    await toolPage.evaluate((rail) => window.__chatTest.width(rail), rail);
    await mountedReady(toolPage, `complete-tool-code-${width}`);
    const scenario = codeReadingScenario.publicTool;
    const feed = async (event) =>
      toolPage.evaluate(
        (value) => window.__chatTest.harborEvent(JSON.stringify(value)),
        event,
      );
    const draft = toolPage.getByRole("textbox", { name: "Agent prompt" });
    await draft.fill("Complete tool output retained draft");
    await draft.focus();
    await feed(scenario.use);
    await feed(scenario.short);
    assert(await draft.evaluate((el) => el.ownerDocument.activeElement === el));
    const row = toolPage.locator(
      '[data-chat-role="arActivity"][data-chat-source="tool_result"]',
    );
    assert.equal(await row.count(), 1);
    const first = row.getByRole("button", {
      name: "Expand code block 1 · nim",
      exact: true,
    });
    const second = row.getByRole("button", {
      name: "Expand code block 2 · sh",
      exact: true,
      includeHidden: true,
    });
    const dialog = toolPage.getByRole("dialog", { name: "Expanded code" });
    const expanded = toolPage.locator("[data-chat-code-expanded-text]");
    const close = toolPage.getByRole("button", {
      name: "Close code",
      exact: true,
    });
    await first.focus();
    await first.press("Enter");
    assert.equal(await expanded.textContent(), 'echo "short start"');
    const firstHandle = await first.elementHandle();
    await feed(scenario.long);
    assert.equal(await row.count(), 1);
    assert.equal(await expanded.textContent(), scenario.expectedFirst);
    assert(
      (await expanded.textContent()).endsWith(
        'echo "FINAL tool line 23 beyond excerpt"',
      ),
    );
    assert.equal(await dialog.getAttribute("data-chat-code-language"), "nim");
    assert(await close.evaluate((el) => el.ownerDocument.activeElement === el));
    assert(
      await firstHandle.evaluate((el) => el.isConnected),
      "full-block control survives excerpt transition",
    );
    const compact = row.locator('[data-chat-markdown="code"]:visible');
    assert.equal(await compact.count(), 1);
    const excerpt = await compact.textContent();
    assert(excerpt.endsWith("…"));
    assert(excerpt.length < 240);
    assert.equal(excerpt.includes("FINAL tool line 23"), false);
    assert.equal(await row.locator("details").evaluate((el) => el.open), false);
    const details = row.locator("[data-chat-detail]");
    assert((await details.textContent()).includes(scenario.long.tool_output));
    assert.equal(await second.count(), 1);
    assert.equal(
      await second.isVisible(),
      false,
      "later fence belongs to closed full Details",
    );
    assert.equal(await second.textContent(), "Expand code block 2 · sh");
    const geometry = await dialog.evaluate((el) => {
      const b = el.getBoundingClientRect(),
        p = el.querySelector("pre").getBoundingClientRect();
      return {
        left: b.left,
        right: b.right,
        top: b.top,
        bottom: b.bottom,
        codeWidth: p.width,
        codeHeight: p.height,
        modal: el.matches(":modal"),
        overflow: document.documentElement.scrollWidth > innerWidth,
      };
    });
    assert(
      geometry.modal &&
        geometry.left >= 0 &&
        geometry.right <= width &&
        geometry.top >= 0 &&
        geometry.bottom <= height,
    );
    assert(geometry.codeWidth > rail * 1.5 && geometry.codeHeight > 200);
    assert.equal(geometry.overflow, false);
    await expanded.evaluate((el) => {
      const range = el.ownerDocument.createRange();
      range.setStart(el.firstChild, 0);
      range.setEnd(el.firstChild, 20);
      const selection = el.ownerDocument.defaultView.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    });
    const selected = await toolPage.evaluate(() => getSelection().toString());
    await feed(scenario.update);
    assert.equal(await expanded.textContent(), scenario.expectedUpdated);
    assert(
      (await expanded.textContent()).endsWith(
        'echo "UPDATED final tool line 23 beyond excerpt"',
      ),
    );
    assert.equal(
      await compact.textContent(),
      excerpt,
      "late-tail update preserves compact excerpt",
    );
    assert((await details.textContent()).includes(scenario.update.tool_output));
    assert.equal(
      await toolPage.evaluate(() => getSelection().toString()),
      selected,
    );
    assert(await close.evaluate((el) => el.ownerDocument.activeElement === el));
    await close.press("Escape");
    assert.equal(await dialog.isVisible(), false);
    assert(await first.evaluate((el) => el.ownerDocument.activeElement === el));
    await row.locator("summary").click();
    assert(await second.isVisible());
    await second.focus();
    await second.press("Space");
    assert.equal(
      await expanded.textContent(),
      "printf '<img src=x onerror=alert(1)> Ω'\necho SECOND final block",
    );
    assert.equal(await dialog.getAttribute("data-chat-code-language"), "sh");
    await close.press("Tab");
    assert(
      await expanded.evaluate((el) => el.ownerDocument.activeElement === el),
    );
    await expanded.press("Shift+Tab");
    assert(await close.evaluate((el) => el.ownerDocument.activeElement === el));
    await close.click();
    assert(
      await second.evaluate((el) => el.ownerDocument.activeElement === el),
    );
    await first.click();
    assert.equal(await expanded.textContent(), scenario.expectedUpdated);
    const next = await toolPage.evaluate(() => window.__chatTest.newChat());
    assert.equal(
      await toolPage.locator("[data-chat-code-reader]:visible").count(),
      0,
    );
    await firstHandle.evaluate((el) => el.click());
    assert.equal(
      await toolPage.locator("[data-chat-code-reader]:visible").count(),
      0,
      "disposed public-tool trigger cannot reopen",
    );
    assert.equal(
      await toolPage.locator(".editor-chat script,.editor-chat img").count(),
      0,
    );
    await firstHandle.dispose();
    writeFileSync(
      path.join(artifacts, `complete-tool-code-${width}.json`),
      JSON.stringify(
        {
          geometry,
          excerpt,
          exactFull: scenario.expectedFirst,
          lateTail: scenario.expectedUpdated,
          secondBlock: scenario.expectedSecond,
          publicDTOs: true,
          detailsAssociated: true,
          streamingSelection: selected,
          disposedChat: next,
        },
        null,
        2,
      ),
    );
    await toolPage.close();
    record(
      `complete public tool fenced code, late-tail update and Details association at ${width}`,
    );
  }

  await page.evaluate(() => window.__chatTest.newChat());
  for (const payload of corpus.events) {
    await page.evaluate(
      (payload) => window.__chatTest.harborEvent(JSON.stringify(payload)),
      payload,
    );
  }
  assert.equal(await page.locator('[data-chat-role="arUser"]').count(), 0);
  assert.equal(
    await page
      .locator(".editor-chat")
      .getByText("Activity", { exact: true })
      .count(),
    0,
  );
  assert(
    (await page.locator(".editor-chat").innerText()).includes(
      "Provider login required",
    ),
  );
  assert(
    (await page.locator(".editor-chat").innerText()).includes("Agent question"),
  );
  assert.equal(
    (await page.locator(".editor-chat").textContent()).includes(
      "PRIVATE_DO_NOT_RENDER",
    ),
    false,
  );
  record("full REST union safe purposeful presentation");
  assert.deepEqual(errors, []);
  record("no browser runtime errors");
  writeFileSync(
    path.join(artifacts, "results.json"),
    JSON.stringify(
      {
        passed: count,
        artifacts,
        views: [
          "empty",
          "streaming",
          "tool-heavy",
          "activity-details",
          "waiting",
          "error",
          "long-history",
        ],
        widths: [240, 420],
        captureEvidence,
      },
      null,
      2,
    ),
  );
  process.stdout.write(`ARTIFACTS ${artifacts}\n`);
} finally {
  if (browser) await browser.close();
  server.kill("SIGTERM");
}
