import { test, expect } from "@playwright/test";

// Strong integration test for the parametric `{.uiComponent.}` extension.
//
// Fixture structure (`hmr_parametric_fixture/main.nim`):
//   Panel A — parametric component `panelA(vm: PanelAVm)` mounted via
//     `mountUiHot` into `#panel-a`. Renders an <input>, an increment
//     button, and a counter span.
//   Panel B — parametric component `panelB(vm, suffix)` mounted via
//     a separate `mountUiHot` into `#panel-b`. Has `before` / `after`
//     / `broken` factory variants the spec swaps in.
//
// What this spec proves on top of the existing zero-arg HMR spec:
//   1. Two independent `mountUiHot` mounts — swapping a slot reachable
//      only from one mount does not re-run the other mount's render
//      effect (DOM identity inside the unswapped mount survives).
//   2. The parametric dispatch routes args through to whichever
//      factory currently lives in the slot.
//   3. The parametric path passes correctly even with two args
//      (`panelB(vm, suffix)` — exercises the multi-arg generated
//      dispatch).
//   4. Failure containment for parametric: a broken factory leaves
//      the previous DOM intact and reports via `onError`.
//   5. The "after" variant adds a brand new element (`#panel-b-extra`)
//      not present in "before" — the spec confirms a real factory
//      replacement happened, not a same-DOM no-op.

const HMR_PROBE_FN = async () => Boolean((window as any).__hmrTest);

