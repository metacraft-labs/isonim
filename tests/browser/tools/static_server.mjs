#!/usr/bin/env node
// Dependency-free static file server for the Playwright `webServer` entries.
//
// The config used to spawn `npx serve <dir> -l <port> -s`. `serve` is not a
// declared dependency of this package, of the repo root, or of the flake dev
// shell, so that line reached out to the npm registry on every run: slow,
// non-deterministic, and simply broken on an offline/sandboxed runner. This
// script is the same contract (static root + SPA fallback) with no install.
//
// Usage: node tools/static_server.mjs <root-dir> <port>
import { createServer } from "node:http";
import { createReadStream, statSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join, normalize, extname, resolve } from "node:path";

const [, , rootArg, portArg] = process.argv;
if (!rootArg || !portArg) {
  console.error("usage: node static_server.mjs <root-dir> <port>");
  process.exit(2);
}
const root = resolve(rootArg);
const port = Number(portArg);

try {
  if (!statSync(root).isDirectory()) throw new Error("not a directory");
} catch {
  console.error(
    `static_server: root ${root} does not exist.\n` +
      "The Playwright config builds this via a `just` target; see tests/browser/README.md.",
  );
  process.exit(1);
}

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".map": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".wasm": "application/wasm",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".txt": "text/plain; charset=utf-8",
};

function resolveFile(urlPath) {
  // Strip query/hash, decode, and refuse anything that escapes the root.
  let p = decodeURIComponent(urlPath.split("?")[0].split("#")[0]);
  if (p.endsWith("/")) p += "index.html";
  const candidate = normalize(join(root, p));
  if (candidate !== root && !candidate.startsWith(root + "/")) return null;
  try {
    const st = statSync(candidate);
    if (st.isDirectory()) {
      const idx = join(candidate, "index.html");
      statSync(idx);
      return idx;
    }
    return candidate;
  } catch {
    return null;
  }
}

const server = createServer(async (req, res) => {
  const file = resolveFile(req.url ?? "/");
  if (file) {
    res.writeHead(200, {
      "Content-Type": TYPES[extname(file)] ?? "application/octet-stream",
      "Cache-Control": "no-store",
    });
    createReadStream(file).pipe(res);
    return;
  }
  // SPA fallback — the `-s` flag the `serve` invocations carried.
  try {
    const body = await readFile(join(root, "index.html"));
    res.writeHead(200, {
      "Content-Type": TYPES[".html"],
      "Cache-Control": "no-store",
    });
    res.end(body);
  } catch {
    res.writeHead(404, { "Content-Type": TYPES[".txt"] });
    res.end("not found\n");
  }
});

server.listen(port, "127.0.0.1", () => {
  console.log(`static_server: serving ${root} on http://127.0.0.1:${port}`);
});
