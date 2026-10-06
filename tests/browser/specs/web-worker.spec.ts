// The Web Worker build target (milestone IFP-M3, test_web_worker_chunk_roundtrip;
// IsoNim.md § Web Worker Target).
//
// Fixture: tests/browser/web_worker_fixture, built by
// `just build-web-worker-fixture` into build/web-worker-fixture:
//   preview.worker.js  preview_compile.nim as a worker chunk (--kind worker)
//   main.js            the page script: a WorkerBridge to preview.worker.js
//   main.inline.js     the negative control: the same compile module linked
//                      into the page script, run on the main thread
//
// No mocks: real Chromium, the real chunks, the bundle tool itself.
//
// Off the main thread is measured as input latency: the compile module
// busy-loops for 200 ms, and a key pressed meanwhile must reach its
// handler promptly (latency = `performance.now() - event.timeStamp`). The
// key is pressed once the busy loop has started, which the compile module
// announces on a BroadcastChannel; the fixture's beacon.js, a worker of its
// own, relays that as a request for /busy-started, routed here. So the test
// learns "busy now" from a thread that is not busy, in both builds.
//
// Sampling. One key press per busy run, SAMPLES (5) runs per test. Each
// sample is checked against its own busy window: a key created outside it,
// or less than 50 ms before its end, measures nothing; it is discarded and
// the run repeated (at most MAX_ATTEMPTS runs; fewer than SAMPLES usable
// keys fails the test). The 50 ms margin is what lets "handled before the
// busy loop ended" be asserted per sample: a key created 5 ms before the
// end may be handled after it by a perfectly free thread (seen once in 50
// runs at load average 70). The assertions are then:
// * per sample: created and handled inside the busy window, under 50 ms;
// * the median latency is under 16 ms (one frame).
// A single-sample bound of 16 ms flaked once in 55 runs on a heavily
// loaded host (load average 54 to 72 on 24 cores: 20.3 ms), from scheduler
// noise that has nothing to do with the busy loop. The median absorbs such
// an outlier, while the 50 ms per-sample cap still rejects any sample from
// the blocked-thread regime: the negative control (the same module in the
// main bundle) measures 126 to 190 ms, so a build that ran the compiler on
// the main thread even once in five runs fails. The negative control runs
// the identical sampler and must land in that regime on every sample.
import { test, expect, Page } from "@playwright/test";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";

const repoRoot = resolve(__dirname, "../../..");
const fixtureDir = resolve(repoRoot, "build/web-worker-fixture");

const SAMPLES = 5;
const MAX_ATTEMPTS = 3 * SAMPLES;
const FRAME_MS = 16;
const BLOCKED_FLOOR_MS = 50;

type Sample = {
  latency: number;
  keyAt: number;
  keyCreated: number;
  busyFrom: number;
  busyTo: number;
  inWorker: boolean;
};

// Runs the compile module busy for `busyMs`, presses a key once it is busy,
// and returns the first SAMPLES samples whose key was created inside that
// run's busy window, at least BLOCKED_FLOOR_MS before its end (at most
// MAX_ATTEMPTS runs).
async function busyWhileTyping(page: Page, busyMs: number): Promise<Sample[]> {
  let started = () => {};
  await page.context().route("**/busy-started*", async (route) => {
    started();
    await route.fulfill({ status: 204 });
  });
  await page.waitForFunction(() => (window as any).beaconReady === true);
  await page.click("#editor");
  const samples: Sample[] = [];
  for (let attempt = 1; attempt <= MAX_ATTEMPTS && samples.length < SAMPLES; attempt++) {
    const busy = new Promise<void>((r) => (started = r));
    await page.evaluate(() => {
      const fx = (window as any).fx;
      fx.keyLatency = [];
      fx.keyAt = [];
      fx.keyCreated = [];
    });
    const rev = await page.evaluate(
      (ms) => (window as any).fx.post("first\n\nsecond <b>", ms, true),
      busyMs,
    );
    await busy;
    await page.keyboard.press("a");
    await page.waitForFunction(
      (r) => (window as any).fx.applied.includes(r) && (window as any).fx.keyLatency.length > 0,
      rev,
    );
    const r: Sample = await page.evaluate(() => {
      const fx = (window as any).fx;
      return {
        latency: fx.keyLatency[0] as number,
        keyAt: fx.keyAt[0] as number,
        keyCreated: fx.keyCreated[0] as number,
        busyFrom: fx.busyFrom as number,
        busyTo: fx.busyTo as number,
        inWorker: fx.inWorker as boolean,
      };
    });
    // In the window with BLOCKED_FLOOR_MS to spare: a key created in it is
    // handled before the busy loop ends if it waits less than that, and
    // waits at least that long if the busy thread is its own.
    if (r.keyCreated > r.busyFrom && r.keyCreated < r.busyTo - BLOCKED_FLOOR_MS) samples.push(r);
  }
  const latencies = samples.map((s) => s.latency.toFixed(1)).join(", ");
  test.info().annotations.push({ type: "latencies-ms", description: latencies });
  console.log(`[web-worker] ${page.url()} latencies ms: ${latencies}`);
  return samples;
}

