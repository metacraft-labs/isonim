// User-requested follow-up — gallery filters by the editor's active
// preview-id AND surfaces a per-capture detail panel populated with
// the reviewer agent's defects.
//
// The contracts this test seals:
//
//   1. Filter by current preview-id: after selecting the Task App /
//      Pages / Inbox @ web story and clicking the history button,
//      only tiles whose ``data-design-review-gallery-preview-id``
//      matches the canonical web preview-id render. Captures seeded
//      for the SAME brief but a DIFFERENT preview-id (e.g. ``@tui``)
//      must NOT appear in the grid.
//
//   2. Real scores: tiles render the agent's real score (parsed out
//      of ``parsed_scores.previews[<previewId>]``) instead of the
//      legacy ``score —`` placeholder. The score chip carries
//      ``data-design-review-gallery-tile-score="true"`` and the
//      inner ``data-design-review-gallery-score`` label shows
//      ``score <N.N>``.
//
//   3. Clickable score → detail panel: clicking the score chip
//      opens a side panel
//      (``[data-design-review-gallery-detail-panel]``) carrying the
//      defects the reviewer agent reported. A ``Close`` chip
//      dismisses the panel.

import test from "node:test";
import assert from "node:assert/strict";
import { execSync } from "node:child_process";
import { bootFullHarness } from "./lib/design_review_harness.mjs";

const PAGE_PORT = 18512;
const EDITOR_BUILD = "/Users/zahary/metacraft/isonim-examples/build/editor";

let harness = null;
let chromium = null;
let browser = null;

// Canonical preview-ids — mirror ``brief_format.canonicalPreviewId``.
// Task App / Pages / Inbox on web: spaces stay, ``/`` is %-encoded.
const INBOX_WEB_PREVIEW_ID = "Task App %2F Pages/Inbox:page#0@web";
const INBOX_TUI_PREVIEW_ID = "Task App %2F Pages/Inbox:page#0@tui";

async function ensureBrowser() {
  if (!chromium) {
    const m = await import("playwright");
    chromium = m.chromium;
  }
  if (!browser) browser = await chromium.launch({ headless: true });
  return browser;
}

/**
 * Attach a reviewer-agent report to ``runId`` populated with a real
 * per-preview score + defects entry for ``previewId``. We bypass the
 * harness API (which only seeds captures) and call
 * ``design_review.record_agent_report`` directly via psql. The
 * ``parsed_scores`` JSONB mirrors the shape ``reviewer_output.nim``
 * documents.
 *
 * The SQL is piped via stdin (``psql`` reads from stdin when there's
 * no ``-c``) so the JSON's embedded double quotes don't fight the
 * shell's outer quoting.
 */
