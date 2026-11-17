/** Real DOMRenderer page preview with the workspace's mount hook.
 *
 * A workspace page story (CodeTracer's full-window layouts) is rendered in the
 * page preview, not the component detail view. The project supplies an empty
 * document and a mount hook, which is what adopting mounting means, so the
 * content of the page exists only if the page preview calls the hook. The hook
 * here is the fixture's declared DOM (tests/helpers/editor_preview_mount_browser.nim),
 * not a source, compiler or launcher result. The page preview, its frame load
 * and the mount itself run for real in Chromium.
 *
 * Covered: the web path mounts the page story into the page preview frame
 * exactly once. The streamed (non-web) path does not mount: the detail and
 * edit views gate the hook to the web backend, and the page preview follows
 * them, so the hook must not run there and the streamed canvas takes the
 * frame. Build with `just editor-preview-mount-build`; run with
 * `node tests/test_editor_page_preview_mount_gui.mjs`. */
import { spawn } from "node:child_process";
import { mkdtempSync, copyFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import { chromium } from "../node_modules/playwright/index.mjs";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const root = mkdtempSync(
  path.join(process.env.ISONIM_POPUP_ARTIFACTS || tmpdir(), "page-preview-mount-"),
);
copyFileSync(
  repo + "/build/editor-preview-mount/editor.js",
  root + "/editor.js",
);
writeFileSync(
  root + "/index.html",
  "<!doctype html><html><head><style>html,body{height:100%;margin:0;overflow:hidden}</style></head><body><script src=\"editor.js\"></script></body></html>",
);

const server = spawn(
  "python3",
  ["-u", "-m", "http.server", "0", "--bind", "127.0.0.1", "--directory", root],
  { stdio: ["ignore", "pipe", "pipe"] },
);
let browser;
const proof = { cases: [], errors: [] };
try {
  const origin = await new Promise((resolve, reject) => {
    let text = "";
    server.stdout.on("data", (d) => {
      text += d;
      const m = text.match(/port (\d+)/);
      if (m) resolve("http://127.0.0.1:" + m[1]);
    });
    server.once("exit", (c) => reject(Error("server exit " + c)));
    setTimeout(() => reject(Error("server startup timeout")), 10000).unref();
  });
  const env = { ...process.env };
  delete env.LD_LIBRARY_PATH;
  browser = await chromium.launch({
    headless: true,
    env,
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE,
  });
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  page.setDefaultTimeout(15000);
  page.on("pageerror", (e) => proof.errors.push(e.message));
  await page.goto(origin, { waitUntil: "load" });
  await page.waitForFunction(() => window.__mountProbe);
  const state = async () =>
    JSON.parse(await page.evaluate(() => window.__mountProbe.snapshot()));

  const initial = await state();
  assert.equal(initial.mounts, 0);

  // Web path: the page story is shown in the page preview frame.
  assert.equal(await page.evaluate(() => window.__mountProbe.selectPage(0)), true);
  const pageFrame = page.locator('iframe[data-page-project-frame="true"]');
  assert.equal(await pageFrame.count(), 1);

  // The mount waits for the frame's own load; the button exists only if the
  // page preview handed its frame to the workspace hook.
  await page.waitForFunction(() => {
    const frame = document.querySelector(
      'iframe[data-page-project-frame="true"]',
    );
    const doc = frame?.contentDocument;
    return doc?.readyState === "complete" && !!doc.querySelector("#fixture-action");
  });
  const webState = await state();
  assert.equal(webState.view, "evPagePreview");
  assert.equal(webState.mounts, 1);
  assert.equal(webState.unmounts, 0);
  const pageButton = pageFrame
    .contentFrame()
    .getByRole("button", { name: "Fixture action", exact: true });
  assert.equal(await pageButton.count(), 1);
  assert.equal(await pageButton.isVisible(), true);
  assert.equal(await pageButton.getAttribute("data-probe-story"), webState.story);
  proof.cases.push(
    "web page story: the workspace hook draws its content into the page preview frame exactly once",
  );

  // Hidden page view: a reload while another view is shown loads the page
  // document, but the story must not be mounted into it.
  await page.evaluate(() => {
    window.__mountProbe.storyboard();
    window.__mountProbe.reload();
  });
  await page.waitForFunction(() => {
    const frame = document.querySelector(
      'iframe[data-page-project-frame="true"]',
    );
    const doc = frame?.contentDocument;
    const revision = frame?.srcdoc.match(
      /name="isonim-mount-document" content="(\d+)"/,
    )?.[1];
    return (
      revision !== undefined &&
      doc?.readyState === "complete" &&
      doc.querySelector('meta[name="isonim-mount-document"]')?.content === revision
    );
  });
  const hiddenState = await state();
  assert.equal(hiddenState.view, "evStoryboard");
  assert.equal(hiddenState.mounts, webState.mounts);
  assert.equal(
    await pageFrame
      .contentFrame()
      .getByRole("button", { name: "Fixture action", exact: true })
      .count(),
    0,
  );
  proof.cases.push(
    "reloaded page document while another view is shown loads without mounting",
  );

  // Back to the page view: the loaded document is mounted, exactly once.
  await page.evaluate(() => window.__mountProbe.showPage());
  await page.waitForFunction(() => {
    const frame = document.querySelector(
      'iframe[data-page-project-frame="true"]',
    );
    return !!frame?.contentDocument?.querySelector("#fixture-action");
  });
  const shownState = await state();
  assert.equal(shownState.view, "evPagePreview");
  assert.equal(shownState.mounts, webState.mounts + 1);
  proof.cases.push(
    "switching back to the page view mounts the loaded document once",
  );

  // Story switch: each selection mounts its own story exactly once, into the
  // document it requests. A mount into the previous, still-loaded document
  // would be an extra hook call, so the count checks for it too.
  assert(
    (await page.evaluate(() => window.__mountProbe.pageStoryCount())) >= 2,
    "the storyboard needs two page stories to switch between",
  );
  // Waits until the page frame shows the document requested last, loaded, with
  // the named story mounted in it.
  const awaitStoryDocument = (name) =>
    page.waitForFunction((expected) => {
      const frame = document.querySelector(
        'iframe[data-page-project-frame="true"]',
      );
      const doc = frame?.contentDocument;
      const revision = frame?.srcdoc.match(
        /name="isonim-mount-document" content="(\d+)"/,
      )?.[1];
      const button = doc?.querySelector("#fixture-action");
      return (
        revision !== undefined &&
        doc?.readyState === "complete" &&
        doc.querySelector('meta[name="isonim-mount-document"]')?.content === revision &&
        button?.getAttribute("data-probe-story") === expected
      );
    }, name);
  const selectAndAwaitStory = async (index) => {
    const before = await state();
    assert.equal(
      await page.evaluate((i) => window.__mountProbe.selectPage(i), index),
      true,
    );
    await awaitStoryDocument((await state()).story);
    const after = await state();
    assert.equal(after.mounts, before.mounts + 1);
    return after;
  };
  // A viewport change re-runs the document effect; the switch after it must
  // still mount exactly once.
  const beforeViewport = await state();
  await page.evaluate(() => window.__mountProbe.phoneViewport());
  await awaitStoryDocument(beforeViewport.story);
  assert.equal((await state()).mounts, beforeViewport.mounts + 1);
  const switchedOnce = await selectAndAwaitStory(1);
  assert.notEqual(switchedOnce.story, shownState.story);
  const switchedBack = await selectAndAwaitStory(0);
  assert.equal(switchedBack.story, shownState.story);
  proof.cases.push(
    "selecting another page story mounts it into its own document exactly once, in both directions",
  );
  const latest = switchedBack;

  // Streamed path: the hook is a web-path rule. Switching to a streamed backend
  // must not mount into the page preview, and the frame is hidden for the stream.
  await page.evaluate(() => window.__mountProbe.streamed());
  const streamed = await state();
  assert.equal(streamed.platform, "pbTui");
  assert.equal(streamed.mounts, latest.mounts);
  assert.equal(
    await pageFrame.evaluate((el) => el.style.display),
    "none",
  );
  proof.cases.push(
    "streamed backend: the page preview does not mount the hook; the frame is hidden for the stream",
  );

  assert.deepEqual(proof.errors, []);
  console.log(JSON.stringify({ ok: true, cases: proof.cases, errors: proof.errors }, null, 2));
} finally {
  if (browser) await browser.close();
  server.kill();
}
