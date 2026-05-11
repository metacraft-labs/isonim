// vite-plugin-isonim — reference integration of isonim's HMR layer
// into Vite's native HMR pipeline.
//
// Wires three things together:
//
//   1. `resolveId` recognises `*.nim` imports so Vite hands them to
//      our `load` instead of returning "module not found".
//
//   2. `load` runs the Nim compiler with `-d:isonimHmr` and returns
//      the resulting JS. We append a self-accept marker so Vite's
//      HMR stops bubbling at the isonim module boundary — the
//      bundler's "I'll just reload the whole page" fallback would
//      lose every signal value.
//
//   3. `handleHotUpdate` invalidates the cached compile when the
//      .nim source — or any of its transitive Nim imports — changes,
//      so Vite re-fetches and `load` runs the compiler again.
//
// The isonim slot system does the rest: when the new module's
// top-level code runs, each {.uiComponent.}-emitted
// `hmrRegisterFactory` call updates its slot's factory signal, and
// every `mountUiHot` boundary that reads that slot re-renders in
// place. See codetracer-specs/Front-Ends/IsoNim/Hot-Module-Reload-Host-Interop.md.
//
// Caveat: this plugin keeps Nim compilation simple — one .nim file
// is one Vite module. For projects with deep Nim import graphs the
// dependency tracking below (walking `import` statements in the
// source) is best-effort; production users would extend
// `findNimImports` or feed Nim's `--listFullPaths --listCmd` output
// back into Vite's watcher.

