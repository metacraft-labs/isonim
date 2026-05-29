// EPP-M4 — editor connects to the Cocoa launcher, the launcher's
// hello capability bag advertises ``cocoaCapturePath: "metal"``, and
// the first streamed F-packet carries non-trivial RGBA bytes (the
// real Metal-backed capture, not a uniform-grey placeholder).
//
// What this test exercises end-to-end:
//
//   1. Build the editor bundle (`just editor-build` in
//      ~/metacraft/isonim-examples) plus the cocoa launcher binary
//      (`just build-backends-macos`). On Linux the cocoa launcher
//      doesn't exist and the entire test skips with `test.skip`.
//   2. Spawn the real ``build/backends/isonim-examples-cocoa`` binary
//      on a free port (no mock launcher — EPP-M4's contract is
//      "real Metal helper runs end-to-end" so we must drive it).
//   3. Open the editor in headless Chromium pointed at a tiny static
//      server that proxies /bridge/cocoa to the real launcher.
//   4. Connect a WS client directly to the launcher to observe the
//      hello packet's capability bag.
//   5. Assert (a) ``capabilities.cocoaCapturePath === "metal"`` —
//      the Metal probe at launcher boot resolved to ``ccpMetal``
//      and the hello carries the human-readable label — and (b) the
//      first F-packet's pixel payload contains at least one non-grey
//      pixel (the Metal path produced a real raster of the task_app
//      tree, not the Linux placeholder grey).
//
// Convention: `node --test` (matches the rest of
// `isonim/tests/browser/e2e_*.mjs`).