function seedReport(pgUrl, runId, previewId, scoreChrome, defects) {
  const [host, port] = pgUrl.split(":");
  const parsedScores = JSON.stringify({
    notes: "",
    overall: { score: scoreChrome, status: "warn" },
    previews: {
      [previewId]: {
        scores: { chrome: scoreChrome, rendering: scoreChrome - 1 },
        status: scoreChrome >= 8 ? "ok" : "warn",
        defects,
      },
    },
  });
  const escScores = parsedScores.replace(/'/g, "''");
  // Transition the run from ``capturing`` → ``capture_complete`` so
  // ``record_agent_report`` can run (its guard requires the run to
  // already be in one of capture_complete / review_pending /
  // reviewed). ``finish_captures`` is idempotent so a second call is
  // safe if the harness ever wires this in directly.
  const sql =
    `SELECT design_review.finish_captures('${runId}'::uuid);\n` +
    `SELECT design_review.record_agent_report('${runId}'::uuid, 'claude-code', 'review-prompt@v2', '/tmp/fake-output.txt', '${escScores}'::jsonb);\n`;
  execSync(
    `psql -h ${host} -p ${port} -d isonim_design_review -A -t -v ON_ERROR_STOP=1`,
    { input: sql, stdio: ["pipe", "pipe", "pipe"] },
  );
}

test.before(async () => {
  harness = await bootFullHarness({
    editorPort: PAGE_PORT,
    editorBuild: EDITOR_BUILD,
  });
  // Seed captures across TWO preview-ids on the same brief. The web
  // preview-id has two captures (the user's active preview when the
  // history button is clicked); the tui preview-id has one capture
  // (which the filter must hide).
  const webRun = await harness.seedCaptures("render.task-app", [
    {
      storyId: INBOX_WEB_PREVIEW_ID,
      platform: "web",
      deviceClass: "desktop",
      width: 320,
      height: 240,
    },
    {
      storyId: INBOX_WEB_PREVIEW_ID,
      platform: "web",
      deviceClass: "mobile",
      width: 200,
      height: 320,
    },
  ]);
  // Attach a reviewer-agent report to the web run with a real score
  // + two defects so the gallery surfaces them on the tile + detail
  // panel.
  seedReport(harness.pgUrl, webRun.runId, INBOX_WEB_PREVIEW_ID, 7.0, [
    {
      id: "web-chrome-spacing",
      summary:
        "Toolbar chip spacing is uneven; the Compare pill sits 2 px closer to the save chip than to its siblings.",
      evidence: "/tmp/inbox-web-chrome.png",
      severity: "warn",
    },
    {
      id: "web-status-label-contrast",
      summary:
        "Status label (#A0A2B0) on the #111827 tile background reads at 3.8:1 — below the 4.5:1 WCAG AA target.",
      evidence: "/tmp/inbox-web-contrast.png",
      severity: "warn",
    },
  ]);
  // Second run on a different preview-id (tui). With the new filter
  // these captures must NOT appear when the editor is on the @web
  // story.
  await harness.seedCaptures("render.task-app", [
    {
      storyId: INBOX_TUI_PREVIEW_ID,
      platform: "tui",
      deviceClass: "desktop",
      width: 320,
      height: 240,
    },
  ]);
});

test.after(async () => {
  try {
    if (browser) await browser.close();
  } catch {}
  if (harness) harness.teardownAll();
});

async function selectInboxStory(page) {
  await page.evaluate(() => {
    const sectionBtns = Array.from(
      document.querySelectorAll("button, [role='button']"),
    );
    for (const b of sectionBtns) {
      if (b.textContent?.trim() === "Pages") {
        b.click();
        break;
      }
    }
  });
  await page.waitForTimeout(150);
  await page.evaluate(() => {
    const groupBtns = Array.from(
      document.querySelectorAll("button, [role='button']"),
    );
    for (const b of groupBtns) {
      if (b.textContent?.trim() === "Task App / Pages") {
        b.click();
        break;
      }
    }
  });
  await page.waitForTimeout(150);
  await page.evaluate(() => {
    const all = Array.from(document.querySelectorAll("*"));
    for (const el of all) {
      if (el.textContent?.trim() === "Inbox" && el.children.length === 0) {
        el.click();
        return;
      }
    }
  });
  await page.waitForTimeout(1000);
}

async function openGallery(page) {
  await page.goto(harness.editorUrl, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(500);
  await selectInboxStory(page);
  // Wait for the history button to surface (the briefHasHistory
  // poll lands true once the seeded run lands in the DB).
  await page.waitForFunction(
    () => {
      const btn = document.querySelector(
        '[data-design-review-history-button="true"]',
      );
      return btn && btn.getAttribute("data-history-visible") === "true";
    },
    null,
    { timeout: 15_000 },
  );
  // Click programmatically — the chrome bar may clip the button.
  await page.evaluate(() => {
    const btn = document.querySelector(
      '[data-design-review-history-button="true"]',
    );
    btn?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  });
  await page.waitForFunction(
    () =>
      document.querySelectorAll("[data-design-review-gallery-tile]").length >=
      1,
    null,
    { timeout: 15_000 },
  );
}

test("gallery filters by current preview — @web shows only the web captures", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (err) => errors.push(String(err)));
  try {
    await openGallery(page);
    // Tile previewIds — must all be the @web canonical id; no @tui.
    const previewIds = await page.evaluate(() =>
      Array.from(
        document.querySelectorAll("[data-design-review-gallery-tile]"),
      ).map((t) => t.getAttribute("data-design-review-gallery-preview-id")),
    );
    assert.ok(
      previewIds.length >= 2,
      `expected ≥2 web tiles to render; got ${previewIds.length}`,
    );
    for (const pid of previewIds) {
      assert.equal(
        pid,
        INBOX_WEB_PREVIEW_ID,
        `every visible tile must belong to the current preview-id (got "${pid}"; expected "${INBOX_WEB_PREVIEW_ID}")`,
      );
    }
    assert.equal(
      errors.length,
      0,
      "no page errors expected: " + JSON.stringify(errors),
    );
  } finally {
    await ctx.close();
  }
});

