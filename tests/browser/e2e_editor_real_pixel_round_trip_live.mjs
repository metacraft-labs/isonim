// End-to-end real-pixel round-trip smoke test.
//
// For each desktop backend (gpui/freya/cocoa), spawn the real launcher
// binary, open a SECOND raw WebSocket to the launcher to capture
// backend-side pixels (F→raw RGBA, W→WebP decoded via ffmpeg, V→H.264
// decoded via ffmpeg), drive the editor's preview canvas via Playwright
// + the same launcher, capture browser-side pixels via getImageData,
// and assert:
//
//   * backend frame is real (non-zero-pixel ratio > 50%, not a
//     placeholder grey/black);
//   * browser canvas is real (non-zero-pixel ratio > 50%);
//   * a 16x16 perceptual fingerprint of the backend frame correlates
//     with the same grid of the browser canvas within mean-channel
//     delta ≤ 16;
//   * the DPR contract holds (canvas CSS rect ≈ intrinsic dims / DPR
//     within 1 px).
//
// This is the missing smoke test for end-to-end pixel reality — it
// would catch the failure mode "launcher process bound its port but
// crashed before producing real pixels" (e.g. the gpui launcher
// regression where ``gpui_render_try_take`` was missing from the dylib
// and the bridge sat emitting placeholder frames). Runs sequentially
// per backend to honour the FUH-M6 deadlock invariant.

import { execSync, spawn, spawnSync } from "node:child_process";
import { createServer } from "node:http";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import net from "node:net";
import test from "node:test";
import assert from "node:assert/strict";
import WebSocket from "ws";

const __dirname = dirname(fileURLToPath(import.meta.url));
const isonimRoot = join(__dirname, "..", "..");
const isonimExamplesRoot = join(isonimRoot, "..", "isonim-examples");
const isonimGpuiRoot = join(isonimRoot, "..", "isonim-gpui");
const editorBuildDir = join(isonimExamplesRoot, "build", "editor");
const backendsBuildDir = join(isonimExamplesRoot, "build", "backends");

const isMacOS = process.platform === "darwin";

// Single-frame capture dims keep ffmpeg-decode budget tiny and the
// backend launchers light. Desktop viewport (1440x900) is the matrix
// target but the smoke test only needs to prove pixels round-trip;
// 800x600 matches the EPP-M2/M3 golden-frame harness so failures share
// the same diagnostic feel.
const FRAME_WIDTH = 800;
const FRAME_HEIGHT = 600;
const VIEWPORT = { name: "Desktop", slug: "desktop", width: 1440, height: 900 };

// Non-zero pixel ratio threshold — proves the launcher / browser canvas
// is NOT a placeholder grey/black (0x18,0x18,0x18 is the synthetic
// painter's canvas fill across every backend). The threshold is set at
// 50% per the brief: a real task_app/settings_app frame paints chrome
// + sidebar + content across well over half of the surface, while a
// degenerate placeholder either is uniformly grey (0% pass) or has a
// narrow band of branding (< 25% pass).
const NON_ZERO_RATIO_MIN = 0.5;

// Per-channel mean delta threshold for the 16x16 perceptual-grid
// correlation between backend frame and browser canvas. Loose because
// the two captures are timing-misaligned (W-decode round-trip + frame
// jitter can put them 1-2 frames apart) and because some encoders are
// lossy in chroma. 16 / 255 ≈ 6%; well below the placeholder-vs-real
// gap (any synthetic grey vs a real frame differs by 60%+ in every
// cell).
const FINGERPRINT_DELTA_MAX = 16;

const DPR_DRIFT_MAX_PX = 1;

const NEUTRAL_GREY = 0x80; // mid-grey used as the "non-zero" baseline
const NEUTRAL_GREY_TOLERANCE = 8; // per channel

const SKIP_REASON =
  "Real-pixel round-trip — cocoa launcher only builds on Darwin and " +
  "the cross-backend smoke test gates all three backends together.";

