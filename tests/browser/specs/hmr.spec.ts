import { test, expect } from "@playwright/test";

// Strong integration test for IsoNim HMR with ui-as-boundary design.
//
// Fixture structure:
//   app — entry component, contains <h1>, unchangedRow(), mutableRow(), filler.
//   unchangedRow — contains an <input>, focus/value targets.
//   mutableRow — what we "edit" via the harness; swapping its slot factory
//     simulates the user editing only this component.
//
// What this proves with the new ui-as-boundary design:
//   1. A swap does not cause a full navigation.
//   2. Container element identity preserved (#app is the same JS object).
//   3. Window scroll position survives.
//   4. The mutableRow's text changes after the simulated reload.
//   5. **Element identity inside an unchanged sibling component is
//      preserved**: <input>'s JS reference is the same before and after
//      the mutableRow swap. (The whole point of ui-as-boundary.)
//   6. **Focus on an input in an unchanged component survives** the swap.
//   7. **Typed input value in an unchanged component survives** the swap.
//   8. A signal whose value lives at module scope (preservedCounter)
//      keeps its value across the swap. (This is shared state, not
//      hmrSignal, but module-scope vars persist naturally.)
//   9. A swap into a factory that throws preserves the previous DOM
//      and reports via onError.
//  10. Repeated swaps don't leak registry entries.
//  11. Generation counter advances.

const HMR_PROBE_FN = async () =>
  Boolean((window as any).__hmrTest && (window as any).__isonim_hmr_root);

test.describe("IsoNim Hot Module Reload (ui-as-boundary)", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await page.waitForFunction(HMR_PROBE_FN);
    await page.evaluate(() => {
      (window as any).__hmrNavBaseline = (window as any).__hmrNavigations;
    });
  });

  test("simulated reload does not cause a full navigation", async ({
    page,
  }) => {
    const before = await page.evaluate(
      () => performance.getEntriesByType("navigation").length,
    );
    await page.evaluate(() => (window as any).__hmrTest.simulateMutableAfter());
    const after = await page.evaluate(
      () => performance.getEntriesByType("navigation").length,
    );
    expect(after).toBe(before);

    const navDelta = await page.evaluate(
      () => (window as any).__hmrNavigations - (window as any).__hmrNavBaseline,
    );
    expect(navDelta).toBe(0);
  });

  test("container element keeps identity", async ({ page }) => {
    const containerHandle = await page.evaluateHandle(() =>
      document.getElementById("app"),
    );
    await page.evaluate(() => (window as any).__hmrTest.simulateMutableAfter());
    const stillSame = await page.evaluate((h) => {
      const c = document.getElementById("app");
      return c !== null && c.isSameNode(h as Node);
    }, containerHandle);
    expect(stillSame).toBe(true);
  });

  test("scroll position is preserved", async ({ page }) => {
    await page.evaluate(() => window.scrollTo(0, 400));
    await page.waitForFunction(() => Math.round(window.scrollY) === 400);

    await page.evaluate(() => (window as any).__hmrTest.simulateMutableAfter());

    const y = await page.evaluate(() => Math.round(window.scrollY));
    expect(y).toBe(400);
  });

  test("the simulated edit changes only the mutableRow's text", async ({
    page,
  }) => {
    await expect(page.locator("#mutable-label")).toHaveText("before");
    await expect(page.locator("#mutable-extra")).toHaveCount(0);

    await page.evaluate(() => (window as any).__hmrTest.simulateMutableAfter());

    await expect(page.locator("#mutable-label")).toHaveText("after");
    await expect(page.locator("#mutable-extra")).toHaveText(
      "new content from edit",
    );
  });

  test("input element in the unchanged component keeps its JS identity", async ({
    page,
  }) => {
    const inputHandle = await page.evaluateHandle(() =>
      document.getElementById("text-input"),
    );

    await page.evaluate(() => (window as any).__hmrTest.simulateMutableAfter());

    const stillSame = await page.evaluate((h) => {
      const current = document.getElementById("text-input");
      return current !== null && current.isSameNode(h as Node);
    }, inputHandle);
    expect(stillSame).toBe(true);
  });

  test("focus on an input in the unchanged component survives", async ({
    page,
  }) => {
    await page.click("#text-input");
    await expect(page.locator("#text-input")).toBeFocused();

    await page.evaluate(() => (window as any).__hmrTest.simulateMutableAfter());

    await expect(page.locator("#text-input")).toBeFocused();
  });

  test("typed input value in the unchanged component survives", async ({
    page,
  }) => {
    await page.fill("#text-input", "hello world");

    await page.evaluate(() => (window as any).__hmrTest.simulateMutableAfter());

    await expect(page.locator("#text-input")).toHaveValue("hello world");
  });

  test("preserved counter (module-scope signal) keeps its value", async ({
    page,
  }) => {
    await page.click("#preserved-inc");
    await page.click("#preserved-inc");
    await page.click("#preserved-inc");
    await expect(page.locator("#preserved-count")).toHaveText("3");

    await page.evaluate(() => (window as any).__hmrTest.simulateMutableAfter());

    await expect(page.locator("#preserved-count")).toHaveText("3");
  });

  test("a broken simulated reload preserves DOM and reports the error", async ({
    page,
  }) => {
    await page.click("#preserved-inc");
    await expect(page.locator("#preserved-count")).toHaveText("1");

    await page.evaluate(() => {
      (window as any).__capturedErrors = [];
      (window as any).__hmrTest.onError((msg: unknown) => {
        (window as any).__capturedErrors.push(String(msg));
      });
    });

    await page.evaluate(() =>
      (window as any).__hmrTest.simulateMutableBroken(),
    );

    // mutableRow should still show its previous content (because the
    // broken factory threw).
    await expect(page.locator("#mutable-label")).toHaveText("before");
    await expect(page.locator("#preserved-count")).toHaveText("1");

    const errors = await page.evaluate(() => (window as any).__capturedErrors);
    expect(errors.length).toBeGreaterThanOrEqual(1);
    expect(errors[0]).toContain("boom");

    const navDelta = await page.evaluate(
      () => (window as any).__hmrNavigations - (window as any).__hmrNavBaseline,
    );
    expect(navDelta).toBe(0);
  });

  test("repeated swaps don't leak registry entries", async ({ page }) => {
    const initialRegistrySize = await page.evaluate(() =>
      (window as any).__hmrTest.registrySize(),
    );

    await page.evaluate(() => {
      for (let i = 0; i < 50; i++) {
        (window as any).__hmrTest.simulateMutableAfter();
      }
    });

    const finalRegistrySize = await page.evaluate(() =>
      (window as any).__hmrTest.registrySize(),
    );

    // No new slots should be created — we keep updating the same one.
    expect(finalRegistrySize).toBeLessThanOrEqual(initialRegistrySize + 1);
  });

  test("generation counter advances with each register call", async ({
    page,
  }) => {
    const before = await page.evaluate(() =>
      (window as any).__hmrTest.generation(),
    );
    await page.evaluate(() => (window as any).__hmrTest.simulateMutableAfter());
    const after1 = await page.evaluate(() =>
      (window as any).__hmrTest.generation(),
    );
    expect(after1).toBeGreaterThan(before);
  });
});
