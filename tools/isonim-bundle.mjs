#!/usr/bin/env node
// isonim-bundle: builds IsoNim JS chunks and reports their sizes.
//
//   node tools/isonim-bundle.mjs build --kind main|worker --entry <file.nim>
//        --out <dir>/<chunk>.js [--minify] [-- <extra nim args>...]
//   node tools/isonim-bundle.mjs report <dir> [--json]
//
// `build` compiles one entry module to one chunk (`nim js -d:release`; a
// worker chunk also gets `-d:isonimWebWorker`, see isonim/web/worker.nim),
// optionally minifies it with terser, and records it in
// <dir>/bundle-manifest.json: {chunks: [{file, kind, entry}]}, one entry per
// file, replaced on rebuild.
//
// `report` lists every chunk of <dir>'s manifest with its size and gzipped
// size (gzip -9), one line each, or as JSON with --json. A chunk whose file
// is missing is an error (exit 1). This is the bundle-size tooling a
// budget such as INF-AREQ19's reads: each worker chunk is its own entry,
// counted separately from the main bundle that loads it.

import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, mkdirSync, statSync } from "node:fs";
import { dirname, basename, resolve, relative } from "node:path";
import { gzipSync } from "node:zlib";

const MANIFEST = "bundle-manifest.json";

function die(msg) {
  console.error(`isonim-bundle: ${msg}`);
  process.exit(1);
}

function readManifest(dir) {
  const path = resolve(dir, MANIFEST);
  if (!existsSync(path)) return { chunks: [] };
  return JSON.parse(readFileSync(path, "utf8"));
}

async function build(args) {
  const sep = args.indexOf("--");
  const own = sep >= 0 ? args.slice(0, sep) : args;
  const nimArgs = sep >= 0 ? args.slice(sep + 1) : [];
  const opt = (name) => {
    const i = own.indexOf(name);
    return i >= 0 ? own[i + 1] : undefined;
  };
  const kind = opt("--kind");
  const entry = opt("--entry");
  const out = opt("--out");
  if (kind !== "main" && kind !== "worker") die("--kind must be main or worker");
  if (!entry || !out) die("build needs --entry and --out");
  const outDir = dirname(resolve(out));
  mkdirSync(outDir, { recursive: true });

  const defines = ["-d:release"];
  if (kind === "worker") defines.push("-d:isonimWebWorker");
  const nim = spawnSync(
    "nim",
    ["js", "--hints:off", ...defines, ...nimArgs, `-o:${resolve(out)}`, entry],
    { stdio: "inherit" },
  );
  if (nim.status !== 0) die(`nim js failed for ${entry}`);

  if (own.includes("--minify")) {
    const { minify } = await import("terser");
    const code = readFileSync(out, "utf8");
    const min = await minify(code, { compress: true, mangle: true });
    writeFileSync(out, min.code);
  }

  const manifest = readManifest(outDir);
  const file = basename(out);
  manifest.chunks = manifest.chunks.filter((c) => c.file !== file);
  manifest.chunks.push({ file, kind, entry: relative(outDir, resolve(entry)) });
  manifest.chunks.sort((a, b) => a.file.localeCompare(b.file));
  writeFileSync(resolve(outDir, MANIFEST), JSON.stringify(manifest, null, 2) + "\n");
}

function report(args) {
  const dir = args.find((a) => !a.startsWith("--"));
  if (!dir) die("report needs a directory");
  const manifest = readManifest(dir);
  if (manifest.chunks.length === 0) die(`no chunks recorded in ${resolve(dir, MANIFEST)}`);
  const rows = manifest.chunks.map((c) => {
    const path = resolve(dir, c.file);
    if (!existsSync(path)) die(`chunk ${c.file} is in the manifest but not in ${dir}`);
    const bytes = statSync(path).size;
    const gzipBytes = gzipSync(readFileSync(path), { level: 9 }).length;
    return { ...c, bytes, gzipBytes };
  });
  if (args.includes("--json")) {
    console.log(JSON.stringify({ dir: resolve(dir), chunks: rows }, null, 2));
  } else {
    for (const r of rows) {
      console.log(
        `${r.file.padEnd(32)} ${r.kind.padEnd(6)} ${String(r.bytes).padStart(9)} B` +
          ` ${String(r.gzipBytes).padStart(8)} B gzip`,
      );
    }
  }
}

const [cmd, ...rest] = process.argv.slice(2);
if (cmd === "build") await build(rest);
else if (cmd === "report") report(rest);
else die("usage: isonim-bundle.mjs build|report ... (see the header)");
