// nim-loader — reference Webpack loader for the isonim HMR interop
// integration.
//
// Pipes each .nim source through the Nim compiler with -d:isonimHmr
// and --genScript, emits the resulting JS to webpack, and appends a
// `module.hot.accept()` self-accept marker so Webpack's HMR runtime
// stops bubbling at the isonim module boundary — otherwise webpack
// walks up to the entry chunk and full-reloads the page, defeating
// the point.
//
// Transitive Nim dependency tracking: webpack only watches files
// that loaders explicitly declare via `this.addDependency(path)`.
// Without those calls, an edit to an imported .nim file wouldn't
// re-invoke this loader. We read the authoritative dependency list
// out of nim's own `--genScript` output: <nimcache>/<base>.deps is
// a newline-separated list of every source file the compiler
// touched (transitively, including macros, conditional imports,
// and nimble package edges).

const { execSync } = require("node:child_process");
const { mkdirSync, mkdtempSync, readFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { basename, join } = require("node:path");

// Paths inside the Nim distribution. Filtered out because they
// belong to the toolchain and only change on `nim` upgrade —
// adding them to webpack's watch set is wasted file handles.
const NIM_STDLIB_RE =
  /[/\\]lib[/\\](system|std|pure|core|impure|posix|windows|wrappers)[/\\]|[/\\]lib[/\\]system\.nim$/;

function readDepsFile(depsPath) {
  let raw;
  try {
    raw = readFileSync(depsPath, "utf8");
  } catch {
    return [];
  }
  const out = [];
  for (const line of raw.split("\n")) {
    const p = line.trim();
    if (!p || NIM_STDLIB_RE.test(p)) continue;
    out.push(p);
  }
  return out;
}

// Per-loader-instance cache dir for compiled JS + .deps files.
// One subdir per .nim source so concurrent compiles (webpack may
// parallelise) don't collide on intermediate files.
const CACHE_DIR = mkdtempSync(join(tmpdir(), "isonim-webpack-"));

function compileNim(nimPath, opts) {
  const defines = ["isonimHmr", ...(opts.extraDefines || [])];
  const paths = opts.searchPaths || [];
  const safeBase =
    basename(nimPath, ".nim") +
    "." +
    Buffer.from(nimPath).toString("base64url").slice(0, 8);
  const moduleCache = join(CACHE_DIR, safeBase);
  mkdirSync(moduleCache, { recursive: true });
  const out = join(moduleCache, "out.js");
  const cmd = [
    "nim js",
    ...defines.map((d) => `-d:${d}`),
    ...paths.map((p) => `--path:${JSON.stringify(p)}`),
    "--hints:off",
    "--warnings:off",
    "--genScript",
    `--nimcache:${JSON.stringify(moduleCache)}`,
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
  const depsPath = join(moduleCache, basename(nimPath, ".nim") + ".deps");
  return {
    code: readFileSync(out, "utf8"),
    deps: readDepsFile(depsPath),
  };
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
    const { code, deps } = compileNim(this.resourcePath, {
      searchPaths,
      extraDefines: opts.extraDefines,
    });
    // Declare every transitive Nim source as a webpack dependency
    // so an edit anywhere in the closure re-invokes this loader
    // and webpack's HMR pipeline picks the change up.
    for (const dep of deps) {
      if (dep !== this.resourcePath) this.addDependency(dep);
    }
    // Self-accept so Webpack's HMR runtime stops bubbling at this
    // module boundary. Without it, an edit to any .nim file walks
    // up to the entry chunk and webpack-dev-server full-reloads
    // the page (HMR's "fallback to liveReload" behaviour) — which
    // discards every signal value.
    const withHot =
      code + "\nif (module.hot) { module.hot.accept(() => {}); }\n";
    callback(null, withHot);
  } catch (e) {
    callback(e);
  }
};