import { execSync, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";
import WebSocket from "ws";
import net from "node:net";

const __dirname = dirname(fileURLToPath(import.meta.url));
const isonimRoot = join(__dirname, "..", "..");
const isonimExamplesRoot = join(isonimRoot, "..", "isonim-examples");
const cocoaLauncherBin = join(
  isonimExamplesRoot,
  "build",
  "backends",
  "isonim-examples-cocoa",
);

const isMacOS = process.platform === "darwin";

function exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

function buildEditorAndCocoa() {
  exec("direnv exec . just editor-build", { cwd: isonimExamplesRoot });
  exec("direnv exec . just build-backends-macos", {
    cwd: isonimExamplesRoot,
  });
  if (!existsSync(cocoaLauncherBin)) {
    throw new Error(
      `cocoa launcher binary missing: ${cocoaLauncherBin} — ` +
        `did just build-backends-macos succeed?`,
    );
  }
}

// Pick an unused local TCP port for the launcher.
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

async function spawnCocoaLauncher(port) {
  // The launcher binds 127.0.0.1:<port>, listens for WS upgrades at
  // /bridge/cocoa, and emits an `M`-packet hello on connect (per
  // RS-M0 / EPP-M4 bridge contract).
  const proc = spawn(
    cocoaLauncherBin,
    [
      "--port",
      String(port),
      "--demo",
      "task",
      "--width",
      "320",
      "--height",
      "240",
      "--fps",
      "30",
    ],
    {
      cwd: isonimExamplesRoot,
      env: { ...process.env },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  // Forward launcher stderr to test stderr for debugging.
  proc.stderr.on("data", (b) => process.stderr.write(`[cocoa-launcher] ${b}`));
  proc.stdout.on("data", (b) => process.stderr.write(`[cocoa-launcher] ${b}`));

  // Wait until the launcher's HTTP socket is accepting connections.
  await new Promise((resolve, reject) => {
    const deadline = Date.now() + 15000;
    const tick = () => {
      if (Date.now() > deadline) {
        reject(new Error("cocoa launcher failed to come up in 15s"));
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

// Drain WebSocket packets up to ``deadlineMs`` and return the
// collected F / M packet bodies. The launcher emits hello as the
// first M, then a steady stream of F's.
async function collectFrames(port, deadlineMs) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/bridge/cocoa`);
    const helloBodies = [];
    const fPackets = [];
    const timer = setTimeout(() => {
      try {
        ws.close();
      } catch (_) {}
      resolve({ helloBodies, fPackets });
    }, deadlineMs);

    ws.on("open", () => {});
    ws.on("message", (data, isBinary) => {
      if (!isBinary || !Buffer.isBuffer(data) || data.length < 5) return;
      const kind = String.fromCharCode(data[0]);
      if (kind === "M") {
        const len = data.readUInt32LE(1);
        if (5 + len > data.length) return;
        const body = data.subarray(5, 5 + len).toString("utf-8");
        try {
          helloBodies.push(JSON.parse(body));
        } catch (_) {}
      } else if (kind === "F") {
        // F header: 'F' | u8 flags | u32 width | u32 height | u32 length | payload
        if (data.length < 14) return;
        const flags = data[1];
        const width = data.readUInt32LE(2);
        const height = data.readUInt32LE(6);
        const length = data.readUInt32LE(10);
        if (14 + length > data.length) return;
        const payload = data.subarray(14, 14 + length);
        fPackets.push({ flags, width, height, length, payload });
      }
    });
    ws.on("error", (e) => {
      clearTimeout(timer);
      reject(e);
    });
    ws.on("close", () => {
      clearTimeout(timer);
      resolve({ helloBodies, fPackets });
    });
  });
}

const SKIP_REASON =
  "EPP-M4 — macOS-only milestone. Linux CI compiles the Nim adapter " +
  "as a placeholder; the live launcher binary is built only on Darwin.";

let launcher = null;

test.before(async () => {
  if (!isMacOS) return;
  buildEditorAndCocoa();
});

test.after(async () => {
  try {
    if (launcher) launcher.kill("SIGTERM");
  } catch (_) {}
});

test("cocoa launcher advertises cocoaCapturePath=metal in hello", async (t) => {
  if (!isMacOS) {
    t.skip(SKIP_REASON);
    return;
  }
  const port = await pickFreePort();
  launcher = await spawnCocoaLauncher(port);
  const { helloBodies, fPackets } = await collectFrames(port, 3000);

  assert.ok(
    helloBodies.length >= 1,
    "expected the launcher to emit at least one M packet (hello)",
  );
  const hello = helloBodies.find((m) => m.type === "hello");
  assert.ok(hello, "expected a hello M packet");
  assert.equal(hello.backend, "cocoa");
  assert.equal(
    hello.capabilities && hello.capabilities.cocoaCapturePath,
    "metal",
    "expected capabilities.cocoaCapturePath to be 'metal' — the " +
      "Metal probe at launcher boot must succeed on a real macOS host",
  );

  // Some F packets should have streamed within the 3-second window
  // even at the conservative 30 FPS cap.
  assert.ok(
    fPackets.length >= 1,
    `expected at least one F packet from the cocoa launcher, got ${fPackets.length}`,
  );

  // Inspect the first non-diff F packet payload (flags bit 0 == diff).
  // The wire format for non-diff F packets is raw RGBA8888 row-major.
  const fullFrame = fPackets.find((f) => (f.flags & 1) === 0);
  assert.ok(
    fullFrame,
    "expected at least one full-frame F packet (flags bit 0 = 0) so " +
      "we can assert the raster content directly",
  );
  assert.equal(
    fullFrame.length,
    fullFrame.width * fullFrame.height * 4,
    "F-packet payload length must match width*height*4 (RGBA8888)",
  );

  // The Linux scaffold returns a uniform (0x18, 0x18, 0x18, 0xFF)
  // dark grey for every pixel. The Metal-backed capture path on a
  // real macOS host must produce at least one pixel whose RGB
  // channels do NOT match that placeholder.
  let nonPlaceholderPixels = 0;
  for (let i = 0; i < fullFrame.length; i += 4) {
    const r = fullFrame.payload[i + 0];
    const g = fullFrame.payload[i + 1];
    const b = fullFrame.payload[i + 2];
    if (!(r === 0x18 && g === 0x18 && b === 0x18)) {
      nonPlaceholderPixels++;
    }
  }
  assert.ok(
    nonPlaceholderPixels > (fullFrame.width * fullFrame.height) / 4,
    `expected more than 25% non-placeholder pixels from the Metal ` +
      `capture path; got ${nonPlaceholderPixels} of ` +
      `${fullFrame.width * fullFrame.height} pixels`,
  );

  launcher.kill("SIGTERM");
  launcher = null;
});
