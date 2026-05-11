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

const NIM_IMPORT_RE = /^\s*(?:from\s+([\w./]+)|import\s+([\w./,\s]+))/gm;

function findNimImports(nimSource: string, sourceDir: string): string[] {
  // Best-effort: pull `import foo`, `from foo import …`, and the
  // bracketed form `import foo/[a, b]`. Resolves relative paths
  // against the source file's directory. Anything that fails to
  // resolve is silently ignored — Vite only needs to know about
  // files that *can* be watched on this developer's machine.
  const deps: string[] = [];
  let m: RegExpExecArray | null;
  while ((m = NIM_IMPORT_RE.exec(nimSource)) !== null) {
    const raw = (m[1] ?? m[2] ?? "").trim();
    if (!raw) continue;
    // Strip bracketed group lists: `foo/[a, b]` → `foo/a`, `foo/b`.
    const expanded = raw.match(/^([\w./]+)\/\[([\w./,\s]+)\]$/);
    const candidates: string[] = expanded
      ? expanded[2].split(",").map((s) => `${expanded[1]}/${s.trim()}`)
      : raw.split(",").map((s) => s.trim());
    for (const c of candidates) {
      if (!c) continue;
      // Only follow path-shaped imports — skip stdlib refs like `std/jsffi`.
      if (!c.includes("/") && !c.startsWith(".")) continue;
      const guess = join(sourceDir, c + ".nim");
      if (existsSync(guess)) deps.push(guess);
    }
  }
  return deps;
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
      const nimSource = readFileSync(id, "utf8");
      const deps = findNimImports(nimSource, dirname(id));
      compiledModules.set(id, new Set(deps));
      // Tell Vite to watch the transitive Nim imports so they
      // trigger the HMR update path even though they aren't
      // first-class modules in Vite's graph.
      for (const dep of deps) this.addWatchFile(dep);

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
      // Find every .nim module whose import tree contains the
      // changed file and tell Vite to update those Vite-modules.
      // For a leaf .nim that was directly imported, ctx.modules
      // already covers it; this loop is the transitive case.
      const affected = new Set(ctx.modules);
      for (const [parent, deps] of compiledModules) {
        if (deps.has(ctx.file) || parent === ctx.file) {
          const mod = ctx.server.moduleGraph.getModuleById(parent);
          if (mod) affected.add(mod);
        }
      }
      return [...affected];
    },
  };
}