import { execSync } from "node:child_process";
import {
  mkdtempSync,
  readFileSync,
  writeFileSync,
  statSync,
  existsSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import type { Plugin, HmrContext } from "vite";

interface IsonimPluginOptions {
  /** Absolute path to the isonim source root (the directory that
   *  contains `isonim/`). Passed to nim as `--path:`. */
  isonimRoot: string;
  /** Extra `--path:` entries to forward to nim, in order. Use for
   *  sibling repos (e.g. `nim-everywhere/src`). */
  extraNimPaths?: string[];
  /** Extra `-d:` defines beyond `-d:isonimHmr`. */
  extraDefines?: string[];
  /** Compiled-output cache dir. Defaults to a fresh tmpdir per
   *  plugin instance. Mainly useful for debugging. */
  cacheDir?: string;
}

// Tokens that start a Nim import. We tolerate `import foo`,
// `import foo, bar`, `import foo/[a, b]`, and `from foo import …`.
// `include` is treated identically — it pulls in source the same
// way as far as Vite watching is concerned.
//
// The character class is intentionally newline-free: `\s` in
// JavaScript regex includes `\n`, which would let a greedy `+`
// gobble half the file when an import line is followed by other
// code (e.g. `import ./foo\nexport foo\n…` becomes one match,
// and the captured "module name" is then garbage). We match a
// single line at a time and strip comments first.
const NIM_IMPORT_LINE_RE =
  /^(?:include|from|import)[ \t]+([\w./,\[\] \t]+?)(?:[ \t]+as[ \t]+\w+)?$/;

const NIM_STDLIB_PREFIXES = [
  // The stdlib we don't try to watch — it lives in the nim
  // distribution and is stable. Skipping these keeps the dep walk
  // bounded.
  "std/",
  "system/",
  "pure/",
];

function isStdlibImport(spec: string): boolean {
  if (NIM_STDLIB_PREFIXES.some((p) => spec.startsWith(p))) return true;
  // Bare names like `strutils` / `tables` / `os` etc. — also
  // stdlib by convention unless the developer's own code shadows
  // them, which `resolveImport`'s search-path probe catches.
  return !spec.includes("/") && !spec.startsWith(".");
}

function resolveImport(
  spec: string,
  sourceDir: string,
  searchPaths: string[],
): string | null {
  // Relative imports resolve against the importer's directory.
  if (spec.startsWith(".")) {
    const guess = resolve(sourceDir, spec + ".nim");
    return existsSync(guess) ? guess : null;
  }
  // Absolute file paths (rare in idiomatic Nim, but legal).
  if (spec.startsWith("/")) {
    const guess = spec + ".nim";
    return existsSync(guess) ? guess : null;
  }
  // Path-shaped imports: probe each `--path:` directory.
  for (const root of searchPaths) {
    const guess = join(root, spec + ".nim");
    if (existsSync(guess)) return guess;
  }
  return null;
}

function findNimImports(
  nimSource: string,
  sourceDir: string,
  searchPaths: string[],
): string[] {
  const deps: string[] = [];
  for (const rawLine of nimSource.split("\n")) {
    // Strip line comments (everything after `#` that isn't inside
    // a string — best-effort; Nim's comment syntax is simple
    // enough that this works for import lines in practice).
    const line = rawLine.replace(/#.*$/, "").trim();
    if (!line) continue;
    const m = NIM_IMPORT_LINE_RE.exec(line);
    if (!m) continue;
    const raw = m[1].trim();
    if (!raw) continue;
    // Bracketed group: `foo/[a, b]` → `foo/a`, `foo/b`.
    const expanded = raw.match(/^([\w./]+)\/\[([\w./,\s]+)\]$/);
    const candidates: string[] = expanded
      ? expanded[2].split(",").map((s) => `${expanded[1]}/${s.trim()}`)
      : raw.split(",").map((s) => s.trim());
    for (const c of candidates) {
      if (!c) continue;
      if (isStdlibImport(c)) continue;
      const resolved = resolveImport(c, sourceDir, searchPaths);
      if (resolved) deps.push(resolved);
    }
  }
  return deps;
}

function transitiveNimDeps(entry: string, searchPaths: string[]): Set<string> {
  // Breadth-first walk over `.nim` import edges. Bounded by visited.
  // Each visit reads the file once; for typical-sized projects this
  // is a few dozen reads, well below the cost of a Nim recompile,
  // so we do it on every `load` rather than caching across edits.
  const visited = new Set<string>();
  const queue = [entry];
  while (queue.length > 0) {
    const path = queue.shift()!;
    if (visited.has(path) || !existsSync(path)) continue;
    visited.add(path);
    let src: string;
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

export default function isonim(opts: IsonimPluginOptions): Plugin {
  const cacheDir = opts.cacheDir ?? mkdtempSync(join(tmpdir(), "isonim-vite-"));
  const defines = ["isonimHmr", ...(opts.extraDefines ?? [])];
  const paths = [opts.isonimRoot, ...(opts.extraNimPaths ?? [])];

  function compileNim(nimPath: string): string {
    const out = join(
      cacheDir,
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
      const err = e as { stdout?: Buffer; stderr?: Buffer; message: string };
      const out = err.stdout?.toString() ?? "";
      const errs = err.stderr?.toString() ?? "";
      throw new Error(
        `nim compile failed for ${nimPath}:\n${errs || out || err.message}`,
      );
    }
    return readFileSync(out, "utf8");
  }

  // Track Nim source files we've seen so handleHotUpdate can map
  // edits to importing chains. Key: absolute path to a .nim file
  // we've compiled. Value: the absolute paths of its direct imports.
  const compiledModules = new Map<string, Set<string>>();

  return {
    name: "vite-plugin-isonim",
    enforce: "pre",

    async resolveId(source, importer) {
      if (!source.endsWith(".nim")) return null;
      if (source.startsWith("/") || source.startsWith(".")) {
        // Relative or absolute paths — resolve them ourselves;
        // Vite's default resolver would refuse the unknown
        // extension.
        const base = importer ? dirname(importer) : process.cwd();
        return source.startsWith("/") ? source : resolve(base, source);
      }
      return null;
    },

    async load(id) {
      if (!id.endsWith(".nim")) return null;
      // Resolve the transitive Nim dependency closure — including
      // edges through the configured `--path:` directories so
      // `import isonim/core/signals` and friends get watched. The
      // closure is recomputed on every load() so refactors that
      // rename or move imports are picked up next compile without
      // a server restart.
      const closure = transitiveNimDeps(id, paths);
      compiledModules.set(id, closure);
      for (const dep of closure) {
        if (dep !== id) this.addWatchFile(dep);
      }

      const compiled = compileNim(id);
      // Self-accept so Vite's HMR stops bubbling here. Without
      // this, Vite would walk up to the entry and full-reload the
      // page on every Nim edit — defeating the whole point.
      const trailer =
        "\nif (import.meta.hot) { import.meta.hot.accept(() => {}); }\n";
      return { code: compiled + trailer, map: null };
    },

    handleHotUpdate(ctx: HmrContext) {
      if (!ctx.file.endsWith(".nim")) return;
      // Map a `.nim` edit to the set of Vite-managed modules whose
      // transitive Nim closure includes the changed file. Anything
      // we've ever compiled is a candidate; the closure recorded
      // at load-time tells us which ones to invalidate.
      const affected = new Set(ctx.modules);
      for (const [parent, closure] of compiledModules) {
        if (closure.has(ctx.file)) {
          const mod = ctx.server.moduleGraph.getModuleById(parent);
          if (mod) affected.add(mod);
        }
      }
      return [...affected];
    },
  };
}
