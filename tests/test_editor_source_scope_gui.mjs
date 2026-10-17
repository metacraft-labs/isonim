/** Real browser/DOMRenderer production inspector and public section frames.
 * Authored ownership fixtures pass through the real normalizer/schema resolver;
 * this proves presentation and public frames, not native discovery/source/compiler
 * or Harbor E2E. No renderer, browser event or ownership outcome is mocked. */
import { spawn } from "node:child_process";
import {
  mkdtempSync,
  readFileSync,
  writeFileSync,
  copyFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { chromium } from "../node_modules/playwright/index.mjs";
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const root = mkdtempSync(
  path.join(process.env.ISONIM_POPUP_ARTIFACTS || tmpdir(), "source-labels-"),
);
copyFileSync(
  repo + "/build/editor-source-labels/editor.js",
  root + "/editor.js",
);
writeFileSync(
  root + "/index.html",
  '<!doctype html><html><body><script src="editor.js"></script></body></html>',
);
const proof = {
  head: process.env.ISONIM_TEST_HEAD,
  sourceState: process.env.ISONIM_TEST_SOURCE_STATE,
  bundleSha256: createHash("sha256")
    .update(readFileSync(root + "/editor.js"))
    .digest("hex"),
  cases: [],
  errors: [],
  requests: [],
};
const server = spawn(
  "python3",
  ["-u", "-m", "http.server", "0", "--bind", "127.0.0.1", "--directory", root],
  { stdio: ["ignore", "pipe", "pipe"] },
);
let browser;
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
  const page = await browser.newPage({
    viewport: { width: 1440, height: 900 },
  });
  page.setDefaultTimeout(30000);
  page.on("pageerror", (e) => proof.errors.push(e.message));
  page.on("request", (r) => {
    if (new URL(r.url()).pathname.startsWith("/api/"))
      proof.requests.push(r.url());
  });
  await page.goto(origin, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(() => window.__sourceLabels);
  const sourceHeader = page.locator('[data-inspector-section-header="source"]');
  assert.equal(await sourceHeader.count(), 1);
  await sourceHeader.click();
  const stage = async (n) =>
    page.evaluate((n) => window.__sourceLabels.stage(n), n);
  const state = async () =>
    JSON.parse(await page.evaluate(() => window.__sourceLabels.state()));
  const label = page.locator('[data-source-scope="true"]');
  const frame = page.locator(
    '[data-inspector-section-row="component-properties"]',
  );
  await stage(0);
  assert.equal((await state()).key, "dom.button");
  await assert.doesNotReject(() => label.waitFor());
  assert.equal(await label.textContent(), "Unknown");
  assert.equal(
    await frame.evaluate((el) => getComputedStyle(el).display),
    "none",
  );
  const count = (await state()).properties;
  await stage(1);
  assert((await state()).unmappedFiles > 0);
  assert.equal(await label.textContent(), "Unknown");
  await stage(2);
  assert.equal((await state()).properties, count);
  assert.equal(await label.textContent(), "Local");
  proof.cases.push(
    "production normalized DOM remains Unknown until every retained property has mapped local ownership; ordinary DOM component frame hidden",
  );
  await stage(3);
  assert((await state()).sharedAllowed);
  assert.equal((await state()).apiAllowed, false);
  assert.equal(await label.textContent(), "Shared");
  assert.equal(
    await page.locator('[data-fill-source-scope="true"]').count(),
    1,
  );
  await stage(4);
  assert.equal(await label.textContent(), "Unknown");
  await stage(5);
  assert.equal(await label.textContent(), "Component schema");
  assert.equal(
    await frame.evaluate((el) => getComputedStyle(el).display),
    "flex",
  );
  // Component section is initially collapsed: physically disclose its public header.
  const button = frame.locator(
    '[data-inspector-section-header="component-properties"]',
  );
  assert.equal(await button.count(), 1);
  await button.click();
  assert.equal(await page.locator('[data-property-row="variant"]').count(), 1);
  assert.equal((await state()).pending, 0);
  assert.equal((await state()).messages, 0);
  proof.cases.push(
    "native shared scope choices and explicit readonly component schema ownership agree with public Source and component frame",
  );
  await stage(6);
  assert.equal(await label.textContent(), "Local");
  await stage(7);
  assert.equal(await label.textContent(), "Component schema");
  for (const order of [8, 9, 10]) {
    await stage(order);
    assert.equal(await label.textContent(), "Unknown");
    assert(await label.isVisible());
    assert.equal((await state()).pending, 0);
    assert.equal((await state()).messages, 0);
  }
  await stage(11);
  assert.equal(await label.textContent(), "Local");
  proof.cases.push(
    "both matching edge orders and distinct same-scope owners are Unknown; single readonly and redundant-same-owner controls remain known",
  );
  await stage(12);
  assert.equal(await label.textContent(), "Component schema");
  assert(await label.isVisible());
  await stage(13);
  assert.equal(await label.textContent(), "Unknown");
  await stage(14);
  assert.equal(await label.textContent(), "Unknown");
  assert(await label.isVisible());
  assert.equal((await state()).pending, 0);
  assert.equal((await state()).messages, 0);
  proof.cases.push(
    "path-scoped readonly owner is known only for matching selected DOM path; mismatched and absent paths remain Unknown",
  );
  assert.deepEqual(proof.errors, []);
  assert.deepEqual(proof.requests, []);
} finally {
  if (browser) await browser.close();
  server.kill("SIGTERM");
  await new Promise((resolve) => server.once("exit", resolve));
  writeFileSync(root + "/proof-final.json", JSON.stringify(proof, null, 2));
  console.log(root + "/proof-final.json");
}
