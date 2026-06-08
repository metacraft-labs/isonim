#!/usr/bin/env node
// tailwind-extract.mjs
//
// Runs the real Tailwind CSS CLI against IsoNim source files, parses the
// generated CSS, and produces:
//   1. A CSS file for web targets (build/tailwind.css)
//   2. A JSON lookup table for native targets (build/tailwind-styles.json)
//
// The JSON maps class names to resolved CSS property/value pairs with all
// CSS variables resolved to concrete values.
//
// Usage: node tools/tailwind-extract.mjs [--input src/input.css] [--out-dir build]
//                                        [--content '<glob>' ...]
//
// `--content` (repeatable) adds explicit @source directives so consuming
// apps can drive the extract from their own repo. Tailwind v4's default
// auto-detection only scans the project root and recognized file types
// (no `.nim`), so callers from sibling repos MUST pass `--content` to
// have their source files scanned. Each pattern is emitted verbatim as
// a `@source "<pattern>";` line in a generated input CSS.

import { execSync } from 'child_process';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'fs';
import { join, dirname, resolve } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, '..');

// Parse args
let inputCss = null;
let outDir = join(projectRoot, 'build');
let contentPatterns = [];

for (let i = 2; i < process.argv.length; i++) {
  if (process.argv[i] === '--input' && process.argv[i + 1]) {
    inputCss = process.argv[++i];
  } else if (process.argv[i] === '--out-dir' && process.argv[i + 1]) {
    outDir = process.argv[++i];
  } else if (process.argv[i] === '--content' && process.argv[i + 1]) {
    contentPatterns.push(process.argv[++i]);
  }
}

mkdirSync(outDir, { recursive: true });

// If --content was passed but no --input, synthesize an input CSS file
// with explicit @source directives.  The generated CSS file MUST live
// inside isonim's tree so Node's module-resolution walk (used by
// Tailwind v4 to resolve `@import "tailwindcss"`) can find isonim's
// node_modules.  Writing it under the caller's out-dir would fail with
// `Error: Can't resolve 'tailwindcss'` when the caller's repo has no
// local node_modules.  Each pattern is resolved to an absolute path
// against the caller's cwd so repo-relative globs work.
if (contentPatterns.length > 0 && !inputCss) {
  const isonimBuild = join(projectRoot, 'build');
  mkdirSync(isonimBuild, { recursive: true });
  const generatedInput = join(isonimBuild, '_input.generated.css');
  const lines = ['@import "tailwindcss";'];
  for (const pat of contentPatterns) {
    const absPat = pat.startsWith('/') ? pat : resolve(process.cwd(), pat);
    lines.push(`@source "${absPat}";`);
  }
  writeFileSync(generatedInput, lines.join('\n') + '\n');
  inputCss = generatedInput;
}

// ---------------------------------------------------------------------------
// Step 1: Run Tailwind CSS CLI
// ---------------------------------------------------------------------------

const cssOutPath = join(outDir, 'tailwind.css');

// Tailwind v4 auto-detects content from the project. We can also pass
// explicit content via a temporary input CSS file.
let tailwindCmd;
if (inputCss) {
  tailwindCmd = `npx tailwindcss -i "${inputCss}" -o "${cssOutPath}" --minify 2>&1`;
} else {
  // v4 auto-scans. Just run with output.
  tailwindCmd = `npx tailwindcss -o "${cssOutPath}" 2>&1`;
}

console.log('==> Running Tailwind CSS...');
try {
  const output = execSync(tailwindCmd, { cwd: projectRoot, encoding: 'utf8' });
  if (output.includes('Done in')) {
    console.log('    ' + output.trim().split('\n').pop());
  }
} catch (e) {
  console.error('Tailwind CSS failed:', e.message);
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Step 2: Parse the CSS output into a class→styles map
// ---------------------------------------------------------------------------

console.log('==> Parsing CSS into style map...');

const css = readFileSync(cssOutPath, 'utf8');

// Extract CSS custom properties (variables) from :root / :host
const cssVars = {};

// Match :root or :host blocks and extract --var: value pairs
const rootBlockRe = /:(?:root|host)\s*\{([^}]+)\}/g;
let rootMatch;
while ((rootMatch = rootBlockRe.exec(css)) !== null) {
  const block = rootMatch[1];
  const varRe = /(--[\w-]+)\s*:\s*([^;]+)/g;
  let varMatch;
  while ((varMatch = varRe.exec(block)) !== null) {
    cssVars[varMatch[1].trim()] = varMatch[2].trim();
  }
}

// Resolve var() references recursively
function resolveVar(value, depth = 0) {
  if (depth > 10) return value; // prevent infinite loops
  return value.replace(/var\((--[\w-]+)(?:\s*,\s*([^)]+))?\)/g, (_, varName, fallback) => {
    if (cssVars[varName] !== undefined) {
      return resolveVar(cssVars[varName], depth + 1);
    }
    if (fallback) {
      return resolveVar(fallback.trim(), depth + 1);
    }
    return `var(${varName})`;
  });
}

