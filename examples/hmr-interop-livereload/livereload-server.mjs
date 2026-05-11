// A minimal LiveReload-protocol server (port 35729 by default).
//
// Implements just enough of the protocol to drive the integration
// test: the WebSocket handshake exchanges a `hello`, then the
// server emits `reload` messages on demand. We expose a tiny HTTP
// control endpoint on a sibling port so the Playwright spec can
// say "send a reload for path X" without owning a WS connection
// of its own.
//
// Control endpoint: POST http://localhost:35730/trigger
//   body: {"path": "<path>"}
//
// Real LiveReload servers (livereload, gulp-livereload,
// browser-sync) are file-watchers that emit `reload` automatically
// on disk changes. Here we let the test drive the timing
// directly — that's the difference between an integration test
// for the transport (this file) and an integration test for the
// whole dev loop (a Vite-style demo).
import { WebSocketServer } from "ws";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join, normalize } from "node:path";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const WS_PORT = Number(process.env.LIVERELOAD_WS_PORT ?? 35729);
const CONTROL_PORT = Number(process.env.LIVERELOAD_CONTROL_PORT ?? 35730);
const STATIC_PORT = Number(process.env.LIVERELOAD_STATIC_PORT ?? 5180);

const wss = new WebSocketServer({ port: WS_PORT, path: "/livereload" });
const clients = new Set();

wss.on("connection", (ws) => {
  clients.add(ws);
  ws.on("close", () => clients.delete(ws));
  ws.on("message", (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw.toString("utf8"));
    } catch {
      return;
    }
    if (msg && msg.command === "hello") {
      // Mirror the client's hello back. Real servers add their
      // own version string; we keep it minimal because the
      // isonim transport only checks `command === "hello"`.
      ws.send(
        JSON.stringify({
          command: "hello",
          protocols: ["http://livereload.com/protocols/official-7"],
          serverName: "isonim-livereload-test-stub",
        }),
      );
    }
  });
});

createServer((req, res) => {
  if (req.method !== "POST" || req.url !== "/trigger") {
    res.statusCode = 404;
    res.end("not found");
    return;
  }
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    let body;
    try {
      body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    } catch {
      res.statusCode = 400;
      res.end("bad json");
      return;
    }
    const path = String(body?.path ?? "");
    if (!path) {
      res.statusCode = 400;
      res.end("missing path");
      return;
    }
    const message = JSON.stringify({
      command: "reload",
      path,
      liveCSS: true,
      liveImg: false,
    });
    let delivered = 0;
    for (const ws of clients) {
      if (ws.readyState === 1) {
        ws.send(message);
        delivered += 1;
      }
    }
    res.statusCode = 200;
    res.end(`delivered=${delivered}`);
  });
}).listen(CONTROL_PORT);

// Static file server for the demo. Node's nix shell may not
// include `python3 -m http.server`, so we self-host the static
// assets on a separate port. Only files inside __dirname are
// served — no directory traversal.
const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
};
createServer(async (req, res) => {
  try {
    const url = new URL(req.url ?? "/", `http://localhost:${STATIC_PORT}`);
    let p = decodeURIComponent(url.pathname);
    if (p === "/" || p === "") p = "/index.html";
    const requested = normalize(join(__dirname, p));
    if (!requested.startsWith(__dirname)) {
      res.statusCode = 403;
      res.end("forbidden");
      return;
    }
    const ext = requested.slice(requested.lastIndexOf("."));
    const body = await readFile(requested);
    res.statusCode = 200;
    res.setHeader("content-type", MIME[ext] ?? "application/octet-stream");
    res.setHeader("cache-control", "no-store");
    res.end(body);
  } catch {
    res.statusCode = 404;
    res.end("not found");
  }
}).listen(STATIC_PORT);

// eslint-disable-next-line no-console
console.log(
  `[livereload-stub] WS :${WS_PORT}/livereload | ` +
    `control :${CONTROL_PORT}/trigger | static :${STATIC_PORT}/`,
);
