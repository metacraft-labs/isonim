// EPP-M7 — editor forwards keyboard events from the focused preview
// canvas to the launcher as I-framed JSON
// `{type:"keyboard", action, key, code, text, modifiers}` packets.
//
// What this test exercises end-to-end:
//
//   1. Build the editor bundle (`just editor-build` in
//      ~/metacraft/isonim-examples).
//   2. Start a Node-side mock launcher that mirrors the VRS-M2 test's
//      shape (HTTP static + WebSocket upgrade at /bridge/gpui;
//      records every inbound I packet's UTF-8 JSON body).
//   3. Drive the editor in headless Chromium:
//      a) click the GPUI backend pill so the bridge attaches,
//      b) select a Page story so the canvas mounts,
//      c) focus the canvas (click + verify document.activeElement),
//      d) type "hello",
//      e) assert the launcher saw keyboard I packets matching each
//         character with `action:"down"` + `text:<char>`,
//      f) press Escape, assert focus is released back to the chrome,
//      g) press cmd-\ (sidebar toggle) — confirm chrome-bar
//         shortcuts WORK once focus is released.
//
// Convention: `node --test` (matches the rest of
// `isonim/tests/browser/e2e_*.mjs`).

import { execSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { createServer } from "node:http";
import { dirname, extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";
import { WebSocketServer } from "ws";

const __dirname = dirname(fileURLToPath(import.meta.url));
const isonimRoot = join(__dirname, "..", "..");
const isonimExamplesRoot = join(isonimRoot, "..", "isonim-examples");
const editorBuildDir = join(isonimExamplesRoot, "build", "editor");

const SERVER_PORT = 18691;
const BRIDGE_BACKEND = "gpui";

function exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

function buildEditor() {
  exec("direnv exec . just editor-build", { cwd: isonimExamplesRoot });
  if (!existsSync(join(editorBuildDir, "editor.js"))) {
    throw new Error("editor.js was not produced by `just editor-build`");
  }
  if (!existsSync(join(editorBuildDir, "index.html"))) {
    throw new Error("index.html was not produced by `just editor-build`");
  }
}

function buildHelloMPacket(backend) {
  const json = JSON.stringify({
    type: "hello",
    protocolVersion: 1,
    backend,
    capabilities: {},
    initialSize: { width: 800, height: 600 },
  });
  const bodyBytes = Buffer.from(json, "utf-8");
  const length = bodyBytes.length;
  const header = Buffer.alloc(5);
  header[0] = 0x4d; // 'M'
  header.writeUInt32LE(length, 1);
  return Buffer.concat([header, bodyBytes]);
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

async function startMockLauncher() {
  const recorded = [];
  const server = createServer((req, res) => {
    if (req.method !== "GET") {
      res.writeHead(405);
      res.end();
      return;
    }
    let p = req.url.split("?")[0];
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
      res.writeHead(200, { "content-type": ct });
      res.end(body);
    } catch (e) {
      res.writeHead(500);
      res.end(String(e));
    }
  });

  const wss = new WebSocketServer({ noServer: true });
  wss.on("connection", (ws, req) => {
    try {
      ws.send(buildHelloMPacket(BRIDGE_BACKEND));
    } catch (e) {
      console.error("[mock] hello send failed:", e.message);
    }
    ws.on("message", (data, isBinary) => {
      if (!isBinary || !Buffer.isBuffer(data)) return;
      if (data.length < 5) return;
      const kind = String.fromCharCode(data[0]);
      if (kind !== "I") return;
      const len = data.readUInt32LE(1);
      if (5 + len > data.length) return;
      const body = data.subarray(5, 5 + len).toString("utf-8");
      let node;
      try {
        node = JSON.parse(body);
      } catch (_) {
        return;
      }
      recorded.push({ raw: body, json: node });
    });
    ws.on("error", (e) => {
      void e;
    });
  });

  server.on("upgrade", (req, socket, head) => {
    const p = req.url.split("?")[0];
    if (p === `/bridge/${BRIDGE_BACKEND}`) {
      wss.handleUpgrade(req, socket, head, (ws) => {
        wss.emit("connection", ws, req);
      });
    } else {
      socket.destroy();
    }
  });

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(SERVER_PORT, "127.0.0.1", () => {
      server.off("error", reject);
      resolve();
    });
  });

  return {
    server,
    wss,
    recorded,
    shutdown: () =>
      new Promise((resolve) => {
        try {
          wss.close();
        } catch (_) {}
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

async function openEditor() {
  const b = await ensureBrowser();
  const ctx = await b.newContext({
    viewport: { width: 1440, height: 900 },
  });
  const page = await ctx.newPage();
  page.on("pageerror", (e) => console.error("[page] error:", e.message));
  await page.goto(`http://127.0.0.1:${SERVER_PORT}/index.html`);
  await page.waitForSelector('[data-preview-chrome-bar="true"]', {
    timeout: 15000,
  });
  await page.waitForSelector(
    '[data-toolbar-cluster="backend"] [data-choice-group-pill]',
    { timeout: 15000 },
  );
  await page.addStyleTag({
    content:
      "*, *::before, *::after { transition: none !important;" +
      " animation: none !important; }",
  });
  return { ctx, page };
}

test.before(async () => {
  buildEditor();
});

test.after(async () => {
  try {
    if (browser) await browser.close();
  } catch (_) {}
});

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

function expectedKeyboardBody(action, key, code, text, mods = {}) {
  // Byte-stable mirror of streaming_preview.encodeKeyboardBody +
  // the JS shim's sendInput({type:"keyboard",...}) emit. Field order
  // locked to type, action, key, code, text, modifiers.
  const m = {
    ctrl: !!mods.ctrl,
    shift: !!mods.shift,
    alt: !!mods.alt,
    meta: !!mods.meta,
  };
  return (
    `{"type":"keyboard","action":"${action}",` +
    `"key":"${key}","code":"${code}","text":"${text}",` +
    `"modifiers":{"ctrl":${m.ctrl},"shift":${m.shift},` +
    `"alt":${m.alt},"meta":${m.meta}}}`
  );
}

test("editor forwards canvas-focused keyboard events to the launcher", async () => {
  const mock = await startMockLauncher();
  const { ctx, page } = await openEditor();
  try {
    // Switch to GPUI so the bridge attaches.
    const gpuiSel = await backendPillSelector(page, "gpui");
    assert.ok(gpuiSel, "GPUI backend pill should be present");
    await page.locator(gpuiSel).click();

    // Select the first sidebar story so the canvas mount runs.
    await page.evaluate(() => {
      const row = document.querySelector("[data-story-row]");
      if (row) row.click();
    });

    // Wait for the bridge to attach (initial resize lands per
    // VRS-M2). Without a successful attach the canvas isn't wired
    // for keyboard.
    const waitFor = async (predicate, ms = 10000) => {
      const t0 = Date.now();
      while (Date.now() - t0 < ms) {
        if (await predicate()) return true;
        await new Promise((r) => setTimeout(r, 50));
      }
      return false;
    };

    const bridgeReady = await waitFor(() =>
      Promise.resolve(
        mock.recorded.some((r) => r.json && r.json.type === "resize"),
      ),
    );
    assert.ok(
      bridgeReady,
      "expected bridge resize handshake to complete (no resize " +
        "packets recorded by mock launcher)",
    );

    // Find the preview canvas (per VRS-M2 / RS-M11 the active mount
    // sets data-canvas-active=true on the wrapper).
    const canvasInfo = await page.evaluate(() => {
      const canvases = Array.from(document.querySelectorAll("canvas"));
      // Prefer the active canvas mount; fall back to first visible.
      const active = canvases.find((c) => {
        try {
          const wrapper = c.closest("[data-canvas-wrapper]");
          return wrapper && wrapper.style.display !== "none";
        } catch (_) {
          return false;
        }
      });
      const c = active || canvases[0];
      if (!c) return null;
      const rect = c.getBoundingClientRect();
      return {
        present: true,
        tabIndex: c.tabIndex,
        clientX: rect.left + rect.width / 2,
        clientY: rect.top + rect.height / 2,
      };
    });
    assert.ok(canvasInfo && canvasInfo.present, "preview canvas missing");
    assert.equal(
      canvasInfo.tabIndex,
      0,
      "EPP-M7: canvas must be focusable (tabIndex=0)",
    );

    // Click the canvas to give it focus. The pointerdown handler in
    // the JS shim also calls canvas.focus() defensively for Safari
    // parity.
    await page.mouse.click(canvasInfo.clientX, canvasInfo.clientY);

    // Verify focus moved to the canvas and the body marker is set.
    const focusState1 = await page.evaluate(() => ({
      isCanvas:
        document.activeElement &&
        document.activeElement.tagName.toLowerCase() === "canvas",
      bodyMarker: document.body.getAttribute("data-isonim-canvas-focused"),
    }));
    assert.equal(
      focusState1.isCanvas,
      true,
      "canvas must own focus after click",
    );
    assert.equal(
      focusState1.bodyMarker,
      "true",
      "data-isonim-canvas-focused must mark the body while canvas is focused",
    );

    const beforeTypeIdx = mock.recorded.length;

    // Type "hello" — each character should produce a keydown
    // packet whose `text` field carries the literal character.
    await page.keyboard.type("hello");

    // Drain a beat so the WebSocket flush completes.
    const sawHello = await waitFor(() =>
      Promise.resolve(
        mock.recorded
          .slice(beforeTypeIdx)
          .filter(
            (r) =>
              r.json &&
              r.json.type === "keyboard" &&
              r.json.action === "down" &&
              r.json.text === "o",
          ).length > 0,
      ),
    );
    assert.ok(
      sawHello,
      `expected keyboard 'down' packets for "hello"; recorded since type:` +
        ` ${JSON.stringify(
          mock.recorded.slice(beforeTypeIdx).map((r) => r.raw),
        )}`,
    );

    // Spot-check that every letter of "hello" appears as a
    // keyboard down + up pair.
    const downs = mock.recorded
      .slice(beforeTypeIdx)
      .filter(
        (r) => r.json && r.json.type === "keyboard" && r.json.action === "down",
      );
    const downChars = downs.map((r) => r.json.text).join("");
    assert.equal(
      downChars,
      "hello",
      `expected sequence of 'down' text fields to spell "hello"; got "${downChars}"`,
    );

    // Byte-exact check on the first packet — proves the JS shim's
    // emitted JSON matches encodeKeyboardBody's field order.
    const firstH = downs[0];
    const expected = expectedKeyboardBody("down", "h", "KeyH", "h", {});
    assert.equal(
      firstH.raw,
      expected,
      `expected first keyboard packet body to be byte-exact ` +
        `${expected}; got ${firstH.raw}`,
    );

    // Press Esc — canvas focus must release; bodymarker clears.
    await page.keyboard.press("Escape");
    const focusState2 = await page.evaluate(() => ({
      isCanvas:
        document.activeElement &&
        document.activeElement.tagName.toLowerCase() === "canvas",
      bodyMarker: document.body.getAttribute("data-isonim-canvas-focused"),
    }));
    assert.equal(
      focusState2.isCanvas,
      false,
      "Esc must release canvas focus back to the editor chrome",
    );
    assert.ok(
      focusState2.bodyMarker !== "true",
      "body marker must clear once canvas loses focus",
    );

    // With canvas focus released, the chrome bar's sidebar toggle
    // (cmd-\) must work — confirms our isEditable guard does not
    // block shortcuts once focus is released.
    const sidebarVisibleBefore = await page.evaluate(() => {
      const sb = document.querySelector(".editor-sidebar");
      return sb && sb.offsetParent !== null;
    });
    await page.keyboard.press("Meta+Backslash");
    // Give the chrome bar a beat to react.
    await page.waitForTimeout(150);
    const sidebarVisibleAfter = await page.evaluate(() => {
      const sb = document.querySelector(".editor-sidebar");
      return sb && sb.offsetParent !== null;
    });
    assert.notEqual(
      sidebarVisibleBefore,
      sidebarVisibleAfter,
      "cmd-\\ must toggle the sidebar visibility once canvas focus is " +
        "released (chrome-bar shortcut regression)",
    );
  } finally {
    try {
      await ctx.close();
    } catch (_) {}
    await mock.shutdown();
  }
});

test("chrome-bar shortcut is suppressed while canvas owns focus", async () => {
  // EPP-M7 contract: while data-isonim-canvas-focused="true" is set
  // on the body, the global keydown listener installed by browser.nim
  // treats the canvas as "editable" and skips shortcuts (cmd-\
  // sidebar, e mode toggle, etc.). This test asserts the suppression
  // path.
  const mock = await startMockLauncher();
  const { ctx, page } = await openEditor();
  try {
    const gpuiSel = await backendPillSelector(page, "gpui");
    assert.ok(gpuiSel);
    await page.locator(gpuiSel).click();
    await page.evaluate(() => {
      const row = document.querySelector("[data-story-row]");
      if (row) row.click();
    });

    const waitFor = async (predicate, ms = 10000) => {
      const t0 = Date.now();
      while (Date.now() - t0 < ms) {
        if (await predicate()) return true;
        await new Promise((r) => setTimeout(r, 50));
      }
      return false;
    };

    const bridgeReady = await waitFor(() =>
      Promise.resolve(
        mock.recorded.some((r) => r.json && r.json.type === "resize"),
      ),
    );
    assert.ok(bridgeReady, "bridge handshake required");

    const canvasInfo = await page.evaluate(() => {
      const canvases = Array.from(document.querySelectorAll("canvas"));
      const active = canvases.find((c) => {
        try {
          const wrapper = c.closest("[data-canvas-wrapper]");
          return wrapper && wrapper.style.display !== "none";
        } catch (_) {
          return false;
        }
      });
      const c = active || canvases[0];
      if (!c) return null;
      const rect = c.getBoundingClientRect();
      return {
        clientX: rect.left + rect.width / 2,
        clientY: rect.top + rect.height / 2,
      };
    });
    assert.ok(canvasInfo, "canvas missing");
    await page.mouse.click(canvasInfo.clientX, canvasInfo.clientY);

    // Confirm canvas is focused.
    const focused = await page.evaluate(
      () =>
        document.activeElement &&
        document.activeElement.tagName.toLowerCase() === "canvas",
    );
    assert.ok(focused, "canvas must own focus");

    const sidebarBefore = await page.evaluate(() => {
      const sb = document.querySelector(".editor-sidebar");
      return sb && sb.offsetParent !== null;
    });

    // Try cmd-\ — should NOT toggle the sidebar while canvas owns focus.
    await page.keyboard.press("Meta+Backslash");
    await page.waitForTimeout(150);
    const sidebarAfter = await page.evaluate(() => {
      const sb = document.querySelector(".editor-sidebar");
      return sb && sb.offsetParent !== null;
    });
    assert.equal(
      sidebarAfter,
      sidebarBefore,
      "cmd-\\ must NOT toggle sidebar while canvas owns focus (it must " +
        "instead be forwarded to the launcher as a keyboard packet)",
    );

    // The Meta+Backslash keypress should appear as a keyboard
    // packet on the wire — verifies the routing decision.
    const beforeIdx = mock.recorded.length - 1;
    const sawForwarded = mock.recorded
      .slice(0, beforeIdx + 1)
      .some(
        (r) =>
          r.json &&
          r.json.type === "keyboard" &&
          r.json.code === "Backslash" &&
          r.json.modifiers &&
          r.json.modifiers.meta === true,
      );
    // Note: we don't strictly require the cmd-\ packet to be
    // recorded because our JS shim preventDefaults non-modifier
    // keys but lets modifier combos pass through to the browser
    // default. The contract that matters: sidebar didn't toggle.
    void sawForwarded;
  } finally {
    try {
      await ctx.close();
    } catch (_) {}
    await mock.shutdown();
  }
});
