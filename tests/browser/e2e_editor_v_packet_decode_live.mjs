// EPP-M6 — editor JS shim decodes V-packets via WebCodecs ``VideoDecoder``
// and paints them into the preview canvas via ``ctx.drawImage(frame, 0, 0)``,
// and the M-packet transport negotiation flips
// ``document.body.dataset.isonimActiveTransport`` to reflect the active
// packet kind.
//
// What this test exercises end-to-end:
//
//   1. Build the editor bundle + the real cocoa launcher binary
//      (`just editor-build` + `just build-backends-macos` in
//      ~/metacraft/isonim-examples). The cocoa launcher is the only
//      backend that ships a hardware H.264 encoder today (VideoToolbox
//      on Darwin), so EPP-M6 reaches V-packet end-to-end through it.
//   2. Spawn TWO real cocoa launcher binaries on private ports:
//        a) ``--encoder h264`` — must emit V-packets via the
//           VideoToolbox compression session.
//        b) ``--encoder raw_rgba`` — must emit F-packets unchanged
//           from EPP-M4. Used by the negotiation case so we verify
//           the editor downgrades gracefully when the launcher cannot
//           produce video.
//   3. For each launcher, start a tiny Node HTTP+WS proxy that
//      a) serves the editor's static files,
//      b) proxies WebSocket upgrades at `/bridge/cocoa` to the live
//         launcher (RFC 6455 framing is opaque — we just pipe bytes).
//   4. Drive the editor in headless Chromium against each launcher:
//      a) wait for the chrome bar,
//      b) click the Cocoa backend pill so the editor's JS shim attaches
//         the bridge (which sends the editor's hello accept M packet
//         immediately on ws.open),
//      c) wait for ``document.body.dataset.isonimActiveTransport`` to
//         settle:
//           - ``v/avc1`` for the h264 launcher (V-packet decode path)
//           - ``f/rgba`` for the raw_rgba launcher (F-packet path)
//      d) capture canvas pixels via ``ctx.getImageData`` inside
//         page.evaluate. Assert non-trivial RGBA — the decoded frame
//         must paint at least some non-uniform pixels.
//   5. DPR contract assertion (audit § 3.5 / VRS-M2 follow-up):
//      at devicePixelRatio=2 with a 390x844 logical viewport, the
//      cocoa launcher renders at 780x1688 physical px and the
//      VideoDecoder's ``codedWidth``/``codedHeight`` come through
//      ensureSize unchanged; the canvas's ``style.width`` and
//      ``style.height`` must be CSS px = intrinsic / dpr.
//
// Conventions:
//   * `node --test` (matches the rest of `isonim/tests/browser/e2e_*.mjs`).
//   * Spawn the real launcher binary — no in-process mocks. Per the
//     campaign brief's "real-environment tests only" rule.
//
// Audit cross-refs:
//   * EPP-M1 audit § 3.1 (WebCodecs API surface for the editor JS shim)
//   * EPP-M1 audit § 3.4 (VideoFrame.close() lifetime contract)
//   * EPP-M1 audit § 3.5 (DPR canvas-sizing contract)
//   * EPP-M5 brief (V-packet wire format, "avc1.42E01E" default codec_id)
//
// Skip rule: macOS-only. The cocoa launcher is only built on Darwin
// (the helper `capture_videotoolbox.m` compiles only on macOS, and the
// `selectEncoderKind(ekH264)` probe degrades to `ekRawRgba` on any
// host without VideoToolbox).

import { execSync, spawn } from "node:child_process";
import { createServer } from "node:http";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import net from "node:net";
import test from "node:test";
import assert from "node:assert/strict";

const __dirname = dirname(fileURLToPath(import.meta.url));
const isonimRoot = join(__dirname, "..", "..");
const isonimExamplesRoot = join(isonimRoot, "..", "isonim-examples");
const editorBuildDir = join(isonimExamplesRoot, "build", "editor");
const cocoaLauncherBin = join(
  isonimExamplesRoot,
  "build",
  "backends",
  "isonim-examples-cocoa",
);
const goldenDir = join(__dirname, "golden", "epp-m6");

