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
//      lose every signal value. As a side effect of `--genScript`,
//      Nim drops a `.deps` file in nimcache that lists every
//      source file it touched (transitively, including macros and
//      conditional imports). We feed that list into
//      `this.addWatchFile` so Vite watches the real graph rather
//      than a regex's best guess.
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

import { execSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync } from "node:fs";
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

// Paths inside the Nim distribution. We strip these from the dep
// list because they are part of the Nim toolchain (lib/system,
// lib/std, lib/pure, lib/core, etc.) and change only when the
// developer upgrades nim itself — not on every save.
function isNimStdlibPath(absPath: string): boolean {
  return (
    /[/\\]lib[/\\](system|std|pure|core|impure|posix|windows|wrappers)[/\\]/.test(
      absPath,
    ) || /[/\\]lib[/\\]system\.nim$/.test(absPath)
  );
}

function readDepsFile(depsPath: string, entry: string): Set<string> {
  // `nim --genScript` writes one absolute path per line to
  // `<nimcache>/<basename>.deps`. The file lists every source the
  // compiler actually touched — including conditional `when`
  // branches, macro-emitted imports, and nimble package edges
  // that a regex over the entry file alone could never see.
  const visited = new Set<string>();
  visited.add(entry);
  let raw: string;
  try {
    raw = readFileSync(depsPath, "utf8");
  } catch {
    return visited;
  }
  for (const line of raw.split("\n")) {
    const p = line.trim();
    if (!p || isNimStdlibPath(p)) continue;
    visited.add(p);
  }
  return visited;
}

export default function isonim(opts: IsonimPluginOptions): Plugin {
  const cacheDir = opts.cacheDir ?? mkdtempSync(join(tmpdir(), "isonim-vite-"));
  const defines = ["isonimHmr", ...(opts.extraDefines ?? [])];
  const paths = [opts.isonimRoot, ...(opts.extraNimPaths ?? [])];

  function compileNim(nimPath: string): { code: string; deps: Set<string> } {
    // One nimcache per .nim source so concurrent compiles (Vite
    // may parallelise) don't collide on intermediate files.
    const safeBase =
      basename(nimPath, ".nim") +
      "." +
      Buffer.from(nimPath).toString("base64url").slice(0, 8);
    const moduleCache = join(cacheDir, safeBase);
    mkdirSync(moduleCache, { recursive: true });
    const out = join(moduleCache, "out.js");
    // `--genScript` makes Nim emit a `<basename>.deps` file in
    // nimcache that lists every source file the build actually
    // read. For JS targets, --genScript still produces the .js
    // output we want; it only adds the .deps + a compile_*.sh
    // script (which we ignore).
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
      const err = e as { stdout?: Buffer; stderr?: Buffer; message: string };
      const out = err.stdout?.toString() ?? "";
      const errs = err.stderr?.toString() ?? "";
      throw new Error(
        `nim compile failed for ${nimPath}:\n${errs || out || err.message}`,
      );
    }
    const depsPath = join(moduleCache, basename(nimPath, ".nim") + ".deps");
    return {
      code: readFileSync(out, "utf8"),
      deps: readDepsFile(depsPath, nimPath),
    };
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
      // Compile via `nim js --genScript`. The same invocation
      // produces both the JS output and the authoritative
      // dependency list (read from <nimcache>/<base>.deps). This
      // catches transitive edges the regex BFS would miss:
      // imports inside `when` blocks, macro-emitted imports,
      // nimble package edges, and re-exports through `include`.
      const { code, deps } = compileNim(id);
      compiledModules.set(id, deps);
      for (const dep of deps) {
        if (dep !== id) this.addWatchFile(dep);
      }
      // Self-accept so Vite's HMR stops bubbling here. Without
      // this, Vite would walk up to the entry and full-reload the
      // page on every Nim edit — defeating the whole point.
      const trailer =
        "\nif (import.meta.hot) { import.meta.hot.accept(() => {}); }\n";
      return { code: code + trailer, map: null };
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