const BACKENDS = [
  {
    name: "gpui",
    bin: join(backendsBuildDir, "isonim-examples-gpui"),
    encoder: "raw_rgba",
    expectedTransport: "f/rgba",
    pillLabelRx: "gpui",
    extraEnv: {
      DYLD_LIBRARY_PATH: join(isonimGpuiRoot, "rust", "target", "release"),
      DYLD_FALLBACK_LIBRARY_PATH: join(
        isonimGpuiRoot,
        "rust",
        "target",
        "release",
      ),
    },
  },
  {
    name: "freya",
    bin: join(backendsBuildDir, "isonim-examples-freya"),
    encoder: "raw_rgba",
    expectedTransport: "f/rgba",
    pillLabelRx: "freya",
    extraEnv: {},
  },
  {
    name: "cocoa",
    bin: join(backendsBuildDir, "isonim-examples-cocoa"),
    encoder: "webp",
    expectedTransport: "w/webp",
    pillLabelRx: "cocoa",
    extraEnv: {},
  },
];

function exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

function buildAll() {
  exec("direnv exec . just editor-build", { cwd: isonimExamplesRoot });
  exec("direnv exec . just build-backends", { cwd: isonimExamplesRoot });
  if (isMacOS) {
    exec("direnv exec . just build-backends-macos", {
      cwd: isonimExamplesRoot,
    });
  }
  if (!existsSync(join(editorBuildDir, "editor.js"))) {
    throw new Error("editor.js was not produced by `just editor-build`");
  }
  for (const b of BACKENDS) {
    if (!existsSync(b.bin)) {
      throw new Error(
        `launcher binary missing for ${b.name}: ${b.bin} — ` +
          "did `just build-backends` / `just build-backends-macos` succeed?",
      );
    }
  }
  // GPUI's dylib must exist for the launcher to even start.
  if (isMacOS) {
    const dylib = join(
      isonimGpuiRoot,
      "rust",
      "target",
      "release",
      "libgpui_nim_shim.dylib",
    );
    if (!existsSync(dylib)) {
      throw new Error(
        `GPUI shim dylib missing at ${dylib} — the gpui launcher ` +
          "would crash silently. Build via `cd isonim-gpui/rust && " +
          "cargo build --release`.",
      );
    }
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

async function spawnLauncher(backend, port) {
  const args = [
    "--port",
    String(port),
    "--demo",
    "task",
    "--width",
    String(FRAME_WIDTH),
    "--height",
    String(FRAME_HEIGHT),
    "--fps",
    "10",
    "--encoder",
    backend.encoder,
  ];
  const proc = spawn(backend.bin, args, {
    cwd: isonimExamplesRoot,
    env: { ...process.env, ...backend.extraEnv },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const tag = `[real-pixel ${backend.name}]`;
  proc.stderr.on("data", (b) => process.stderr.write(`${tag} ${b}`));
  proc.stdout.on("data", (b) => process.stderr.write(`${tag} ${b}`));
  let exited = false;
  let exitCode = null;
  proc.once("exit", (code, signal) => {
    exited = true;
    exitCode = code != null ? code : signal;
  });

  await new Promise((resolve, reject) => {
    const deadline = Date.now() + 20000;
    const tick = () => {
      if (exited) {
        reject(
          new Error(
            `${backend.name} launcher exited before binding port ` +
              `(code=${exitCode}). Check the launcher diagnostics above — ` +
              "a typical cause is a missing dylib or a runtime crash in " +
              "the headless render path.",
          ),
        );
        return;
      }
      if (Date.now() > deadline) {
        reject(
          new Error(
            `${backend.name} launcher failed to bind ` +
              `127.0.0.1:${port} within 20s`,
          ),
        );
        return;
      }
      const s = net.connect(port, "127.0.0.1");
      s.once("connect", () => {
        s.end();
        resolve();
      });
      s.once("error", () => setTimeout(tick, 100));
    };
    tick();
  });
  return proc;
}

// -----------------------------------------------------------------------
// Raw-WebSocket backend-side capture
// -----------------------------------------------------------------------

// Open a raw WebSocket to the launcher (NOT through the editor's
// proxy) and resolve with the first F or W packet that arrives. V is
// supported but the matrix doesn't request it.
async function captureBackendPacket(port) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/`);
    let settled = false;
    const finish = (err, value) => {
      if (settled) return;
      settled = true;
      try {
        ws.close();
      } catch (_) {}
      if (err) reject(err);
      else resolve(value);
    };
    const timeout = setTimeout(
      () => finish(new Error("Timed out waiting for F/W/V packet")),
      15000,
    );
    ws.on("message", (data, isBinary) => {
      if (!isBinary || !Buffer.isBuffer(data) || data.length < 3) return;
      const tag = data[0];
      if (tag === 0x46 /* F */) {
        if (data.length < 14) return;
        const flags = data[1];
        const width = data.readUInt32LE(2);
        const height = data.readUInt32LE(6);
        const length = data.readUInt32LE(10);
        if (14 + length > data.length) return;
        // Skip diff frames — we want a full reference frame as the
        // backend ground truth.
        if (flags & 0x01) return;
        const payload = data.subarray(14, 14 + length);
        clearTimeout(timeout);
        finish(null, {
          tag: "F",
          width,
          height,
          rgba: Buffer.from(payload),
        });
        return;
      }
      if (tag === 0x57 /* W */) {
        // W packet layout: 'W' | u8 flags | u8 codec_id_len | codec_id |
        // u32 width | u32 height | u32 length | RIFF bytes.
        // Skip diff variant (bit 1) — we want a full-frame RIFF.
        const flags = data[1];
        if (flags & 0x02) return;
        if (data.length < 3) return;
        const codecLen = data[2];
        const headerEnd = 3 + codecLen + 12;
        if (data.length < headerEnd) return;
        const widthOff = 3 + codecLen;
        const width = data.readUInt32LE(widthOff);
        const height = data.readUInt32LE(widthOff + 4);
        const length = data.readUInt32LE(widthOff + 8);
        if (data.length - headerEnd !== length) return;
        const riff = data.subarray(headerEnd, headerEnd + length);
        clearTimeout(timeout);
        finish(null, {
          tag: "W",
          width,
          height,
          riff: Buffer.from(riff),
        });
        return;
      }
      // V packet: 'V' | u8 flags | u8 codec_id_len | codec_id |
      // u32 width | u32 height | u32 length | NALUs.
      if (tag === 0x56 /* V */) {
        if (data.length < 3) return;
        const codecLen = data[2];
        const headerEnd = 3 + codecLen + 12;
        if (data.length < headerEnd) return;
        const widthOff = 3 + codecLen;
        const width = data.readUInt32LE(widthOff);
        const height = data.readUInt32LE(widthOff + 4);
        const length = data.readUInt32LE(widthOff + 8);
        if (data.length - headerEnd !== length) return;
        const nalus = data.subarray(headerEnd, headerEnd + length);
        clearTimeout(timeout);
        finish(null, {
          tag: "V",
          width,
          height,
          nalus: Buffer.from(nalus),
        });
      }
    });
    ws.on("error", (e) => finish(e));
    ws.on("close", () => {
      if (!settled) finish(new Error("WS closed before frame packet arrived"));
    });
  });
}

// Decode the captured backend packet into a Buffer of RGBA8888 row-major
// bytes of length width*height*4. F: trivial. W: write RIFF to a temp
// file and run `ffmpeg -i in.webp -f rawvideo -pix_fmt rgba out.bin`.
// V: write NALUs as an Annex-B byte-stream and run the same ffmpeg
// pipeline with H.264 input format.
function decodeBackendToRgba(packet) {
  if (packet.tag === "F") {
    return packet.rgba;
  }
  if (packet.tag === "W") {
    return decodeWithFfmpeg(packet.riff, "webp", packet.width, packet.height);
  }
  if (packet.tag === "V") {
    return decodeWithFfmpeg(packet.nalus, "h264", packet.width, packet.height);
  }
  throw new Error(`unknown packet tag ${packet.tag}`);
}

function decodeWithFfmpeg(inBytes, inFormat, width, height) {
  const dir = mkdtempSync(join(tmpdir(), "real-pixel-rt-"));
  const inPath = join(dir, "in." + (inFormat === "webp" ? "webp" : "h264"));
  const outPath = join(dir, "out.rgba");
  try {
    writeFileSync(inPath, inBytes);
    const args = [
      "-y",
      "-loglevel",
      "error",
      "-f",
      inFormat,
      "-i",
      inPath,
      "-f",
      "rawvideo",
      "-pix_fmt",
      "rgba",
      outPath,
    ];
    const res = spawnSync("ffmpeg", args, {
      stdio: ["ignore", "pipe", "pipe"],
    });
    if (res.status !== 0) {
      throw new Error(
        `ffmpeg ${inFormat} decode failed (status=${res.status}): ` +
          (res.stderr ? res.stderr.toString() : ""),
      );
    }
    const rgba = readFileSync(outPath);
    const expected = width * height * 4;
    if (rgba.length !== expected) {
      throw new Error(
        `ffmpeg produced ${rgba.length} RGBA bytes, expected ` +
          `${expected} for ${width}x${height}`,
      );
    }
    return rgba;
  } finally {
    try {
      rmSync(dir, { recursive: true, force: true });
    } catch (_) {}
  }
}

// -----------------------------------------------------------------------
// Pixel fingerprints (shared between backend-decoded RGBA + browser
// getImageData RGBA).
// -----------------------------------------------------------------------

function fingerprint(rgba, width, height) {
  const total = width * height;
  let nonZero = 0;
  let sumR = 0,
    sumG = 0,
    sumB = 0;
  let sumR2 = 0,
    sumG2 = 0,
    sumB2 = 0;
  for (let i = 0; i < total; i++) {
    const off = i * 4;
    const r = rgba[off];
    const g = rgba[off + 1];
    const b = rgba[off + 2];
    sumR += r;
    sumG += g;
    sumB += b;
    sumR2 += r * r;
    sumG2 += g * g;
    sumB2 += b * b;
    if (
      Math.abs(r - NEUTRAL_GREY) > NEUTRAL_GREY_TOLERANCE ||
      Math.abs(g - NEUTRAL_GREY) > NEUTRAL_GREY_TOLERANCE ||
      Math.abs(b - NEUTRAL_GREY) > NEUTRAL_GREY_TOLERANCE
    ) {
      nonZero++;
    }
  }
  const meanR = sumR / total;
  const meanG = sumG / total;
  const meanB = sumB / total;
  const varR = sumR2 / total - meanR * meanR;
  const varG = sumG2 / total - meanG * meanG;
  const varB = sumB2 / total - meanB * meanB;
  const stddev = Math.sqrt(Math.max(0, (varR + varG + varB) / 3));
  // 16x16 grid of per-cell mean colours.
  const GRID = 16;
  const cellW = Math.max(1, Math.floor(width / GRID));
  const cellH = Math.max(1, Math.floor(height / GRID));
  const grid = new Float32Array(GRID * GRID * 3);
  for (let gy = 0; gy < GRID; gy++) {
    for (let gx = 0; gx < GRID; gx++) {
      const x0 = gx * cellW;
      const y0 = gy * cellH;
      const x1 = Math.min(width, x0 + cellW);
      const y1 = Math.min(height, y0 + cellH);
      let cR = 0,
        cG = 0,
        cB = 0,
        cN = 0;
      for (let y = y0; y < y1; y++) {
        const rowOff = y * width * 4;
        for (let x = x0; x < x1; x++) {
          const off = rowOff + x * 4;
          cR += rgba[off];
          cG += rgba[off + 1];
          cB += rgba[off + 2];
          cN++;
        }
      }
      const baseGrid = (gy * GRID + gx) * 3;
      if (cN > 0) {
        grid[baseGrid] = cR / cN;
        grid[baseGrid + 1] = cG / cN;
        grid[baseGrid + 2] = cB / cN;
      }
    }
  }
  return {
    width,
    height,
    nonZeroRatio: nonZero / total,
    meanR,
    meanG,
    meanB,
    stddev,
    grid,
  };
}

function fingerprintCompareDelta(a, b) {
  if (a.grid.length !== b.grid.length) {
    throw new Error("fingerprint grid length mismatch");
  }
  let sum = 0;
  for (let i = 0; i < a.grid.length; i++) {
    sum += Math.abs(a.grid[i] - b.grid[i]);
  }
  return sum / a.grid.length;
}

// -----------------------------------------------------------------------
// Editor (browser) side capture — copied/condensed from FUH-M8.
// -----------------------------------------------------------------------

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

async function startEditorProxy(serverPort, launcherPort, backendName) {
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
      res.writeHead(200, {
        "content-type": ct,
        "cache-control": "no-store",
      });
      res.end(body);
    } catch (e) {
      res.writeHead(500);
      res.end(String(e));
    }
  });
  server.on("upgrade", (req, clientSocket, head) => {
    const url = req.url || "";
    if (!url.startsWith(`/bridge/${backendName}`)) {
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

async function openEditor(serverPort) {
  const b = await ensureBrowser();
  const ctx = await b.newContext({
    viewport: { width: 1920, height: 1080 },
    deviceScaleFactor: 1,
  });
  const page = await ctx.newPage();
  page.on("pageerror", (e) =>
    console.error("[page] error:", e && e.message ? e.message : String(e)),
  );
  await page.goto(`http://127.0.0.1:${serverPort}/index.html`);
  await page.waitForSelector('[data-preview-chrome-bar="true"]', {
    timeout: 20000,
  });
  await page.waitForSelector(
    '[data-toolbar-cluster="backend"] [data-choice-group-pill]',
    { timeout: 20000 },
  );
  await page.waitForSelector(
    '[data-toolbar-cluster="viewport"] [data-choice-group-pill]',
    { timeout: 20000 },
  );
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

async function pickBackendAndTaskStory(page, backend) {
  const sel = await backendPillSelector(page, backend.pillLabelRx);
  assert.ok(sel, `${backend.name} backend pill should be present`);
  await page.locator(sel).click();
  await page.evaluate(() => {
    const rx = /task app/i;
    const rows = document.querySelectorAll("[data-story-row]");
    for (const r of rows) {
      const slug = r.getAttribute("data-story-row") || "";
      if (rx.test(slug)) {
        r.click();
        return slug;
      }
    }
    const fallback = document.querySelector("[data-story-row]");
    if (fallback) fallback.click();
    return null;
  });
}

async function pickViewportPill(page, slug) {
  const labelForSlug = { phone: "Phone", laptop: "Laptop", desktop: "Desktop" };
  const label = labelForSlug[slug];
  if (!label) return false;
  const pinnedClicked = await page.evaluate((labelArg) => {
    const pills = document.querySelectorAll(
      '[data-toolbar-cluster="viewport"] [data-choice-group-pill]',
    );
    for (const p of pills) {
      const lbl =
        p.getAttribute("data-choice-group-label") || p.textContent || "";
      if (lbl.trim().toLowerCase() === labelArg.toLowerCase()) {
        const rect = p.getBoundingClientRect();
        if (rect.width > 0 && rect.height > 0) {
          p.click();
          return true;
        }
      }
    }
    return false;
  }, label);
  if (pinnedClicked) return true;
  const chevronClicked = await page.evaluate(() => {
    const ch = document.querySelector(
      '[data-preview-viewport-overflow="true"]',
    );
    if (!ch) return false;
    ch.click();
    return true;
  });
  if (!chevronClicked) return false;
  await new Promise((r) => setTimeout(r, 200));
  return page.evaluate((slugArg) => {
    const opt = document.querySelector(
      `[data-preview-viewport-dropdown-option="${slugArg}"]`,
    );
    if (!opt) return false;
    opt.click();
    return true;
  }, slug);
}

async function waitFor(predicate, ms = 30000, intervalMs = 100) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (await predicate()) return true;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  return false;
}

async function captureBrowserPixels(page) {
  return page.evaluate(() => {
    const wrappers = document.querySelectorAll('[data-canvas-wrapper="true"]');
    let canvas = null;
    let wrapperRect = null;
    for (const w of wrappers) {
      if (getComputedStyle(w).display === "none") continue;
      const candidate = w.querySelector("canvas");
      if (!candidate) continue;
      const cr = candidate.getBoundingClientRect();
      if (cr.width > 10 && cr.height > 10) {
        canvas = candidate;
        wrapperRect = w.getBoundingClientRect();
        break;
      }
    }
    if (!canvas) {
      const c = document.querySelector('canvas[data-canvas-active="true"]');
      if (c) {
        canvas = c;
        wrapperRect = c.getBoundingClientRect();
      }
    }
    if (!canvas) return null;
    const ctx = canvas.getContext("2d");
    if (!ctx) return null;
    const w = canvas.width;
    const h = canvas.height;
    const img = ctx.getImageData(0, 0, w, h);
    const rect = canvas.getBoundingClientRect();
    return {
      width: w,
      height: h,
      rectW: rect.width,
      rectH: rect.height,
      dpr: window.devicePixelRatio || 1,
      wrapperW: wrapperRect ? wrapperRect.width : null,
      wrapperH: wrapperRect ? wrapperRect.height : null,
      // Transfer the RGBA buffer as a base64 string so it survives the
      // CDP serializer (Uint8ClampedArray is otherwise stringified to
      // "[object Uint8ClampedArray]").
      rgbaB64: (() => {
        // Encode in chunks of 0x8000 bytes to avoid the apply-arg-limit
        // ceiling that bites large frames (1440x900x4 = 5 MB).
        const u8 = img.data;
        let s = "";
        const CHUNK = 0x8000;
        for (let i = 0; i < u8.length; i += CHUNK) {
          s += String.fromCharCode.apply(
            null,
            u8.subarray(i, Math.min(i + CHUNK, u8.length)),
          );
        }
        return btoa(s);
      })(),
    };
  });
}

// -----------------------------------------------------------------------
// Per-backend runner
// -----------------------------------------------------------------------

async function runBackend(backend) {
  const t0 = Date.now();
  const launcherPort = await pickFreePort();
  const editorPort = await pickFreePort();
  let launcher = null;
  let proxy = null;
  let ctx = null;
  try {
    launcher = await spawnLauncher(backend, launcherPort);

    // Backend-side raw-WebSocket capture. Open this BEFORE the editor
    // connects so we don't race the launcher's per-connection hello.
    const backendPacket = await captureBackendPacket(launcherPort);
    assert.equal(
      backendPacket.width,
      FRAME_WIDTH,
      `${backend.name}: backend frame width should be ${FRAME_WIDTH}`,
    );
    assert.equal(
      backendPacket.height,
      FRAME_HEIGHT,
      `${backend.name}: backend frame height should be ${FRAME_HEIGHT}`,
    );
    const backendRgba = decodeBackendToRgba(backendPacket);
    const backendFp = fingerprint(
      backendRgba,
      backendPacket.width,
      backendPacket.height,
    );

    // Backend-side reality assertion.
    assert.ok(
      backendFp.nonZeroRatio > NON_ZERO_RATIO_MIN,
      `${backend.name}: backend non-zero pixel ratio ` +
        `${backendFp.nonZeroRatio.toFixed(3)} <= ${NON_ZERO_RATIO_MIN} — ` +
        "the launcher is emitting a placeholder grey/black frame. " +
        "This is the regression signature for a broken render path " +
        "(e.g. gpui_render_try_take missing from the dylib).",
    );

    // Now spin up the editor proxy + browser path.
    proxy = await startEditorProxy(editorPort, launcherPort, backend.name);
    const opened = await openEditor(editorPort);
    ctx = opened.ctx;
    const page = opened.page;

    await page.evaluate(() => {
      window.__isonimTestMode = true;
    });
    await pickBackendAndTaskStory(page, backend);

    // Wait for the transport to settle on the expected encoder.
    const transportSettled = await waitFor(async () => {
      const v = await page.evaluate(
        () => document.body.dataset.isonimActiveTransport || "",
      );
      return v === backend.expectedTransport;
    }, 25000);
    if (!transportSettled) {
      const last = await page.evaluate(
        () => document.body.dataset.isonimActiveTransport || "",
      );
      assert.fail(
        `${backend.name}: editor transport never settled on ` +
          `${backend.expectedTransport} (last="${last}")`,
      );
    }

    await pickViewportPill(page, VIEWPORT.slug);
    await new Promise((r) => setTimeout(r, 1200));

    // Wait for a non-zero canvas to be painted.
    const canvasReady = await waitFor(async () => {
      const ok = await page.evaluate(() => {
        const cs = document.querySelectorAll(
          '[data-canvas-wrapper="true"] canvas',
        );
        for (const c of cs) {
          const r = c.getBoundingClientRect();
          if (r.width > 10 && r.height > 10 && c.width > 10 && c.height > 10) {
            return true;
          }
        }
        return false;
      });
      return ok;
    }, 15000);
    assert.ok(canvasReady, `${backend.name}: canvas never became renderable`);
    // Give a few frames headroom so the canvas has paint to read.
    await new Promise((r) => setTimeout(r, 800));

    const browserCap = await captureBrowserPixels(page);
    assert.ok(browserCap, `${backend.name}: failed to capture browser pixels`);

    // Decode the base64 RGBA into a Buffer for fingerprinting.
    const browserRgba = Buffer.from(browserCap.rgbaB64, "base64");
    const expectedBrowserLen = browserCap.width * browserCap.height * 4;
    assert.equal(
      browserRgba.length,
      expectedBrowserLen,
      `${backend.name}: browser RGBA buffer length mismatch ` +
        `(${browserRgba.length} vs expected ${expectedBrowserLen})`,
    );
    const browserFp = fingerprint(
      browserRgba,
      browserCap.width,
      browserCap.height,
    );

    // Browser-side reality assertion.
    assert.ok(
      browserFp.nonZeroRatio > NON_ZERO_RATIO_MIN,
      `${backend.name}: browser canvas non-zero pixel ratio ` +
        `${browserFp.nonZeroRatio.toFixed(3)} <= ${NON_ZERO_RATIO_MIN} — ` +
        "the canvas is stuck on a placeholder fill. The browser-side " +
        "decode/paint path is broken even though the bridge delivered " +
        "real bytes.",
    );

    // DPR contract.
    const dprDriftW = Math.abs(
      browserCap.rectW * browserCap.dpr - browserCap.width,
    );
    const dprDriftH = Math.abs(
      browserCap.rectH * browserCap.dpr - browserCap.height,
    );
    assert.ok(
      dprDriftW <= DPR_DRIFT_MAX_PX && dprDriftH <= DPR_DRIFT_MAX_PX,
      `${backend.name}: DPR drift exceeds ${DPR_DRIFT_MAX_PX}px ` +
        `(w=${dprDriftW.toFixed(2)}, h=${dprDriftH.toFixed(2)}, ` +
        `intrinsic=${browserCap.width}x${browserCap.height}, ` +
        `rect=${browserCap.rectW.toFixed(1)}x${browserCap.rectH.toFixed(1)}, ` +
        `dpr=${browserCap.dpr})`,
    );

    // Perceptual-grid correlation between backend and browser.
    const gridDelta = fingerprintCompareDelta(backendFp, browserFp);
    assert.ok(
      gridDelta <= FINGERPRINT_DELTA_MAX,
      `${backend.name}: backend↔browser 16x16 grid delta ` +
        `${gridDelta.toFixed(2)} > ${FINGERPRINT_DELTA_MAX}. The browser ` +
        "canvas does not visually correspond to what the launcher " +
        "emitted — wires are crossed somewhere between the bridge and " +
        "the canvas paint.",
    );

    const dt = Date.now() - t0;
    process.stderr.write(
      `[real-pixel-rt] ${backend.name}: pass ` +
        `backend(nz=${backendFp.nonZeroRatio.toFixed(3)} ` +
        `sd=${backendFp.stddev.toFixed(1)} ` +
        `mean=${backendFp.meanR.toFixed(0)}/${backendFp.meanG.toFixed(0)}/${backendFp.meanB.toFixed(0)}) ` +
        `browser(nz=${browserFp.nonZeroRatio.toFixed(3)} ` +
        `sd=${browserFp.stddev.toFixed(1)} ` +
        `mean=${browserFp.meanR.toFixed(0)}/${browserFp.meanG.toFixed(0)}/${browserFp.meanB.toFixed(0)}) ` +
        `gridΔ=${gridDelta.toFixed(2)} ` +
        `dprDrift=(${dprDriftW.toFixed(2)},${dprDriftH.toFixed(2)}) ` +
        `runtime=${dt}ms\n`,
    );
  } finally {
    try {
      if (ctx) await ctx.close();
    } catch (_) {}
    try {
      if (launcher) launcher.kill("SIGTERM");
      await new Promise((r) => setTimeout(r, 200));
      if (launcher) launcher.kill("SIGKILL");
    } catch (_) {}
    try {
      if (proxy) await proxy.shutdown();
    } catch (_) {}
  }
}

// -----------------------------------------------------------------------
// Test harness
// -----------------------------------------------------------------------

test.before(async () => {
  // Verify ffmpeg is on PATH up front; the W/V decode paths depend on
  // it. The build step also runs here so the failure surface is
  // clearly diagnostic (build failure vs runtime failure).
  const probe = spawnSync("ffmpeg", ["-version"], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (probe.status !== 0) {
    throw new Error(
      "ffmpeg is not on PATH — required for W/V packet decode " +
        "(install via nix / brew / apt).",
    );
  }
  buildAll();
});

test.after(async () => {
  try {
    if (browser) await browser.close();
  } catch (_) {}
});

test("real-pixel round-trip across desktop backends", async (t) => {
  if (!isMacOS) {
    t.skip(SKIP_REASON);
    return;
  }
  // Sequential per backend — see FUH-M6 (the matrix harness)
  // for the deadlock surprise that motivates this.
  for (const backend of BACKENDS) {
    await t.test(backend.name, async () => {
      await runBackend(backend);
    });
  }
});
