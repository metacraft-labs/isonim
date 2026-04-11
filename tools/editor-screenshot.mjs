#!/usr/bin/env node
// tools/editor-screenshot.mjs
//
// Captures screenshots from the IsoNim Editor at various viewports.
// Builds the editor, serves it, navigates to specific views, and captures.
//
// Usage:
//   node tools/editor-screenshot.mjs                    # all views, all sizes
//   node tools/editor-screenshot.mjs --view shell       # just the editor shell
//   node tools/editor-screenshot.mjs --size wide        # just wide viewport
//   node tools/editor-screenshot.mjs --view shell --size narrow
//   node tools/editor-screenshot.mjs --list             # list available views and sizes
//   node tools/editor-screenshot.mjs --no-build         # skip nim compilation
//
// Screenshots are saved to: build/editor/screenshots/<view>-<size>.png

import { execSync, spawn } from 'child_process';
import { mkdirSync, rmSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, '..');
const editorDir = join(projectRoot, 'build', 'editor');
const screenshotDir = join(editorDir, 'screenshots');

// ---------------------------------------------------------------------------
// Viewports
// ---------------------------------------------------------------------------

const sizes = {
  'wide':      { width: 1920, height: 1080 },
  'laptop':    { width: 1440, height: 900 },
  'medium':    { width: 1280, height: 800 },
  'tablet':    { width: 1024, height: 768 },
  'narrow':    { width: 768,  height: 1024 },
  'mobile':    { width: 375,  height: 812 },
};

// ---------------------------------------------------------------------------
// Views — each defines how to set up the page before capturing
// ---------------------------------------------------------------------------

const views = {
  'shell': {
    description: 'Editor shell — sidebar + preview + inspector (default state)',
    setup: async (page) => {
      // Default state — nothing to do
    },
  },
  'shell-story-selected': {
    description: 'Editor shell with a story selected in the sidebar',
    setup: async (page) => {
      // Click first story item to select it
      const items = await page.$$('[style*="cursor: pointer"]');
      if (items.length > 3) await items[3].click();
      await page.waitForTimeout(200);
    },
  },
  'sidebar-only': {
    description: 'Just the sidebar (cropped)',
    setup: async (page) => {},
    clip: { x: 0, y: 0, width: 280, height: 1080 },
  },
  'inspector-only': {
    description: 'Just the inspector panel (cropped)',
    setup: async (page) => {},
    clip: (vp) => ({ x: vp.width - 320, y: 0, width: 320, height: vp.height }),
  },
  'preview-only': {
    description: 'Just the preview pane (cropped)',
    setup: async (page) => {},
    clip: (vp) => ({ x: 280, y: 0, width: vp.width - 280 - 320, height: vp.height }),
  },
  'component-detail': {
    description: 'Component detail page — hero, variants, props, guidelines',
    initialUrl: 'http://127.0.0.1:8091/#component-detail',
    setup: async (page) => {},
  },
  'component-edit': {
    description: 'Component edit mode — live preview + CSS inspector',
    initialUrl: 'http://127.0.0.1:8091/#component-edit',
    setup: async (page) => {},
  },
  'vector-editor': {
    description: 'Vector graphics editor — tool palette, SVG canvas, properties',
    initialUrl: 'http://127.0.0.1:8091/#vector-editor',
    setup: async (page) => {},
  },
  'inspector-layout': {
    description: 'Inspector Layout section — display, flex, alignment controls',
    initialUrl: 'http://127.0.0.1:8091/#component-edit-layout',
    setup: async (page) => {},
  },
  'inspector-fill': {
    description: 'Inspector Fill section — color picker with 2D field, hue, swatches',
    initialUrl: 'http://127.0.0.1:8091/#component-edit-fill',
    setup: async (page) => {},
  },
  'inspector-effects': {
    description: 'Inspector Effects section — shadow editor, rotation dial, scale',
    initialUrl: 'http://127.0.0.1:8091/#component-edit-effects',
    setup: async (page) => {},
  },
  'inspector-stroke': {
    description: 'Inspector Stroke section — border, border-radius editor',
    initialUrl: 'http://127.0.0.1:8091/#component-edit-stroke',
    setup: async (page) => {},
  },
  'inspector-transitions': {
    description: 'Inspector Transitions section — bezier curve editor, duration',
    initialUrl: 'http://127.0.0.1:8091/#component-edit-transitions',
    setup: async (page) => {},
  },
};

