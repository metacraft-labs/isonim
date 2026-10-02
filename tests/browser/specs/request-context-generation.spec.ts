// test_stale_context_response_dropped (IFP-M2).
//
// The nginx fixture (tests/nginx/README.md): the page's client calls the
// route manifest's generated clients for `GET /api/v1/delayed` (scope
// csAccount) and `GET /api/v1/delayed-nav` (scope csNavigation), which the
// server answers after `ms` milliseconds.  An applied response sets a
// signal (shown in #value, counted by an effect), a cache entry and a
// localStorage key (tests/nginx/fixture_client.nim).
//
// Each case changes the client context while the response is delayed
// (URL-Schema.md §5.4):
//   * account switch and incarnation change: the response reaches the
//     client (HTTP 200 with the value) and is dropped;
//   * navigation: the navigation-scoped request is aborted, and dropped.
// Vacuity guard: the dropped-response hook saw it, and no signal, cache or
// storage changed.  Negative controls: without a context change the same
// response is applied; an account-scoped response survives a navigation.
//
// Two navigation races the abort alone does not settle:
//   * the abort lands after the response headers, while the body is being
//     read: `text()` rejects with AbortError, which must still be a drop
//     (hook reason navigation, status -1), never an exception.  The
//     response comes from a small HTTP server this spec runs behind the
//     fixture's nginx (`/api/v1/slow-body`, proxied unbuffered): it sends
//     the headers and holds the body until the test releases it;
//   * the navigation lands after the body has been read, before the
//     client's continuation runs: the abort can no longer reach the request,
//     so only the navigation-generation check drops it.  The test harness
//     injects the navigation at exactly that point (a wrapper of
//     Response.prototype.text that navigates once the body is in).
//
// Falsifying mutations (tests/nginx/run_mutants.sh):
//   * no-generation: a client built with the generation check removed
//     applies the stale responses; the account and incarnation cases fail;
//   * no-navigation-generation: staleReason without its navigation branch
//     (client_context.nim); the after-the-body navigation case fails;
//   * body-abort: rawFetch handling only an abort that rejects fetch() (the
//     abort while the body is read reaches the caller); the slow-body case
//     fails.
//
// Mocks: the slow-body upstream is a test-owned HTTP server, not a mock of
// anything under test: it stands in for any server whose body is slow, so
// that the browser's fetch is caught between headers and body; nginx (the
// real module's fixture) proxies it, and the client is the real one.
// Nothing else is mocked.

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { test, expect, type Page } from "@playwright/test";

declare global {
  interface Window {
    fx: any;
    fxReady: boolean;
    __navigateAfterBody: string | null;
    __fxErrors: string[];
  }
}

type State = {
  value: string;
  effectRuns: number;
  cacheSize: number;
  dropped: number;
  dropReason: string;
  dropStatus: number;
  storage: string | null;
};

async function state(page: Page): Promise<State> {
  return page.evaluate(() => ({
    ...window.fx.state(),
    storage: window.localStorage.getItem("fx.value"),
  }));
}

async function expectUnchanged(page: Page, before: State) {
  const after = await state(page);
  expect(after.value).toBe(before.value);
  expect(after.effectRuns).toBe(before.effectRuns);
  expect(after.cacheSize).toBe(before.cacheSize);
  expect(after.storage).toBe(before.storage);
  expect(await page.locator("#value").textContent()).toBe(before.value);
  return after;
}

test.beforeEach(async ({ page }) => {
  await page.goto("/");
  await page.waitForFunction(() => window.fxReady === true);
});

const delayed = (path: string) => (r: { url(): string }) =>
  new URL(r.url()).pathname === path;

