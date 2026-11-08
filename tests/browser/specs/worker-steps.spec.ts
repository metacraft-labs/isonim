// The Web Worker target's stepwise handler and supervised bridge
// (isonim/web/worker.nim: serveWorkerSteps, newSupervisedBridge, onRestart;
// IsoNim.md § Web Worker Target).
//
// Fixture: tests/browser/worker_steps_fixture, built by
// `just build-worker-steps-fixture` into build/worker-steps-fixture:
//   steps.worker.js  steps_compile.nim served with serveWorkerSteps
//   steps_main.js    the page script: a supervised bridge (overrun 32 ms)
//                    recording results, errors and replacements on window.fx
//
// No mocks: real Chromium, real dedicated workers, the bundle tool itself.
//
// Each test is stated so that the feature's absence fails it (the mutations
// that were run against it are listed in its comment):
// * a superseded run is abandoned between steps: it is never answered;
// * a step that overruns while a newer revision waits gets the worker
//   replaced by the spare, `onRestart` names the re-posted revision, the
//   newer revision is answered long before the overrunning step would end,
//   and a second overrun is handled by the spare started after the first;
// * a JavaScript error in a step is that revision's error, and the worker
//   answers the next revision;
// * a stream of revisions posted faster than the overrun bound does not
//   postpone the replacement of a stuck worker.
import { test, expect, Page } from "@playwright/test";

async function open(page: Page) {
  await page.goto("/");
  await page.waitForFunction(() => (window as any).fx && (window as any).fx.post);
}

const post = (page: Page, stepMs: number[], throwAt: number, tag: string) =>
  page.evaluate(([s, t, g]) => (window as any).fx.post(s, t, g), [stepMs, throwAt, tag] as const);
const fx = (page: Page) => page.evaluate(() => JSON.parse(JSON.stringify((window as any).fx)));
const stats = (page: Page) => page.evaluate(() => (window as any).fx.stats());

// Mutation run: the worker's step loop not checking for a newer revision
// (it completes every run): fails on "the superseded run is never answered".
test("a superseded run is abandoned between steps", async ({ page }) => {
  await open(page);
  await post(page, Array(40).fill(25), -1, "long");          // 1 s in 25 ms steps
  await page.waitForTimeout(150);
  const rev = await post(page, [1], -1, "short");
  await expect.poll(async () => (await fx(page)).results.map((r: any) => r.tag)).toContain("short");
  await page.waitForTimeout(1500);                           // past the long run's planned end
  const s = await stats(page);
  const f = await fx(page);
  expect(f.results.map((r: any) => r.rev), "only the newest revision is answered").toEqual([rev]);
  expect(s.received, "the superseded run is never answered").toBe(1);
  expect(s.dropped).toBe(0);
  expect(s.restarts, "a run that yields between steps is not replaced").toBe(0);
});

// Mutation run: the supervision's replacement disabled (`replaceBusy` not
// called): fails on "the busy worker was replaced by the spare". Mutation
// run: `onRestart`'s callback not called: fails on "onRestart is called once
// per replacement".
test("an overrunning step is replaced by the spare, twice", async ({ page }) => {
  await open(page);
  for (const round of [1, 2]) {
    await post(page, [3000], -1, `stuck-${round}`);           // one step of 3 s
    await page.waitForTimeout(150);
    const before = (await stats(page)).now;
    const rev = await post(page, [1], -1, `next-${round}`);
    await expect.poll(async () => (await fx(page)).results.map((r: any) => r.tag), { timeout: 10_000 })
      .toContain(`next-${round}`);
    const f = await fx(page);
    const answered = f.results.find((r: any) => r.tag === `next-${round}`);
    expect((await stats(page)).restarts, "the busy worker was replaced by the spare").toBe(round);
    expect(f.restarts.length, "onRestart is called once per replacement").toBe(round);
    expect(f.restarts[round - 1].rev, "onRestart names the re-posted revision").toBe(rev);
    expect(answered.at - before, "the newer revision is answered long before the stuck step would end")
      .toBeLessThan(2000);
  }
  await page.waitForTimeout(3500);
  const tags = (await fx(page)).results.map((r: any) => r.tag);
  expect(tags.filter((t: string) => t.startsWith("stuck")), "a replaced worker's run is never answered").toEqual([]);
});

// A stream of newer revisions posted faster than the overrun bound (every
// 10 ms, for longer than the stuck step lasts) while one step runs 600 ms:
// the deadline runs from the first waiting revision, so the worker is
// replaced about 32 ms after it, not after the stream ends. Mutation run:
// the deadline re-armed by every post (only the last post's check counts):
// fails on "replaced while the stream still runs" (the step ends before the
// stream does, and the worker is never replaced).
test("a stream of revisions does not postpone the replacement of a stuck worker", async ({ page }) => {
  await open(page);
  await post(page, [600], -1, "stuck");
  await page.waitForTimeout(100);
  const r = await page.evaluate(() => new Promise<any>((resolve) => {
    const fx = (window as any).fx;
    const start = performance.now();
    let n = 0;
    const timer = setInterval(() => {
      fx.post([1], -1, "stream-" + (++n));
      if (performance.now() - start > 900) {
        clearInterval(timer);
        resolve({ start, end: performance.now(), restarts: fx.restarts.map((x: any) => x.at) });
      }
    }, 10);
  }));
  expect(r.restarts.length, "the stuck worker was replaced while the stream still runs").toBeGreaterThanOrEqual(1);
  expect(r.restarts[0] - r.start, "within the overrun bound of the first waiting revision (plus scheduling)")
    .toBeLessThan(400);
  await expect.poll(async () => (await fx(page)).results.length, { timeout: 10_000 }).toBeGreaterThan(0);
  const last = (await fx(page)).results.at(-1);
  expect(last.tag, "the newest revision is answered").toMatch(/^stream-/);
});

// Mutation run: the step loop catching only CatchableError (a JavaScript
// error escapes and the loop stays marked running): fails on "the worker
// answers the next revision".
test("a JavaScript error is that revision's error, and the worker goes on", async ({ page }) => {
  await open(page);
  const bad = await post(page, [1, 1], 0, "throws");
  await expect.poll(async () => (await fx(page)).errors.length, { message: "the error is reported" }).toBe(1);
  const f = await fx(page);
  expect(f.errors[0].rev).toBe(bad);
  expect(f.errors[0].msg, "the JavaScript error's message").toMatch(/null/i);
  await post(page, [1], -1, "after");
  await expect.poll(async () => (await fx(page)).results.map((r: any) => r.tag),
                    { message: "the worker answers the next revision", timeout: 10_000 }).toContain("after");
});