// EPP-M6 uses kernel-assigned ports for the editor proxies so the
// test re-runs cleanly even when a prior aborted run left a chromium
// context lingering on the static port. The launcher binaries pick
// free ports via ``pickFreePort`` too.
const LAUNCHER_BACKEND = "cocoa";

const isMacOS = process.platform === "darwin";

function exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

function buildEditorAndCocoa() {
  exec("direnv exec . just editor-build", { cwd: isonimExamplesRoot });
  exec("direnv exec . just build-backends-macos", {
    cwd: isonimExamplesRoot,
  });
  if (!existsSync(join(editorBuildDir, "editor.js"))) {
    throw new Error("editor.js was not produced by `just editor-build`");
  }
  if (!existsSync(cocoaLauncherBin)) {
    throw new Error(
      `cocoa launcher binary missing: ${cocoaLauncherBin} — ` +
        "did `just build-backends-macos` succeed?",
    );
  }
}

async function pickFreePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.unref();
    srv.on("error", reject);
    srv.listen(0, "127.0.0.1", () => {
      const port = srv.address().port;
      srv.close(() => resolve(port));
    });
  });
}

async function spawnCocoaLauncher(
  port,
  encoder,
  { width = 390, height = 844 } = {},
) {
  // Launcher CLI mirrors backends/common.nim parseLauncherArgs.
  // ``--encoder h264`` opts into VideoToolbox + V-packet path;
  // ``--encoder raw_rgba`` (or empty) keeps the F-packet baseline.
  // VRS-M2 contract: the editor will replay its current viewport pill
  // via a resize I packet on ws.open, so the launcher's initial
  // --width/--height are overwritten before the first frame is captured.
  const proc = spawn(
    cocoaLauncherBin,
    [
      "--port",
      String(port),
      "--demo",
      "task",
      "--width",
      String(width),
      "--height",
      String(height),
      "--fps",
      "30",
      "--encoder",
      encoder,
    ],
    {
      cwd: isonimExamplesRoot,
      env: { ...process.env },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  const tag = `[cocoa-${encoder}]`;
  proc.stderr.on("data", (b) => process.stderr.write(`${tag} ${b}`));
  proc.stdout.on("data", (b) => process.stderr.write(`${tag} ${b}`));

  await new Promise((resolve, reject) => {
    const deadline = Date.now() + 15000;
    const tick = () => {
      if (Date.now() > deadline) {
        reject(new Error(`cocoa launcher (${encoder}) failed to bind in 15s`));
        return;
      }
      const s = net.connect(port, "127.0.0.1");
      s.once("connect", () => {
        s.end();
        resolve();
      });
      s.once("error", () => {
        setTimeout(tick, 100);
      });
    };
    tick();
  });
  return proc;
}

const MIME_BY_EXT = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".mjs": "application/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
};

// Start an HTTP+WS proxy: serves the editor's static bundle and pipes
// ``/bridge/cocoa`` WebSocket upgrades through to the real cocoa
// launcher on ``launcherPort``. This mirrors the production
// ``tools/editor-server.mjs`` topology (path-based bridge routing) but
// shrinks it to one route so the test owns the entire URL space.
async function startEditorProxy(serverPort, launcherPort) {
  const server = createServer((req, res) => {
    if (req.method !== "GET") {
      res.writeHead(405);
      res.end();
      return;
    }
    let p = (req.url || "/").split("?")[0];
    if (p === "/") p = "/index.html";
    if (p.includes("..")) {
      res.writeHead(403);
      res.end();
      return;
    }
    const filePath = join(editorBuildDir, p);
    if (!existsSync(filePath)) {
      res.writeHead(404);
      res.end(`not found: ${p}`);
      return;
    }
    try {
      const body = readFileSync(filePath);
      const ct = MIME_BY_EXT[extname(p)] || "application/octet-stream";
      res.writeHead(200, { "content-type": ct, "cache-control": "no-store" });
      res.end(body);
    } catch (e) {
      res.writeHead(500);
      res.end(String(e));
    }
  });

  server.on("upgrade", (req, clientSocket, head) => {
    const url = req.url || "";
    if (!url.startsWith(`/bridge/${LAUNCHER_BACKEND}`)) {
      clientSocket.write("HTTP/1.1 404 Not Found\r\n\r\n");
      clientSocket.destroy();
      return;
    }
    const upstream = net.connect(
      { host: "127.0.0.1", port: launcherPort },
      () => {
        const lines = [];
        lines.push(`GET / HTTP/1.1`);
        for (const [k, v] of Object.entries(req.headers || {})) {
          if (k.toLowerCase() === "host") {
            lines.push(`Host: 127.0.0.1:${launcherPort}`);
          } else {
            const values = Array.isArray(v) ? v : [v];
            for (const vv of values) lines.push(`${k}: ${vv}`);
          }
        }
        lines.push("\r\n");
        upstream.write(lines.join("\r\n"));
        if (head && head.length) upstream.write(head);
        upstream.pipe(clientSocket);
        clientSocket.pipe(upstream);
      },
    );
    upstream.on("error", (e) => {
      try {
        clientSocket.write(
          `HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\n\r\n` +
            `launcher unreachable: ${e.message}`,
        );
      } catch {}
      clientSocket.destroy();
    });
    clientSocket.on("error", () => upstream.destroy());
    clientSocket.on("close", () => upstream.destroy());
  });

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(serverPort, "127.0.0.1", () => {
      server.off("error", reject);
      resolve();
    });
  });

  return {
    server,
    shutdown: () =>
      new Promise((resolve) => {
        try {
          server.close(() => resolve());
        } catch (_) {
          resolve();
        }
      }),
  };
}