test.describe("IsoNim HMR — parametric components", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await page.waitForFunction(HMR_PROBE_FN);
    await page.evaluate(() => {
      (window as any).__hmrNavBaseline = (window as any).__hmrNavigations;
    });
  });

  test("initial render shows panels mounted into their containers", async ({
    page,
  }) => {
    await expect(page.locator("#panel-a-content")).toBeVisible();
    await expect(page.locator("#panel-b-content")).toBeVisible();
    await expect(page.locator("#panel-a-input")).toBeVisible();
    await expect(page.locator("#panel-a-counter")).toHaveText("0");
    // Initial label is "before"; the suffix the mount passed in is
    // "-suffix"; the parametric dispatch must have forwarded both.
    await expect(page.locator("#panel-b-label")).toHaveText("before-suffix");
  });

  test("Panel A input keeps element identity when Panel B is swapped", async ({
    page,
  }) => {
    const handle = await page.evaluateHandle(() =>
      document.getElementById("panel-a-input"),
    );

    await page.evaluate(() => (window as any).__hmrTest.simulateMutateBAfter());

    const stillSame = await page.evaluate((h) => {
      const cur = document.getElementById("panel-a-input");
      return cur !== null && cur.isSameNode(h as Node);
    }, handle);
    expect(stillSame).toBe(true);
  });

  test("Panel A focus + typed value survive a Panel B swap", async ({
    page,
  }) => {
    await page.click("#panel-a-input");
    await expect(page.locator("#panel-a-input")).toBeFocused();
    await page.fill("#panel-a-input", "hello world");

    await page.evaluate(() => (window as any).__hmrTest.simulateMutateBAfter());

    await expect(page.locator("#panel-a-input")).toBeFocused();
    await expect(page.locator("#panel-a-input")).toHaveValue("hello world");
  });

  test("Panel A counter (signal) keeps its value across a Panel B swap", async ({
    page,
  }) => {
    await page.click("#panel-a-inc");
    await page.click("#panel-a-inc");
    await page.click("#panel-a-inc");
    await expect(page.locator("#panel-a-counter")).toHaveText("3");

    await page.evaluate(() => (window as any).__hmrTest.simulateMutateBAfter());

    await expect(page.locator("#panel-a-counter")).toHaveText("3");
  });

  test("Panel B's text changes after the swap and a new element appears", async ({
    page,
  }) => {
    await expect(page.locator("#panel-b-label")).toHaveText("before-suffix");
    await expect(page.locator("#panel-b-extra")).toHaveCount(0);

    await page.evaluate(() => (window as any).__hmrTest.simulateMutateBAfter());

    await expect(page.locator("#panel-b-label")).toHaveText(
      "AFTER:before-suffix",
    );
    await expect(page.locator("#panel-b-extra")).toHaveText(
      "new content from edit",
    );
  });

  test("Panel B's parametric component still receives signal updates after the swap", async ({
    page,
  }) => {
    await page.evaluate(() => (window as any).__hmrTest.simulateMutateBAfter());
    await expect(page.locator("#panel-b-label")).toHaveText(
      "AFTER:before-suffix",
    );

    // The new factory still reads `vm.label.val` — writing the VM
    // signal should reflow through the new DOM.
    await page.evaluate(() => (window as any).__hmrTest.setPanelBLabel("ZZZ"));
    await expect(page.locator("#panel-b-label")).toHaveText("AFTER:ZZZ-suffix");
  });

  test("a broken Panel B swap preserves Panel A's DOM and reports the error", async ({
    page,
  }) => {
    await page.fill("#panel-a-input", "still here");
    await page.click("#panel-a-inc");
    await expect(page.locator("#panel-a-counter")).toHaveText("1");

    await page.evaluate(() => {
      (window as any).__capturedErrors = [];
      (window as any).__hmrTest.onError((msg: unknown) => {
        (window as any).__capturedErrors.push(String(msg));
      });
    });

    await page.evaluate(() =>
      (window as any).__hmrTest.simulateMutateBBroken(),
    );

    // Panel A is untouched.
    await expect(page.locator("#panel-a-input")).toHaveValue("still here");
    await expect(page.locator("#panel-a-counter")).toHaveText("1");

    const errors = await page.evaluate(() => (window as any).__capturedErrors);
    expect(errors.length).toBeGreaterThanOrEqual(1);
    expect(errors[0]).toContain("boom");

    const navDelta = await page.evaluate(
      () => (window as any).__hmrNavigations - (window as any).__hmrNavBaseline,
    );
    expect(navDelta).toBe(0);
  });

  test("simulated mutation does not cause a navigation", async ({ page }) => {
    const before = await page.evaluate(
      () => performance.getEntriesByType("navigation").length,
    );
    await page.evaluate(() => (window as any).__hmrTest.simulateMutateBAfter());
    const after = await page.evaluate(
      () => performance.getEntriesByType("navigation").length,
    );
    expect(after).toBe(before);
  });

  test("scroll position is preserved across a Panel B swap", async ({
    page,
  }) => {
    await page.evaluate(() => window.scrollTo(0, 400));
    await page.waitForFunction(() => Math.round(window.scrollY) === 400);

    await page.evaluate(() => (window as any).__hmrTest.simulateMutateBAfter());

    const y = await page.evaluate(() => Math.round(window.scrollY));
    expect(y).toBe(400);
  });

  test("repeated swaps don't leak registry entries", async ({ page }) => {
    const initial = await page.evaluate(() =>
      (window as any).__hmrTest.registrySize(),
    );
    await page.evaluate(() => {
      for (let i = 0; i < 50; i++) {
        (window as any).__hmrTest.simulateMutateBAfter();
      }
    });
    const finalSize = await page.evaluate(() =>
      (window as any).__hmrTest.registrySize(),
    );
    // Two slots (panelA + panelB) were registered at module init plus
    // the implicit re-registrations the harness drives. The bound
    // matches the zero-arg fixture's allowance.
    expect(finalSize).toBeLessThanOrEqual(initial + 1);
  });

  test("generation counter advances with each register call", async ({
    page,
  }) => {
    const before = await page.evaluate(() =>
      (window as any).__hmrTest.generation(),
    );
    await page.evaluate(() => (window as any).__hmrTest.simulateMutateBAfter());
    const after = await page.evaluate(() =>
      (window as any).__hmrTest.generation(),
    );
    expect(after).toBeGreaterThan(before);
  });
});