// Resolve calc() with simple multiplications: calc(X * N) where X is a known value
function resolveCalc(value) {
  return value.replace(/calc\(([^)]+)\)/g, (_, expr) => {
    // Handle: calc(0.25rem * N) or calc(var-resolved * N)
    const mulMatch = expr.match(/^([\d.]+)(rem|px|em)?\s*\*\s*([\d.]+)$/);
    if (mulMatch) {
      const a = parseFloat(mulMatch[1]);
      const unit = mulMatch[2] || '';
      const b = parseFloat(mulMatch[3]);
      return `${a * b}${unit}`;
    }
    // Handle: calc(N * 0.25rem)
    const mulMatch2 = expr.match(/^([\d.]+)\s*\*\s*([\d.]+)(rem|px|em)?$/);
    if (mulMatch2) {
      const a = parseFloat(mulMatch2[1]);
      const b = parseFloat(mulMatch2[2]);
      const unit = mulMatch2[3] || '';
      return `${a * b}${unit}`;
    }
    // Handle: infinity * 1px
    if (expr.includes('infinity')) {
      return '9999px';
    }
    return `calc(${expr})`;
  });
}

// Convert rem to px (1rem = 16px default)
function remToPx(value) {
  return value.replace(/([\d.]+)rem/g, (_, n) => {
    return `${Math.round(parseFloat(n) * 16)}px`;
  });
}

// Convert oklch() to hex (approximate conversion for common Tailwind colors)
function oklchToHex(value) {
  return value.replace(/oklch\(([^)]+)\)/g, (match, args) => {
    try {
      const parts = args.trim().split(/\s+/);
      const L = parseFloat(parts[0].replace('%', '')) / 100;
      const C = parseFloat(parts[1]);
      const H = parseFloat(parts[2]) || 0;

      // OKLCH → OKLab
      const a = C * Math.cos(H * Math.PI / 180);
      const b = C * Math.sin(H * Math.PI / 180);

      // OKLab → linear sRGB (approximate)
      const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
      const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
      const s_ = L - 0.0894841775 * a - 1.2914855480 * b;

      const l3 = l_ * l_ * l_;
      const m3 = m_ * m_ * m_;
      const s3 = s_ * s_ * s_;

      let r = +4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3;
      let g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3;
      let bl = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3;

      // Gamma correction
      const gamma = (x) => x <= 0.0031308 ? 12.92 * x : 1.055 * Math.pow(x, 1/2.4) - 0.055;
      r = Math.round(Math.max(0, Math.min(1, gamma(r))) * 255);
      g = Math.round(Math.max(0, Math.min(1, gamma(g))) * 255);
      bl = Math.round(Math.max(0, Math.min(1, gamma(bl))) * 255);

      return '#' + [r, g, bl].map(c => c.toString(16).padStart(2, '0')).join('').toUpperCase();
    } catch {
      return match; // return original if conversion fails
    }
  });
}

// Full resolution pipeline
function resolveValue(value) {
  let v = resolveVar(value);
  v = resolveCalc(v);
  v = oklchToHex(v);
  v = remToPx(v);
  // Strip px suffix for numeric values (native platforms use raw numbers)
  v = v.replace(/^([\d.]+)px$/, '$1');
  return v;
}

// Parse utility rules from @layer utilities
const styleMap = {};

// Match .classname { declarations } — handles both minified and formatted CSS
const ruleRe = /\.([\w-]+(?:\\:[\w-]+)*)\s*\{([^}]+)\}/g;
let ruleMatch;

while ((ruleMatch = ruleRe.exec(css)) !== null) {
  const className = ruleMatch[1].replace(/\\/g, ''); // unescape
  const declarations = ruleMatch[2];

  const props = {};
  const declRe = /([\w-]+)\s*:\s*([^;]+)/g;
  let declMatch;
  while ((declMatch = declRe.exec(declarations)) !== null) {
    const prop = declMatch[1].trim();
    let val = declMatch[2].trim();

    // Skip CSS custom property declarations (--tw-*)
    if (prop.startsWith('--tw-')) continue;
    // Resolve and skip properties with unresolvable vars
    val = resolveValue(val);
    if (val.includes('var(')) continue;

    props[prop] = val;
  }

  if (Object.keys(props).length > 0) {
    styleMap[className] = props;
  }
}

// Also handle Tailwind v4 padding-inline/padding-block → padding-left/right/top/bottom
for (const [cls, props] of Object.entries(styleMap)) {
  if (props['padding-inline']) {
    props['padding-left'] = props['padding-inline'];
    props['padding-right'] = props['padding-inline'];
    delete props['padding-inline'];
  }
  if (props['padding-block']) {
    props['padding-top'] = props['padding-block'];
    props['padding-bottom'] = props['padding-block'];
    delete props['padding-block'];
  }
  if (props['margin-inline']) {
    props['margin-left'] = props['margin-inline'];
    props['margin-right'] = props['margin-inline'];
    delete props['margin-inline'];
  }
  if (props['margin-block']) {
    props['margin-top'] = props['margin-block'];
    props['margin-bottom'] = props['margin-block'];
    delete props['margin-block'];
  }
}

// ---------------------------------------------------------------------------
// Step 3: Write outputs
// ---------------------------------------------------------------------------

const jsonPath = join(outDir, 'tailwind-styles.json');
writeFileSync(jsonPath, JSON.stringify(styleMap, null, 2));

console.log(`==> Generated: ${cssOutPath} (${(readFileSync(cssOutPath).length / 1024).toFixed(1)}KB CSS)`);
console.log(`==> Generated: ${jsonPath} (${Object.keys(styleMap).length} classes)`);

// Print sample
const sample = Object.keys(styleMap).slice(0, 5);
for (const cls of sample) {
  console.log(`    .${cls} → ${JSON.stringify(styleMap[cls])}`);
}
console.log(`    ... and ${Object.keys(styleMap).length - sample.length} more`);