function median(xs: number[]): number {
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.floor(s.length / 2)];
}

test.describe("Web Worker build target", () => {
  test("revision-tagged requests: the main thread keeps only the newest result", async ({
    page,
  }) => {
    const workers: string[] = [];
    page.on("worker", (w) => workers.push(w.url()));
    await page.goto("/index.html");

    const revs = await page.evaluate(() => {
      const fx = (window as any).fx;
      const out: number[] = [];
      for (let i = 1; i <= 5; i++) out.push(fx.post(`rev ${i}\n\nblock ${i}`, 30, false));
      return out;
    });
    expect(revs).toEqual([1, 2, 3, 4, 5]);

    await page.waitForFunction(() => (window as any).fx.stats().received === 5);
    const r = await page.evaluate(() => {
      const fx = (window as any).fx;
      return { stats: fx.stats(), applied: fx.applied, blocks: fx.blocks, inWorker: fx.inWorker };
    });
    // All five answers came back; the four stale ones were dropped.
    expect(r.stats).toEqual({ latest: 5, received: 5, dropped: 4 });
    expect(r.applied).toEqual([5]);
    expect(r.blocks).toEqual(["<p>rev 5</p>", "<p>block 5</p>"]);
    expect(r.inWorker).toBe(true);
    // The worker was loaded from its own chunk (beacon.js is the fixture's).
    expect(workers.map((u) => new URL(u).pathname).sort()).toEqual([
      "/beacon.js",
      "/preview.worker.js",
    ]);
  });

  test("the worker runs off the main thread: input latency under 16 ms while it is busy", async ({
    page,
  }) => {
    await page.goto("/index.html");
    const samples = await busyWhileTyping(page, 200);
    expect(samples).toHaveLength(SAMPLES);
    for (const r of samples) {
      expect(r.inWorker).toBe(true);
      // Each key was pressed and handled while the worker was busy, and
      // none waited anywhere near as long as a blocked main thread makes it.
      expect(r.keyCreated).toBeGreaterThan(r.busyFrom);
      expect(r.keyAt).toBeLessThan(r.busyTo);
      expect(r.latency).toBeLessThan(BLOCKED_FLOOR_MS);
    }
    expect(median(samples.map((r) => r.latency))).toBeLessThan(FRAME_MS);
  });

  test("negative control: the same module compiled into the main bundle blocks input", async ({
    page,
  }) => {
    await page.goto("/inline.html");
    const samples = await busyWhileTyping(page, 200);
    expect(samples).toHaveLength(SAMPLES);
    for (const r of samples) {
      expect(r.inWorker).toBe(false);
      // Each key was pressed while the main thread was busy and waited for
      // the busy loop: both latency assertions of the worker test fail here.
      expect(r.keyCreated).toBeGreaterThan(r.busyFrom);
      expect(r.keyCreated).toBeLessThan(r.busyTo);
      expect(r.keyAt).toBeGreaterThanOrEqual(r.busyTo);
      expect(r.latency).not.toBeLessThan(BLOCKED_FLOOR_MS);
    }
    expect(median(samples.map((r) => r.latency))).not.toBeLessThan(FRAME_MS);
  });

  test("the bundle tooling reports the worker chunk as a separate file", async () => {
    const out = execFileSync(
      "node",
      [resolve(repoRoot, "tools/isonim-bundle.mjs"), "report", fixtureDir, "--json"],
      { encoding: "utf8" },
    );
    const chunks: { file: string; kind: string; bytes: number; gzipBytes: number }[] =
      JSON.parse(out).chunks;
    const byFile = Object.fromEntries(chunks.map((c) => [c.file, c]));
    expect(byFile["preview.worker.js"].kind).toBe("worker");
    expect(byFile["main.js"].kind).toBe("main");
    for (const c of chunks) {
      expect(c.bytes).toBeGreaterThan(0);
      expect(c.gzipBytes).toBeGreaterThan(0);
      expect(c.gzipBytes).toBeLessThan(c.bytes);
    }
    // The compiler is in the worker chunk and not in the page script that
    // loads it (the FNV-1a prime is a literal only the compile module has);
    // the inline build, by contrast, carries it.
    const { readFileSync } = await import("node:fs");
    const has = (f: string) => readFileSync(resolve(fixtureDir, f), "utf8").includes("16777619");
    expect(has("preview.worker.js")).toBe(true);
    expect(has("main.js")).toBe(false);
    expect(has("main.inline.js")).toBe(true);
  });
});