// ---------------------------------------------------------------------------
// CLI parsing
// ---------------------------------------------------------------------------

let selectedViews = Object.keys(views);
let selectedSizes = Object.keys(sizes);
let skipBuild = false;
let isFiltered = false;  // true when --view or --size narrows the selection

for (let i = 2; i < process.argv.length; i++) {
  const arg = process.argv[i];
  if (arg === '--view' && process.argv[i + 1]) {
    selectedViews = [process.argv[++i]];
    isFiltered = true;
  } else if (arg === '--size' && process.argv[i + 1]) {
    selectedSizes = [process.argv[++i]];
    isFiltered = true;
  } else if (arg === '--no-build') {
    skipBuild = true;
  } else if (arg === '--list') {
    console.log('Views:');
    for (const [name, v] of Object.entries(views)) {
      console.log(`  ${name.padEnd(25)} ${v.description}`);
    }
    console.log('\nSizes:');
    for (const [name, s] of Object.entries(sizes)) {
      console.log(`  ${name.padEnd(10)} ${s.width}x${s.height}`);
    }
    process.exit(0);
  }
}

// Validate
for (const v of selectedViews) {
  if (!views[v]) { console.error(`Unknown view: ${v}`); process.exit(1); }
}
for (const s of selectedSizes) {
  if (!sizes[s]) { console.error(`Unknown size: ${s}`); process.exit(1); }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  // Step 1: Build
  if (!skipBuild) {
    console.log('==> Building editor...');
    let nimPath = 'nim';
    try { execSync('nim --version', { stdio: 'ignore' }); } catch {
      nimPath = execSync('find /nix/store -maxdepth 3 -name nim \\( -type f -o -type l \\) ! -path "*bootstrap*" ! -path "*unwrapped*" 2>/dev/null | head -1', { encoding: 'utf8' }).trim();
      if (!nimPath) { console.error('nim not found'); process.exit(1); }
    }
    mkdirSync(editorDir, { recursive: true });
    execSync(`${nimPath} js --path:src --hints:off -o:build/editor/editor.js src/isonim/editor/main.nim`, {
      cwd: projectRoot, stdio: 'pipe',
    });
    execSync(`cp src/isonim/editor/index.html build/editor/index.html`, { cwd: projectRoot });
    console.log('    Built.');
  }

  // Step 2: Start server
  console.log('==> Starting server...');
  const server = spawn('python3', ['-m', 'http.server', '8091', '--bind', '127.0.0.1'], {
    cwd: editorDir, stdio: 'ignore', detached: true,
  });
  await new Promise(resolve => setTimeout(resolve, 1000));

  // Step 3: Take screenshots
  // Clean output directory when regenerating all screenshots (no --view/--size filter)
  if (!isFiltered && existsSync(screenshotDir)) {
    console.log('==> Cleaning screenshot directory (full regeneration)...');
    rmSync(screenshotDir, { recursive: true });
  }
  mkdirSync(screenshotDir, { recursive: true });
  console.log('==> Capturing screenshots...');

  const { chromium } = await import('playwright');
  const browser = await chromium.launch({ headless: true });

  let count = 0;
  for (const viewName of selectedViews) {
    const view = views[viewName];
    for (const sizeName of selectedSizes) {
      const vp = sizes[sizeName];

      const context = await browser.newContext({
        viewport: { width: vp.width, height: vp.height },
        deviceScaleFactor: 2,
      });
      const page = await context.newPage();
      const url = view.initialUrl || 'http://127.0.0.1:8091/';
      await page.goto(url);
      await page.waitForTimeout(500);

      // Run view-specific setup
      await view.setup(page);
      await page.waitForTimeout(300);

      // Determine clip region
      let clip = undefined;
      if (view.clip) {
        clip = typeof view.clip === 'function' ? view.clip(vp) : view.clip;
      }

      const path = join(screenshotDir, `${viewName}-${sizeName}.png`);
      await page.screenshot({ path, clip });
      console.log(`    ${viewName}-${sizeName} (${vp.width}x${vp.height}): ${path}`);
      count++;

      await context.close();
    }
  }

  await browser.close();

  // Step 4: Stop server
  try { process.kill(-server.pid, 'SIGTERM'); } catch {}
  console.log(`==> Done. ${count} screenshots saved to build/editor/screenshots/`);
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
