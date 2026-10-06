// The SSR -> hydrate -> interact round trip against real nginx with the
// ngx-isonim module (milestone IFP-M3, test_ssr_hydration_round_trip).
//
// The pages are rendered inside nginx by tests/nginx/hydration_app.nim,
// once per SSR mode (`ui:` string mode at /ssr.html, `uiWrite` stream mode
// at /ssr-stream.html), with the module's `_$HY` bootstrap appended. The
// client, tests/nginx/hydration_client.nim (/static/hydrate.js, `defer`),
// builds the same tree with `ui(r):` and `hydrate`s it.
//
// No mocks: real nginx, the real module, the real client bundle, Chromium.
// Where a test needs the page BEFORE hydration (identity marking, a click
// to replay) it holds /static/hydrate.js back with a route that waits on a
// promise the test resolves, rather than on a timer.
//
// Identity is element identity: hydration adopts every server-rendered
// element and re-creates the text nodes (by design, IsoNim.md § Hydration).
// So the elements are checked by identity, and the text, which re-created
// nodes could silently change, by value: every element's textContent after
// hydration equals the server's.
//
// Falsifying mutation (tests/nginx/run_mutants.sh `no-data-hk`): a module
// whose SSR emits no `data-hk` makes the identity assertion fail: the
// client then finds nothing to adopt and builds a second copy.
import { test, expect, Page } from "@playwright/test";

type Gate = { release: () => void };

// Holds the client bundle until `release()`: the page is parsed and painted
// (the bundle is `defer`, so DOMContentLoaded waits for it, not the paint).
async function holdClient(page: Page): Promise<Gate> {
  let release!: () => void;
  const gate = new Promise<void>((r) => (release = r));
  await page.route("**/static/hydrate.js", async (route) => {
    await gate;
    await route.continue();
  });
  return { release };
}

async function gotoServerRendered(page: Page, path: string) {
  await page.goto(path, { waitUntil: "commit" });
  await expect(page.locator(".task-list li")).toHaveCount(3);
  await page.waitForFunction(() => Array.isArray((window as any)._$HY?.events));
}

async function waitHydrated(page: Page) {
  await page.waitForFunction(() => (window as any)._$HY?.done === true);
}

// Gives every element under #root a marker property and records its
// server-rendered textContent; returns how many elements and #root's text.
async function markServerNodes(page: Page): Promise<{ count: number; text: string }> {
  return page.evaluate(() => {
    const els = Array.from(document.querySelectorAll("#root *"));
    els.forEach((el, i) => {
      (el as any).__ssrMark = i + 1;
      (el as any).__ssrText = el.textContent;
    });
    return { count: els.length, text: document.getElementById("root")!.textContent! };
  });
}

// The server text against the hydrated text: #root's, and how many marked
// elements' textContent changed.
async function textReport(page: Page) {
  return page.evaluate(() => {
    const els = Array.from(document.querySelectorAll("#root *"));
    return {
      text: document.getElementById("root")!.textContent!,
      changed: els.filter(
        (el) => (el as any).__ssrMark !== undefined && el.textContent !== (el as any).__ssrText,
      ).length,
    };
  });
}

async function identityReport(page: Page) {
  return page.evaluate(() => {
    const els = Array.from(document.querySelectorAll("#root *"));
    return {
      total: els.length,
      unmarked: els.filter((el) => (el as any).__ssrMark === undefined).length,
      mismatches: (window as any)._$HY.mismatches,
      rootChildren: document.getElementById("root")!.children.length,
    };
  });
}