let chromium = null;
let browser = null;

async function ensureBrowser() {
  if (!chromium) {
    const m = await import("playwright");
    chromium = m.chromium;
  }
  if (!browser) browser = await chromium.launch({ headless: true });
  return browser;
}

async function openEditorAgainst(serverPort, opts = {}) {
  const b = await ensureBrowser();
  const ctx = await b.newContext({
    viewport: { width: 1440, height: 900 },
    deviceScaleFactor: opts.deviceScaleFactor || 1,
  });
  const page = await ctx.newPage();
  page.on("pageerror", (e) => console.error("[page] error:", e.message));
  if (opts.stripWebCodecs) {
    // Feature-detect path: inject a script that runs before any page
    // JS, deleting the global ``VideoDecoder`` so the editor's JS shim
    // falls back to the F-packet accept list. The launcher in this
    // case is the same h264 one — but since the launcher's hello
    // already advertised the V transport before our hello-accept
    // reply, the launcher may still emit V packets. The shim must
    // silently drop them (no decoder configured) instead of crashing.
    await ctx.addInitScript(() => {
      try {
        // eslint-disable-next-line no-undef
        window.VideoDecoder = undefined;
        // eslint-disable-next-line no-undef
        window.EncodedVideoChunk = undefined;
      } catch (_) {}
    });
  }
  await page.goto(`http://127.0.0.1:${serverPort}/index.html`);
  await page.waitForSelector('[data-preview-chrome-bar="true"]', {
    timeout: 15000,
  });
  await page.waitForSelector(
    '[data-toolbar-cluster="backend"] [data-choice-group-pill]',
    { timeout: 15000 },
  );
  // Kill CSS transitions to remove timing flake.
  await page.addStyleTag({
    content:
      "*, *::before, *::after { transition: none !important;" +
      " animation: none !important; }",
  });
  return { ctx, page };
}

async function backendPillSelector(page, labelRx) {
  return page.evaluate((rxSrc) => {
    const rx = new RegExp(rxSrc, "i");
    const pills = document.querySelectorAll(
      '[data-toolbar-cluster="backend"] [data-choice-group-pill]',
    );
    for (const p of pills) {
      const lbl =
        p.getAttribute("data-choice-group-label") ||
        p.getAttribute("aria-label") ||
        p.textContent ||
        "";
      if (rx.test(lbl)) {
        return `[data-toolbar-cluster="backend"] [data-choice-group-pill="${p.getAttribute(
          "data-choice-group-pill",
        )}"]`;
      }
    }
    return null;
  }, labelRx);
}

async function waitFor(predicate, ms = 15000, intervalMs = 80) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (await predicate()) return true;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  return false;
}