test("tile score chips show the agent's real score, not the placeholder", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  try {
    await openGallery(page);
    // Wait for the score chip to receive the real value (the
    // fetchRun → parse cycle is async at the JS layer even though
    // the resource path is synchronous on native).
    await page.waitForFunction(
      () => {
        const chips = Array.from(
          document.querySelectorAll(
            "[data-design-review-gallery-tile-score-has-report='true']",
          ),
        );
        if (chips.length === 0) return false;
        const labels = chips
          .map(
            (c) =>
              c
                .querySelector("[data-design-review-gallery-score]")
                ?.textContent?.trim() || "",
          )
          .filter((t) => t.length > 0);
        return labels.every((t) => /score \d+\.\d+/.test(t));
      },
      null,
      { timeout: 15_000 },
    );
    const labels = await page.evaluate(() =>
      Array.from(
        document.querySelectorAll(
          "[data-design-review-gallery-tile-score-has-report='true']",
        ),
      ).map(
        (c) =>
          c
            .querySelector("[data-design-review-gallery-score]")
            ?.textContent?.trim() || "",
      ),
    );
    for (const label of labels) {
      assert.ok(
        /score \d+\.\d+/.test(label),
        `score chip label must match "score N.N"; got "${label}"`,
      );
      assert.notEqual(
        label,
        "score —",
        "score chip must surface the agent's real score, not the legacy placeholder",
      );
    }
  } finally {
    await ctx.close();
  }
});

test("clicking a tile's score chip opens the detail panel with the agent's defects", async () => {
  const b = await ensureBrowser();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  try {
    await openGallery(page);
    // Wait for the detail panel to be PRESENT in the DOM (it's
    // ``display: none`` by default so ``state: "attached"`` is
    // required — the default ``"visible"`` waits for non-zero
    // bounding box and would time out on a hidden panel).
    await page.waitForSelector(
      '[data-design-review-gallery-detail-panel="true"]',
      { timeout: 10_000, state: "attached" },
    );
    // Panel starts hidden.
    const initiallyHidden = await page.evaluate(() =>
      document
        .querySelector('[data-design-review-gallery-detail-panel="true"]')
        ?.getAttribute("data-design-review-gallery-detail-visible"),
    );
    assert.equal(
      initiallyHidden,
      "false",
      "detail panel must be hidden before the score chip is clicked",
    );
    // Click the first score chip via Playwright. The user-trusted
    // path runs the inline-JS shim (bubble-phase ``stopPropagation``
    // so the tile's primary "open full-tab" click doesn't ALSO fire)
    // plus the Nim-installed handler that flips the detail panel
    // visible reactively.
    const chipHandle = await page
      .locator("[data-design-review-gallery-tile-score-has-report='true']")
      .first();
    await chipHandle.click({ force: true });
    await page.waitForFunction(
      () => {
        const p = document.querySelector(
          '[data-design-review-gallery-detail-panel="true"]',
        );
        return (
          p &&
          p.getAttribute("data-design-review-gallery-detail-visible") === "true"
        );
      },
      null,
      { timeout: 10_000 },
    );
    // Detail panel surfaces the agent's defects.
    const defectIds = await page.evaluate(() =>
      Array.from(
        document.querySelectorAll("[data-design-review-gallery-detail-defect]"),
      ).map((d) => d.getAttribute("data-design-review-gallery-detail-defect")),
    );
    assert.ok(
      defectIds.includes("web-chrome-spacing"),
      `detail panel must list the seeded "web-chrome-spacing" defect; got ${JSON.stringify(defectIds)}`,
    );
    assert.ok(
      defectIds.includes("web-status-label-contrast"),
      `detail panel must list the seeded "web-status-label-contrast" defect; got ${JSON.stringify(defectIds)}`,
    );
    // Defect summary text is rendered (not just the id chip).
    const firstSummary = await page.evaluate(() =>
      document
        .querySelector(
          "[data-design-review-gallery-detail-defect-summary='true']",
        )
        ?.textContent?.trim(),
    );
    assert.ok(
      firstSummary && firstSummary.length > 10,
      `defect summary text must render; got "${firstSummary}"`,
    );
    // Close the detail panel and assert it dismisses.
    await page
      .locator('[data-design-review-gallery-detail-close="true"]')
      .first()
      .click({ force: true });
    await page.waitForFunction(
      () => {
        const p = document.querySelector(
          '[data-design-review-gallery-detail-panel="true"]',
        );
        return (
          p &&
          p.getAttribute("data-design-review-gallery-detail-visible") ===
            "false"
        );
      },
      null,
      { timeout: 10_000 },
    );
    // Grid is back at full visible width — at least one tile is still
    // present and not styled hidden.
    const visibleTiles = await page.evaluate(
      () =>
        document.querySelectorAll("[data-design-review-gallery-tile]").length,
    );
    assert.ok(
      visibleTiles >= 2,
      `grid must remain populated after closing detail; got ${visibleTiles} tiles`,
    );
  } finally {
    await ctx.close();
  }
});
