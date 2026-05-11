// IsoNim × Webpack 5 HMR interop integration test.
//
// Same shape as the Vite spec; just speaks Webpack's HMR API
// instead of Vite's. The contract under test:
//
//   1. Webpack dev server boots, nim-loader compiles counter.nim
//      to JS and webpack serves the bundle.
//   2. The page mounts the isonim counter via mountUiHot.
//   3. The user clicks the counter to a nonzero value.
//   4. The test edits a literal in counter.nim — Webpack's
//      watcher fires, the loader recompiles, webpack-dev-server
//      sends the HMR update over its WebSocket, the runtime
//      replaces the module and re-executes its top-level code.
//   5. The new init runs hmrRegisterFactory; the slot factory is
//      rewritten; mountUiHot's effect re-runs; the DOM reflects
//      the new literal AND the counter signal value is preserved
//      across the swap.

import { test, expect } from "@playwright/test";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { execSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const EXAMPLE_ROOT = resolve(__dirname, "..");
const NIM_SOURCE = join(EXAMPLE_ROOT, "src", "counter.nim");

function captureNimSource(): string {
  try {
    execSync(`git checkout HEAD -- ${JSON.stringify(NIM_SOURCE)}`, {
      stdio: "ignore",
    });
  } catch {
    // Untracked or no git — proceed with on-disk content.
  }
  return readFileSync(NIM_SOURCE, "utf8");
}

test.describe("IsoNim × Webpack 5 HMR interop", () => {
  test.skip(!existsSync(NIM_SOURCE), "counter.nim missing");

  test("editing counter.nim updates DOM in place; counter signal value survives the swap", async ({
    page,
  }) => {
    const original = captureNimSource();
    try {
      await page.goto("/");
      await expect(page.locator("#counter-root")).toBeVisible({
        timeout: 30_000,
      });
      await expect(page.locator("#counter-label")).toContainText("Count: 0");

      await page.click("#counter-inc");
      await page.click("#counter-inc");
      await page.click("#counter-inc");
      await expect(page.locator("#counter-label")).toContainText("Count: 3");

      const navsBefore = await page.evaluate(
        () => performance.getEntriesByType("navigation").length,
      );

      const edited = original.replace('"Count: " &', '"Hits: " &');
      if (edited === original) {
        throw new Error(
          "could not find 'Count: ' literal in counter.nim — fixture drifted.",
        );
      }
      writeFileSync(NIM_SOURCE, edited);

      // Generous timeout: Nim cold-cache compile + webpack watch
      // detection + HMR roundtrip. Warm-cache runs are ~3s.
      await expect(page.locator("#counter-label")).toContainText("Hits: 3", {
        timeout: 60_000,
      });

      // State-preservation: "3" survives the swap. The literal
      // changed (proves the slot factory was rewritten) and the
      // VM signal storage survived (proves mountUiHot reused the
      // existing reactive boundary).

      const navsAfter = await page.evaluate(
        () => performance.getEntriesByType("navigation").length,
      );
      expect(navsAfter).toBe(navsBefore);
    } finally {
      writeFileSync(NIM_SOURCE, original);
    }
  });
});