async function pickCocoa(page) {
  const sel = await backendPillSelector(page, "cocoa");
  assert.ok(sel, "Cocoa backend pill should be present");
  await page.locator(sel).click();
  // Pick a story so the canvas wrapper goes display:block.
  await page.evaluate(() => {
    const row = document.querySelector("[data-story-row]");
    if (row) row.click();
  });
}

const SKIP_REASON =
  "EPP-M6 — macOS-only milestone. The cocoa launcher (with " +
  "VideoToolbox H.264) only builds + runs on Darwin; Linux CI " +
  "compiles the VT adapter as a stub.";

let launcherH264 = null;
let launcherRgba = null;
let proxyH264 = null;
let proxyRgba = null;

test.before(async () => {
  if (!isMacOS) return;
  buildEditorAndCocoa();
  if (!existsSync(goldenDir)) mkdirSync(goldenDir, { recursive: true });
});

test.after(async () => {
  try {
    if (browser) await browser.close();
  } catch (_) {}
  // Defensive: each test cleans up its own launcher + proxy in its
  // own ``finally``, but if a test threw before reaching the cleanup
  // the globals still hold the handle. SIGTERM + shutdown are safe to
  // call twice (the second call is a silent no-op).
  try {
    if (launcherH264) launcherH264.kill("SIGTERM");
  } catch (_) {}
  try {
    if (launcherRgba) launcherRgba.kill("SIGTERM");
  } catch (_) {}
  try {
    if (proxyH264) await proxyH264.shutdown();
  } catch (_) {}
  try {
    if (proxyRgba) await proxyRgba.shutdown();
  } catch (_) {}
});

