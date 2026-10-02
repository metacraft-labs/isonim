// test_server_function_post_roundtrip_async (IFP-M2).
//
// The nginx fixture (tests/nginx/README.md): real nginx, one worker, with
// the real ngx-isonim module serving the route manifest and the server
// functions of tests/nginx (`isonim_rpc on`, `isonim_rpc_max_body_size
// 1100k`).  The page's client (tests/nginx/fixture_client.nim) calls the
// async server functions through their generated `fetch` stubs.
//
// Vacuity guard: the results are typed and correct; a 1 MB argument
// arrives whole; a body over isonim_rpc_max_body_size is answered 413; a
// request sent while a slow server function is suspended completes before
// it, on the same worker; the browser's main thread keeps running and no
// XMLHttpRequest (let alone a synchronous one) is ever opened.
//
// Falsifying mutation (tests/nginx/run_mutants.sh): a module that runs the
// handler synchronously in nginx's content phase makes the concurrency
// test fail.
//
// No mocks.

import { test, expect, type Page } from "@playwright/test";

declare global {
  interface Window {
    fx: any;
    fxReady: boolean;
    __xhr: { opened: number; sync: number };
    __fetches: string[];
  }
}

async function open(page: Page) {
  await page.addInitScript(() => {
    window.__xhr = { opened: 0, sync: 0 };
    const xhrOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (this: XMLHttpRequest, ...args: any[]) {
      window.__xhr.opened++;
      if (args.length > 2 && args[2] === false) window.__xhr.sync++;
      return (xhrOpen as any).apply(this, args);
    } as any;
    window.__fetches = [];
    const realFetch = window.fetch;
    window.fetch = function (input: any, init?: any) {
      window.__fetches.push(String(input));
      return realFetch.call(window, input, init);
    } as any;
  });
  await page.goto("/");
  await page.waitForFunction(() => window.fxReady === true);
}

test.beforeEach(async ({ page }) => {
  await open(page);
});

test.afterEach(async ({ page }) => {
  // No test may ever open an XMLHttpRequest, synchronous or not.
  const xhr = await page.evaluate(() => window.__xhr);
  expect(xhr).toEqual({ opened: 0, sync: 0 });
});

test("async server functions return typed results over POST", async ({ page }) => {
  const req = page.waitForRequest((r) => r.url().endsWith("/api/v1/rpc/fixture_rpc/sum"));
  expect(await page.evaluate(() => window.fx.sum(2, 40))).toBe(42);
  const sent = await req;
  expect(sent.method()).toBe("POST");
  expect(sent.headers()["content-type"]).toBe("application/json");
  expect(sent.headers()["x-isonim-context"]).toBe("inc-1:0");
  expect(sent.headers()["x-csrf-token"]?.length).toBeGreaterThan(40);
  expect(JSON.parse(sent.postData() ?? "")).toEqual({ a: 2, b: 40 });
  expect(await page.evaluate(() => window.fx.describe(2, 3, "pair"))).toEqual({
    a: 2,
    b: 3,
    sum: 5,
    label: "pair",
  });
});

test("a 1 MB argument arrives whole", async ({ page }) => {
  const r = await page.evaluate(() => window.fx.bodySize(1024 * 1024));
  expect(r).toEqual({ ok: true, value: 1024 * 1024 });
});

test("a body over isonim_rpc_max_body_size is answered 413", async ({ page }) => {
  const resp = page.waitForResponse((r) => r.url().endsWith("/fixture_rpc/bodySize"));
  const r = await page.evaluate(() => window.fx.bodySize(1536 * 1024));
  expect(r).toEqual({ ok: false, status: 413 });
  expect((await resp).status()).toBe(413);
});

test("a concurrent request completes during the slow server function; the main thread never blocks", async ({
  page,
}) => {
  const r = await page.evaluate(async () => {
    const fx = window.fx;
    const t0 = performance.now();
    let ticks = 0;
    const timer = setInterval(() => ticks++, 20);
    let slowDone = -1;
    const slow = fx.slow(1500).then((v: string) => {
      slowDone = performance.now() - t0;
      return v;
    });
    // Wait (bounded) until the server is inside slowOp.  Each poll is
    // itself a request the worker serves while slowOp is suspended.
    let pending = 0;
    while (performance.now() - t0 < 3000) {
      pending = await fx.slowPending();
      if (pending >= 1) break;
    }
    const fastStart = performance.now();
    const fast = await fx.fast();
    const fastDone = performance.now() - t0;
    const fastLatency = performance.now() - fastStart;
    const slowValue = await slow;
    const ticksDuringSlow = ticks;
    clearInterval(timer);
    return { pending, fast, fastDone, fastLatency, slowValue, slowDone, ticksDuringSlow };
  });
  // The fast call finished while the slow one was still suspended on the
  // same worker, and quickly.
  expect(r.fastDone).toBeLessThan(r.slowDone);
  expect(r.fastLatency).toBeLessThan(500);
  expect(r.pending).toBeGreaterThanOrEqual(1);
  expect(r.fast).toBe("fast");
  expect(r.slowValue).toBe("slow:1500");
  expect(r.slowDone).toBeGreaterThanOrEqual(1500);
  // The main thread ran its timer throughout (a blocked thread runs none).
  expect(r.ticksDuringSlow).toBeGreaterThan(1500 / 20 / 2);
  const fetches = await page.evaluate(() => window.__fetches);
  expect(fetches.filter((u) => u.includes("/fixture_rpc/")).length).toBeGreaterThanOrEqual(3);
});
