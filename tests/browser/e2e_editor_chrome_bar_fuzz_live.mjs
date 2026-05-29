// Property-based fuzz test for the chrome bar's clickable controls.
//
// Why this exists: a user reported that "after repeatedly clicking on the
// buttons in the top chrome bar, they sometimes stop working (or their
// active state stops being properly displayed)". This file drives the
// real editor bundle in headless Chromium, picks chrome-bar controls at
// random from a seeded PRNG, clicks them, and verifies a set of
// invariants after every click. Any invariant break captures the seed +
// click sequence so the failure is deterministic to reproduce.
//
// Seed policy
//   * Default: ``FUZZ_SEED`` env override (any integer string), else a
//     fresh ``Date.now()``.  The chosen seed is logged at the start of
//     every test run so CI failures carry the reproduction recipe.
//   * Iterations: ``FUZZ_ITERATIONS`` env override (any integer string).
//     Default 200 — high enough to exercise rebuild paths (the viewport
//     strip rebuilds on backend change, the right sidebar swaps between
//     Inspector and AI Assistant on Mode-edit transitions) without
//     blowing past a reasonable test budget. Verified clean at
//     iterations=2000 (seed=2026) and at 200/300-iteration sweeps
//     across {7,13,31,42,67,89,101,200,1000,12345,31337,99999}.
//
// CSS transitions are turned off by the harness so the invariant check
// reads the post-click final-state computed background without racing
// the chrome-bar pills' 120ms ``transition: background-color`` ease-out.
// (Without this, the t=0+ in-flight transition value for a transparent→
// indigo flip reads as ``rgba(0,0,0,0)``, which would be a false-positive
// invariant break.) The story selector is also clicked once on mount so
// the Mode cluster's View / Comment / Edit pills come out of the
// no-story disabled gate and the fuzz pool exercises the full triplet
// rather than just Spec.
//
// Invariants per click (asserted on the current chrome-bar DOM):
//   1. The chrome bar still has exactly one Backend cluster, one
//      Viewport cluster, one Mode cluster, one history trough, one
//      left-sidebar bookend, and one right-sidebar bookend.
//   2. Within each cluster (Backend / Viewport / Mode) at most one
//      pill carries ``aria-pressed="true"`` (the viewport strip can
//      have zero when the active viewport sits in the overflow
//      dropdown).
//   3. Each pill's ``aria-pressed`` agrees with its ``data-active``.
//   4. The history pill's ``aria-pressed`` agrees with its
//      ``data-gallery-open``.
//   5. The viewport overflow chevron's ``aria-expanded`` agrees with
//      the dropdown's computed ``display`` (open ↔ ``block``).
//
// Invariant 1 catches a chrome-bar that lost a cluster wrapper to an
// errant ``clearChildren`` or a swap that detached the wrong subtree.
// Invariants 2-5 catch state-binding drift — the ``setAttribute("style",
// ...)`` reactive effects in ``choice_group.nim`` and
// ``preview_chrome.nim`` are write-through, so any divergence between
// ``aria-pressed`` and ``data-active`` means a reactive effect
// either didn't fire or fired against a stale node.
//
// Convention: ``node --test`` (not ``npx playwright test``) — matches
// the rest of ``isonim/tests/browser/e2e_*.mjs``.

