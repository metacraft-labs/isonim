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

  test("editing a transitively-imported .nim file also triggers HMR (proves the plugin's dep walker)", async ({
    page,
  }) => {
    // counter.nim imports ./counter_state.nim. Vite has no idea
    // about that edge — the .nim file isn't a Vite module. The
    // plugin's transitiveNimDeps walker has to surface the
    // import to Vite via `addWatchFile` AND map a counter_state
    // edit back to counter.nim in handleHotUpdate. If either
    // breaks, this test times out because Vite never schedules
    // an HMR update.
    const originalVm = captureNimSource(NIM_VM_SOURCE);
    try {
      await page.goto("/");
      await expect(page.locator("#counter-root")).toBeVisible();

      await page.click("#counter-inc");
      await page.click("#counter-inc");
      await expect(page.locator("#counter-label")).toContainText(
        "Count: 2 clicks",
      );

      // Edit the imported module: change the default label.
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

      // The module-scope `counterVm = newCounterVm()` runs at
      // module init. When Vite invalidates counter.nim because
      // counter_state.nim changed and the new bundle re-runs the
      // init, a *new* CounterVm with `label = "taps"` replaces
      // the old one. The mount's reactive closure still holds
      // the old `counterVm` ref, so the assertion is: a fresh
      // page load *would* show "taps", but the current mount
      // continues to show "clicks". This is the standard caveat
      // for module-scope state that the host's HMR can't reach;
      // the spec docs the limitation in
      // Hot-Module-Reload-Host-Interop.md anti-patterns.
      //
      // What we *can* assert: HMR fired (Vite ran handleHotUpdate
      // and dispatched an update). We detect that by watching the
      // counter slot re-render — the new module init re-registers
      // the slot which re-runs the mount's effect. Element
      // identity of #counter-root changes when the slot factory
      // is rewritten.
      const handleBefore = await page.evaluateHandle(() =>
        document.getElementById("counter-root"),
      );
      // Wait for the slot factory to be replaced (a new node
      // with the same id is inserted). We use a polling
      // expression because the swap is async after the WS
      // message lands.
      await page.waitForFunction(
        (oldRef) => {
          const cur = document.getElementById("counter-root");
          return cur !== null && !cur.isSameNode(oldRef as Node);
        },
        handleBefore,
        { timeout: 30_000 },
      );
    } finally {
      writeFileSync(NIM_VM_SOURCE, originalVm);
    }
  });
});