for (const [mode, path] of [
  ["string mode", "/ssr.html"],
  ["stream mode", "/ssr-stream.html"],
] as const) {
  test.describe(`SSR Hydration (${mode})`, () => {
    test("SSR HTML renders without JavaScript", async ({ browser }) => {
      const context = await browser.newContext({ javaScriptEnabled: false });
      const page = await context.newPage();
      await page.goto(path);

      await expect(page.locator("h1").first()).toHaveText("IsoNim Task Manager");
      await expect(page.locator(".task-list li")).toHaveCount(3);
      await expect(page.locator(".task-list li").nth(0).locator("span")).toHaveText(
        "Buy groceries",
      );
      await expect(page.locator(".task-list li").nth(1).locator("span")).toHaveText(
        "Write tests",
      );
      await expect(page.locator(".task-list li").nth(2).locator("span")).toHaveText(
        "Deploy app",
      );
      await expect(page.locator(".task-list li.completed")).toHaveCount(1);
      await expect(page.locator(".task-list li").nth(2)).toHaveClass(/completed/);
      await expect(page.locator(".task-footer span")).toContainText("2 items left");

      await context.close();
    });

    test("hydration markers are present in SSR HTML", async ({ browser }) => {
      const context = await browser.newContext({ javaScriptEnabled: false });
      const page = await context.newPage();
      await page.goto(path);

      const htmlContent = await page.content();
      expect(htmlContent).toContain("data-hk=");
      expect(htmlContent).toContain("_$HY");

      // Every element the app rendered carries a key, numbered 1..n in
      // document order (what the client's createElement count expects).
      const keys = await page.evaluate(() =>
        Array.from(document.querySelectorAll("#root *")).map((el) =>
          el.getAttribute("data-hk"),
        ),
      );
      expect(keys.length).toBeGreaterThan(20);
      expect(keys).toEqual(keys.map((_, i) => String(i + 1)));

      await context.close();
    });

    test("hydration preserves SSR content", async ({ page }) => {
      const gate = await holdClient(page);
      await gotoServerRendered(page, path);
      const server = await markServerNodes(page);
      expect(server.text).toContain("Buy groceries");
      gate.release();
      await waitHydrated(page);

      // The hydrated elements are the server's: every element under #root
      // still carries its marker, and there are no others (no second copy).
      const r = await identityReport(page);
      expect(r).toEqual({ total: server.count, unmarked: 0, mismatches: 0, rootChildren: 1 });
      // The text nodes are re-created; their content is the server's,
      // element by element.
      expect(await textReport(page)).toEqual({ text: server.text, changed: 0 });

      await expect(page.locator("h1").first()).toHaveText("IsoNim Task Manager");
      await expect(page.locator(".task-list li")).toHaveCount(3);
      await expect(page.locator(".task-list li").nth(0).locator("span")).toHaveText(
        "Buy groceries",
      );
      await expect(page.locator(".task-list li").nth(1).locator("span")).toHaveText(
        "Write tests",
      );
      await expect(page.locator(".task-list li").nth(2).locator("span")).toHaveText(
        "Deploy app",
      );
      await expect(page.locator(".task-list li.completed")).toHaveCount(1);
      await expect(page.locator(".task-footer span")).toContainText("2 items left");
      // The completed task's checkbox is checked as a property too.
      await expect(page.locator(".task-list li").nth(2).locator("input")).toBeChecked();
    });

    test("hydrated page is interactive - toggle task", async ({ page }) => {
      await page.goto(path);
      await waitHydrated(page);

      await page.click('.task-list li:first-child input[type="checkbox"]');

      await expect(page.locator(".task-list li").first()).toHaveClass(/completed/);
      await expect(page.locator(".task-footer span")).toContainText("1 item left");
    });

    test("hydrated page is interactive - add task", async ({ page }) => {
      await page.goto(path);
      await waitHydrated(page);

      await page.fill('input[type="text"]', "New hydrated task");
      await page.click('button[type="submit"]');

      await expect(page.locator(".task-list li")).toHaveCount(4);
      await expect(page.locator(".task-list li").nth(3).locator("span")).toHaveText(
        "New hydrated task",
      );
      await expect(page.locator(".task-footer span")).toContainText("3 items left");
      // The submission was handled by the client, not by a navigation.
      expect(new URL(page.url()).pathname).toBe(path);
    });

    test("hydrated page is interactive - filter tasks", async ({ page }) => {
      await page.goto(path);
      await waitHydrated(page);

      await expect(page.locator(".task-list li")).toHaveCount(3);

      await page.click('.filters button:has-text("active")');
      await expect(page.locator(".task-list li")).toHaveCount(2);
      await expect(page.locator(".task-list li").nth(0).locator("span")).toHaveText(
        "Buy groceries",
      );
      await expect(page.locator(".task-list li").nth(1).locator("span")).toHaveText(
        "Write tests",
      );
      await expect(page.locator(".filters button.selected")).toHaveText("active");

      await page.click('.filters button:has-text("completed")');
      await expect(page.locator(".task-list li")).toHaveCount(1);
      await expect(page.locator(".task-list li").first().locator("span")).toHaveText(
        "Deploy app",
      );

      await page.click('.filters button:has-text("all")');
      await expect(page.locator(".task-list li")).toHaveCount(3);
    });

    test("hydrated page is interactive - clear completed", async ({ page }) => {
      await page.goto(path);
      await waitHydrated(page);

      await expect(page.locator(".task-list li.completed")).toHaveCount(1);

      await page.click('button:has-text("Clear completed")');

      await expect(page.locator(".task-list li")).toHaveCount(2);
      await expect(page.locator(".task-list li.completed")).toHaveCount(0);
      await expect(page.locator('button:has-text("Clear completed")')).toHaveCount(0);
    });

    test("event replay during hydration", async ({ page }) => {
      const gate = await holdClient(page);
      await gotoServerRendered(page, path);
      const server = await markServerNodes(page);

      // A click before the client exists: the browser toggles the checkbox,
      // no handler runs, and the bootstrap records it.
      await page.click('.task-list li:first-child input[type="checkbox"]');
      const recorded = await page.evaluate(() =>
        (window as any)._$HY.events.map((e: [Element, Event]) => e[1].type),
      );
      expect(recorded.filter((t: string) => t === "click")).toHaveLength(1);
      await expect(page.locator(".task-footer span")).toContainText("2 items left");

      gate.release();
      await waitHydrated(page);

      // Replayed exactly once: the store toggled the task (zero replays
      // would leave it active, two would toggle it back), and the checkbox
      // the user checked stays checked (no second activation).
      await expect(page.locator(".task-list li").first()).toHaveClass(/completed/);
      await expect(page.locator(".task-footer span")).toContainText("1 item left");
      await expect(
        page.locator('.task-list li:first-child input[type="checkbox"]'),
      ).toBeChecked();
      // Recording stopped when the client took the queue.
      expect(await page.evaluate(() => (window as any)._$HY.events)).toBeNull();

      // And it happened on the server's nodes.
      const r = await identityReport(page);
      expect(r).toEqual({ total: server.count, unmarked: 0, mismatches: 0, rootChildren: 1 });
    });
  });
}