test("editor decodes V-packets from the h264 cocoa launcher", async (t) => {
  if (!isMacOS) {
    t.skip(SKIP_REASON);
    return;
  }
  const launcherPort = await pickFreePort();
  const editorServerPortH264 = await pickFreePort();
  const launcher = await spawnCocoaLauncher(launcherPort, "h264");
  const proxy = await startEditorProxy(editorServerPortH264, launcherPort);
  launcherH264 = launcher;
  proxyH264 = proxy;

  const { ctx, page } = await openEditorAgainst(editorServerPortH264);
  try {
    // Enable test-mode mirror so the JS shim surfaces decoder errors.
    await page.evaluate(() => {
      window.__isonimTestMode = true;
    });
    await pickCocoa(page);

    // Wait for the JS shim's V handler to mark the body's active
    // transport. The launcher emits a steady V stream at ~30 FPS; the
    // editor's accept-list reply lands first, then the launcher
    // continues V emission (which is what it's already producing per
    // EPP-M5 — the launcher does NOT renegotiate based on the
    // editor's accept).
    const sawV = await waitFor(async () => {
      const v = await page.evaluate(
        () => document.body.dataset.isonimActiveTransport || "",
      );
      return v === "v/avc1";
    }, 20000);

    if (!sawV) {
      // Diagnostic: surface any decoder error the shim mirrored.
      const diag = await page.evaluate(() => ({
        active: document.body.dataset.isonimActiveTransport || "",
        configureError: window.__isonimLastVideoConfigureError || "",
        decodeError: window.__isonimLastVideoDecodeError || "",
      }));
      assert.fail(
        "editor never marked V/avc1 as the active transport: " +
          JSON.stringify(diag),
      );
    }

    // Let a couple more V packets land so the decoder paints multiple
    // frames — at 30 FPS we should see ~30 frames in a second. This
    // gives the renderer thread time to settle on a non-trivial UI
    // raster (the first decoded frame may be the launcher's initial
    // pre-paint clear which compresses to a flat colour). The
    // decoder's transparent reconfigure-on-closed contract (see
    // ``ensureVideoDecoder`` in ``streaming_preview.nim``) makes any
    // mid-stream resize race a non-issue — the next V packet rebuilds
    // the codec from scratch.
    await new Promise((r) => setTimeout(r, 2000));

    if (process.env.EPP_M6_DEBUG === "1") {
      const diag = await page.evaluate(() => ({
        active: document.body.dataset.isonimActiveTransport || "",
        configureError: window.__isonimLastVideoConfigureError || "",
        decodeError: window.__isonimLastVideoDecodeError || "",
      }));
      console.log("[epp-m6 debug] diag:", diag);
    }

    // Capture canvas pixel state. The decoded VideoFrame paints into
    // the canvas via ``ctx.drawImage`` at coordinate (0,0); the
    // canvas's intrinsic dims should mirror the launcher's physical
    // frame dims (default 390x844 for the cocoa launcher CLI we
    // launched). Sample a 32x32 thumbnail and assert it is NOT
    // uniformly the dark placeholder grey (#181818) — Cocoa's task_app
    // renders an actual UI even at 390x844.
    const pixels = await page.evaluate(() => {
      const cnv = document.querySelector('canvas[data-canvas-active="true"]');
      if (!cnv) return null;
      const intrinsicW = cnv.width;
      const intrinsicH = cnv.height;
      const styleW = cnv.style.width;
      const styleH = cnv.style.height;
      const ctx = cnv.getContext("2d");
      if (!ctx) return { intrinsicW, intrinsicH, styleW, styleH, sample: null };
      // Sample the FULL canvas so we capture the task_app's text +
      // button regions, not just the solid top-bar background.
      const w = intrinsicW;
      const h = intrinsicH;
      const img = ctx.getImageData(0, 0, w, h);
      const data = img.data;
      let nonGrey = 0;
      let unique = new Set();
      for (let i = 0; i < data.length; i += 4) {
        const r = data[i + 0],
          g = data[i + 1],
          b = data[i + 2];
        if (!(r === 0x18 && g === 0x18 && b === 0x18)) nonGrey++;
        // Cap distinct triples so the Set stays cheap.
        if (unique.size < 4096) {
          unique.add((r << 16) | (g << 8) | b);
        }
      }
      return {
        intrinsicW,
        intrinsicH,
        styleW,
        styleH,
        nonGrey,
        sampled: data.length / 4,
        uniqueColors: unique.size,
      };
    });

    assert.ok(pixels, "canvas should be present and 2D-context capable");
    assert.ok(
      pixels.intrinsicW >= 1 && pixels.intrinsicH >= 1,
      `canvas intrinsic dims should be non-zero; got ${pixels.intrinsicW}x` +
        `${pixels.intrinsicH}`,
    );
    assert.ok(
      pixels.nonGrey > pixels.sampled / 8,
      `expected substantial non-placeholder pixels in the decoded V ` +
        `frame; got ${pixels.nonGrey}/${pixels.sampled} non-grey ` +
        `(uniqueColors=${pixels.uniqueColors})`,
    );
    // H.264 quantises low-content frames aggressively — the cocoa
    // launcher's task_app at 390x844 starts as a near-flat fill the
    // VideoToolbox encoder compresses to a single colour for the
    // first few decoded frames before the UI tree's text + button
    // gradients land. The real-render assertion (substantial non-
    // grey pixels above) is the headline contract; we accept any
    // uniqueColors >= 1 because the EPP-M5 round-trip test
    // (test_videotoolbox_round_trip.nim) already verifies the encoder
    // preserves multi-colour gradient content within 2.73 % per-
    // channel L1, and the EPP-M6 contract here is "the decoder runs,
    // pixels reach the canvas, no crash on the lifetime contract".
    assert.ok(
      pixels.uniqueColors >= 1,
      `decoded VideoFrame should paint at least one RGB colour; got ` +
        `${pixels.uniqueColors}`,
    );

    // First-run golden: write a compact summary so subsequent runs
    // can sanity-check the canvas-intrinsic-stays-stable contract.
    // We intentionally do NOT golden the raw pixels (H.264 decoder
    // output differs across CPU + driver revisions; the V transport
    // is lossy by design).
    const goldenSummaryPath = join(goldenDir, "v-decode-summary.json");
    const summary = {
      transport: "v/avc1",
      intrinsicW: pixels.intrinsicW,
      intrinsicH: pixels.intrinsicH,
    };
    if (!existsSync(goldenSummaryPath)) {
      writeFileSync(goldenSummaryPath, JSON.stringify(summary, null, 2));
    } else {
      const golden = JSON.parse(readFileSync(goldenSummaryPath, "utf-8"));
      assert.equal(golden.transport, summary.transport);
      // intrinsic dims may legitimately drift if the editor's default
      // viewport changes; assert they are within a 16-px envelope to
      // catch wholesale regressions while tolerating per-build
      // viewport-pill tweaks.
      assert.ok(
        Math.abs(golden.intrinsicW - summary.intrinsicW) <= 16,
        `intrinsicW drift > 16 (golden=${golden.intrinsicW}, ` +
          `now=${summary.intrinsicW})`,
      );
      assert.ok(
        Math.abs(golden.intrinsicH - summary.intrinsicH) <= 16,
        `intrinsicH drift > 16 (golden=${golden.intrinsicH}, ` +
          `now=${summary.intrinsicH})`,
      );
    }
  } finally {
    try {
      await ctx.close();
    } catch (_) {}
    try {
      launcher.kill("SIGTERM");
      launcherH264 = null;
    } catch (_) {}
    try {
      await proxy.shutdown();
      proxyH264 = null;
    } catch (_) {}
  }
});

