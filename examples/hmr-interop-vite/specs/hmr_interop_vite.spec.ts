// IsoNim × Vite HMR interop integration test.
//
// This spec is the canonical proof that an isonim component
// embedded inside a Vite-hosted app gets full state-preserving
// HMR through Vite's native machinery — no isonim-specific
// runtime adapter, no SSE, no fs.watch. Vite's plugin compiles
// the .nim source on the fly, its WebSocket HMR replaces the
// module on change, the new init runs hmrRegisterFactory, and
// mountUiHot reconciles in place.
//
// What gets exercised end-to-end:
//   1. The Vite dev server boots, compiles counter.nim via
//      vite-plugin-isonim, and serves the page.
//   2. The page mounts the isonim counter component.
//   3. The user clicks the counter a few times.
//   4. The test edits counter.nim — appending a marker rule and
//      changing a visible literal — runs Vite's natural HMR loop.
//   5. The label text in the DOM reflects the new literal; the
//      counter value is preserved (proves the slot updated
//      without disposing the VM signals); the browser did not
//      perform a full-page navigation.

import { test, expect } from "@playwright/test";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { execSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const EXAMPLE_ROOT = resolve(__dirname, "..");
const NIM_SOURCE = join(EXAMPLE_ROOT, "src", "counter.nim");
const NIM_VM_SOURCE = join(EXAMPLE_ROOT, "src", "counter_state.nim");

function captureNimSource(path: string): string {
  // Wash out any leftover mutation from a previous crashed run.
  try {
    execSync(`git checkout HEAD -- ${JSON.stringify(path)}`, {
      stdio: "ignore",
    });
  } catch {
    // Untracked or no git — fall through with whatever's on disk.
  }
  return readFileSync(path, "utf8");
}

test.describe("IsoNim × Vite HMR interop", () => {
  test.skip(!existsSync(NIM_SOURCE), "counter.nim missing");

  test("editing counter.nim updates DOM in place; counter signal value survives the swap", async ({
    page,
  }) => {
    const original = captureNimSource(NIM_SOURCE);
    try {
      await page.goto("/");
      await expect(page.locator("#counter-root")).toBeVisible();
      await expect(page.locator("#counter-label")).toContainText(
        "Count: 0 clicks",
      );

      // Click a few times so we can observe state preservation
      // across the HMR swap.
      await page.click("#counter-inc");
      await page.click("#counter-inc");
      await page.click("#counter-inc");
      await expect(page.locator("#counter-label")).toContainText(
        "Count: 3 clicks",
      );

      const navsBefore = await page.evaluate(
        () => performance.getEntriesByType("navigation").length,
      );

      // Edit the .nim source — change a visible literal so we can
      // detect the swap unambiguously. The Nim string "clicks" is
      // a `vm.label.val` default; we keep the signal-driven part
      // intact and rewrite the *label-text formatter* in the
      // panel proc. Simplest robust change: rename the prefix
      // "Count:" to "Hits:".
      const edited = original.replace('"Count: " &', '"Hits: " &');
      if (edited === original) {
        throw new Error(
          "could not find 'Count: ' literal to edit in counter.nim — " +
            "the test fixture's source structure has drifted.",
        );
      }
      writeFileSync(NIM_SOURCE, edited);

      // Vite's plugin recompiles, dispatches an HMR update over
      // its WebSocket, the new module runs its top-level init,
      // the slot's factory signal updates, and mountUiHot
      // re-renders. 30s is well over the typical cycle (~1s on a
      // warm Nim cache) but covers cold starts where the Nim
      // compiler has to walk a fresh nimcache.
      await expect(page.locator("#counter-label")).toContainText(
        "Hits: 3 clicks",
        { timeout: 30_000 },
      );

      // Crucial state-preservation assertion: the counter went
      // from "Count: 3 clicks" to "Hits: 3 clicks" — the 3 stuck.
      // That can only happen if the slot factory was rewritten
      // (so the literal swapped) AND the VM signal's storage
      // survived (so the count survived). Together these prove
      // the slot system did its job.

      // No full-page navigation.
      const navsAfter = await page.evaluate(
        () => performance.getEntriesByType("navigation").length,
      );
      expect(navsAfter).toBe(navsBefore);
    } finally {
      writeFileSync(NIM_SOURCE, original);
    }
  });

  test("editing a transitively-imported .nim file triggers Vite HMR via the plugin's dep walker", async ({
    page,
  }) => {
    // counter.nim imports ./counter_state.nim. Vite has no idea
    // about that edge — the .nim file isn't a Vite module. The
    // plugin's transitiveNimDeps walker has to surface the
    // import to Vite via `addWatchFile` AND map a counter_state
    // edit back to counter.nim in handleHotUpdate. If either
    // breaks, this test times out because Vite never schedules
    // an HMR update.
    //
    // Note: a `symBodyHash`-clean edit to counter_state.nim does
    // NOT cause a DOM swap, because counterPanel's body in
    // counter.nim is unchanged — the slot's factory hash matches,
    // and the runtime correctly skips the redundant write. So we
    // assert on Vite's client-side HMR log instead, which is
    // emitted whenever Vite *dispatches* an update over the WS,
    // regardless of whether the new bundle's slot writes were
    // semantically effectful. That's the right contract for "the
    // walker is plumbed through Vite".
    const originalVm = captureNimSource(NIM_VM_SOURCE);
    const hmrUpdates: string[] = [];
    page.on("console", (msg) => {
      const t = msg.text();
      if (t.includes("[vite]") && t.includes("hot updated")) {
        hmrUpdates.push(t);
      }
    });
    try {
      await page.goto("/");
      await expect(page.locator("#counter-root")).toBeVisible();

      hmrUpdates.length = 0; // reset baseline

      // Edit the imported module — change the default label.
      const edited = originalVm.replace(
        '"clicks"): CounterVm',
        '"taps"): CounterVm',
      );
      if (edited === originalVm) {
        throw new Error(
          "could not find default-label literal in counter_state.nim — " +
            "fixture has drifted.",
        );
      }
      writeFileSync(NIM_VM_SOURCE, edited);

      // Wait for Vite to dispatch an HMR update. The plugin's
      // handleHotUpdate must return a non-empty module list for
      // counter.nim → Vite sends a `hot updated` message → the
      // client logs it. Generous timeout because the Nim
      // recompile dominates (~1-3s on a warm cache).
      await expect
        .poll(() => hmrUpdates.length, { timeout: 30_000 })
        .toBeGreaterThan(0);
      expect(hmrUpdates.some((u) => u.includes("counter.nim"))).toBe(true);
    } finally {
      writeFileSync(NIM_VM_SOURCE, originalVm);
    }
  });
});