for (const c of [
  { name: "account switch", change: () => window.fx.switchAccount(), reason: "account" },
  {
    name: "incarnation change",
    change: () => window.fx.changeIncarnation("inc-2"),
    reason: "incarnation",
  },
]) {
  test(`${c.name}: the delayed response reaches the client and is dropped`, async ({ page }) => {
    const before = await state(page);
    const sent = page.waitForRequest(delayed("/api/v1/delayed"));
    const arrived = page.waitForResponse(delayed("/api/v1/delayed"));
    await page.evaluate(() => {
      window.fx.load(800, "stale", "account");
    });
    expect((await sent).headers()["x-isonim-context"]).toBe("inc-1:0");
    await page.evaluate(c.change);
    const resp = await arrived;
    expect(resp.status()).toBe(200);
    expect(await resp.json()).toEqual({ value: "stale" });
    await page.waitForFunction((n) => window.fx.state().dropped > n, before.dropped);
    const after = await expectUnchanged(page, before);
    expect(after.dropped).toBe(before.dropped + 1);
    expect(after.dropReason).toBe(c.reason);
    expect(after.dropStatus).toBe(200);
  });
}

test("navigation: the navigation-scoped request is aborted and dropped", async ({ page }) => {
  const before = await state(page);
  const sent = page.waitForRequest(delayed("/api/v1/delayed-nav"));
  const failed = page.waitForEvent("requestfailed", delayed("/api/v1/delayed-nav"));
  await page.evaluate(() => {
    window.fx.load(800, "stale-nav", "navigation");
  });
  await sent;
  await page.evaluate(() => window.fx.navigate("/other"));
  expect((await failed).failure()?.errorText).toContain("ERR_ABORTED");
  await page.waitForFunction((n) => window.fx.state().dropped > n, before.dropped);
  const after = await expectUnchanged(page, before);
  expect(after.dropReason).toBe("navigation");
  expect(after.dropStatus).toBe(-1);
});

test("negative control: without a context change the response is applied", async ({ page }) => {
  const before = await state(page);
  const arrived = page.waitForResponse(delayed("/api/v1/delayed"));
  await page.evaluate(() => {
    window.fx.load(300, "fresh", "account");
  });
  await arrived;
  await page.waitForFunction(() => window.fx.state().value === "fresh");
  const after = await state(page);
  expect(after.effectRuns).toBe(before.effectRuns + 1);
  expect(after.cacheSize).toBe(before.cacheSize + 1);
  expect(after.storage).toBe("fresh");
  expect(after.dropped).toBe(before.dropped);
  await expect(page.locator("#value")).toHaveText("fresh");
});

test("negative control: an account-scoped response survives a navigation", async ({ page }) => {
  const before = await state(page);
  const sent = page.waitForRequest(delayed("/api/v1/delayed"));
  await page.evaluate(() => {
    window.fx.load(800, "kept", "account");
  });
  await sent;
  await page.evaluate(() => window.fx.navigate("/other"));
  await page.waitForFunction(() => window.fx.state().value === "kept");
  const after = await state(page);
  expect(after.dropped).toBe(before.dropped);
  expect(after.storage).toBe("kept");
});

test("navigation after the body is read: only the generation check drops it", async ({ page }) => {
  // The harness navigates the moment the body of /api/v1/delayed-nav has
  // been read: the request completed, so its abort is a no-op, and the
  // response reaches the client (HTTP 200, the value) under a new
  // navigation generation.
  await page.addInitScript(() => {
    const text = Response.prototype.text;
    Response.prototype.text = function (this: Response) {
      const path = new URL(this.url).pathname;
      return text.call(this).then((t: string) => {
        if (window.__navigateAfterBody === path) {
          window.__navigateAfterBody = null;
          window.fx.navigate("/other");
        }
        return t;
      });
    };
  });
  await page.goto("/");
  await page.waitForFunction(() => window.fxReady === true);
  const before = await state(page);
  const navBefore = await page.evaluate(() => window.fx.state().navigationGeneration);
  const arrived = page.waitForResponse(delayed("/api/v1/delayed-nav"));
  let failed = false;
  page.on("requestfailed", (r) => {
    if (delayed("/api/v1/delayed-nav")(r)) failed = true;
  });
  await page.evaluate(() => {
    window.__navigateAfterBody = "/api/v1/delayed-nav";
    window.fx.load(100, "late-nav", "navigation");
  });
  const resp = await arrived;
  expect(resp.status()).toBe(200);
  expect(await resp.json()).toEqual({ value: "late-nav" });
  expect(await resp.finished()).toBeNull(); // completed, not aborted
  await page.waitForFunction((n) => window.fx.state().dropped > n, before.dropped);
  expect(failed).toBe(false);
  expect(await page.evaluate(() => window.__navigateAfterBody)).toBeNull(); // it ran
  expect(await page.evaluate(() => window.fx.state().navigationGeneration)).toBe(navBefore + 1);
  const after = await expectUnchanged(page, before);
  expect(after.dropped).toBe(before.dropped + 1);
  expect(after.dropReason).toBe("navigation");
  expect(after.dropStatus).toBe(200);
});