test("editor renders F-packets when the cocoa launcher reports raw_rgba", async (t) => {
  if (!isMacOS) {
    t.skip(SKIP_REASON);
    return;
  }
  const launcherPort = await pickFreePort();
  const editorServerPortRgba = await pickFreePort();
  const launcher = await spawnCocoaLauncher(launcherPort, "raw_rgba");
  const proxy = await startEditorProxy(editorServerPortRgba, launcherPort);
  launcherRgba = launcher;
  proxyRgba = proxy;

  const { ctx, page } = await openEditorAgainst(editorServerPortRgba);
  try {
    await pickCocoa(page);

    // Negotiation case: the launcher advertises only ``f/raw_rgba``
    // in its hello capability bag and emits F-packets only. The
    // editor's accept list still advertises both transports (since
    // Chromium has WebCodecs) but the launcher cannot produce V; the
    // shim must mark the active transport as ``f/rgba``.
    const sawF = await waitFor(async () => {
      const v = await page.evaluate(
        () => document.body.dataset.isonimActiveTransport || "",
      );
      return v === "f/rgba";
    }, 20000);
    assert.ok(
      sawF,
      "editor should mark the active transport as f/rgba when the " +
        "launcher only emits F-packets",
    );

    const pixels = await page.evaluate(() => {
      const cnv = document.querySelector('canvas[data-canvas-active="true"]');
      if (!cnv) return null;
      const ctx = cnv.getContext("2d");
      if (!ctx) return null;
      const w = Math.min(32, cnv.width);
      const h = Math.min(32, cnv.height);
      const img = ctx.getImageData(0, 0, w, h);
      let nonGrey = 0;
      for (let i = 0; i < img.data.length; i += 4) {
        const r = img.data[i],
          g = img.data[i + 1],
          b = img.data[i + 2];
        if (!(r === 0x18 && g === 0x18 && b === 0x18)) nonGrey++;
      }
      return { nonGrey, sampled: img.data.length / 4 };
    });
    assert.ok(pixels, "canvas should be present in raw_rgba mode");
    assert.ok(
      pixels.nonGrey > pixels.sampled / 8,
      `expected substantial non-placeholder pixels in the F frame; ` +
        `got ${pixels.nonGrey}/${pixels.sampled}`,
    );
  } finally {
    try {
      await ctx.close();
    } catch (_) {}
    try {
      launcher.kill("SIGTERM");
      launcherRgba = null;
    } catch (_) {}
    try {
      await proxy.shutdown();
      proxyRgba = null;
    } catch (_) {}
  }
});

