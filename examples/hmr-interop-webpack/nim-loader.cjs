// nim-loader — reference Webpack loader for the isonim HMR interop
// integration.
//
// Pipes each .nim source through the Nim compiler with -d:isonimHmr,
// emits the resulting JS to webpack, and appends a
// `module.hot.accept()` self-accept marker so Webpack's HMR runtime
// stops bubbling at the isonim module boundary — otherwise webpack
// walks up to the entry chunk and full-reloads the page, defeating
// the point.
//
// Transitive Nim dependency tracking: webpack only watches files
// that loaders explicitly declare via `this.addDependency(path)`.
// Without those calls, an edit to an imported .nim file wouldn't
// re-invoke this loader. We BFS the .nim import graph using the
// same line-by-line scanner the Vite plugin uses; the search-paths
// list resolves path-shaped imports against the configured
// `--path:` directories so isonim core modules show up too.
//
// Companion: see `webpack.config.js` for how the loader is wired
// (rule + paths come from there) and the
// codetracer-specs/Front-Ends/IsoNim/Hot-Module-Reload-Host-Interop.md
// spec for the integration patterns this loader implements.

const { execSync } = require("node:child_process");
const { mkdtempSync, readFileSync, existsSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { basename, dirname, join, resolve } = require("node:path");

const NIM_IMPORT_LINE_RE =
  /^(?:include|from|import)[ \t]+([\w./,\[\] \t]+?)(?:[ \t]+as[ \t]+\w+)?$/;

const NIM_STDLIB_PREFIXES = ["std/", "system/", "pure/"];

function isStdlibImport(spec) {
  if (NIM_STDLIB_PREFIXES.some((p) => spec.startsWith(p))) return true;
  return !spec.includes("/") && !spec.startsWith(".");
}

function resolveImport(spec, sourceDir, searchPaths) {
  if (spec.startsWith(".")) {
    const guess = resolve(sourceDir, spec + ".nim");
    return existsSync(guess) ? guess : null;
  }
  if (spec.startsWith("/")) {
    const guess = spec + ".nim";
    return existsSync(guess) ? guess : null;
  }
  for (const root of searchPaths) {
    const guess = join(root, spec + ".nim");
    if (existsSync(guess)) return guess;
  }
  return null;
}

function findNimImports(source, sourceDir, searchPaths) {
  const deps = [];
  for (const rawLine of source.split("\n")) {
    const line = rawLine.replace(/#.*$/, "").trim();
    if (!line) continue;
    const m = NIM_IMPORT_LINE_RE.exec(line);
    if (!m) continue;
    const raw = m[1].trim();
    if (!raw) continue;
    const expanded = raw.match(/^([\w./]+)\/\[([\w./,\s]+)\]$/);
    const candidates = expanded
      ? expanded[2].split(",").map((s) => `${expanded[1]}/${s.trim()}`)
      : raw.split(",").map((s) => s.trim());
    for (const c of candidates) {
      if (!c || isStdlibImport(c)) continue;
      const resolved = resolveImport(c, sourceDir, searchPaths);
      if (resolved) deps.push(resolved);
    }
  }
  return deps;
}

function transitiveNimDeps(entry, searchPaths) {
  const visited = new Set();
  const queue = [entry];
  while (queue.length > 0) {
    const path = queue.shift();
    if (visited.has(path) || !existsSync(path)) continue;
    visited.add(path);
    let src;
    try {
      src = readFileSync(path, "utf8");
    } catch {
      continue;
    }
    for (const dep of findNimImports(src, dirname(path), searchPaths)) {
      if (!visited.has(dep)) queue.push(dep);
    }
  }
  return visited;
}

// Per-process cache dir for compiled JS. Mostly useful when
// debugging — webpack's own cache layer sits on top of the loader.
const CACHE_DIR = mkdtempSync(join(tmpdir(), "isonim-webpack-"));

function compileNim(nimPath, opts) {
  const defines = ["isonimHmr", ...(opts.extraDefines || [])];
  const paths = opts.searchPaths || [];
  const out = join(
    CACHE_DIR,
    basename(nimPath, ".nim") +
      "." +
      Buffer.from(nimPath).toString("base64url").slice(0, 8) +
      ".js",
  );
  const cmd = [
    "nim js",
    ...defines.map((d) => `-d:${d}`),
    ...paths.map((p) => `--path:${JSON.stringify(p)}`),
    "--hints:off",
    "--warnings:off",
    `-o:${JSON.stringify(out)}`,
    JSON.stringify(nimPath),
  ].join(" ");
  try {
    execSync(cmd, { stdio: ["ignore", "pipe", "pipe"] });
  } catch (e) {
    const stdout = e.stdout ? e.stdout.toString() : "";
    const stderr = e.stderr ? e.stderr.toString() : "";
    throw new Error(
      `nim compile failed for ${nimPath}:\n${stderr || stdout || e.message}`,
    );
  }
  return readFileSync(out, "utf8");
}

module.exports = function nimLoader(source) {
  const callback = this.async();
  const opts = this.getOptions
    ? this.getOptions() || {}
    : this.query && typeof this.query === "object"
      ? this.query
      : {};
  const searchPaths = opts.searchPaths || [];

  try {
    // Declare every transitive Nim import as a webpack dependency so
    // an edit anywhere in the closure re-invokes this loader and
    // webpack's HMR pipeline picks the change up.
    const closure = transitiveNimDeps(this.resourcePath, searchPaths);
    for (const dep of closure) {
      if (dep !== this.resourcePath) this.addDependency(dep);
    }

    const compiled = compileNim(this.resourcePath, {
      searchPaths,
      extraDefines: opts.extraDefines,
    });
    // Self-accept so Webpack's HMR runtime stops bubbling at this
    // module boundary. Without it, an edit to any .nim file walks
    // up to the entry chunk and webpack-dev-server full-reloads
    // the page (HMR's "fallback to liveReload" behaviour) — which
    // discards every signal value.
    const withHot =
      compiled + "\nif (module.hot) { module.hot.accept(() => {}); }\n";
    callback(null, withHot);
  } catch (e) {
    callback(e);
  }
};
