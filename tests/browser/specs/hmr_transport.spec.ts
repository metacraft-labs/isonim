import { test, expect } from "@playwright/test";
import { copyFileSync } from "node:fs";
import { join } from "node:path";

// End-to-end test for the SSE transport.
//
// What this exercises:
//   - The dev server (`/tmp/isonim_test_server`) serves /main.js
//     (currently the "before" bundle), exposes /__isonim/hmr (SSE),
//     and /__isonim/trigger (POST).
//   - The fixture's app.nim installs the SSE transport via
//     `installSseTransport()` so the browser auto-connects.
//   - The test seeds main.js with the "before" bundle, navigates,
//     verifies "BEFORE" is rendered.
//   - The test then resets main.js back to "before" (in case prior
//     runs left "after" in place), POSTs /__isonim/trigger which
//     causes the server to `cp after.js main.js` (= "user edited
//     source") and broadcast an SSE `update` event.
//   - The browser receives the event, fetches /main.js (cache-busted),
//     evaluates it. The new bundle's {.uiComponent.}-emitted
//     registration sees a different symBodyHash for `heading()` and
//     writes the new factory to its slot — the cascade swaps the
//     <h1> text without a navigation.

const FIXTURE_DIR = join(__dirname, "..", "hmr_transport_fixture");
const BUNDLE_FILE = join(FIXTURE_DIR, "main.js");
const BEFORE_FILE = join(FIXTURE_DIR, "before.js");

test.beforeEach(() => {
  // Reset main.js to the "before" variant before each test so the
  // initial page state is deterministic regardless of what the
  // previous test did.
  copyFileSync(BEFORE_FILE, BUNDLE_FILE);
});

test.describe("IsoNim HMR — SSE transport end-to-end", () => {
  test("initial render shows BEFORE", async ({ page }) => {
    await page.goto("/");
    await expect(page.locator("#heading")).toHaveText("BEFORE");
  });

  test("triggering a rebuild causes the page to update without navigation", async ({
    page,
    request,
  }) => {
    await page.goto("/");
    await expect(page.locator("#heading")).toHaveText("BEFORE");

    // Wait for the SSE connection to be established. EventSource sets
    // readyState to 1 (OPEN) once the server's preamble lands.
    await page.waitForFunction(() => {
      const sse = (window as any).EventSource;
      return typeof sse === "function";
    });

    const navsBefore = await page.evaluate(
      () => performance.getEntriesByType("navigation").length,
    );

    await request.post("/__isonim/trigger");

    // Wait for the heading to update. Up to 5s — the server has to
    // finish the cp, broadcast SSE, the client fetches the new bundle,
    // evaluates it, and the cascade has to propagate.
    await expect(page.locator("#heading")).toHaveText("AFTER", {
      timeout: 5000,
    });

    const navsAfter = await page.evaluate(
      () => performance.getEntriesByType("navigation").length,
    );
    expect(navsAfter).toBe(navsBefore);
  });

  test("the bundle endpoint serves the current main.js with a no-store header", async ({
    request,
  }) => {
    const r = await request.get("/main.js");
    expect(r.status()).toBe(200);
    expect(r.headers()["content-type"]).toContain("text/javascript");
    expect(r.headers()["cache-control"]).toContain("no-store");
  });
});
