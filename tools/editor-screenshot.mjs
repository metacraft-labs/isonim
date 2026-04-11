#!/usr/bin/env node
// tools/editor-screenshot.mjs
//
// Builds the editor, serves it, takes screenshots at multiple viewports,
// and saves them to build/editor/screenshots/.
//
// Usage: node tools/editor-screenshot.mjs [--width 1920] [--height 1080]

import { execSync, spawn } from 'child_process';
import { mkdirSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, '..');
const editorDir = join(projectRoot, 'build', 'editor');
const screenshotDir = join(editorDir, 'screenshots');

// Parse args
const viewports = [
  { name: 'wide', width: 1920, height: 1080 },
  { name: 'medium', width: 1280, height: 800 },
  { name: 'narrow', width: 768, height: 1024 },
];

// Check for single custom viewport
for (let i = 2; i < process.argv.length; i++) {
  if (process.argv[i] === '--only') {
    const name = process.argv[++i];
    const v = viewports.find(v => v.name === name);
    if (v) {
      viewports.length = 0;
      viewports.push(v);
    }
  }
}

async function main() {
  // Step 1: Build
  console.log('==> Building editor...');
  // Find nim in Nix store
  let nimPath = 'nim';
  try {
    execSync('nim --version', { stdio: 'ignore' });
  } catch {
    nimPath = execSync('find /nix/store -maxdepth 3 -name nim \\( -type f -o -type l \\) ! -path "*bootstrap*" ! -path "*unwrapped*" 2>/dev/null | head -1', { encoding: 'utf8' }).trim();
    if (!nimPath) {
      console.error('nim not found');
      process.exit(1);
    }
  }
  execSync(`${nimPath} js --path:src --hints:off -o:build/editor/editor.js src/isonim/editor/main.nim`, {
    cwd: projectRoot,
    stdio: 'inherit',
  });
  execSync(`cp src/isonim/editor/index.html build/editor/index.html`, { cwd: projectRoot });

  // Step 2: Start server
  console.log('==> Starting server...');
  const server = spawn('python3', ['-m', 'http.server', '8091', '--bind', '127.0.0.1'], {
    cwd: editorDir,
    stdio: 'ignore',
    detached: true,
  });

  // Wait for server to be ready
  await new Promise(resolve => setTimeout(resolve, 1000));

  // Step 3: Take screenshots
  mkdirSync(screenshotDir, { recursive: true });

  console.log('==> Taking screenshots...');
  const { chromium } = await import('playwright');
  const browser = await chromium.launch({ headless: true });

  for (const vp of viewports) {
    const context = await browser.newContext({
      viewport: { width: vp.width, height: vp.height },
      deviceScaleFactor: 2,
    });
    const page = await context.newPage();
    await page.goto('http://127.0.0.1:8091/');
    await page.waitForTimeout(500); // Wait for render

    const path = join(screenshotDir, `editor-${vp.name}.png`);
    await page.screenshot({ path, fullPage: false });
    console.log(`    ${vp.name} (${vp.width}x${vp.height}): ${path}`);

    await context.close();
  }

  await browser.close();

  // Step 4: Stop server
  process.kill(-server.pid, 'SIGTERM');
  console.log('==> Done.');
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