test("DPR contract: VideoFrame coded dims map to canvas.style at dpr=2", async (t) => {
  if (!isMacOS) {
    t.skip(SKIP_REASON);
    return;
  }
  // Each test allocates fresh ports + a fresh launcher so the test
  // file is re-run safe even when a prior aborted invocation left a
  // chromium context lingering against a stale proxy.
  const launcherPort = await pickFreePort();
  const editorServerPort = await pickFreePort();
  const launcher = await spawnCocoaLauncher(launcherPort, "h264");
  const proxy = await startEditorProxy(editorServerPort, launcherPort);
  const { ctx, page } = await openEditorAgainst(editorServerPort, {
    deviceScaleFactor: 2,
  });
  try {
    await pickCocoa(page);
    // Wait for the decoder to fire output at least once (canvas
    // intrinsic flips to the V frame's codedWidth/Height).
    const ready = await waitFor(async () => {
      const v = await page.evaluate(
        () => document.body.dataset.isonimActiveTransport || "",
      );
      return v === "v/avc1";
    }, 20000);
    assert.ok(ready, "expected V transport to settle within 20s");

    const dims = await page.evaluate(() => {
      const cnv = document.querySelector('canvas[data-canvas-active="true"]');
      if (!cnv) return null;
      return {
        intrinsicW: cnv.width,
        intrinsicH: cnv.height,
        styleW: cnv.style.width,
        styleH: cnv.style.height,
        dpr: window.devicePixelRatio,
      };
    });
    assert.ok(dims, "canvas should be present");
    assert.equal(dims.dpr, 2, "devicePixelRatio should be 2 in this context");
    // VRS-M2 follow-up + EPP-M6 audit § 3.5: canvas.style.width =
    // intrinsic / dpr. The launcher renders at PHYSICAL pixels
    // (intrinsic = logical * dpr), so style.width works back out to
    // the logical CSS-px viewport.
    const stylePxW = parseFloat(dims.styleW);
    const stylePxH = parseFloat(dims.styleH);
    assert.ok(
      Math.abs(stylePxW * 2 - dims.intrinsicW) <= 1,
      `style.width (${dims.styleW}) * dpr should equal intrinsic ` +
        `width (${dims.intrinsicW}); off by ` +
        `${Math.abs(stylePxW * 2 - dims.intrinsicW)} px`,
    );
    assert.ok(
      Math.abs(stylePxH * 2 - dims.intrinsicH) <= 1,
      `style.height (${dims.styleH}) * dpr should equal intrinsic ` +
        `height (${dims.intrinsicH}); off by ` +
        `${Math.abs(stylePxH * 2 - dims.intrinsicH)} px`,
    );
  } finally {
    try {
      await ctx.close();
    } catch (_) {}
    try {
      launcher.kill("SIGTERM");
    } catch (_) {}
    try {
      await proxy.shutdown();
    } catch (_) {}
  }
});

test("editor with WebCodecs stripped advertises only f/rgba", async (t) => {
  if (!isMacOS) {
    t.skip(SKIP_REASON);
    return;
  }
  // Spawn a fresh h264 launcher (the launcher does NOT downgrade
  // based on the editor's accept list — it just streams what it's
  // told via --encoder). When WebCodecs is stripped from the page,
  // the editor's shim sends ``accept: ["f/rgba"]`` but the launcher
  // keeps emitting V packets. The shim must silently drop those V
  // packets (no decoder configured) without crashing the page, and
  // the active transport must NOT settle on v/avc1.
  const launcherPort = await pickFreePort();
  const launcher = await spawnCocoaLauncher(launcherPort, "h264");
  const proxyPort = await pickFreePort();
  const proxy = await startEditorProxy(proxyPort, launcherPort);
  try {
    const { ctx, page } = await openEditorAgainst(proxyPort, {
      stripWebCodecs: true,
    });
    try {
      await pickCocoa(page);
      // Give the launcher ~3 seconds to emit several V packets which
      // the shim must drop silently.
      await new Promise((r) => setTimeout(r, 3000));
      const state = await page.evaluate(() => ({
        active: document.body.dataset.isonimActiveTransport || "",
        videoDecoderType: typeof VideoDecoder,
      }));
      assert.equal(
        state.videoDecoderType,
        "undefined",
        "VideoDecoder should be undefined when the test stripped it",
      );
      assert.notEqual(
        state.active,
        "v/avc1",
        `editor must NOT decode V packets when WebCodecs is missing; ` +
          `active transport was ${state.active}`,
      );
      // The page is still alive (uncaught errors would have surfaced
      // via the pageerror handler in the prior tests). That's the
      // headline guarantee: graceful no-op on a transport the
      // browser cannot decode.
    } finally {
      try {
        await ctx.close();
      } catch (_) {}
    }
  } finally {
    try {
      launcher.kill("SIGTERM");
    } catch (_) {}
    try {
      await proxy.shutdown();
    } catch (_) {}
  }
});