import { execSync, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";

const __dirname = dirname(fileURLToPath(import.meta.url));
const isonimRoot = join(__dirname, "..", "..");
const isonimExamplesRoot = join(isonimRoot, "..", "isonim-examples");
const editorBuildDir = join(isonimExamplesRoot, "build", "editor");

const PAGE_PORT = 18671;
let pageServer = null;
let chromium = null;
let browser = null;

function exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

function buildEditor() {
  exec("direnv exec . just editor-build", { cwd: isonimExamplesRoot });
  if (!existsSync(join(editorBuildDir, "editor.js"))) {
    throw new Error("editor.js was not produced by `just editor-build`");
  }
  if (!existsSync(join(editorBuildDir, "index.html"))) {
    throw new Error("index.html was not produced by `just editor-build`");
  }
}

function startPageServer() {
  pageServer = spawn(
    "python3",
    ["-m", "http.server", String(PAGE_PORT), "--bind", "127.0.0.1"],
    { cwd: editorBuildDir, stdio: "ignore", detached: true },
  );
  for (let i = 0; i < 60; i++) {
    try {
      execSync(
        `curl -s -o /dev/null --max-time 0.5 ` +
          `http://127.0.0.1:${PAGE_PORT}/index.html`,
        { stdio: "pipe" },
      );
      return;
    } catch {
      execSync("sleep 0.2");
    }
  }
  throw new Error("static server failed to bind on " + PAGE_PORT);
}

async function ensureBrowser() {
  if (!chromium) {
    const m = await import("playwright");
    chromium = m.chromium;
  }
  if (!browser) browser = await chromium.launch({ headless: true });
  return browser;
}

async function openEditor() {
  const b = await ensureBrowser();
  const ctx = await b.newContext({
    viewport: { width: 1440, height: 900 },
  });
  const page = await ctx.newPage();
  await page.goto(`http://127.0.0.1:${PAGE_PORT}/index.html`);
  await page.waitForSelector('[data-preview-chrome-bar="true"]', {
    timeout: 15000,
  });
  // Wait until the three cluster wrappers are present + their pills are
  // mounted. The chrome bar mounts the wrappers synchronously but the
  // pills land via the ``ui:`` DSL on the same tick, so a single
  // wait-for-selector on a pill is enough.
  await page.waitForSelector(
    '[data-toolbar-cluster="backend"] [data-choice-group-pill]',
    { timeout: 15000 },
  );
  await page.waitForSelector(
    '[data-toolbar-cluster="mode"] [data-choice-group-pill]',
    { timeout: 15000 },
  );
  // Disable CSS transitions + animations everywhere so the invariant
  // check can read the post-click computed background without racing
  // the 120ms ``transition: background-color`` ease-out the chrome-bar
  // pills declare. Without this the fuzz test would routinely catch
  // mid-transition computed colours and flag them as bugs that aren't
  // real.
  await page.addStyleTag({
    content:
      "*, *::before, *::after { transition: none !important;" +
      " animation: none !important; }",
  });
  // Select the first available sidebar story so the Mode cluster's
  // View / Comment / Edit pills come out of their no-story disabled
  // state. Without a selection the cluster only carries Spec as a
  // clickable target — the fuzz pool would never exercise the
  // disabled→enabled→selected mode-pill paths. Best-effort: when no
  // story row is present (e.g. an empty fixture) the fuzzer falls back
  // to the Spec-only Mode cluster.
  await page.evaluate(() => {
    const row = document.querySelector("[data-story-row]");
    if (row) row.click();
  });
  // Give the mode-driven sidebar swap + downstream effects a tick to
  // settle before the fuzz pool is sampled.
  await page.evaluate(() => new Promise((res) => setTimeout(res, 50)));
  return { ctx, page };
}

test.before(async () => {
  buildEditor();
  startPageServer();
});

test.after(async () => {
  try {
    if (browser) await browser.close();
  } catch {}
  try {
    if (pageServer) process.kill(-pageServer.pid);
  } catch {}
});

// Tiny seeded PRNG so a failure deterministically reproduces from the
// logged seed. Mulberry32 — small, fast, well-distributed for the
// modest amount of randomness we need (a few thousand draws per run).
function makeRng(seed) {
  let s = seed >>> 0;
  return function next() {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function randInt(rng, n) {
  return Math.floor(rng() * n);
}

// Read the full population of clickable chrome-bar targets out of the
// live DOM. Returns a list of records with a fully-qualified selector
// so we can re-resolve the element by index after each click (the DOM
// can rebuild — the viewport strip explicitly does on backend change).
async function readChromePool(page) {
  return await page.evaluate(() => {
    function out(kind, selector, extra) {
      return Object.assign({ kind, selector }, extra || {});
    }
    const bar = document.querySelector('[data-preview-chrome-bar="true"]');
    if (!bar) return null;
    const pool = [];

    // Left + right sidebar bookends — pulled by aria-label since they
    // share the chrome-bar host with the cluster wrappers and don't
    // carry a dedicated data-* selector.
    const left = bar.querySelector('[aria-label="Toggle left sidebar"]');
    if (left)
      pool.push(
        out(
          "left-toggle",
          '[data-preview-chrome-bar="true"] [aria-label="Toggle left sidebar"]',
        ),
      );
    const right = bar.querySelector('[aria-label="Toggle right sidebar"]');
    if (right)
      pool.push(
        out(
          "right-toggle",
          '[data-preview-chrome-bar="true"] [aria-label="Toggle right sidebar"]',
        ),
      );

    // History pill.
    const history = bar.querySelector(
      '[data-preview-chrome-history-button="true"]',
    );
    if (history)
      pool.push(
        out(
          "history",
          '[data-preview-chrome-bar="true"] ' +
            '[data-preview-chrome-history-button="true"]',
        ),
      );

    // Backend pills.
    const backendPills = bar.querySelectorAll(
      '[data-toolbar-cluster="backend"] [data-choice-group-pill]',
    );
    backendPills.forEach((p) => {
      const idx = p.getAttribute("data-choice-group-pill");
      const disabled = p.getAttribute("aria-disabled") === "true";
      if (disabled) return;
      pool.push(
        out(
          "backend-pill",
          `[data-preview-chrome-bar="true"] [data-toolbar-cluster="backend"] ` +
            `[data-choice-group-pill="${idx}"]`,
          { index: idx },
        ),
      );
    });

    // Viewport pills (in the segmented strip).
    const viewportPills = bar.querySelectorAll(
      '[data-toolbar-cluster="viewport"] ' +
        '[data-preview-viewport-strip-host="true"] ' +
        "[data-choice-group-pill]",
    );
    viewportPills.forEach((p) => {
      const idx = p.getAttribute("data-choice-group-pill");
      const disabled = p.getAttribute("aria-disabled") === "true";
      if (disabled) return;
      pool.push(
        out(
          "viewport-pill",
          `[data-preview-chrome-bar="true"] [data-toolbar-cluster="viewport"] ` +
            `[data-preview-viewport-strip-host="true"] ` +
            `[data-choice-group-pill="${idx}"]`,
          { index: idx },
        ),
      );
    });

    // Viewport overflow chevron.
    const chevron = bar.querySelector(
      '[data-preview-viewport-overflow="true"]',
    );
    if (chevron)
      pool.push(
        out(
          "viewport-chevron",
          '[data-preview-chrome-bar="true"] ' +
            '[data-preview-viewport-overflow="true"]',
        ),
      );

    // Viewport dropdown options — pool them when the dropdown is open
    // so the fuzzer can occasionally click into an overflow viewport.
    const dropdown = bar.querySelector(
      '[data-preview-viewport-dropdown="true"]',
    );
    if (dropdown && getComputedStyle(dropdown).display !== "none") {
      const opts = dropdown.querySelectorAll(
        "[data-preview-viewport-dropdown-option]",
      );
      opts.forEach((o) => {
        const slug = o.getAttribute("data-preview-viewport-dropdown-option");
        pool.push(
          out(
            "viewport-dropdown-option",
            `[data-preview-chrome-bar="true"] ` +
              `[data-preview-viewport-dropdown="true"] ` +
              `[data-preview-viewport-dropdown-option="${slug}"]`,
            { slug },
          ),
        );
      });
    }

    // Mode pills.
    const modePills = bar.querySelectorAll(
      '[data-toolbar-cluster="mode"] [data-choice-group-pill]',
    );
    modePills.forEach((p) => {
      const idx = p.getAttribute("data-choice-group-pill");
      const disabled = p.getAttribute("aria-disabled") === "true";
      if (disabled) return;
      pool.push(
        out(
          "mode-pill",
          `[data-preview-chrome-bar="true"] [data-toolbar-cluster="mode"] ` +
            `[data-choice-group-pill="${idx}"]`,
          { index: idx },
        ),
      );
    });

    return pool;
  });
}

// Invariants check — returns null when everything is consistent, or
// an object { reason, details } describing the first invariant break.
async function checkInvariants(page) {
  return await page.evaluate(() => {
    const bar = document.querySelector('[data-preview-chrome-bar="true"]');
    if (!bar) return { reason: "chrome-bar disappeared" };

    // (1) Cluster wrappers + bookends still present.
    const need = [
      ['[data-toolbar-cluster="backend"]', "Backend cluster"],
      ['[data-toolbar-cluster="viewport"]', "Viewport cluster"],
      ['[data-toolbar-cluster="mode"]', "Mode cluster"],
      ['[data-toolbar-cluster="history"]', "History trough"],
      ['[aria-label="Toggle left sidebar"]', "Left sidebar toggle"],
      ['[aria-label="Toggle right sidebar"]', "Right sidebar toggle"],
    ];
    for (const [sel, name] of need) {
      const found = bar.querySelectorAll(sel);
      if (found.length !== 1) {
        return {
          reason: `expected exactly 1 ${name}, found ${found.length}`,
          selector: sel,
        };
      }
    }

    function countActivePills(cluster, requireHostFilter) {
      const sel = requireHostFilter
        ? `[data-toolbar-cluster="${cluster}"] ` +
          `[data-preview-viewport-strip-host="true"] [data-choice-group-pill]`
        : `[data-toolbar-cluster="${cluster}"] [data-choice-group-pill]`;
      const pills = bar.querySelectorAll(sel);
      let activeCount = 0;
      let mismatchCount = 0;
      const stamps = [];
      pills.forEach((p) => {
        const pressed = p.getAttribute("aria-pressed");
        const active = p.getAttribute("data-active");
        const idx = p.getAttribute("data-choice-group-pill");
        stamps.push(`${idx}:p=${pressed}/a=${active}`);
        if (pressed === "true") activeCount++;
        // data-active should mirror aria-pressed.
        if ((pressed === "true") !== (active === "true")) {
          mismatchCount++;
        }
      });
      return { pills: pills.length, activeCount, mismatchCount, stamps };
    }

    // (2) Backend / Viewport / Mode invariants.
    // Backend + Mode are exhaustive (always exactly one active pill).
    // Viewport may have zero active pills when the active viewport sits
    // in the overflow dropdown.
    const backend = countActivePills("backend", false);
    if (backend.pills < 1) {
      return { reason: "backend cluster has no pills" };
    }
    if (backend.activeCount > 1) {
      return {
        reason: "backend cluster has more than one active pill",
        details: backend.stamps.join(","),
      };
    }
    if (backend.mismatchCount > 0) {
      return {
        reason: "backend cluster: aria-pressed != data-active on a pill",
        details: backend.stamps.join(","),
      };
    }

    const mode = countActivePills("mode", false);
    if (mode.pills < 1) {
      return { reason: "mode cluster has no pills" };
    }
    if (mode.activeCount > 1) {
      return {
        reason: "mode cluster has more than one active pill",
        details: mode.stamps.join(","),
      };
    }
    if (mode.mismatchCount > 0) {
      return {
        reason: "mode cluster: aria-pressed != data-active on a pill",
        details: mode.stamps.join(","),
      };
    }

    const viewport = countActivePills("viewport", true);
    if (viewport.activeCount > 1) {
      return {
        reason: "viewport strip has more than one active pill",
        details: viewport.stamps.join(","),
      };
    }
    if (viewport.mismatchCount > 0) {
      return {
        reason: "viewport strip: aria-pressed != data-active on a pill",
        details: viewport.stamps.join(","),
      };
    }

    // (3) History pill: aria-pressed mirrors data-gallery-open.
    const history = bar.querySelector(
      '[data-preview-chrome-history-button="true"]',
    );
    if (history) {
      const pressed = history.getAttribute("aria-pressed");
      const gallery = history.getAttribute("data-gallery-open");
      if (pressed !== gallery) {
        return {
          reason: "history pill: aria-pressed != data-gallery-open",
          details: `pressed=${pressed} gallery=${gallery}`,
        };
      }
      // Visual coherency — the user-reported failure mode is "active
      // state stops being properly displayed". Verify the COMPUTED
      // background colour agrees with the active/inactive treatment.
      // Active = indigo accent rgb(124, 122, 237); inactive = transparent
      // (rgba(0,0,0,0)).
      const cs = getComputedStyle(history);
      const bg = cs.backgroundColor;
      const isActiveBg = bg === "rgb(124, 122, 237)";
      const isInactiveBg = bg === "rgba(0, 0, 0, 0)" || bg === "transparent";
      const expectActive = pressed === "true";
      if (expectActive && !isActiveBg) {
        return {
          reason:
            "history pill: aria-pressed=true but background-color is not accent",
          details: `bg=${bg}`,
        };
      }
      if (!expectActive && !isInactiveBg) {
        return {
          reason:
            "history pill: aria-pressed=false but background-color is not transparent",
          details: `bg=${bg}`,
        };
      }
    }

    // (3b) Cluster pill computed-style coherence. For every Backend /
    // Mode pill (and Viewport strip pill) check that the computed
    // background colour agrees with aria-pressed. This guards against
    // the case where two reactive effects both wrote the ``style``
    // attribute and the last write happened to be the inactive
    // treatment over an active pill (or vice-versa).
    function pillBgOk(p) {
      const pressed = p.getAttribute("aria-pressed");
      const disabled = p.getAttribute("aria-disabled") === "true";
      if (disabled) return null; // skip disabled pills
      const bg = getComputedStyle(p).backgroundColor;
      const isActiveBg = bg === "rgb(124, 122, 237)";
      const isInactiveBg = bg === "rgba(0, 0, 0, 0)" || bg === "transparent";
      const inlineStyle = p.getAttribute("style") || "";
      // Excerpt the bg-color declaration from the inline style for
      // diagnostic clarity in the failure log.
      const bgDecl = (inlineStyle.match(/background-color:\s*[^;]+/) || [
        "(none)",
      ])[0];
      if (pressed === "true" && !isActiveBg) {
        return `pressed=true computedBg=${bg} inlineBg=${bgDecl}`;
      }
      if (pressed === "false" && !isInactiveBg) {
        return `pressed=false computedBg=${bg} inlineBg=${bgDecl}`;
      }
      return null;
    }
    for (const cluster of ["backend", "mode"]) {
      const pills = bar.querySelectorAll(
        `[data-toolbar-cluster="${cluster}"] [data-choice-group-pill]`,
      );
      for (const p of pills) {
        const bad = pillBgOk(p);
        if (bad) {
          return {
            reason: `${cluster} pill: background-color disagrees with aria-pressed`,
            details: `idx=${p.getAttribute("data-choice-group-pill")} ${bad}`,
          };
        }
      }
    }
    {
      const vpPills = bar.querySelectorAll(
        '[data-toolbar-cluster="viewport"] ' +
          '[data-preview-viewport-strip-host="true"] [data-choice-group-pill]',
      );
      for (const p of vpPills) {
        const bad = pillBgOk(p);
        if (bad) {
          return {
            reason:
              "viewport strip pill: background-color disagrees with aria-pressed",
            details: `idx=${p.getAttribute("data-choice-group-pill")} ${bad}`,
          };
        }
      }
    }

    // (4) Viewport overflow chevron + dropdown coherency.
    const chevron = bar.querySelector(
      '[data-preview-viewport-overflow="true"]',
    );
    const dropdown = bar.querySelector(
      '[data-preview-viewport-dropdown="true"]',
    );
    if (chevron && dropdown) {
      const expanded = chevron.getAttribute("aria-expanded");
      const display = getComputedStyle(dropdown).display;
      const isOpenAria = expanded === "true";
      const isOpenDisplay = display !== "none";
      if (isOpenAria !== isOpenDisplay) {
        return {
          reason:
            "viewport overflow: aria-expanded != dropdown computed display",
          details: `expanded=${expanded} display=${display}`,
        };
      }
    }

    return null;
  });
}

// Resolve a target by its full selector. We re-query each time so a
// rebuild doesn't leave the test holding a detached ElementHandle.
async function clickTarget(page, target) {
  const result = await page.evaluate((sel) => {
    const el = document.querySelector(sel);
    if (!el) return { ok: false, reason: "element not found" };
    // Use the DOM-level ``.click()`` rather than the Playwright pointer
    // path: we want a real click event to dispatch to the
    // ``addEventListener("click", ...)`` handler the chrome bar
    // installs. Pointer-coords clicks would risk hitting overlay
    // chrome (the AIVS-NSO overlay) or scrollbars.
    el.click();
    return { ok: true };
  }, target.selector);
  if (!result.ok) {
    return { ok: false, reason: result.reason };
  }
  // Let reactive effects flush. The reactive graph is synchronous, so
  // the next microtask is enough; setTimeout(0) gives the JS runtime a
  // chance to drain rAF if any of the chrome handlers schedule one.
  await page.evaluate(() => new Promise((res) => setTimeout(res, 0)));
  return { ok: true };
}

async function captureFailureArtifacts(page, seed, trace, info) {
  // Best-effort artifact dump. We do NOT throw from this helper — the
  // caller is already on the failure path and we don't want to mask
  // the original assertion.
  try {
    const screenshotPath = join(
      __dirname,
      `chrome_bar_fuzz_FAIL_seed${seed}.png`,
    );
    await page.screenshot({ path: screenshotPath, fullPage: false });
    console.error("[fuzz] saved screenshot:", screenshotPath);
  } catch (e) {
    console.error("[fuzz] screenshot capture failed:", e.message);
  }
  // Dump the chrome bar's mode + backend pill internals — useful for
  // understanding which reactive effect last won the race.
  try {
    const dump = await page.evaluate(() => {
      const bar = document.querySelector('[data-preview-chrome-bar="true"]');
      if (!bar) return { error: "no chrome bar" };
      function snap(cluster) {
        const sel =
          cluster === "viewport"
            ? `[data-toolbar-cluster="${cluster}"] [data-preview-viewport-strip-host="true"] [data-choice-group-pill]`
            : `[data-toolbar-cluster="${cluster}"] [data-choice-group-pill]`;
        const pills = bar.querySelectorAll(sel);
        const out = [];
        pills.forEach((p) => {
          const cs = getComputedStyle(p);
          out.push({
            idx: p.getAttribute("data-choice-group-pill"),
            ariaPressed: p.getAttribute("aria-pressed"),
            dataActive: p.getAttribute("data-active"),
            ariaDisabled: p.getAttribute("aria-disabled"),
            inlineStyle: p.getAttribute("style"),
            computedBg: cs.backgroundColor,
            computedColor: cs.color,
            computedBorder: cs.borderColor,
            childCount: p.childNodes.length,
            firstChildTag: p.firstChild && p.firstChild.nodeName,
            firstChildHasInner:
              p.firstChild &&
              p.firstChild.innerHTML &&
              p.firstChild.innerHTML.length > 0,
          });
        });
        return out;
      }
      return {
        backend: snap("backend"),
        viewport: snap("viewport"),
        mode: snap("mode"),
      };
    });
    console.error("[fuzz] cluster dump:", JSON.stringify(dump, null, 2));
  } catch (e) {
    console.error("[fuzz] dump failed:", e.message);
  }
  console.error("[fuzz] seed:", seed);
  console.error("[fuzz] trace (last 60 steps):");
  const tail = trace.slice(Math.max(0, trace.length - 60));
  for (const step of tail) {
    console.error("  ", JSON.stringify(step));
  }
  console.error("[fuzz] invariant break:", JSON.stringify(info));
}

async function fuzzRound(page, seed, iterations) {
  const rng = makeRng(seed);
  const trace = [];

  // Initial sanity check before any clicks.
  const initial = await checkInvariants(page);
  if (initial) {
    await captureFailureArtifacts(page, seed, trace, initial);
    throw new Error(
      `chrome-bar invariant broken on initial mount: ${initial.reason}`,
    );
  }

  for (let i = 0; i < iterations; i++) {
    const pool = await readChromePool(page);
    if (!pool || pool.length === 0) {
      await captureFailureArtifacts(page, seed, trace, {
        reason: "no clickable chrome-bar targets — bar rebuilt empty?",
      });
      throw new Error("chrome-bar exposes no clickable targets");
    }

    // Stress patterns: every 25th iteration, fire 10 rapid clicks on
    // the same picked target. Every 25th iteration offset by 12, do an
    // alternate-clicks loop between two distinct targets. The fixed
    // offsets keep the stress fully deterministic against the seed.
    const stressKind =
      i % 25 === 0 ? "rapid-fire" : i % 25 === 12 ? "alternate" : "single";

    if (stressKind === "rapid-fire") {
      const t = pool[randInt(rng, pool.length)];
      for (let k = 0; k < 10; k++) {
        const clk = await clickTarget(page, t);
        trace.push({
          i,
          k,
          kind: t.kind,
          selector: t.selector,
          stress: "rapid",
        });
        if (!clk.ok) break; // detached after rebuild; move on
      }
    } else if (stressKind === "alternate" && pool.length >= 2) {
      const a = pool[randInt(rng, pool.length)];
      let b = pool[randInt(rng, pool.length)];
      // Try a few times to pick a distinct second target. Don't loop
      // forever: when the pool collapses to one effective target the
      // alternation degrades to a rapid-fire which is also acceptable.
      let tries = 0;
      while (b.selector === a.selector && tries < 5) {
        b = pool[randInt(rng, pool.length)];
        tries++;
      }
      for (let k = 0; k < 8; k++) {
        const t = k % 2 === 0 ? a : b;
        const clk = await clickTarget(page, t);
        trace.push({
          i,
          k,
          kind: t.kind,
          selector: t.selector,
          stress: "alternate",
        });
        if (!clk.ok) break;
      }
    } else {
      const t = pool[randInt(rng, pool.length)];
      const clk = await clickTarget(page, t);
      trace.push({ i, kind: t.kind, selector: t.selector, stress: "single" });
      if (!clk.ok) {
        // Selector went stale (rebuild swapped DOM). Skip the
        // invariant check for this iteration; the next iteration's
        // pool read will pick up the new DOM.
        continue;
      }
    }

    const broken = await checkInvariants(page);
    if (broken) {
      await captureFailureArtifacts(page, seed, trace, broken);
      throw new Error(
        `chrome-bar invariant broken at iteration ${i} ` +
          `(seed=${seed}): ${broken.reason}` +
          (broken.details ? ` — ${broken.details}` : ""),
      );
    }
  }
}

test("chrome bar survives 200 randomised clicks under property invariants", async () => {
  const seed = Number(process.env.FUZZ_SEED) || Date.now() & 0xffffffff;
  const iterations = Number(process.env.FUZZ_ITERATIONS) || 200;
  console.log(
    `[fuzz] seed=${seed} iterations=${iterations} ` +
      `(reproduce with FUZZ_SEED=${seed})`,
  );
  const { ctx, page } = await openEditor();
  try {
    await fuzzRound(page, seed, iterations);
  } finally {
    await ctx.close();
  }
});

// User-reported repro (2026-05-29): "click iPhone + 2 viewport pill clicks
// → buttons stop responding / active state not displayed". Root cause:
// the viewport-strip rebuild effect in shell.nim read viewport.val tracked,
// so every viewport click re-ran the rebuild effect, whose cleanNode
// disposed the inner choice_group createRenderEffect that drives pill
// aria-pressed + styles. Click handlers (live on the DOM) still fired and
// mutated the VM, but no live subscriber repainted the pills → the user
// perceived the pills as stuck. Fix: split into two effects — one that
// re-runs only on backend change (and creates the strip), one that
// re-runs on viewport change (and only calls activate, never mounts).
// This test reproduces the exact 3-click sequence and asserts the pills
// repaint correctly. Without the fix the second viewport click leaves
// aria-pressed stuck on pill #0.
test("user repro: iPhone Backend + 2 viewport pills repaint correctly", async () => {
  const { ctx, page } = await openEditor();
  try {
    const iphoneSelector = await page.evaluate(() => {
      const pills = document.querySelectorAll(
        '[data-toolbar-cluster="backend"] [data-choice-group-pill]',
      );
      for (const p of pills) {
        const lbl =
          p.getAttribute("data-choice-group-label") ||
          p.getAttribute("aria-label") ||
          "";
        if (/iphone|ios/i.test(lbl)) {
          return `[data-toolbar-cluster="backend"] [data-choice-group-pill="${p.getAttribute("data-choice-group-pill")}"]`;
        }
      }
      return null;
    });
    if (!iphoneSelector) {
      console.warn(
        "[repro] no iPhone Backend pill found in current build — skipping",
      );
      return;
    }

    await page.locator(iphoneSelector).click();
    await page.waitForTimeout(120);

    const viewportPillCount = await page.evaluate(
      () =>
        document.querySelectorAll(
          '[data-toolbar-cluster="viewport"] [data-choice-group-pill]',
        ).length,
    );
    if (viewportPillCount < 2) {
      console.warn(
        `[repro] iPhone viewport strip has only ${viewportPillCount} pill(s) — cannot reproduce the 2-click sequence`,
      );
      return;
    }

    const pill0 =
      '[data-toolbar-cluster="viewport"] [data-choice-group-pill="0"]';
    const pill1 =
      '[data-toolbar-cluster="viewport"] [data-choice-group-pill="1"]';

    await page.locator(pill0).click();
    await page.waitForTimeout(50);
    await page.locator(pill1).click();
    await page.waitForTimeout(50);

    const state = await page.evaluate(
      ({ p0, p1 }) => ({
        p0Pressed: document.querySelector(p0)?.getAttribute("aria-pressed"),
        p1Pressed: document.querySelector(p1)?.getAttribute("aria-pressed"),
      }),
      { p0: pill0, p1: pill1 },
    );

    assert.strictEqual(
      state.p1Pressed,
      "true",
      `after iPhone + click(p0) + click(p1), viewport pill #1 must be aria-pressed=true (got ${state.p1Pressed}) — this is the regression net for the rebuild-effect-disposes-inner-effect bug fixed 2026-05-29`,
    );
    assert.strictEqual(
      state.p0Pressed,
      "false",
      `viewport pill #0 must be aria-pressed=false after pill #1 click (got ${state.p0Pressed})`,
    );
  } finally {
    await ctx.close();
  }
});

// User-reported follow-up repro (2026-05-29 second pass): "I click on
// iPhone, Zed, and Freya, I do it quick and at some point the
// currently clicked screen size button stops being highlighted." Root
// cause: the same disposal cascade as the first fix but triggered via
// a different path — Zed and Freya share the same pinned-viewport set
// (both are desktop launchers), so the Zed→Freya rebuild effect re-run
// sees needsRebuild=false and skips re-mounting the strip. But
// cleanNode already disposed the previous mount's inner effect on
// re-run, leaving the strip lifeless. Fix: anchor the strip's inner
// effect to the shell-level owner via runWithOwner.
test("user repro 2: iPhone → Zed → Freya quick, then viewport click", async () => {
  const { ctx, page } = await openEditor();
  try {
    const pillSelectorFor = (matcher) =>
      page.evaluate((rxSrc) => {
        const rx = new RegExp(rxSrc, "i");
        const pills = document.querySelectorAll(
          '[data-toolbar-cluster="backend"] [data-choice-group-pill]',
        );
        for (const p of pills) {
          const lbl =
            p.getAttribute("data-choice-group-label") ||
            p.getAttribute("aria-label") ||
            "";
          if (rx.test(lbl)) {
            return `[data-toolbar-cluster="backend"] [data-choice-group-pill="${p.getAttribute("data-choice-group-pill")}"]`;
          }
        }
        return null;
      }, matcher);

    const iphone = await pillSelectorFor("iphone|ios");
    const zed = await pillSelectorFor("zed");
    const freya = await pillSelectorFor("freya");
    if (!iphone || !zed || !freya) {
      console.warn(
        "[repro 2] missing iPhone/Zed/Freya pill in current backend set — skipping",
      );
      return;
    }

    await page.locator(iphone).click();
    await page.waitForTimeout(30);
    await page.locator(zed).click();
    await page.waitForTimeout(30);
    await page.locator(freya).click();
    await page.waitForTimeout(80);

    const viewportPillCount = await page.evaluate(
      () =>
        document.querySelectorAll(
          '[data-toolbar-cluster="viewport"] [data-choice-group-pill]',
        ).length,
    );
    if (viewportPillCount < 2) {
      console.warn(
        `[repro 2] Freya viewport strip has only ${viewportPillCount} pill(s) — cannot reproduce the 2-click sequence`,
      );
      return;
    }

    const pill1 =
      '[data-toolbar-cluster="viewport"] [data-choice-group-pill="1"]';
    await page.locator(pill1).click();
    await page.waitForTimeout(60);

    const p1Pressed = await page.evaluate(
      (sel) => document.querySelector(sel)?.getAttribute("aria-pressed"),
      pill1,
    );
    assert.strictEqual(
      p1Pressed,
      "true",
      `after iPhone→Zed→Freya + click(viewport pill #1), pill #1 must be aria-pressed=true (got ${p1Pressed}) — regression net for the same-pinned-set disposal cascade fixed 2026-05-29`,
    );
  } finally {
    await ctx.close();
  }
});
