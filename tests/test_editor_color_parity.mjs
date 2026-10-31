/** No mocks: compare the production native source validator with Chromium's real
 * CSS parser for a finite literal-color corpus. This is parser integration;
 * actual source/compiler/pointer/preview persistence has separate owned suites.
 */
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { chromium } from "../node_modules/playwright/index.mjs";
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const root = mkdtempSync(
  path.join(process.env.ISONIM_POPUP_ARTIFACTS || tmpdir(), "color-parity-"),
);
const values = [
  "#123",
  "#1234",
  "#123456",
  "#12345678",
  "#12",
  "#12345",
  "#GG0000",
  "rgb(18, 52, 86)",
  "rgba(18, 52, 86, .5)",
  "rgb(999,2,3)",
  "rgba(1,2,3,2)",
  "rgb(18 52 86 / 50%)",
  "rgb(10%, 20%, 30%)",
  "rgb(10% 20% 30% / .5)",
  "rgb(10%, 20, 30)",
  "rgb(10 20% 30)",
  "rgba(18, 52, 86)",
  "rgba(18 52 86)",
  "RGB(18,52,86)",
  "RGB(NaN,2,3)",
  "rgb(1,2)",
  "rgb(1,2,3,4,5)",
  "rgb(1,2 3)",
  "rgb(1,,3)",
  "rgb(1 2 3 4)",
  "rgb(1,2,3)junk",
  "rgb(NaN,2,3)",
  "rgba(1,2,3,Infinity)",
  "rgb(1e999,2,3)",
  "hsl(120,50%,25%)",
  "hsl(120deg,50%,25%)",
  "hsl(.5turn 50% 25% / 50%)",
  "hsl(120rad,50%,25%)",
  "hsl(100grad,50%,25%)",
  "hsla(120,50%,25%)",
  "hsla(120 50% 25%)",
  "hsl(10%,50%,50%)",
  "hsl(10,50,50%)",
  "hsl(10 50 50)",
  "hsl(10,junk,20%)",
  "hsl(NaN,50%,50%)",
  "hsl(10,50%,50%)junk",
];
const binary = root + "/native-validator";
const build = spawnSync(
  "nim",
  [
    "c",
    "--path:src",
    "--path:.",
    "--path:../nim-everywhere/src",
    "--path:../isonim-render-serve/src",
    "--path:../nim-acp/src",
    "--path:../nim-agent-harbor/src",
    "--path:../nim-agents/src",
    "--out:" + binary,
    "tests/helpers/editor_color_validation.nim",
  ],
  { cwd: repo, encoding: "utf8", timeout: 120000 },
);
writeFileSync(root + "/build.log", build.stdout + build.stderr);
assert.equal(build.status, 0, build.stdout + build.stderr);
writeFileSync(root + "/values.json", JSON.stringify(values));
const native = spawnSync(binary, [root + "/values.json"], {
  cwd: repo,
  encoding: "utf8",
  timeout: 5000,
});
assert.equal(native.status, 0, native.stdout + native.stderr);
const actual = JSON.parse(native.stdout);
const env = { ...process.env };
delete env.LD_LIBRARY_PATH;
const server = await chromium.launchServer({
  headless: true,
  env,
  executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE,
});
const browser = await chromium.connect(server.wsEndpoint());
try {
  const page = await browser.newPage();
  const supported = await page.evaluate(
    (values) => values.map((value) => CSS.supports("color", value)),
    values,
  );
  const rows = actual.map((row, index) => ({
    ...row,
    browser: supported[index],
  }));
  const finitePolicyExceptions = new Set(["rgb(1e999,2,3)"]);
  for (const row of rows.filter((row) =>
    finitePolicyExceptions.has(row.value),
  )) {
    assert.equal(row.accepted, false);
    assert.equal(row.browser, true);
  }
  const proof = {
    count: values.length,
    nativeValidatorSha256: createHash("sha256")
      .update(readFileSync(binary))
      .digest("hex"),
    browserVersion: browser.version(),
    finitePolicyExceptions: [...finitePolicyExceptions],
    head:
      process.env.ISONIM_TEST_HEAD ||
      spawnSync("git", ["rev-parse", "HEAD"], {
        cwd: repo,
        encoding: "utf8",
      }).stdout.trim(),
    sourceState:
      process.env.ISONIM_TEST_SOURCE_STATE || "C4a authored working copy",
    rows,
    mismatches: rows.filter((row) =>
      finitePolicyExceptions.has(row.value)
        ? row.accepted !== false
        : row.accepted !== row.browser,
    ),
  };
  writeFileSync(root + "/proof.json", JSON.stringify(proof, null, 2));
  assert.deepEqual(
    proof.mismatches,
    [],
    "Native literal validation must match real browser acceptance: " + root,
  );
  console.log("Color literal parity passed:", root, values.length);
} finally {
  await browser.close();
  await server.close();
}