test.describe("slow body", () => {
  // The upstream of the fixture's /api/v1/slow-body (fixture_conf.sh): the
  // port after nginx's.  It answers with the headers at once and the body
  // only when `release` is called.
  let server: ReturnType<typeof createServer>;
  let pending: ServerResponse[] = [];
  let headersSent: Promise<void>;
  let onHeaders: () => void;
  const body = JSON.stringify({ value: "slow-body" });

  test.beforeAll(async ({}, info) => {
    const port = Number(new URL(info.project.use.baseURL as string).port) + 1;
    server = createServer((_req: IncomingMessage, res: ServerResponse) => {
      res.on("error", () => {});
      res.writeHead(200, {
        "Content-Type": "application/json",
        "Content-Length": String(Buffer.byteLength(body)),
        "Cache-Control": "private, no-store",
      });
      res.flushHeaders();
      pending.push(res);
      onHeaders();
    });
    await new Promise<void>((resolve) => server.listen(port, "127.0.0.1", resolve));
  });

  test.beforeEach(() => {
    headersSent = new Promise<void>((resolve) => (onHeaders = resolve));
  });

  const release = () => {
    for (const res of pending) {
      try {
        res.end(body);
      } catch {
        // the client is gone: nothing to deliver
      }
    }
    pending = [];
  };

  test.afterAll(async () => {
    release();
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  });

  test("navigation while the body is read: dropped, no exception", async ({ page }) => {
    const errors: string[] = [];
    page.on("pageerror", (e) => errors.push(String(e)));
    const before = await state(page);
    const headers = page.waitForResponse(delayed("/api/v1/slow-body"));
    await page.evaluate(() => {
      window.__fxErrors = [];
      window.fx.loadSlowBody("slow-body").catch((e: unknown) => window.__fxErrors.push(String(e)));
    });
    await headersSent;
    const resp = await headers; // the browser has the headers; the body is held back
    expect(resp.status()).toBe(200);
    await page.evaluate(() => window.fx.navigate("/other"));
    // The call settles one way or the other: dropped (the hook runs), or
    // the abort surfaces as an exception.
    await page.waitForFunction(
      (n) => window.fx.state().dropped > n || window.__fxErrors.length > 0,
      before.dropped,
    );
    release(); // too late: the request was aborted
    expect(await page.evaluate(() => window.__fxErrors)).toEqual([]);
    expect(errors).toEqual([]);
    const after = await expectUnchanged(page, before);
    expect(after.dropped).toBe(before.dropped + 1);
    expect(after.dropReason).toBe("navigation");
    expect(after.dropStatus).toBe(-1);
  });

  test("negative control: without a navigation the slow body is applied", async ({ page }) => {
    const before = await state(page);
    await page.evaluate(() => {
      window.__fxErrors = [];
      window.fx.loadSlowBody("slow-body").catch((e: unknown) => window.__fxErrors.push(String(e)));
    });
    await headersSent;
    release();
    await page.waitForFunction(() => window.fx.state().value === "slow-body");
    const after = await state(page);
    expect(after.dropped).toBe(before.dropped);
    expect(after.storage).toBe("slow-body");
    expect(await page.evaluate(() => window.__fxErrors)).toEqual([]);
  });
});
