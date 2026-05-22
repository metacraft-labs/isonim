// TBAR-M5b: esbuild driver for the editor-vendor Nix derivation.
//
// Shells out to the ``esbuild`` CLI (provided via ``pkgs.esbuild`` in
// both the Nix derivation and the dev shell) to bundle each entry
// script into a minified UMD-shaped IIFE, then writes a
// ``MANIFEST.txt`` next to the bundles recording each output's path,
// SHA-256, byte count, and the originating ``yarn.lock`` SHA-256 so
// the editor-vendor dist-check test can verify integrity.
//
// Uses the CLI rather than ``import("esbuild")`` so this script
// doesn't need ``esbuild`` available in ``node_modules/`` — the Nix
// derivation deliberately keeps the JS dependency tree minimal
// (``@tiptap/*``, ``tiptap-markdown``, ``xterm``).
//
// Inputs:
//   * ``$OUT_DIR``   — destination directory (set by the Nix
//                      derivation; defaults to ``build/editor-vendor``).
//   * ``$REPO_ROOT`` — path to the isonim repo root (defaults to the
//                      parent directory of this script).

import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  readFileSync,
  statSync,
  writeFileSync,
  mkdirSync,
  existsSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot =
  process.env.REPO_ROOT && process.env.REPO_ROOT.length > 0
    ? resolve(process.env.REPO_ROOT)
    : resolve(__dirname, "..");
const outDir =
  process.env.OUT_DIR && process.env.OUT_DIR.length > 0
    ? resolve(process.env.OUT_DIR)
    : resolve(repoRoot, "build", "editor-vendor");

if (!existsSync(outDir)) {
  mkdirSync(outDir, { recursive: true });
}

const targets = [
  {
    entry: join(__dirname, "entry-tiptap.mjs"),
    outfile: join(outDir, "tiptap.umd.js"),
    label: "tiptap.umd.js",
  },
  {
    entry: join(__dirname, "entry-xterm.mjs"),
    outfile: join(outDir, "xterm.umd.js"),
    label: "xterm.umd.js",
  },
];

function sha256(path) {
  const h = createHash("sha256");
  h.update(readFileSync(path));
  return h.digest("hex");
}

function runEsbuild(entry, outfile) {
  const res = spawnSync(
    "esbuild",
    [
      entry,
      "--bundle",
      "--minify",
      "--format=iife",
      "--target=es2020",
      `--outfile=${outfile}`,
    ],
    {
      cwd: repoRoot,
      stdio: ["ignore", "inherit", "inherit"],
    },
  );
  if (res.status !== 0) {
    throw new Error(
      `esbuild failed for ${entry}: exit ${res.status} signal ${res.signal}`,
    );
  }
}

const summary = [];
for (const t of targets) {
  runEsbuild(t.entry, t.outfile);
  const info = statSync(t.outfile);
  summary.push({
    label: t.label,
    bytes: info.size,
    sha256: sha256(t.outfile),
  });
}

// xterm.js 5.3.0 ships its CSS as a separate stylesheet; bundling it
// into the IIFE would mean inlining the styles at runtime via
// ``document.head.appendChild`` which fights with the existing editor
// chrome.  Drop ``xterm.css`` next to the UMD so the editor's
// ``index.html`` can pick it up via a ``<link rel="stylesheet">`` tag.
const xtermCssSrc = join(repoRoot, "node_modules", "xterm", "css", "xterm.css");
if (existsSync(xtermCssSrc)) {
  const xtermCssDst = join(outDir, "xterm.css");
  copyFileSync(xtermCssSrc, xtermCssDst);
  const cssInfo = statSync(xtermCssDst);
  summary.push({
    label: "xterm.css",
    bytes: cssInfo.size,
    sha256: sha256(xtermCssDst),
  });
}

const yarnLockPath = join(repoRoot, "yarn.lock");
const yarnLockHash = existsSync(yarnLockPath)
  ? sha256(yarnLockPath)
  : "<missing>";

const lines = [
  "## TBAR-M5b — editor-vendor UMD bundles",
  "##",
  "## Produced by ``nix build .#editor-vendor`` against the pinned",
  "## yarn.lock + node_modules tree.  The Nim per-library FFI",
  "## modules (vendor/tiptap.nim, vendor/tiptap_starter_kit.nim,",
  "## vendor/tiptap_markdown.nim, vendor/xterm.nim) consume the",
  "## globals these bundles attach to globalThis.",
  "##",
  `## yarn.lock sha256: ${yarnLockHash}`,
  "##",
  "## Bundles (SHA-256):",
  "##",
];
for (const s of summary) {
  lines.push(`##   ${s.label}  ${s.sha256}  ${s.bytes} bytes`);
}
lines.push("");

const manifestPath = join(outDir, "MANIFEST.txt");
writeFileSync(manifestPath, lines.join("\n"));

console.log("[editor-vendor] wrote", manifestPath);
for (const s of summary) {
  console.log(`[editor-vendor] ${s.label}: ${s.bytes} bytes (${s.sha256})`);
}
