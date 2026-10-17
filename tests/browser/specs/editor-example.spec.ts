import {
  test,
  expect,
  type Locator,
  type Page,
  type Request,
  type Frame,
  type ConsoleMessage,
} from "@playwright/test";

const desktop = { width: 1440, height: 900 };
const laptop = { width: 1280, height: 800 };
const tablet = { width: 1024, height: 768 };
const mobileWidth = { width: 390, height: 844 };
function previewMode(page: Page, mode: "View" | "Comment" | "Edit"): Locator {
  return page.locator('[data-toolbar-cluster="mode"]').getByRole("button", {
    name: mode,
    exact: true,
  });
}

const demoFoundationSource =
  "examples/wanderlust/design-system/foundations.css";

async function expectStableVisualSnapshot(page, name: string) {
  await page.addStyleTag({
    content: `
      *, *::before, *::after {
        animation-duration: 0s !important;
        animation-delay: 0s !important;
        transition-duration: 0s !important;
        caret-color: transparent !important;
      }
    `,
  });
  await expect(page).toHaveScreenshot(name, {
    fullPage: true,
    maxDiffPixelRatio: 0.03,
  });
}

async function expectStableElementSnapshot(
  page: Page,
  locator: Locator,
  name: string,
) {
  await page.addStyleTag({
    content: `
      *, *::before, *::after {
        animation-duration: 0s !important;
        animation-delay: 0s !important;
        transition-duration: 0s !important;
        caret-color: transparent !important;
      }
    `,
  });
  await expect(locator).toHaveScreenshot(name, {
    maxDiffPixelRatio: 0.03,
  });
}

async function assertVisibleBox(locator, label: string) {
  await expect(locator).toBeVisible();
  const box = await locator.boundingBox();
  expect(box, `${label} has a layout box`).not.toBeNull();
  expect(box!.width, `${label} width`).toBeGreaterThan(24);
  expect(box!.height, `${label} height`).toBeGreaterThan(10);
}

async function assertNoBodyScrollbar(page) {
  const overflow = await page.evaluate(() => ({
    x:
      document.documentElement.scrollWidth -
      document.documentElement.clientWidth,
    y:
      document.documentElement.scrollHeight -
      document.documentElement.clientHeight,
  }));
  expect(overflow.x, "body must not expose horizontal scroll").toBeLessThan(2);
  expect(overflow.y, "body must not expose vertical scroll").toBeLessThan(2);
}

async function assertNoEssentialOverlaps(page, selectors: string[]) {
  const overlaps = await page.evaluate((items) => {
    const visibleRect = (selector: string) => {
      const element = document.querySelector(selector);
      if (!element) return null;
      const style = window.getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      if (
        style.visibility === "hidden" ||
        style.display === "none" ||
        rect.width < 1 ||
        rect.height < 1
      ) {
        return null;
      }
      return {
        selector,
        left: rect.left,
        top: rect.top,
        right: rect.right,
        bottom: rect.bottom,
      };
    };
    const rects = items.map(visibleRect).filter(Boolean) as Array<{
      selector: string;
      left: number;
      top: number;
      right: number;
      bottom: number;
    }>;
    const failures: string[] = [];
    for (let i = 0; i < rects.length; i++) {
      for (let j = i + 1; j < rects.length; j++) {
        const a = rects[i];
        const b = rects[j];
        const x = Math.max(
          0,
          Math.min(a.right, b.right) - Math.max(a.left, b.left),
        );
        const y = Math.max(
          0,
          Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top),
        );
        if (x * y > 24) failures.push(`${a.selector} overlaps ${b.selector}`);
      }
    }
    return failures;
  }, selectors);
  expect(overlaps).toEqual([]);
}

async function assertNoClippedEssentialText(page) {
  const clipped = await page.evaluate(() => {
    const selectors = [
      ".editor-sidebar button",
      ".editor-statusbar [role=button]",
      ".editor-tabbar [role=tab]",
      ".editor-manual-inspector [role=button]",
      ".editor-chat [role=button]",
      ".editor-manual-inspector input",
      ".editor-chat textarea",
      '[data-variable-picker="true"][data-variable-picker-open="true"] [role=button]',
      '[data-variable-picker="true"][data-variable-picker-open="true"] [data-variable-picker-row-name]',
      '[data-variable-picker="true"][data-variable-picker-open="true"] [data-variable-picker-row-value]',
    ];
    const failures: string[] = [];
    for (const selector of selectors) {
      for (const element of Array.from(
        document.querySelectorAll<HTMLElement>(selector),
      )) {
        const style = window.getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        if (style.display === "none" || style.visibility === "hidden") continue;
        if (rect.width < 1 || rect.height < 1) continue;
        const text = (element.innerText || "").trim();
        if (!text) continue;
        if (text.length > 32) continue;
        const clippedX = element.scrollWidth - element.clientWidth > 2;
        const clippedY = element.scrollHeight - element.clientHeight > 2;
        if (clippedX || clippedY) {
          failures.push(`${selector}: ${text}`);
        }
      }
    }
    return failures;
  });
  expect(clipped).toEqual([]);
}

async function assertVectorCanvasHasPixels(page) {
  const stats = await page
    .locator('canvas[data-vector-canvas="fabric"]')
    .first()
    .evaluate((canvas: HTMLCanvasElement) => {
      const context = canvas.getContext("2d");
      if (!context) return { nonBlank: 0, distinct: 0 };
      const width = canvas.width;
      const height = canvas.height;
      const data = context.getImageData(0, 0, width, height).data;
      const colors = new Set<string>();
      let nonBlank = 0;
      const stride = Math.max(4, Math.floor(data.length / 8000) * 4);
      for (let i = 0; i < data.length; i += stride) {
        const r = data[i];
        const g = data[i + 1];
        const b = data[i + 2];
        const a = data[i + 3];
        if (a > 0 && (r < 245 || g < 245 || b < 245)) {
          nonBlank++;
          colors.add(`${r >> 4}:${g >> 4}:${b >> 4}:${a >> 4}`);
        }
      }
      return { nonBlank, distinct: colors.size };
    });
  expect(stats.nonBlank, "vector canvas has visible pixels").toBeGreaterThan(
    20,
  );
  expect(
    stats.distinct,
    "vector canvas has more than a blank fill",
  ).toBeGreaterThan(1);
}

async function assertVectorPathHandlesVisible(page: Page) {
  const host = page.locator('[data-vector-adapter="fabric"]').first();
  await expect(host).toHaveAttribute(
    "data-vector-path-overlay-visible",
    "true",
  );
  await expect(host).toHaveAttribute("data-vector-path-source-backed", "paper");
  await expect
    .poll(async () =>
      Number(await host.getAttribute("data-vector-path-anchor-count")),
    )
    .toBeGreaterThanOrEqual(3);
  await expect
    .poll(async () =>
      Number(await host.getAttribute("data-vector-path-paper-segment-count")),
    )
    .toBeGreaterThanOrEqual(3);
  await expect
    .poll(async () =>
      Number(await host.getAttribute("data-vector-path-hit-target-min")),
    )
    .toBeGreaterThanOrEqual(14);
  await expect(host.locator('[data-vector-anchor="node-0"]')).toBeVisible();
}

async function openDestinationComponentDetail(page: Page) {
  await page.goto("/");
  await page.getByRole("button", { name: "Open Components section" }).click();
  await page
    .getByRole("button", { name: "Toggle DestinationCard stories" })
    .click();
  await page
    .getByRole("button", { name: "Select story DestinationCard / Default" })
    .click();
  await expect(
    page.locator('[data-component-variant-matrix="true"]'),
  ).toBeVisible();
}

async function openDestinationComponentEdit(page: Page) {
  await openDestinationComponentDetail(page);
  await previewMode(page, "Edit").click();
  await expect(page.locator(".editor-manual-inspector")).toBeVisible();
}

async function nativeInspectorSection(page: Page, slug: string) {
  const header = page.locator(`[data-inspector-section-header="${slug}"]`);
  if ((await header.getAttribute("aria-expanded")) !== "true")
    await header.click();
  return page.locator(`[data-inspector-section-body="${slug}"]`);
}

async function actualDemoSources(page: Page): Promise<Record<string, string>> {
  return page.evaluate(() => {
    const sources = (
      window as unknown as { __isonimDemoSources?: Record<string, string> }
    ).__isonimDemoSources;
    if (!sources || Object.keys(sources).length === 0)
      throw new Error("Actual source adapter receipt map is missing");
    return { ...sources };
  });
}

// Client-side observation only: no extra browser actions or altered waits.
const inspectorTimingOrigins = new WeakMap<Page, number>();
const inspectorStageTimings = new WeakMap<
  Page,
  { stage: string; elapsedMs: number }[]
>();
function recordInspectorStage(page: Page, stage: string) {
  const rows = inspectorStageTimings.get(page) ?? [];
  rows.push({
    stage,
    elapsedMs:
      performance.now() -
      (inspectorTimingOrigins.get(page) ?? performance.now()),
  });
  if (rows.length > 100) rows.shift();
  inspectorStageTimings.set(page, rows);
}

async function setInspectorProperty(
  page: Page,
  tab: string,
  property: string,
  value: string,
  expectAccepted = true,
) {
  const fields: Record<
    string,
    { legacy: string; section: string; label?: string; choice?: string }
  > = {
    "letter-spacing": {
      legacy: "Type",
      section: "typography",
      label: "Edit Letter spacing",
    },
    "text-transform": {
      legacy: "Type",
      section: "typography",
      choice: "Uppercase",
    },
    "background-image": {
      legacy: "Fill",
      section: "fill",
      label: "Edit Image",
    },
    "background-size": {
      legacy: "Fill",
      section: "fill",
      label: "Edit Image size",
    },
    "border-style": { legacy: "Stroke", section: "stroke", choice: "Dashed" },
    "outline-offset": {
      legacy: "Stroke",
      section: "stroke",
      label: "Edit Outline offset",
    },
    filter: { legacy: "Effects", section: "effects", label: "Edit Filter" },
    transform: {
      legacy: "Effects",
      section: "position",
      label: "Edit Transform",
    },
    "transition-duration": {
      legacy: "Transitions",
      section: "effects",
      label: "Edit Duration",
    },
    "flex-wrap": { legacy: "Layout", section: "layout", choice: "Wrap" },
    overflow: { legacy: "Layout", section: "layout", choice: "Auto" },
    "aspect-ratio": {
      legacy: "Size",
      section: "layout",
      label: "Edit Aspect ratio",
    },
  };
  recordInspectorStage(page, `${property}:begin`);
  const field = fields[property];
  expect(field, `Native property control for ${property}`).toBeTruthy();
  expect(tab).toBe(field.legacy);
  const body = await nativeInspectorSection(page, field.section);
  const row = body
    .locator(`[data-property-row-css-property="${property}"]`)
    .filter({
      has: field.label
        ? page.getByRole("textbox", { name: field.label, exact: true })
        : page.locator("[data-property-row-choice-host]"),
    });
  await expect(row).toHaveCount(1);
  const beforeSources = expectAccepted
    ? undefined
    : await actualDemoSources(page);
  if (field.choice) {
    const trigger = row.locator('[data-choice-group-trigger="true"]');
    if (await trigger.count()) {
      await trigger.click();
      await page
        .locator('[data-choice-group-popup="true"][data-popup-open="true"]')
        .getByRole("option", { name: field.choice, exact: true })
        .click();
      await expect(row.locator("[data-choice-group-trigger-label]")).toHaveText(
        field.choice,
      );
    } else {
      const choice = row.getByRole("button", {
        name: field.choice,
        exact: true,
      });
      await choice.click();
      await expect(choice).toHaveAttribute("aria-pressed", "true");
    }
  } else {
    const input = row.getByRole("textbox", { name: field.label, exact: true });
    await input.fill(value);
    await input.press("Enter");
    if (expectAccepted) {
      await expect(input).toHaveValue(
        property === "letter-spacing" ? /^2(?:\.0+)?(?:px)?$/ : value,
      );
    }
  }
  recordInspectorStage(page, `${property}:control-action-complete`);
  // All accepted declarations are checked together after the real autosave
  // debounce; every operation still has its original rendered-value assertion.
  if (!expectAccepted) {
    await expect(
      row.locator('[data-property-row-message-visible="true"]'),
    ).toContainText("Filter values must use supported CSS filter functions");
    expect(await actualDemoSources(page)).toEqual(beforeSources);
  }
}

async function applyRawInspectorCss(page: Page, tab: string, cssText: string) {
  await page.getByRole("tab", { name: `Show ${tab} edit controls` }).click();
  const input = page
    .getByRole("textbox", { name: `Edit raw CSS for ${tab} section` })
    .first();
  await expect(input).toBeVisible();
  await input.evaluate((node: HTMLTextAreaElement, nextValue) => {
    node.value = String(nextValue);
  }, cssText);
  await page
    .getByRole("button", { name: `Apply raw CSS for ${tab} section` })
    .click();
  await expect(page.getByText("Unsaved source edit")).toBeVisible();
}

async function forceSelectedStyle(page: Page, property: string, value: string) {
  await page.evaluate(
    ({ property, value }) => {
      const frame = document.querySelector<HTMLIFrameElement>(
        'iframe[title="Editable component preview"]',
      );
      const selected =
        frame?.contentDocument?.querySelector<HTMLElement>(
          '[data-isonim-selected="true"]',
        ) ?? null;
      selected?.style.setProperty(property, value);
    },
    { property, value },
  );
}

async function previewStyle(page: Page) {
  return page.evaluate(() => {
    const frame = document.querySelector<HTMLIFrameElement>(
      'iframe[title="Editable component preview"]',
    );
    const node =
      frame?.contentDocument?.querySelector<HTMLElement>(
        '[data-isonim-selected="true"]',
      ) ??
      frame?.contentDocument?.querySelector<HTMLElement>(
        '[data-testid="component-edit-preview"]',
      ) ??
      null;
    if (!node) return null;
    const style = frame!.contentWindow!.getComputedStyle(node);
    const rect = node.getBoundingClientRect();
    return {
      padding: style.paddingTop,
      width: rect.width,
      height: rect.height,
      liveEdited: node.getAttribute("data-isonim-live-edited") ?? "",
      source: node.getAttribute("data-isonim-src") ?? "",
    };
  });
}

async function demoSourceContent(page: Page, file: string) {
  return page.evaluate(
    (path) =>
      (window as unknown as { __isonimDemoSources?: Record<string, string> })
        .__isonimDemoSources?.[path] ?? "",
    file,
  );
}

async function markPreviewSelected(page: Page) {
  await page.evaluate(() => {
    const frame = document.querySelector<HTMLIFrameElement>(
      'iframe[title="Editable component preview"]',
    );
    const target = frame?.contentDocument?.querySelector<HTMLElement>(
      '[data-testid="component-edit-preview"]',
    );
    target?.setAttribute("data-isonim-selected", "true");
    if (frame?.contentWindow && target) {
      (
        frame.contentWindow as unknown as {
          __isonimSelectedElement?: HTMLElement;
        }
      ).__isonimSelectedElement = target;
    }
  });
}

test.describe("IsoNim packaged editor example", () => {
  test.afterEach(async ({ page }, testInfo) => {
    const stages = inspectorStageTimings.get(page);
    if (stages) {
      console.log(
        "INSPECTOR_OPERATION_STAGE_TIMINGS " + JSON.stringify(stages),
      );
      try {
        await testInfo.attach("inspector-operation-stage-timings", {
          body: JSON.stringify(stages),
          contentType: "application/json",
        });
      } catch (error) {
        console.error("Inspector timing attachment failed:", error);
      }
    }
  });
  test.beforeEach(async ({ page }, testInfo) => {
    inspectorTimingOrigins.set(page, performance.now());
    // Failure-only navigation evidence; the original load wait and deadline stay intact.
    const events: { event: string; detail: string }[] = [];
    const totals: Record<string, number> = {};
    const pending = new Map<Request, string>();
    let pendingTotal = 0;
    let pendingSampleOmissions = 0;
    const safeUrl = (value: string) => {
      try {
        const url = new URL(value);
        return url.origin + url.pathname;
      } catch {
        return value.slice(0, 256);
      }
    };
    const record = (event: string, detail = "") => {
      totals[event] = (totals[event] ?? 0) + 1;
      events.push({ event, detail: detail.slice(0, 4096) });
      if (events.length > 200) events.shift();
    };
    const onRequest = (request: Request) => {
      const detail = (
        request.resourceType() +
        " " +
        safeUrl(request.url())
      ).slice(0, 4096);
      pendingTotal++;
      if (pending.size < 200) pending.set(request, detail);
      else pendingSampleOmissions++;
      record("request", detail);
    };
    const onFinished = (request: Request) => {
      pendingTotal--;
      pending.delete(request);
      record("requestfinished", safeUrl(request.url()));
    };
    const onFailed = (request: Request) => {
      pendingTotal--;
      pending.delete(request);
      record(
        "requestfailed",
        safeUrl(request.url()) + " " + (request.failure()?.errorText ?? ""),
      );
    };
    const onFrame = (frame: Frame) =>
      record(
        "framenavigated",
        (frame.parentFrame() ? "child " : "main ") + safeUrl(frame.url()),
      );
    const onError = (error: Error) =>
      record("pageerror", error.stack ?? error.message);
    const onConsole = (message: ConsoleMessage) => {
      if (message.type() === "error") record("consoleerror", message.text());
    };
    const onDom = () => record("domcontentloaded");
    const onLoad = () => record("load");
    page.on("request", onRequest);
    page.on("requestfinished", onFinished);
    page.on("requestfailed", onFailed);
    page.on("framenavigated", onFrame);
    page.on("pageerror", onError);
    page.on("console", onConsole);
    page.on("domcontentloaded", onDom);
    page.on("load", onLoad);
    try {
      await page.goto("/");
      await expect(page.getByText("IsoNim Editor")).toBeVisible();
      recordInspectorStage(page, "initial-load-visible");
    } catch (error) {
      try {
        await testInfo.attach("original-initial-load-failure", {
          body: JSON.stringify(
            {
              totals,
              events,
              pendingTotal,
              pendingSampleOmissions,
              pendingSample: [...pending.values()],
            },
            null,
            2,
          ),
          contentType: "application/json",
        });
      } catch (attachmentError) {
        console.error(
          "Initial-load evidence attachment failed:",
          attachmentError,
        );
      }
      throw error;
    } finally {
      page.off("request", onRequest);
      page.off("requestfinished", onFinished);
      page.off("requestfailed", onFailed);
      page.off("framenavigated", onFrame);
      page.off("pageerror", onError);
      page.off("console", onConsole);
      page.off("domcontentloaded", onDom);
      page.off("load", onLoad);
    }
  });

  test("e2e_editor_sidebar_story_selection", async ({ page }) => {
    await expect(page.locator('[data-figma-canvas="true"]')).toBeVisible();

    const play = page
      .locator('[aria-label="Play flow"], [aria-label="Pause flow"]')
      .first();
    await expect(play).toHaveAttribute("aria-label", "Play flow");
    await play.click();
    await expect(play).toHaveAttribute("aria-pressed", "true");

    await page.getByRole("button", { name: "Stop flow" }).click();
    await expect(play).toHaveAttribute("aria-pressed", "false");

    await page.getByRole("button", { name: "Next flow step" }).click();
    await expect(
      page.getByRole("button", {
        name: "Select story Pages / Destination Detail",
      }),
    ).toHaveAttribute("aria-current", "true");

    const story = page.getByRole("button", {
      name: "Select story Pages / Destination Detail",
    });

    await story.click();
    await expect(story).toHaveAttribute("aria-current", "true");
    await expect(
      page.getByText("Pages / Destination Detail").last(),
    ).toBeVisible();
    await expect(page.getByText("Santorini detail with reviews")).toBeVisible();
    await expect(page.getByText("Ask for design-system changes")).toBeVisible();

    await page
      .getByRole("button", { name: "Open User Journeys section" })
      .click();
    await page
      .getByRole("button", {
        name: "Select flow step Taps Santorini card to see details",
      })
      .click();
    await expect(
      page.getByText("Pages / Destination Detail").last(),
    ).toBeVisible();

    await page.goto("/?view=vector#vector-editor");
    await expect(page.getByText("Vector Editor")).toBeVisible();
    await expect(page.locator(".editor-sidebar")).toBeHidden();

    const pen = page.getByRole("button", { name: "Select Pen vector tool" });
    await pen.click();
    await expect(pen).toHaveAttribute("aria-pressed", "true");

    const layer = page.getByRole("button", {
      name: "Select vector layer Rectangle",
    });
    await layer.click();
    await expect(layer).toHaveAttribute("aria-selected", "true");

    await page.getByRole("button", { name: "Toggle inspector panel" }).click();
    await expect(page.locator(".editor-chat")).toBeHidden();
  });

  test("e2e_agent_assisted_edit_flow", async ({ page }) => {
    await expect(page.getByText("Ask for design-system changes")).toBeVisible();
    await expect(page.locator('[data-chat-role="arAssistant"]')).toHaveCount(0);
    await expect(
      page.getByRole("button", {
        name: "Allow agent permission agent-permission-1",
      }),
    ).toHaveCount(0);
    await expect(
      page.getByRole("button", { name: "Accept agent edit agent-proposal-1" }),
    ).toHaveCount(0);

    await page
      .getByRole("textbox", { name: "Agent prompt" })
      .fill("Apply the spacing edit");
    await page.getByRole("button", { name: "Send agent prompt" }).click();

    const conversation = page.locator(
      '.editor-chat[data-chat-local-id="chat-1"]',
    );
    const userTurn = conversation.locator(
      '[data-chat-role="arUser"][data-chat-turn="1"]',
    );
    await expect(conversation).toBeVisible();
    await expect(userTurn).toHaveCount(1);
    await expect(userTurn).toBeVisible();
    await expect(
      userTurn.locator('[data-chat-markdown="paragraph"]'),
    ).toHaveText("Apply the spacing edit");
    await expect(
      conversation.locator('[data-chat-role="arAssistant"]'),
    ).toHaveCount(1);
    await expect(
      page.getByText(
        "Fake adapter streamed response for 'Apply the spacing edit'",
      ),
    ).toBeVisible();
    await expect(page.getByText("tool state complete")).toBeVisible();
    await expect(page.getByText("0 inspector edit(s)")).toBeVisible();
    await expect(page.getByText("Permission Requests")).toBeVisible();
    await expect(page.getByText("Agent Proposed Edits")).toBeVisible();
    await expect(
      page.getByRole("button", {
        name: "Allow agent permission agent-permission-1",
      }),
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Accept agent edit agent-proposal-1" }),
    ).toBeVisible();
    await page
      .getByRole("button", {
        name: "Allow agent permission agent-permission-1",
      })
      .click();
    await expect(
      page
        .getByRole("button", {
          name: "Allow agent permission agent-permission-1",
          exact: true,
        })
        .locator("..")
        .locator("..")
        .getByText("Write workspace source - granted", { exact: true }),
    ).toBeVisible();
    await page
      .getByRole("button", { name: "Accept agent edit agent-proposal-1" })
      .click();
    await expect(
      page
        .getByRole("button", {
          name: "Accept agent edit agent-proposal-1",
          exact: true,
        })
        .locator("..")
        .locator("..")
        .getByText(
          "examples/wanderlust/design-system/vector-symbols.svg svgContent - accepted - current",
          { exact: true },
        ),
    ).toBeVisible();
    await page
      .getByRole("button", { name: "Revert agent edit agent-proposal-1" })
      .click();
    await expect(
      page
        .getByRole("button", {
          name: "Accept agent edit agent-proposal-1",
          exact: true,
        })
        .locator("..")
        .locator("..")
        .getByText(
          "examples/wanderlust/design-system/vector-symbols.svg svgContent - reverted - current",
          { exact: true },
        ),
    ).toBeVisible();
    await expect(page.locator("[data-chat-session-status]")).toHaveText(
      /(^|\n)Ready for next message$/,
    );
    await expect(page.locator("[data-chat-session-status]")).toBeVisible();
  });

  test("e2e_comment_review_ai_prompt_and_acceptance_flow", async ({ page }) => {
    await page.getByRole("button", { name: "Open Components section" }).click();
    await page
      .getByRole("button", { name: "Toggle DestinationCard stories" })
      .click();
    await page
      .getByRole("button", { name: "Select story DestinationCard / Default" })
      .click();
    await previewMode(page, "Edit").click();
    await expect(page.locator(".editor-manual-inspector")).toBeVisible();

    await previewMode(page, "Comment").click();
    await expect(page.locator(".editor-chat")).toBeVisible();

    const editFrame = page.frameLocator(
      'iframe[title="Editable component preview"]',
    );
    await expect(editFrame.getByTestId("component-edit-preview")).toBeVisible();
    await editFrame
      .getByTestId("component-edit-preview")
      .click({ force: true });
    const comment = editFrame.getByLabel("Comment on selected element");
    await expect(comment).toBeVisible();
    await comment.fill("Make the hero headline quieter.");
    await editFrame.getByRole("button", { name: "Add" }).click();

    await expect(
      editFrame.getByRole("button", { name: "Design review comment marker" }),
    ).toBeVisible();
    await expect(page.getByText("Design Review Comments")).toBeVisible();
    await expect(
      page.getByText("Make the hero headline quieter."),
    ).toBeVisible();
    await expect(
      page.getByText("review-annotation-1 - open - included"),
    ).toBeVisible();

    await page
      .getByRole("button", {
        name: "Exclude review comment review-annotation-1",
      })
      .click();
    await expect(
      page.getByText("review-annotation-1 - open - excluded"),
    ).toBeVisible();
    await page
      .getByRole("button", {
        name: "Include review comment review-annotation-1",
      })
      .click();
    await expect(
      page.getByText("review-annotation-1 - open - included"),
    ).toBeVisible();

    await page
      .getByRole("textbox", { name: "Agent prompt" })
      .fill("Apply the selected review comment");
    await page.getByRole("button", { name: "Send agent prompt" }).click();
    await expect(page.getByText("1 included review comment(s)")).toBeVisible();
    await expect(page.getByText("Diff: svgContent updated")).toBeVisible();
    await expect(
      page.getByText(
        "Impact: Updates the shared Compass vector symbol through the workspace adapter.",
      ),
    ).toBeVisible();
    await expect(
      page.getByText("Affected stories: Foundations/Vector Symbols"),
    ).toBeVisible();
    await expect(
      page.getByText(
        "Tests: compile Foundations / Vector Symbols, reload affected vector symbol preview",
      ),
    ).toBeVisible();

    await page
      .getByRole("button", { name: "Accept agent edit agent-proposal-1" })
      .click();
    await expect(
      page
        .getByRole("button", {
          name: "Accept agent edit agent-proposal-1",
          exact: true,
        })
        .locator("..")
        .locator("..")
        .getByText(
          "examples/wanderlust/design-system/vector-symbols.svg svgContent - accepted - current",
          { exact: true },
        ),
    ).toBeVisible();
    await page
      .getByRole("button", {
        name: "Resolve review comment review-annotation-1",
      })
      .click();
    await expect(
      page.getByText("review-annotation-1 - resolved - included"),
    ).toBeVisible();
  });

  test("e2e_editor_edit_buttons_keyboard_and_pointer", async ({ page }) => {
    await page
      .getByRole("button", { name: "Select story Pages / Destination Detail" })
      .click();

    const edit = previewMode(page, "Edit");
    const view = previewMode(page, "View");

    await expect(edit).toHaveAttribute("aria-disabled", "false");
    await edit.click();
    await expect(edit).toHaveAttribute("aria-pressed", "true");
    await expect(page).toHaveURL(/mode=edit/);

    await view.focus();
    await page.keyboard.press("Enter");
    await expect(view).toHaveAttribute("aria-pressed", "true");
    await expect(page).toHaveURL(/mode=view/);

    await page.goBack();
    await expect(edit).toHaveAttribute("aria-pressed", "true");
    await expect(page).toHaveURL(/mode=edit/);

    await page.goBack();
    await expect(view).toHaveAttribute("aria-pressed", "true");
    await expect(page).toHaveURL(/mode=view/);
  });

  test("e2e_editor_keyboard_and_accessibility_workflows", async ({ page }) => {
    await page.evaluate(() => localStorage.setItem("isonim-editor-debug", "1"));
    await page.reload();
    await openDestinationComponentEdit(page);

    const mod = process.platform === "darwin" ? "Meta" : "Control";
    const sidebarToggle = page.getByRole("button", {
      name: "Toggle left sidebar",
    });
    await sidebarToggle.focus();
    await page.keyboard.press(`${mod}+K`);
    const palette = page.locator('[data-editor-command-palette="true"]');
    await expect(palette).toHaveAttribute("aria-hidden", "false");
    await expect(
      page.getByRole("textbox", { name: "Search editor commands" }),
    ).toBeFocused();
    await expect(palette).toHaveAttribute("role", "dialog");
    await expect(palette).toHaveAttribute("aria-modal", "true");
    const search = page.getByRole("textbox", {
      name: "Search editor commands",
    });
    const editOption = page.getByRole("option", { name: /Edit command/ });
    const commentOption = page.getByRole("option", {
      name: /Comment command/,
    });
    const saveOption = page.locator('[data-command-kind="eckSave"]');
    await expect(editOption).toHaveAttribute("tabindex", "0");
    await expect(editOption).toHaveAttribute("aria-selected", "true");
    await expect(commentOption).toHaveAttribute("tabindex", "-1");
    await expect(saveOption).toHaveAttribute("aria-disabled", "true");
    await expect(saveOption).toHaveAttribute(
      "data-command-diagnostic",
      "There are no pending source edits.",
    );
    await page.keyboard.press("ArrowDown");
    await expect(commentOption).toHaveAttribute("tabindex", "0");
    await expect(commentOption).toHaveAttribute("aria-selected", "true");
    await expect(editOption).toHaveAttribute("tabindex", "-1");
    await page.keyboard.press("End");
    await expect(
      page.getByRole("option", { name: /Navigate layers down command/ }),
    ).toHaveAttribute("aria-selected", "true");
    await page.keyboard.press("Home");
    await expect(editOption).toHaveAttribute("aria-selected", "true");
    await page.keyboard.press("Tab");
    await expect(editOption).toBeFocused();
    await page.keyboard.press("Tab");
    await expect(search).toBeFocused();
    await page.keyboard.press("Home");
    for (let i = 0; i < 5; i++) {
      await page.keyboard.press("ArrowDown");
    }
    await expect(saveOption).toHaveAttribute("aria-selected", "true");
    await page.keyboard.press("Enter");
    await expect(palette).toHaveAttribute("aria-hidden", "false");
    await expect(
      page.locator("#isonim-command-palette-diagnostic"),
    ).toContainText("There are no pending source edits.");

    await page.keyboard.press("Escape");
    await expect(palette).toHaveAttribute("aria-hidden", "true");
    await expect(sidebarToggle).toBeFocused();

    await page.keyboard.press(`${mod}+K`);
    await expect(palette).toHaveAttribute("aria-hidden", "false");
    await search.evaluate((node: HTMLInputElement) =>
      node.focus({ preventScroll: true }),
    );
    await expect(search).toBeFocused();
    await page.keyboard.press("Home");
    await page.keyboard.press("ArrowDown");
    await page.keyboard.press("Tab");
    await expect(commentOption).toBeFocused();
    await page.keyboard.press("Space");
    await expect(palette).toHaveAttribute("aria-hidden", "true");
    await expect(previewMode(page, "Comment")).toHaveAttribute(
      "aria-pressed",
      "true",
    );
    await page.keyboard.press("E");
    await expect(previewMode(page, "Edit")).toHaveAttribute(
      "aria-pressed",
      "true",
    );

    await sidebarToggle.evaluate((node: HTMLElement) =>
      node.focus({ preventScroll: true }),
    );
    await expect(sidebarToggle).toBeFocused();
    await page.keyboard.press(`${mod}+Backslash`);
    await expect(page.locator(".editor-sidebar")).toBeHidden();
    await page.keyboard.press(`${mod}+Backslash`);
    await expect(page.locator(".editor-sidebar")).toBeVisible();

    await sidebarToggle.evaluate((node: HTMLElement) =>
      node.focus({ preventScroll: true }),
    );
    await page.keyboard.press(`${mod}+K`);
    await expect(palette).toHaveAttribute("aria-hidden", "false");
    await page
      .getByRole("option", { name: /Toggle inspector command/ })
      .click();
    await expect(page.locator(".editor-manual-inspector")).toBeHidden();
    await sidebarToggle.evaluate((node: HTMLElement) =>
      node.focus({ preventScroll: true }),
    );
    await page.keyboard.press("I");
    await expect(page.locator(".editor-manual-inspector")).toBeVisible();
    await expect(
      page.getByRole("textbox", { name: "Search inspector sections" }),
    ).toBeFocused();
    const sectionSearch = page.getByRole("textbox", {
      name: "Search inspector sections",
    });
    const sectionFrames = page.locator("[data-inspector-section-row]");
    const priorExpansion = await sectionFrames.evaluateAll((frames) =>
      frames.map((frame) =>
        frame
          .querySelector("[data-inspector-section-header]")
          ?.getAttribute("aria-expanded"),
      ),
    );
    await sectionSearch.fill("padding");
    await expect(
      page.locator('[data-inspector-section-row="layout"]'),
    ).toBeVisible();
    await expect(
      page.locator('[data-inspector-section-row="typography"]'),
    ).toBeHidden();
    await expect(
      page.locator('[data-property-row-css-property="padding-top"]'),
    ).toHaveAttribute("data-inspector-search-match", "true");
    await expect(
      page.locator('[data-inspector-section-header="layout"]'),
    ).toHaveAttribute("aria-expanded", "true");
    await page.locator('[data-inspector-section-header="layout"]').click();
    await expect(
      page.locator('[data-inspector-section-header="layout"]'),
    ).toHaveAttribute("aria-expanded", "false");
    await sectionSearch.press("Escape");
    await expect(sectionSearch).toHaveValue("");
    await expect
      .poll(() =>
        sectionFrames.evaluateAll((frames) =>
          frames.map((frame) =>
            frame
              .querySelector("[data-inspector-section-header]")
              ?.getAttribute("aria-expanded"),
          ),
        ),
      )
      .toEqual(priorExpansion);
    await expect(
      page.locator('[data-inspector-search-match="true"]'),
    ).toHaveCount(0);
    const editModeButton = previewMode(page, "Edit");
    await editModeButton.click();
    await editModeButton.evaluate((node: HTMLElement) =>
      node.focus({ preventScroll: true }),
    );
    await expect(editModeButton).toBeFocused();

    const editFrame = page.frameLocator(
      'iframe[title="Editable component preview"]',
    );
    await editFrame
      .getByRole("heading", { name: /DestinationCard \/ Default/ })
      .click();
    const selectedLayer = page
      .locator('[data-scene-graph-row][data-selected="true"]')
      .first();
    const selectedBefore = await selectedLayer.getAttribute(
      "data-scene-graph-row",
    );
    expect(selectedBefore).toBeTruthy();
    await editModeButton.evaluate((node: HTMLElement) =>
      node.focus({ preventScroll: true }),
    );
    await page.keyboard.press(`${mod}+K`);
    await expect(palette).toHaveAttribute("aria-hidden", "false");
    await page
      .getByRole("option", { name: /Select next element command/ })
      .click();
    await expect
      .poll(() =>
        page
          .locator('[data-scene-graph-row][data-selected="true"]')
          .first()
          .getAttribute("data-scene-graph-row"),
      )
      .not.toBe(selectedBefore);
    await editModeButton.evaluate((node: HTMLElement) =>
      node.focus({ preventScroll: true }),
    );
    await page.keyboard.press(`${mod}+K`);
    await expect(palette).toHaveAttribute("aria-hidden", "false");
    await page
      .getByRole("option", { name: /Select previous element command/ })
      .click();
    await expect
      .poll(() =>
        page
          .locator('[data-scene-graph-row][data-selected="true"]')
          .first()
          .getAttribute("data-scene-graph-row"),
      )
      .toBe(selectedBefore);

    await editModeButton.evaluate((node: HTMLElement) =>
      node.focus({ preventScroll: true }),
    );
    await expect(editModeButton).toBeFocused();
    await page.keyboard.press("V");
    await expect(previewMode(page, "View")).toHaveAttribute(
      "aria-pressed",
      "true",
    );

    await expect(
      page.locator('[data-editor-telemetry-overlay="true"]'),
    ).toHaveAttribute("aria-hidden", "false");
    await page.evaluate(() => localStorage.removeItem("isonim-editor-debug"));
  });

  test("editor_interaction_performance_budgets", async ({ page }) => {
    await page.goto("/?debug=1");
    await expect(page.getByText("IsoNim Editor")).toBeVisible();
    const budgetCount = await page
      .locator("[data-performance-budget-kind]")
      .count();
    expect(budgetCount).toBe(6);

    const budgetMs = async (kind: string) =>
      Number(
        await page
          .locator(`[data-performance-budget-kind="${kind}"]`)
          .getAttribute("data-performance-budget-ms"),
      );

    await page.getByRole("button", { name: "Open Components section" }).click();
    await page
      .getByRole("button", { name: "Toggle DestinationCard stories" })
      .click();

    // Campaign-only CPU evidence; normal performance runs keep this disabled.
    const storyCpu =
      process.env.ISONIM_REVIEW_STORY_CPU_PROFILE === "1"
        ? await page.context().newCDPSession(page)
        : null;
    let storyCpuStarted = false;
    let storyMeasurement:
      | { totalMs: number; clickMs: number; frameWaitMs: number }
      | undefined;
    let storyActionFailed = false;
    let storyActionError: unknown;
    let storyDiagnosticFailed = false;
    let storyDiagnosticError: unknown;
    try {
      if (storyCpu) {
        await storyCpu.send("Profiler.enable");
        await storyCpu.send("Profiler.setSamplingInterval", { interval: 1000 });
        await storyCpu.send("Profiler.start");
        storyCpuStarted = true;
      }
      storyMeasurement = await page.evaluate(async () => {
        const target = document.querySelector<HTMLElement>(
          '[aria-label="Select story DestinationCard / Default"]',
        );
        const started = performance.now();
        if (!target)
          throw new Error("Actual DestinationCard story control is missing");
        target.click();
        const clicked = performance.now();
        await new Promise((resolve) => requestAnimationFrame(resolve));
        const ended = performance.now();
        return {
          totalMs: ended - started,
          clickMs: clicked - started,
          frameWaitMs: ended - clicked,
        };
      });
    } catch (error) {
      storyActionFailed = true;
      storyActionError = error;
    } finally {
      if (storyCpu) {
        try {
          if (storyCpuStarted) {
            const { profile } = await storyCpu.send("Profiler.stop");
            const raw = JSON.stringify(profile);
            if (Buffer.byteLength(raw, "utf8") > 8 * 1024 * 1024)
              throw new Error("Finite story CPU profile bound exceeded");
            console.log("ORIGINAL_STORY_CPU_PROFILE_JSON", raw);
          }
        } catch (error) {
          storyDiagnosticFailed = true;
          storyDiagnosticError = error;
        } finally {
          try {
            await storyCpu.detach();
          } catch (error) {
            storyDiagnosticFailed = true;
            storyDiagnosticError ??= error;
          }
        }
      }
    }
    if (storyActionFailed) {
      if (storyDiagnosticFailed)
        console.log(
          "STORY_CPU_SECONDARY_FAILURE",
          String(storyDiagnosticError).slice(0, 2048),
        );
      throw storyActionError;
    }
    if (storyDiagnosticFailed) throw storyDiagnosticError;
    if (!storyMeasurement)
      throw new Error("Actual story timing result is missing");
    const storyDuration = storyMeasurement.totalMs;
    console.log(
      "ORIGINAL_STORY_SELECTION_INTERVALS",
      JSON.stringify(storyMeasurement),
    );
    expect(storyDuration).toBeLessThan(await budgetMs("epbkStorySelection"));

    const modeDuration = await page.evaluate(async () => {
      const target = document.querySelector<HTMLElement>(
        '[data-toolbar-cluster="mode"] [data-preview-mode="edit"]',
      );
      if (!target) throw new Error("Canonical Edit mode control is missing");
      const started = performance.now();
      target.click();
      await new Promise((resolve) => requestAnimationFrame(resolve));
      return performance.now() - started;
    });
    expect(modeDuration).toBeLessThan(await budgetMs("epbkModeSwitch"));
    await expect(page.locator(".editor-manual-inspector")).toBeVisible();

    const editFrame = page.frameLocator(
      'iframe[title="Editable component preview"]',
    );
    await page.evaluate(async () => {
      const frame = document.querySelector<HTMLIFrameElement>(
        'iframe[title="Editable component preview"]',
      );
      const target =
        frame?.contentDocument?.querySelector<HTMLElement>(
          '[data-testid="component-edit-preview"]',
        ) ?? null;
      target?.click();
      await new Promise((resolve) => requestAnimationFrame(resolve));
    });
    await expect(
      editFrame.locator('[data-isonim-selected="true"]'),
    ).toBeVisible();

    const layout = await nativeInspectorSection(page, "layout");
    const paddingRow = layout.locator(
      '[data-property-row-css-property="padding"]',
    );
    await expect(paddingRow).toHaveCount(1);
    const paddingInput = paddingRow.getByRole("textbox", {
      name: "Edit Padding",
      exact: true,
    });
    await paddingInput.fill("28px");
    await paddingInput.press("Enter");
    await expect
      .poll(() =>
        editFrame
          .locator('[data-isonim-selected="true"]')
          .first()
          .evaluate((node) => {
            const style = getComputedStyle(node);
            return [
              style.paddingTop,
              style.paddingRight,
              style.paddingBottom,
              style.paddingLeft,
            ];
          }),
      )
      .toEqual(["28px", "28px", "28px", "28px"]);
    // The published automatic-save contract retains Mod+S even while a field
    // has focus; exercise the real keyboard command rather than a removed button.
    const keyboardSave = page.locator(
      '[data-editor-telemetry-event="save and reload"][data-editor-telemetry-detail="keyboard:save"]',
    );
    await expect(keyboardSave).toHaveCount(0);
    await paddingInput.focus();
    await page.keyboard.press("ControlOrMeta+s");
    await expect(keyboardSave).toHaveCount(1);
    await expect(
      page.locator('[data-editor-telemetry-event="save and reload"]').last(),
    ).toBeVisible();
    const saveOutcome = page.locator(
      '[data-editor-telemetry-event="save and reload"][data-editor-telemetry-detail^="bridge-error:"], [data-editor-telemetry-event="save and reload"][data-editor-telemetry-detail^="preview-reload:"]',
    );
    await expect(saveOutcome.last()).toBeVisible();
    const saveDetail = await saveOutcome
      .last()
      .getAttribute("data-editor-telemetry-detail");
    expect(saveDetail ?? "").toMatch(/bridge-error:|preview-reload:/);
    const saveError = page.locator(
      '.editor-statusbar [data-save-error="true"]',
    );
    await expect(saveError).toHaveCount(1);
    if (saveDetail?.startsWith("bridge-error:")) {
      await expect(saveError).toBeVisible();
    } else {
      await expect(saveError).toBeHidden();
    }
    await expect
      .poll(() =>
        page.evaluate(() => {
          const editor = (
            window as unknown as {
              __isonimEditor?: { pendingSourceEdits?: () => number };
            }
          ).__isonimEditor;
          if (!editor?.pendingSourceEdits)
            throw new Error("Actual pending-source getter is missing");
          return editor.pendingSourceEdits();
        }),
      )
      .toBe(0);
    await expect
      .poll(() =>
        page.evaluate(() => {
          const sources = (
            window as unknown as {
              __isonimDemoSources?: Record<string, string>;
            }
          ).__isonimDemoSources;
          if (!sources?.["examples/wanderlust/design-system/foundations.css"])
            throw new Error("Actual project stylesheet receipt is missing");
          const sheet = new CSSStyleSheet();
          sheet.replaceSync(
            sources["examples/wanderlust/design-system/foundations.css"],
          );
          const rules = Array.from(sheet.cssRules).filter(
            (rule): rule is CSSStyleRule =>
              rule instanceof CSSStyleRule &&
              rule.selectorText === ".destination-card",
          );
          return rules.length === 1
            ? rules[0].style.getPropertyValue("padding")
            : "";
        }),
      )
      .toBe("28px");

    const searchDuration = await page.evaluate(async () => {
      const input = document.querySelector<HTMLInputElement>(
        'input[aria-label="Search stories"]',
      );
      const started = performance.now();
      if (input) {
        input.value = "destination";
        input.dispatchEvent(new Event("input", { bubbles: true }));
      }
      await new Promise((resolve) => requestAnimationFrame(resolve));
      return performance.now() - started;
    });
    expect(searchDuration).toBeLessThan(
      await budgetMs("epbkLargeSidebarSearch"),
    );

    await expect(
      page.locator('[data-editor-telemetry-overlay="true"]'),
    ).toBeVisible();
    for (const eventName of [
      "story selection",
      "mode switch",
      "element selection",
      "property edit preview",
      "save and reload",
    ]) {
      await expect(
        page.locator(`[data-editor-telemetry-event="${eventName}"]`).last(),
      ).toBeVisible();
    }
    await page.evaluate(() => localStorage.removeItem("isonim-editor-debug"));
  });

  test("e2e_long_tail_css_property_visual_evidence", async ({ page }) => {
    await openDestinationComponentEdit(page);
    const editFrame = page.frameLocator(
      'iframe[title="Editable component preview"]',
    );
    const target = editFrame
      .locator('[data-testid="component-edit-preview"]')
      .first();
    await target.click({ force: true });
    const selected = editFrame.locator('[data-isonim-selected="true"]').first();
    await expect(selected).toBeVisible();

    const beforeShot = await page.screenshot({ fullPage: true });
    const beforeBox = await selected.boundingBox();
    expect(beforeBox, "selected target has visual box").not.toBeNull();

    await setInspectorProperty(page, "Type", "letter-spacing", "2px");
    await expect
      .poll(() =>
        selected.evaluate((node) => getComputedStyle(node).letterSpacing),
      )
      .toBe("2px");

    const letterSpacingInput = page
      .getByRole("textbox", { name: "Edit Letter spacing", exact: true })
      .first();
    await letterSpacingInput.focus();
    await expect(letterSpacingInput).toBeFocused();
    await page.keyboard.press("Enter");
    await expect
      .poll(() =>
        selected.evaluate((node) => getComputedStyle(node).letterSpacing),
      )
      .toBe("2px");

    await setInspectorProperty(page, "Type", "text-transform", "uppercase");
    await expect
      .poll(() =>
        selected.evaluate((node) => getComputedStyle(node).textTransform),
      )
      .toBe("uppercase");

    await setInspectorProperty(
      page,
      "Fill",
      "background-image",
      "linear-gradient(90deg, rgb(59, 130, 246), rgb(34, 197, 94))",
    );
    await expect
      .poll(() =>
        selected.evaluate((node) => getComputedStyle(node).backgroundImage),
      )
      .toContain("linear-gradient");
    await setInspectorProperty(page, "Fill", "background-size", "contain");
    await expect
      .poll(() =>
        selected.evaluate((node) => getComputedStyle(node).backgroundSize),
      )
      .toBe("contain");

    await setInspectorProperty(page, "Stroke", "border-style", "dashed");
    await expect
      .poll(() =>
        selected.evaluate((node) => getComputedStyle(node).borderStyle),
      )
      .toContain("dashed");
    await setInspectorProperty(page, "Stroke", "outline-offset", "4px");
    await expect(
      page.getByRole("textbox", {
        name: "Edit Outline offset",
        exact: true,
      }),
    ).toHaveValue("4px");

    await setInspectorProperty(
      page,
      "Effects",
      "filter",
      "brightness(1.08) contrast(1.1)",
    );
    await expect
      .poll(() => selected.evaluate((node) => getComputedStyle(node).filter))
      .toContain("brightness");
    await setInspectorProperty(
      page,
      "Effects",
      "transform",
      "translateX(8px) scale(1.02)",
    );
    await expect
      .poll(() => selected.evaluate((node) => getComputedStyle(node).transform))
      .not.toBe("none");
    await expect
      .poll(() =>
        selected.evaluate((node) => {
          const matrix = new DOMMatrixReadOnly(
            getComputedStyle(node).transform,
          );
          return [matrix.a, matrix.d, matrix.e, matrix.f];
        }),
      )
      .toEqual([1.02, 1.02, 8, 0]);

    await setInspectorProperty(
      page,
      "Transitions",
      "transition-duration",
      "180ms",
    );
    await expect
      .poll(() =>
        selected.evaluate((node) => getComputedStyle(node).transitionDuration),
      )
      .toBe("0.18s");

    await setInspectorProperty(page, "Layout", "flex-wrap", "wrap");
    await expect
      .poll(() => selected.evaluate((node) => getComputedStyle(node).flexWrap))
      .toBe("wrap");
    await setInspectorProperty(page, "Layout", "overflow", "auto");
    await expect
      .poll(() => selected.evaluate((node) => getComputedStyle(node).overflowX))
      .toBe("auto");
    await setInspectorProperty(page, "Size", "aspect-ratio", "4 / 3");
    await expect
      .poll(() =>
        selected.evaluate((node) => getComputedStyle(node).aspectRatio),
      )
      .toBe("4 / 3");

    const acceptedDeclarations = {
      "letter-spacing": "2px",
      "text-transform": "uppercase",
      "background-image":
        "linear-gradient(90deg, rgb(59, 130, 246), rgb(34, 197, 94))",
      "background-size": "contain",
      "border-style": "dashed",
      "outline-offset": "4px",
      filter: "brightness(1.08) contrast(1.1)",
      transform: "translateX(8px) scale(1.02)",
      "transition-duration": "180ms",
      "flex-wrap": "wrap",
      overflow: "auto",
      "aspect-ratio": "4 / 3",
    };
    await expect
      .poll(() =>
        page.evaluate((expected) => {
          const sources = (
            window as unknown as {
              __isonimDemoSources?: Record<string, string>;
            }
          ).__isonimDemoSources;
          if (!sources?.["examples/wanderlust/design-system/foundations.css"])
            throw new Error("Actual project stylesheet receipt is missing");
          const sheet = new CSSStyleSheet();
          sheet.replaceSync(
            sources["examples/wanderlust/design-system/foundations.css"],
          );
          const matching = Array.from(sheet.cssRules).filter(
            (rule): rule is CSSStyleRule =>
              rule instanceof CSSStyleRule &&
              rule.selectorText === ".destination-card",
          );
          if (matching.length !== 1) return false;
          const wanted = new CSSStyleSheet();
          wanted.replaceSync(
            ".destination-card {" +
              Object.entries(expected)
                .map(([name, value]) => `${name}:${value};`)
                .join("") +
              "}",
          );
          const expectedStyle = (wanted.cssRules[0] as CSSStyleRule).style;
          return Object.keys(expected).every(
            (name) =>
              expectedStyle.getPropertyValue(name) !== "" &&
              matching[0].style.getPropertyValue(name) ===
                expectedStyle.getPropertyValue(name),
          );
        }, acceptedDeclarations),
      )
      .toBe(true);
    recordInspectorStage(page, "all-twelve-written-declarations-confirmed");
    await expect(
      page.locator('.editor-statusbar [data-save-error="true"]'),
    ).toHaveCount(1);
    await expect(
      page.locator('.editor-statusbar [data-save-error="true"]'),
    ).toBeHidden();
    await expect
      .poll(() =>
        page.evaluate(() => {
          const editor = (
            window as unknown as {
              __isonimEditor?: { pendingSourceEdits?: () => number };
            }
          ).__isonimEditor;
          if (!editor?.pendingSourceEdits)
            throw new Error("Actual pending-source getter is missing");
          return editor.pendingSourceEdits();
        }),
      )
      .toBe(0);

    const lastValidSources = await actualDemoSources(page);
    await setInspectorProperty(page, "Effects", "filter", "glow(4px)", false);
    await nativeInspectorSection(page, "fill");
    await page.locator('[data-inspector-section-header="effects"]').click();
    await nativeInspectorSection(page, "effects");
    await expect(
      page.locator(
        '[data-inspector-section-body="effects"] [data-property-row-css-property="filter"] [data-property-row-message-visible="true"]',
      ),
    ).toContainText("Filter values must use supported CSS filter functions");
    await expect(
      page.locator('.editor-statusbar [data-save-error="true"]'),
    ).toHaveCount(1);
    await expect(
      page.locator('.editor-statusbar [data-save-error="true"]'),
    ).toBeHidden();
    await expect
      .poll(() =>
        page.evaluate(() => {
          const editor = (
            window as unknown as {
              __isonimEditor?: { pendingSourceEdits?: () => number };
            }
          ).__isonimEditor;
          if (!editor?.pendingSourceEdits)
            throw new Error("Actual pending-source getter is missing");
          return editor.pendingSourceEdits();
        }),
      )
      .toBe(0);
    expect(await actualDemoSources(page)).toEqual(lastValidSources);

    const afterShot = await page.screenshot({ fullPage: true });
    expect(
      afterShot.length,
      "long-tail evidence screenshot has bytes",
    ).toBeGreaterThan(20000);
    expect(
      Buffer.compare(beforeShot, afterShot),
      "long-tail edits produce a changed screenshot",
    ).not.toBe(0);
    expect(Object.keys(await actualDemoSources(page)).length).toBeGreaterThan(
      0,
    );
    await expect(
      page.locator('.editor-statusbar [data-save-error="true"]'),
    ).toHaveCount(1);
    await expect(
      page.locator('.editor-statusbar [data-save-error="true"]'),
    ).toBeHidden();
    await assertNoClippedEssentialText(page);
    await assertNoBodyScrollbar(page);
  });

  test("e2e_vector_editor_pointer_keyboard_and_rendering", async ({ page }) => {
    await page.goto("/?view=vector#vector-editor");
    await expect(page.getByText("Vector Editor")).toBeVisible();

    const host = page.locator('[data-vector-adapter="fabric"]').first();
    await expect(host).toHaveAttribute("data-vector-library-backed", "true");
    await expect(host).toHaveAttribute("data-vector-backend-version", "7.3.1");
    await expect(host).toHaveAttribute("data-vector-path-adapter", "paper");
    await expect(host).toHaveAttribute(
      "data-vector-path-library-backed",
      "true",
    );
    await expect(host).toHaveAttribute(
      "data-vector-path-backend-version",
      "0.12.18",
    );
    await expect(host).toHaveAttribute("data-vector-svgo-backed", "true");
    await expect(
      host.locator('canvas[data-vector-canvas="fabric"]'),
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Vector Union" }),
    ).toHaveAttribute("data-vector-action", "boolean-unite");

    const rect = page.getByRole("button", {
      name: "Select Rectangle vector tool",
    });
    await rect.click();
    await expect(rect).toHaveAttribute("aria-pressed", "true");
    await expect(host).toHaveAttribute("data-vector-tool", "rectangle");

    const box = await host.locator("canvas").first().boundingBox();
    expect(box).not.toBeNull();
    await page.mouse.move(box!.x + 125, box!.y + 150);
    await page.mouse.down();
    await page.mouse.move(box!.x + 178, box!.y + 180);
    await page.mouse.up();
    await expect(host).toHaveAttribute("data-selected-vector-object", /\w/);
    await expect(host).toHaveAttribute("data-vector-controls-visible", "true");

    const countBeforeImport = Number(
      await host.evaluate((node) =>
        node.getAttribute("data-vector-object-count"),
      ),
    );

    await page.getByRole("button", { name: "Vector import-sample" }).click();
    await expect(host).toHaveAttribute("data-vector-import-backed", "fabric");
    await expect
      .poll(async () =>
        Number(
          await host.evaluate((node) =>
            node.getAttribute("data-vector-imported-count"),
          ),
        ),
      )
      .toBeGreaterThan(1);

    const zoomBefore = Number(
      await host.evaluate((node) => node.getAttribute("data-vector-zoom")),
    );
    await page.getByRole("button", { name: "Vector zoom-in" }).click();
    await expect
      .poll(async () =>
        Number(
          await host.evaluate((node) => node.getAttribute("data-vector-zoom")),
        ),
      )
      .toBeGreaterThan(zoomBefore);

    const panBefore = Number(
      await host.evaluate((node) => node.getAttribute("data-vector-pan-x")),
    );
    await page.getByRole("button", { name: "Vector pan-right" }).click();
    await expect
      .poll(async () =>
        Number(
          await host.evaluate((node) => node.getAttribute("data-vector-pan-x")),
        ),
      )
      .toBeGreaterThan(panBefore);

    const vectorSourcePath =
      "examples/wanderlust/design-system/vector-symbols.svg";
    const sourceBeforeColorEdit = await host.evaluate((node) => {
      const editor = (
        node as HTMLElement & {
          __isonimVectorEditor?: { sourceSvg(): string };
        }
      ).__isonimVectorEditor;
      if (!editor)
        throw new Error("Real vector source serializer is unavailable");
      return editor.sourceSvg();
    });
    await test.info().attach("vector-source-before-color-edit", {
      body: sourceBeforeColorEdit,
      contentType: "image/svg+xml",
    });
    const writtenColorObjects = (source: string) =>
      page.evaluate((svg) => {
        const document = new DOMParser().parseFromString(svg, "image/svg+xml");
        if (document.querySelector("parsererror"))
          throw new Error(
            "Invalid written vector SVG (" +
              svg.length +
              " bytes): " +
              document.querySelector("parsererror")!.textContent,
          );
        return Array.from(document.querySelectorAll<SVGElement>("*")).filter(
          (node) =>
            node.style?.fill.replace(/\s/g, "").toLowerCase() ===
              "rgb(239,68,68)" &&
            node.style?.stroke.replace(/\s/g, "").toLowerCase() ===
              "rgb(34,197,94)",
        ).length;
      }, source);
    expect(await writtenColorObjects(sourceBeforeColorEdit)).toBe(0);
    await page.getByRole("button", { name: "Vector set-fill" }).click();
    await expect(host).toHaveAttribute("data-vector-active-fill", "#EF4444");
    await page.getByRole("button", { name: "Vector set-stroke" }).click();
    await expect(host).toHaveAttribute("data-vector-active-stroke", "#22C55E");
    await expect(host).toHaveAttribute("data-vector-source-dirty", "true");

    const vectorSourceState = page.locator("[data-vector-source-stage]");
    await expect(vectorSourceState).toHaveAttribute(
      "data-vector-source-stage",
      "wesClean",
    );
    await expect(vectorSourceState).toHaveAttribute(
      "data-vector-pending-source-edits",
      "0",
    );
    await expect
      .poll(() => demoSourceContent(page, vectorSourcePath))
      .not.toBe(sourceBeforeColorEdit);
    await expect
      .poll(async () =>
        writtenColorObjects(await demoSourceContent(page, vectorSourcePath)),
      )
      .toBe(1);
    await expect(host).toHaveAttribute("data-vector-source-saved", "true");

    await page
      .getByRole("button", { name: "Select Polygon vector tool" })
      .click();
    await expect(host).toHaveAttribute(
      "data-selected-vector-object",
      "drawn-polygon",
    );
    await page.getByRole("button", { name: "Select Star vector tool" }).click();
    await expect(host).toHaveAttribute(
      "data-selected-vector-object",
      "drawn-star",
    );

    const angleBefore = Number(
      await host.evaluate((node) =>
        node.getAttribute("data-vector-active-angle"),
      ),
    );
    await page
      .getByRole("button", { name: "Vector transform-selection" })
      .click();
    await expect
      .poll(async () =>
        Number(
          await host.evaluate((node) =>
            node.getAttribute("data-vector-active-angle"),
          ),
        ),
      )
      .toBeGreaterThan(angleBefore);

    const countBefore = Number(
      await host.evaluate((node) =>
        node.getAttribute("data-vector-object-count"),
      ),
    );
    expect(countBefore).toBeGreaterThan(countBeforeImport);

    await host.focus();
    await page.keyboard.press(
      process.platform === "darwin" ? "Meta+D" : "Control+D",
    );
    await expect
      .poll(async () =>
        Number(
          await host.evaluate((node) =>
            node.getAttribute("data-vector-object-count"),
          ),
        ),
      )
      .toBeGreaterThan(countBefore);

    await page.getByRole("button", { name: "Vector export" }).click();
    await expect(host).toHaveAttribute("data-vector-export-has-svg", "true");
    await expect(host).toHaveAttribute("data-vector-export-optimized", "true");
    await expect
      .poll(async () =>
        Number(
          await host.evaluate((node) =>
            node.getAttribute("data-vector-svg-length"),
          ),
        ),
      )
      .toBeGreaterThan(100);

    const paperBooleanActions = [
      ["Vector Union", "unite"],
      ["Vector Sub", "subtract"],
      ["Vector Inter", "intersect"],
      ["Vector Excl", "exclude"],
    ] as const;
    for (const [buttonName, operation] of paperBooleanActions) {
      await page.getByRole("button", { name: buttonName }).click();
      await expect(host).toHaveAttribute(
        "data-vector-path-operation-backed",
        "paper",
      );
      await expect(host).toHaveAttribute(
        "data-vector-path-operation",
        operation,
      );
      await expect(host).toHaveAttribute(
        "data-vector-path-export-has-path",
        "true",
      );
      await expect
        .poll(async () =>
          Number(
            await host.evaluate((node) =>
              node.getAttribute("data-vector-path-data-length"),
            ),
          ),
        )
        .toBeGreaterThan(10);
    }

    const sourceBeforeSegmentEdit = await host.evaluate((node) => {
      const editor = (
        node as HTMLElement & {
          __isonimVectorEditor?: { sourceSvg(): string };
        }
      ).__isonimVectorEditor;
      if (!editor)
        throw new Error("Real vector source serializer is unavailable");
      return editor.sourceSvg();
    });
    await page.getByRole("button", { name: "Vector move-segment" }).click();
    await expect(host).toHaveAttribute(
      "data-vector-path-operation",
      "move-segment",
    );
    const sourceAfterSegmentEdit = await host.evaluate((node) => {
      const editor = (
        node as HTMLElement & {
          __isonimVectorEditor?: { sourceSvg(): string };
        }
      ).__isonimVectorEditor;
      if (!editor)
        throw new Error("Real vector source serializer is unavailable");
      return editor.sourceSvg();
    });
    expect(sourceAfterSegmentEdit).not.toBe(sourceBeforeSegmentEdit);
    const svgStructure = (
      source: string,
      corrupt?: "path" | "text" | "document-pi" | "text-space",
    ) =>
      page.evaluate(
        ({ source, corrupt }) => {
          const document = new DOMParser().parseFromString(
            source,
            "image/svg+xml",
          );
          if (document.querySelector("parsererror"))
            throw new Error("Invalid source SVG");
          if (corrupt === "path") {
            const path = document.querySelector("path");
            if (!path) throw new Error("Path sensitivity requires a real path");
            path.setAttribute("transform", "translate(9999 0)");
          }
          if (corrupt === "text") {
            const text = document.querySelector("tspan");
            if (!text) throw new Error("Text sensitivity requires real text");
            text.textContent += " changed";
          }
          if (corrupt === "document-pi") {
            document.insertBefore(
              document.createProcessingInstruction("fixture", "changed"),
              document.documentElement,
            );
          }
          if (corrupt === "text-space") {
            const text = document.querySelector("tspan");
            if (!text)
              throw new Error("Whitespace sensitivity requires real text");
            text.appendChild(document.createTextNode(" "));
          }
          // This compares SVG content, not general XML byte/DOM identity. Only
          // ASCII layout between SVG graphical-container children is irrelevant.
          // All text in text/title/desc, foreign/unknown elements, and xml:space
          // values remains exact; inherited preservation in text is never trimmed.
          const svgNamespace = "http://www.w3.org/2000/svg";
          const structure = (
            node: Node,
            graphicalLayout = false,
            protectedContext = false,
          ): unknown => {
            if (node.nodeType === Node.DOCUMENT_TYPE_NODE) {
              const doctype = node as DocumentType;
              return [
                node.nodeType,
                doctype.name,
                doctype.publicId,
                doctype.systemId,
              ];
            }
            if (node.nodeType === Node.ELEMENT_NODE) {
              const element = node as Element;
              const childLayout =
                !protectedContext &&
                element.namespaceURI === svgNamespace &&
                ["svg", "g", "defs"].includes(element.localName);
              const childProtected = protectedContext || !childLayout;
              return [
                element.namespaceURI,
                element.localName,
                Array.from(element.attributes)
                  .map((attribute) => [
                    attribute.namespaceURI,
                    attribute.localName,
                    attribute.value,
                  ])
                  .sort(),
                Array.from(element.childNodes)
                  .map((child) => structure(child, childLayout, childProtected))
                  .filter((child) => child !== null),
              ];
            }
            const value = node.nodeValue ?? "";
            if (
              node.nodeType === Node.TEXT_NODE &&
              graphicalLayout &&
              /^[\t\n\r ]*$/.test(value)
            )
              return null;
            return [node.nodeType, node.nodeName, value];
          };
          return Array.from(document.childNodes).map((node) => structure(node));
        },
        { source, corrupt },
      );
    const expectedSourceStructure = await svgStructure(sourceAfterSegmentEdit);
    expect(await svgStructure(sourceAfterSegmentEdit, "path")).not.toEqual(
      expectedSourceStructure,
    );
    expect(await svgStructure(sourceAfterSegmentEdit, "text")).not.toEqual(
      expectedSourceStructure,
    );
    expect(
      await svgStructure(sourceAfterSegmentEdit, "document-pi"),
    ).not.toEqual(expectedSourceStructure);
    expect(
      await svgStructure(sourceAfterSegmentEdit, "text-space"),
    ).not.toEqual(expectedSourceStructure);
    await expect
      .poll(async () =>
        svgStructure(await demoSourceContent(page, vectorSourcePath)),
      )
      .toEqual(expectedSourceStructure);
    await expect(vectorSourceState).toHaveAttribute(
      "data-vector-source-stage",
      "wesClean",
    );
    await expect(vectorSourceState).toHaveAttribute(
      "data-vector-pending-source-edits",
      "0",
    );

    const countBeforeDelete = Number(
      await host.evaluate((node) =>
        node.getAttribute("data-vector-object-count"),
      ),
    );
    await page.getByRole("button", { name: "Vector delete" }).click();
    await expect
      .poll(async () =>
        Number(
          await host.evaluate((node) =>
            node.getAttribute("data-vector-object-count"),
          ),
        ),
      )
      .toBe(countBeforeDelete - 1);
  });

  test("e2e_vector_path_browser_handle_polish", async ({ page }) => {
    await page.setViewportSize(desktop);
    await page.goto("/?view=vector#vector-editor");
    const host = page.locator('[data-vector-adapter="fabric"]').first();
    await expect(host).toHaveAttribute(
      "data-vector-path-library-backed",
      "true",
    );
    await assertVectorPathHandlesVisible(page);
    const beforePaperPath = await host.evaluate((node) => {
      const editor = (node as any).__isonimVectorEditor;
      return {
        pathData: editor.paperPath.pathData,
        segmentCount: editor.paperPath.segments.length,
        backedByPaper:
          editor.paperPath &&
          editor.paperEditScope &&
          typeof editor.paperPath.insert === "function" &&
          typeof editor.paperPath.exportSVG === "function" &&
          typeof editor.paperEditScope.Path === "function",
        firstX: editor.paperPath.segments[0].point.x,
        firstY: editor.paperPath.segments[0].point.y,
      };
    });
    expect(beforePaperPath.backedByPaper).toBe(true);
    expect(beforePaperPath.segmentCount).toBeGreaterThanOrEqual(3);
    expect(beforePaperPath.pathData).toContain("M");

    const beforeBox = await host.boundingBox();
    expect(beforeBox).not.toBeNull();
    const firstAnchor = host.locator('[data-vector-anchor="node-0"]');
    const anchorBox = await firstAnchor.boundingBox();
    expect(anchorBox).not.toBeNull();
    await page.mouse.move(
      anchorBox!.x + anchorBox!.width / 2,
      anchorBox!.y + anchorBox!.height / 2,
    );
    await page.mouse.down();
    await page.mouse.move(anchorBox!.x + 32, anchorBox!.y + 18);
    await page.mouse.up();
    await expect(host).toHaveAttribute("data-vector-path-pointer-drag", "true");
    const draggedPaperPath = await host.evaluate((node) => {
      const editor = (node as any).__isonimVectorEditor;
      return {
        pathData: editor.paperPath.pathData,
        firstX: editor.paperPath.segments[0].point.x,
        firstY: editor.paperPath.segments[0].point.y,
      };
    });
    expect(draggedPaperPath.pathData).not.toBe(beforePaperPath.pathData);
    expect(draggedPaperPath.firstX).toBeGreaterThan(beforePaperPath.firstX);
    expect(draggedPaperPath.firstY).toBeGreaterThan(beforePaperPath.firstY);
    await expect
      .poll(async () =>
        Number(await host.getAttribute("data-vector-path-data-length")),
      )
      .toBeGreaterThan(10);

    await page.getByRole("button", { name: "Vector path-insert" }).click();
    await expect(host).toHaveAttribute(
      "data-vector-path-operation",
      "insert-node",
    );
    await expect
      .poll(async () =>
        Number(await host.getAttribute("data-vector-path-anchor-count")),
      )
      .toBeGreaterThanOrEqual(4);
    await page
      .getByRole("button", { name: "Vector path-convert-smooth" })
      .click();
    await expect(host).toHaveAttribute(
      "data-vector-path-operation",
      "convert-smooth",
    );
    await expect
      .poll(async () =>
        Number(await host.getAttribute("data-vector-path-handle-count")),
      )
      .toBeGreaterThanOrEqual(2);
    await page.getByRole("button", { name: "Vector path-handle-drag" }).click();
    await expect(host).toHaveAttribute(
      "data-vector-path-operation",
      "drag-handle",
    );
    const handleEdit = await host.evaluate((node) => {
      const editor = (node as any).__isonimVectorEditor;
      const selected = Array.from(editor.selectedSegmentIndices)[0] as number;
      const segment = editor.paperPath.segments[selected];
      return {
        backedByPaper:
          editor.paperPath &&
          editor.paperEditScope &&
          typeof editor.paperPath.insert === "function" &&
          typeof editor.paperPath.exportSVG === "function" &&
          typeof editor.paperEditScope.Path === "function",
        handleOutX: segment.handleOut.x,
        handleOutY: segment.handleOut.y,
        pathData: editor.paperPath.pathData,
      };
    });
    expect(handleEdit.backedByPaper).toBe(true);
    expect(Math.abs(handleEdit.handleOutX)).toBeGreaterThan(0);
    expect(Math.abs(handleEdit.handleOutY)).toBeGreaterThan(0);

    await host.focus();
    await page.keyboard.press("ArrowRight");
    await expect(host).toHaveAttribute(
      "data-vector-path-keyboard-operation",
      "nudge-node",
    );
    const nudgedPaperPath = await host.evaluate((node) => {
      const editor = (node as any).__isonimVectorEditor;
      return editor.paperPath.pathData;
    });
    expect(nudgedPaperPath).not.toBe(handleEdit.pathData);
    const undoDepth = Number(
      await host.getAttribute("data-vector-path-undo-depth"),
    );
    expect(undoDepth).toBeGreaterThan(0);
    await page.keyboard.press(
      process.platform === "darwin" ? "Meta+Z" : "Control+Z",
    );
    await expect(host).toHaveAttribute(
      "data-vector-path-keyboard-operation",
      "path-undo",
    );
    const undoPaperPath = await host.evaluate((node) => {
      const editor = (node as any).__isonimVectorEditor;
      return editor.paperPath.pathData;
    });
    expect(undoPaperPath).toBe(handleEdit.pathData);
    await page.getByRole("button", { name: "Vector path-redo" }).click();
    await expect(host).toHaveAttribute(
      "data-vector-path-keyboard-operation",
      "path-redo",
    );
    const redoPaperPath = await host.evaluate((node) => {
      const editor = (node as any).__isonimVectorEditor;
      return editor.paperPath.pathData;
    });
    expect(redoPaperPath).toBe(nudgedPaperPath);

    await page.getByRole("button", { name: "Vector zoom-in" }).click();
    await page.getByRole("button", { name: "Vector zoom-in" }).click();
    await assertVectorPathHandlesVisible(page);
    const afterBox = await host.boundingBox();
    expect(
      afterBox!.width,
      "path operations keep vector host width stable",
    ).toBe(beforeBox!.width);
    expect(
      afterBox!.height,
      "path operations keep vector host height stable",
    ).toBe(beforeBox!.height);
    await assertVectorCanvasHasPixels(page);
    const screenshot = await page.screenshot({ fullPage: true });
    expect(
      screenshot.length,
      "vector path screenshot has content",
    ).toBeGreaterThan(20_000);
  });

  test("e2e_editor_visual_baselines_cover_all_primary_modes", async ({
    page,
  }) => {
    await page.setViewportSize(desktop);
    await page.goto("/");
    await expect(page.locator('[data-figma-canvas="true"]')).toBeVisible();
    await expectStableVisualSnapshot(page, "m43-shell-desktop.png");

    await page.setViewportSize(laptop);
    await page.goto("/");
    await expect(page.locator(".editor-sidebar")).toBeVisible();
    await expectStableVisualSnapshot(page, "m43-shell-laptop.png");

    await page.setViewportSize(tablet);
    await page.goto("/");
    await expect(page.locator(".editor-sidebar")).toBeVisible();
    await expectStableVisualSnapshot(page, "m43-shell-tablet.png");

    await page.setViewportSize(mobileWidth);
    await page.goto("/");
    await expect(page.locator(".editor-sidebar")).toBeVisible();
    await expect(page.locator(".editor-preview:visible")).toHaveCount(0);
    await expectStableVisualSnapshot(page, "m43-shell-mobile-width.png");

    await page.setViewportSize(desktop);
    await openDestinationComponentEdit(page);
    const visualSelectionFrame = page.frameLocator(
      'iframe[title="Editable component preview"]',
    );
    await visualSelectionFrame
      .getByTestId("component-edit-preview")
      .click({ position: { x: 8, y: 8 } });
    await expect(
      visualSelectionFrame.getByTestId("component-edit-preview"),
    ).toHaveAttribute("data-isonim-selected", "true");
    const nativeLayout = await nativeInspectorSection(page, "layout");
    await expect(
      nativeLayout.getByRole("button", {
        name: "Bind Padding to variable",
        exact: true,
      }),
    ).toBeVisible();
    await expect(
      nativeLayout.getByRole("group", {
        name: "Choose source scope for Padding",
        exact: true,
      }),
    ).toBeVisible();
    await expect(page.locator('[data-scene-graph="true"]')).toBeVisible();
    await expectStableVisualSnapshot(page, "m55-compact-inspector.png");
    await nativeLayout
      .getByRole("button", { name: "Bind Padding to variable", exact: true })
      .click();
    const visualPicker = page.locator('[data-variable-picker="true"]');
    await expect(visualPicker).toHaveAttribute(
      "data-variable-picker-open",
      "true",
    );
    await expect
      .poll(() => visualPicker.locator("[data-variable-picker-row]").count())
      .toBeGreaterThan(0);
    await expectStableVisualSnapshot(
      page,
      "m43-edit-inspector-token-style-layers.png",
    );
    await visualPicker
      .getByRole("button", { name: "Close variable picker", exact: true })
      .click();
    await expect(visualPicker).toHaveAttribute(
      "data-variable-picker-open",
      "false",
    );
    const sharedEditFrame = page.frameLocator(
      'iframe[title="Editable component preview"]',
    );
    await sharedEditFrame
      .getByTestId("component-edit-preview")
      .click({ position: { x: 8, y: 8 } });
    await expect(
      sharedEditFrame.getByTestId("component-edit-preview"),
    ).toHaveAttribute("data-isonim-selected", "true");
    await expect(
      sharedEditFrame.locator('[data-isonim-selected="true"]'),
    ).toBeVisible();
    const initialStyle = await previewStyle(page);
    expect(initialStyle, "initial preview style").not.toBeNull();
    expect(initialStyle!.padding).toBe("18px");
    expect(initialStyle!.source).not.toBe("");
    const beforeSources = await actualDemoSources(page);
    const layout = await nativeInspectorSection(page, "layout");
    const padding = layout.getByRole("textbox", {
      name: "Edit Padding",
      exact: true,
    });
    const impact = layout.locator('[data-property-source-impact="padding"]');
    // This real metadata is visible BEFORE a scope choice may immediately commit.
    await expect(impact).toBeVisible();
    for (const text of [
      "Shared class",
      "destination-card",
      demoFoundationSource,
      "classes.destination-card.padding",
      "4 mapped uses",
      "DestinationCard",
      "Other uses of this shared source may change.",
    ])
      await expect(impact).toContainText(text);
    await expectStableVisualSnapshot(page, "m55-scope-selector.png");
    await expectStableElementSnapshot(page, impact, "m55-impact-panel.png");
    await layout
      .getByRole("button", {
        name: "Apply shared class scope for padding",
        exact: true,
      })
      .click();
    await expect(impact).toContainText("Shared class (selected)");
    const writtenPadding = async () =>
      page.evaluate((file) => {
        const sources = (
          window as unknown as { __isonimDemoSources?: Record<string, string> }
        ).__isonimDemoSources;
        if (!sources?.[file])
          throw new Error("Actual project stylesheet receipt is missing");
        const sheet = new CSSStyleSheet();
        sheet.replaceSync(sources[file]);
        const rules = Array.from(sheet.cssRules).filter(
          (rule): rule is CSSStyleRule =>
            rule instanceof CSSStyleRule &&
            rule.selectorText === ".destination-card",
        );
        if (rules.length !== 1)
          throw new Error("Expected exactly one actual shared class rule");
        return rules[0].style.getPropertyValue("padding");
      }, demoFoundationSource);
    const pending = async () =>
      page.evaluate(() => {
        const editor = (
          window as unknown as {
            __isonimEditor?: { pendingSourceEdits?: () => number };
          }
        ).__isonimEditor;
        if (!editor?.pendingSourceEdits)
          throw new Error("Actual pending-source getter is missing");
        return editor.pendingSourceEdits();
      });
    await padding.fill("24px");
    await padding.press("Enter");
    await expect
      .poll(async () => (await previewStyle(page))?.padding)
      .toBe("24px");
    const editedStyle = await previewStyle(page);
    expect(editedStyle!.height).toBeGreaterThan(initialStyle!.height);
    // Automatic saving replaces removed manual Save/pending-only chrome. These
    // are the actual owning adapter's written bytes, not an expected diff string.
    await expect.poll(writtenPadding).toBe("24px");
    await expect.poll(pending).toBe(0);
    const saved24 = await actualDemoSources(page);
    expect(saved24[demoFoundationSource]).not.toBe(
      beforeSources[demoFoundationSource],
    );
    expect(Object.keys(saved24).sort()).toEqual(
      Object.keys(beforeSources).sort(),
    );
    for (const [file, text] of Object.entries(beforeSources)) {
      if (file !== demoFoundationSource) expect(saved24[file]).toBe(text);
    }
    const saveError = page.locator(
      '.editor-statusbar [data-save-error="true"]',
    );
    await expect(saveError).toHaveCount(1);
    await expect(saveError).toBeHidden();
    await expectStableElementSnapshot(
      page,
      layout.locator('[data-property-row="padding"]'),
      "m55-shared-edit-review.png",
    );
    await sharedEditFrame
      .getByTestId("component-edit-preview")
      .click({ position: { x: 8, y: 8 } });
    await expect(
      sharedEditFrame.getByTestId("component-edit-preview"),
    ).toHaveAttribute("data-isonim-selected", "true");
    await padding.fill("30px");
    await padding.press("Enter");
    await expect
      .poll(async () => (await previewStyle(page))?.padding)
      .toBe("30px");
    await expect.poll(writtenPadding).toBe("30px");
    await expect.poll(pending).toBe(0);
    const saved30 = await actualDemoSources(page);
    expect(saved30[demoFoundationSource]).not.toBe(
      saved24[demoFoundationSource],
    );
    expect(Object.keys(saved30).sort()).toEqual(Object.keys(saved24).sort());
    for (const [file, text] of Object.entries(saved24)) {
      if (file !== demoFoundationSource) expect(saved30[file]).toBe(text);
    }
    // Published Saving preserves written history: Revert discards only pending
    // work. Observe that refusal through the real command palette, then Undo
    // the written edit through the normal keyboard path outside the text field.
    await page
      .getByRole("button", { name: "Toggle left sidebar", exact: true })
      .focus();
    await page.keyboard.press("ControlOrMeta+k");
    await page
      .getByRole("textbox", { name: "Search editor commands", exact: true })
      .fill("Revert");
    const revert = page.locator(
      '[data-editor-command-palette="true"] [data-command-kind="eckRevert"]',
    );
    await expect(revert).toBeVisible();
    await expect(revert).toHaveAttribute("aria-disabled", "true");
    await expect(revert).toHaveAttribute(
      "data-command-diagnostic",
      "There are no edits to discard.",
    );
    await page.keyboard.press("Escape");
    expect(await actualDemoSources(page)).toEqual(saved30);
    await page
      .getByRole("button", { name: "Toggle left sidebar", exact: true })
      .focus();
    await page.keyboard.press("ControlOrMeta+z");
    await expect
      .poll(async () => (await previewStyle(page))?.padding)
      .toBe("24px");
    await expect.poll(() => actualDemoSources(page)).toEqual(saved24);
    await expect.poll(pending).toBe(0);
    await expect.poll(writtenPadding).toBe("24px");
    await expect(saveError).toHaveCount(1);
    await expect(saveError).toBeHidden();
    // Original downstream visual states followed Revert to the initial18px.
    // Automatic saving uses real written history; restore the same exact initial
    // adapter bytes before the narrow/comment/AI/API/token/vector states.
    await page
      .getByRole("button", { name: "Toggle left sidebar", exact: true })
      .focus();
    await page.keyboard.press("ControlOrMeta+z");
    await expect
      .poll(async () => (await previewStyle(page))?.padding)
      .toBe("18px");
    await expect.poll(() => actualDemoSources(page)).toEqual(beforeSources);
    await expect.poll(pending).toBe(0);
    await expect.poll(writtenPadding).toBe("18px");
    await expect(saveError).toHaveCount(1);
    await expect(saveError).toBeHidden();
    const panelBox = await page
      .locator(".editor-manual-inspector")
      .boundingBox();
    expect(panelBox).not.toBeNull();
    const resize = page.locator(
      '.editor-manual-inspector [data-resize-handle="right-panel"]',
    );
    await expect(resize).toHaveCount(1);
    const resizeBox = await resize.boundingBox();
    expect(resizeBox).not.toBeNull();
    const resizeX = resizeBox!.x + resizeBox!.width / 2;
    const resizeY = resizeBox!.y + Math.min(40, resizeBox!.height / 2);
    await page.mouse.move(resizeX, resizeY);
    await page.mouse.down();
    await page.mouse.move(resizeX + panelBox!.width - 280, resizeY, {
      steps: 5,
    });
    await page.mouse.up();
    await expect(page.locator(".editor-manual-inspector")).toHaveAttribute(
      "data-right-panel-width",
      "280",
    );
    // Refresh the real hover annotation after history changes, then leave the
    // pointer in the iframe background so stale pre-Undo labels are not captured.
    const restoredFrame = page.frameLocator(
      'iframe[title="Editable component preview"]',
    );
    await restoredFrame
      .getByTestId("component-edit-preview")
      .hover({ position: { x: 8, y: 8 } });
    const restoredFrameBox = await page
      .locator('iframe[title="Editable component preview"]')
      .boundingBox();
    expect(restoredFrameBox).not.toBeNull();
    await page.mouse.move(
      restoredFrameBox!.x + restoredFrameBox!.width - 8,
      restoredFrameBox!.y + restoredFrameBox!.height - 8,
    );
    await expect
      .poll(async () => (await previewStyle(page))?.padding)
      .toBe("18px");
    await expectStableVisualSnapshot(page, "m43-narrow-right-panel.png");

    await openDestinationComponentEdit(page);
    await previewMode(page, "Comment").click();
    const editFrame = page.frameLocator(
      'iframe[title="Editable component preview"]',
    );
    await editFrame
      .getByTestId("component-edit-preview")
      .click({ position: { x: 8, y: 8 } });
    await expect(
      editFrame.getByLabel("Comment on selected element"),
    ).toBeVisible();
    await expectStableVisualSnapshot(page, "m43-comment-mode-popover.png");

    await page.goto("/");
    await page
      .getByRole("textbox", { name: "Agent prompt" })
      .fill("Review the selected editor state visually");
    await page.getByRole("button", { name: "Send agent prompt" }).click();
    await expect(page.getByText("Agent Proposed Edits")).toBeVisible();
    const assistantResponse = page.locator(
      '[data-chat-entry][data-chat-role="arAssistant"]',
    );
    await expect(assistantResponse).toHaveCount(1);
    await expect(
      assistantResponse.locator('[data-chat-activity-status="true"]'),
    ).toHaveText("completed");
    await expect(page.locator('[data-chat-session-status="true"]')).toHaveText(
      "Ready for next message",
    );
    await expectStableVisualSnapshot(page, "m43-ai-mode-proposals.png");

    await openDestinationComponentDetail(page);
    await expectStableVisualSnapshot(page, "m55-component-api-editor.png");
    const variantMatrix = page.locator(
      '[data-component-variant-matrix="true"]',
    );
    await expect(variantMatrix).toHaveCount(1);
    await variantMatrix.scrollIntoViewIfNeeded();
    await expect(variantMatrix).toBeVisible();
    expect(
      await variantMatrix
        .locator("[data-component-variant-matrix-cell]")
        .count(),
    ).toBeGreaterThan(0);
    await variantMatrix
      .locator("[data-component-variant-matrix-cell]")
      .first()
      .scrollIntoViewIfNeeded();
    await expect(
      variantMatrix.locator("[data-component-variant-matrix-cell]").first(),
    ).toBeInViewport();
    await expectStableVisualSnapshot(page, "m43-component-variant-matrix.png");

    await page.goto("/?view=foundations#foundations");
    await page
      .getByRole("button", { name: "Select foundation category Color" })
      .click();
    await page
      .getByRole("button", { name: "Select foundation token color.blue.600" })
      .click();
    await expect(
      page.getByRole("textbox", { name: "Foundation token value" }),
    ).toBeVisible();
    await expectStableVisualSnapshot(page, "m55-token-editor.png");

    await page.goto("/?view=vector#vector-editor");
    await expect(page.locator('[data-vector-adapter="fabric"]')).toBeVisible();
    await assertVectorCanvasHasPixels(page);
    await expectStableVisualSnapshot(page, "m43-vector-editor.png");
  });

  test("m52_shared_design_editor_preview_save_and_revert", async ({ page }) => {
    await page.setViewportSize(desktop);
    await openDestinationComponentEdit(page);
    const editFrame = page.frameLocator(
      'iframe[title="Editable component preview"]',
    );
    await editFrame
      .getByTestId("component-edit-preview")
      .click({ position: { x: 8, y: 8 } });
    await expect(
      editFrame.getByTestId("component-edit-preview"),
    ).toHaveAttribute("data-isonim-selected", "true");
    await expect(
      editFrame.locator('[data-isonim-selected="true"]'),
    ).toBeVisible();
    const initialStyle = await previewStyle(page);
    expect(initialStyle, "initial preview style").not.toBeNull();
    expect(initialStyle!.padding).toBe("18px");
    expect(initialStyle!.source).not.toBe("");
    const beforeSources = await actualDemoSources(page);
    const layout = await nativeInspectorSection(page, "layout");
    const padding = layout.getByRole("textbox", {
      name: "Edit Padding",
      exact: true,
    });
    const impact = layout.locator('[data-property-source-impact="padding"]');
    // This real metadata is visible BEFORE a scope choice may immediately commit.
    await expect(impact).toBeVisible();
    for (const text of [
      "Shared class",
      "destination-card",
      demoFoundationSource,
      "classes.destination-card.padding",
      "4 mapped uses",
      "DestinationCard",
      "Other uses of this shared source may change.",
    ])
      await expect(impact).toContainText(text);
    await layout
      .getByRole("button", {
        name: "Apply shared class scope for padding",
        exact: true,
      })
      .click();
    await expect(impact).toContainText("Shared class (selected)");
    const writtenPadding = async () =>
      page.evaluate((file) => {
        const sources = (
          window as unknown as { __isonimDemoSources?: Record<string, string> }
        ).__isonimDemoSources;
        if (!sources?.[file])
          throw new Error("Actual project stylesheet receipt is missing");
        const sheet = new CSSStyleSheet();
        sheet.replaceSync(sources[file]);
        const rules = Array.from(sheet.cssRules).filter(
          (rule): rule is CSSStyleRule =>
            rule instanceof CSSStyleRule &&
            rule.selectorText === ".destination-card",
        );
        if (rules.length !== 1)
          throw new Error("Expected exactly one actual shared class rule");
        return rules[0].style.getPropertyValue("padding");
      }, demoFoundationSource);
    const pending = async () =>
      page.evaluate(() => {
        const editor = (
          window as unknown as {
            __isonimEditor?: { pendingSourceEdits?: () => number };
          }
        ).__isonimEditor;
        if (!editor?.pendingSourceEdits)
          throw new Error("Actual pending-source getter is missing");
        return editor.pendingSourceEdits();
      });
    await padding.fill("24px");
    await padding.press("Enter");
    await expect
      .poll(async () => (await previewStyle(page))?.padding)
      .toBe("24px");
    const editedStyle = await previewStyle(page);
    expect(editedStyle!.height).toBeGreaterThan(initialStyle!.height);
    // Automatic saving replaces removed manual Save/pending-only chrome. These
    // are the actual owning adapter's written bytes, not an expected diff string.
    await expect.poll(writtenPadding).toBe("24px");
    await expect.poll(pending).toBe(0);
    const saved24 = await actualDemoSources(page);
    expect(saved24[demoFoundationSource]).not.toBe(
      beforeSources[demoFoundationSource],
    );
    expect(Object.keys(saved24).sort()).toEqual(
      Object.keys(beforeSources).sort(),
    );
    for (const [file, text] of Object.entries(beforeSources)) {
      if (file !== demoFoundationSource) expect(saved24[file]).toBe(text);
    }
    const saveError = page.locator(
      '.editor-statusbar [data-save-error="true"]',
    );
    await expect(saveError).toHaveCount(1);
    await expect(saveError).toBeHidden();
    await editFrame
      .getByTestId("component-edit-preview")
      .click({ position: { x: 8, y: 8 } });
    await expect(
      editFrame.getByTestId("component-edit-preview"),
    ).toHaveAttribute("data-isonim-selected", "true");
    await padding.fill("30px");
    await padding.press("Enter");
    await expect
      .poll(async () => (await previewStyle(page))?.padding)
      .toBe("30px");
    await expect.poll(writtenPadding).toBe("30px");
    await expect.poll(pending).toBe(0);
    const saved30 = await actualDemoSources(page);
    expect(saved30[demoFoundationSource]).not.toBe(
      saved24[demoFoundationSource],
    );
    expect(Object.keys(saved30).sort()).toEqual(Object.keys(saved24).sort());
    for (const [file, text] of Object.entries(saved24)) {
      if (file !== demoFoundationSource) expect(saved30[file]).toBe(text);
    }
    // Published Saving preserves written history: Revert discards only pending
    // work. Observe that refusal through the real command palette, then Undo
    // the written edit through the normal keyboard path outside the text field.
    await page
      .getByRole("button", { name: "Toggle left sidebar", exact: true })
      .focus();
    await page.keyboard.press("ControlOrMeta+k");
    await page
      .getByRole("textbox", { name: "Search editor commands", exact: true })
      .fill("Revert");
    const revert = page.locator(
      '[data-editor-command-palette="true"] [data-command-kind="eckRevert"]',
    );
    await expect(revert).toBeVisible();
    await expect(revert).toHaveAttribute("aria-disabled", "true");
    await expect(revert).toHaveAttribute(
      "data-command-diagnostic",
      "There are no edits to discard.",
    );
    await page.keyboard.press("Escape");
    expect(await actualDemoSources(page)).toEqual(saved30);
    await page
      .getByRole("button", { name: "Toggle left sidebar", exact: true })
      .focus();
    await page.keyboard.press("ControlOrMeta+z");
    await expect
      .poll(async () => (await previewStyle(page))?.padding)
      .toBe("24px");
    await expect.poll(() => actualDemoSources(page)).toEqual(saved24);
    await expect.poll(pending).toBe(0);
    await expect.poll(writtenPadding).toBe("24px");
    await expect(saveError).toHaveCount(1);
    await expect(saveError).toBeHidden();
  });

  test("e2e_editor_ui_quality_no_overlap_or_unexpected_scrollbars", async ({
    page,
  }) => {
    await page.setViewportSize(desktop);
    await openDestinationComponentEdit(page);
    await assertVisibleBox(
      page.locator('iframe[title="Editable component preview"]'),
      "component edit preview iframe",
    );
    await assertVisibleBox(
      page.locator(".editor-manual-inspector"),
      "manual inspector",
    );
    const frame = page.frameLocator(
      'iframe[title="Editable component preview"]',
    );
    await frame
      .getByTestId("component-edit-preview")
      .click({ position: { x: 8, y: 8 } });
    await expect(frame.getByTestId("component-edit-preview")).toHaveAttribute(
      "data-isonim-selected",
      "true",
    );
    const layout = await nativeInspectorSection(page, "layout");
    // Current published inspector uses a variable popover and inline source
    // choices; the removed all-in-one manager labels no longer name its UI.
    await layout
      .getByRole("button", { name: "Bind Padding to variable", exact: true })
      .click();
    const picker = page.locator('[data-variable-picker="true"]');
    await expect(picker).toHaveCount(1);
    await assertVisibleBox(picker, "native variable picker");
    await expect(picker).toHaveAttribute("data-variable-picker-open", "true");
    await expect
      .poll(() => picker.locator("[data-variable-picker-row]").count())
      .toBeGreaterThan(0);
    await assertNoBodyScrollbar(page);
    const pickerBounds = await picker.evaluate((node) => {
      const box = node.getBoundingClientRect();
      return {
        left: box.left,
        top: box.top,
        right: box.right,
        bottom: box.bottom,
        viewportWidth: window.innerWidth,
        viewportHeight: window.innerHeight,
      };
    });
    expect(
      pickerBounds.left,
      "variable picker stays inside left viewport edge",
    ).toBeGreaterThan(-2);
    expect(
      pickerBounds.top,
      "variable picker stays inside top viewport edge",
    ).toBeGreaterThan(-2);
    expect(
      pickerBounds.right - pickerBounds.viewportWidth,
      "variable picker stays inside right viewport edge",
    ).toBeLessThan(2);
    expect(
      pickerBounds.bottom - pickerBounds.viewportHeight,
      "variable picker stays inside bottom viewport edge",
    ).toBeLessThan(2);
    await assertNoClippedEssentialText(page);
    await picker
      .getByRole("button", { name: "Close variable picker", exact: true })
      .click();
    await expect(picker).toHaveAttribute("data-variable-picker-open", "false");
    await assertVisibleBox(
      layout.getByRole("group", {
        name: "Choose source scope for Padding",
        exact: true,
      }),
      "native style source-scope choices",
    );
    await assertVisibleBox(
      layout.locator('[data-property-source-impact="padding"]'),
      "shared source impact",
    );
    await assertVisibleBox(
      page.locator('[data-scene-graph="true"]'),
      "native layers panel",
    );
    await assertNoBodyScrollbar(page);
    await assertNoEssentialOverlaps(page, [
      ".editor-manual-inspector",
      ".editor-preview",
      ".editor-preview iframe",
    ]);
    await assertNoClippedEssentialText(page);

    await frame
      .getByTestId("component-edit-preview")
      .click({ position: { x: 8, y: 8 } });
    await expect(frame.locator('[data-isonim-selected="true"]')).toBeVisible();
    await expect(
      frame.locator("#isonim-editor-selection-handles"),
    ).toBeVisible();
    await expect(
      frame.locator('[data-layout-guide="gap-overlay"]'),
    ).toBeVisible();
    await expect(
      frame.locator('[data-layout-guide="snap-lines"]'),
    ).toBeVisible();
    await expect(
      frame.locator('[data-layout-guide="spacing-measurement"]'),
    ).toBeVisible();

    const before = await page.locator(".editor-manual-inspector").boundingBox();
    await previewMode(page, "Comment").click();
    await expect(page.locator(".editor-chat")).toBeVisible();
    await previewMode(page, "Edit").click();
    await expect(page.locator(".editor-manual-inspector")).toBeVisible();
    const after = await page.locator(".editor-manual-inspector").boundingBox();
    expect(after!.width, "mode switch keeps right panel width stable").toBe(
      before!.width,
    );

    const panelBox = await page
      .locator(".editor-manual-inspector")
      .boundingBox();
    expect(panelBox).not.toBeNull();
    const resize = page.locator(
      '.editor-manual-inspector [data-resize-handle="right-panel"]',
    );
    await expect(resize).toHaveCount(1);
    const resizeBox = await resize.boundingBox();
    expect(resizeBox).not.toBeNull();
    const resizeX = resizeBox!.x + resizeBox!.width / 2;
    const resizeY = resizeBox!.y + Math.min(40, resizeBox!.height / 2);
    await page.mouse.move(resizeX, resizeY);
    await page.mouse.down();
    await page.mouse.move(resizeX + panelBox!.width - 280, resizeY, {
      steps: 5,
    });
    await page.mouse.up();
    await expect(page.locator(".editor-manual-inspector")).toHaveAttribute(
      "data-right-panel-width",
      "280",
    );
    await assertNoBodyScrollbar(page);
    await assertNoClippedEssentialText(page);

    await openDestinationComponentDetail(page);
    await assertVisibleBox(
      page.locator('[data-component-variant-matrix="true"]'),
      "variant matrix",
    );
    await assertNoBodyScrollbar(page);

    await page.goto("/?view=vector#vector-editor");
    await assertVisibleBox(
      page.locator('[data-vector-adapter="fabric"]'),
      "vector host",
    );
    await assertVectorCanvasHasPixels(page);
    await page
      .getByRole("button", { name: "Select Rectangle vector tool" })
      .click();
    const host = page.locator('[data-vector-adapter="fabric"]').first();
    const box = await host.locator("canvas").first().boundingBox();
    expect(box).not.toBeNull();
    await page.mouse.move(box!.x + 125, box!.y + 150);
    await page.mouse.down();
    await page.mouse.move(box!.x + 178, box!.y + 180);
    await page.mouse.up();
    await expect(host).toHaveAttribute("data-vector-controls-visible", "true");
    await assertVectorPathHandlesVisible(page);
    await page
      .getByRole("button", { name: "Vector path-convert-smooth" })
      .click();
    await expect(host).toHaveAttribute(
      "data-vector-path-operation",
      "convert-smooth",
    );
    await assertVectorPathHandlesVisible(page);
    await assertNoBodyScrollbar(page);

    await page.setViewportSize(mobileWidth);
    await page.goto("/");
    await expect(page.locator(".editor-sidebar")).toBeVisible();
    await expect(page.locator(".editor-preview:visible")).toHaveCount(0);
    await assertNoBodyScrollbar(page);
  });

  test("e2e_foundations_page_browser_editing", async ({ page }) => {
    await page.setViewportSize(desktop);
    await page.goto("/?view=foundations#foundations");
    await expect(page.locator('[data-foundations-page="true"]')).toBeVisible();

    for (const label of [
      "Color",
      "Semantic aliases",
      "Typography",
      "Spacing",
      "Radius",
      "Shadow",
      "Motion",
      "Breakpoints",
    ]) {
      const category = page.getByRole("button", {
        name: `Select foundation category ${label}`,
      });
      await expect(category).toBeVisible();
      await category.focus();
      await expect(category).toBeFocused();
      await category.click();
      await expect(category).toHaveAttribute("aria-pressed", "true");
      await expect(
        page.locator("[data-foundation-token]").first(),
      ).toBeVisible();
    }

    await page
      .getByRole("button", { name: "Select foundation category Color" })
      .click();
    await page
      .getByRole("button", { name: "Select foundation token color.blue.600" })
      .click();
    await expect(
      page.getByRole("textbox", { name: "Foundation token value" }),
    ).toHaveValue("#2563EB");

    await page
      .getByRole("textbox", { name: "Foundation token value" })
      .fill("not-a-color");
    await page
      .getByRole("button", { name: "Apply foundation token value" })
      .click();
    await expect(page.locator("[data-foundation-diagnostics]")).toContainText(
      "Color tokens must use a hex color or token alias",
    );

    const sourceBeforeTokenEdit = await demoSourceContent(
      page,
      demoFoundationSource,
    );
    await page
      .getByRole("textbox", { name: "Foundation token value" })
      .fill("#1D4ED8");
    await page
      .getByRole("button", { name: "Apply foundation token value" })
      .click();
    await expect(page.locator("[data-foundation-diagnostics]")).toContainText(
      "No diagnostics",
    );
    await expect(page.locator("[data-foundation-preview]")).toHaveAttribute(
      "style",
      /#1D4ED8/,
    );
    await expect
      .poll(() => demoSourceContent(page, demoFoundationSource))
      .toContain("#1D4ED8");

    await page
      .getByRole("button", { name: "Undo foundation token edit" })
      .click();
    await expect(
      page.getByRole("textbox", { name: "Foundation token value" }),
    ).toHaveValue("#2563EB");
    await expect
      .poll(() => demoSourceContent(page, demoFoundationSource))
      .toBe(sourceBeforeTokenEdit);

    await page
      .getByRole("textbox", { name: "Foundation token value" })
      .fill("#1D4ED8");
    await page
      .getByRole("button", { name: "Apply foundation token value" })
      .click();
    await expect
      .poll(() => demoSourceContent(page, demoFoundationSource))
      .toContain("#1D4ED8");

    const desktopShot = await page.screenshot({ fullPage: true });
    expect(desktopShot.length).toBeGreaterThan(10000);
    await page.setViewportSize(mobileWidth);
    const narrowShot = await page.screenshot({ fullPage: true });
    expect(narrowShot.length).toBeGreaterThan(5000);
  });

  test("preview_pane_top_toolbar_drives_mode_backend_and_viewport", async ({
    page,
  }) => {
    await page.setViewportSize(desktop);
    await page.goto("/?view=page");
    await expect(page.locator(".editor-sidebar")).toBeVisible();

    // Consolidated chrome bar at the top of the center column hosts
    // the view switcher AND all three chip groups (mode / backend /
    // viewport). The legacy left/right edge strips are gone.
    const chromeBar = page.locator('[data-preview-chrome-bar="true"]').first();
    await expect(chromeBar).toBeVisible();

    // Mode chips.
    const modeStrip = chromeBar.locator('[data-edge-strip="mode"]').first();
    await expect(modeStrip).toBeVisible();
    for (const slug of ["view", "comment", "edit"]) {
      await expect(
        modeStrip.locator(`[data-preview-mode="${slug}"]`),
      ).toHaveCount(1);
    }

    // Backend chips — all six PreviewBackend values.
    const backendStrip = chromeBar
      .locator('[data-edge-strip="backend"]')
      .first();
    await expect(backendStrip).toBeVisible();
    for (const id of ["web", "tui", "gpui", "freya", "cocoa", "android"]) {
      await expect(
        backendStrip.locator(`[data-preview-backend="${id}"]`),
      ).toHaveCount(1);
    }

    // Viewport chips — desktop/laptop/tablet/phone pinned for the web
    // backend, with an overflow chevron for the long-tail entries.
    const viewportStrip = chromeBar
      .locator('[data-edge-strip="viewport"]')
      .first();
    await expect(viewportStrip).toBeVisible();
    for (const slug of ["desktop", "laptop", "tablet", "phone"]) {
      await expect(
        viewportStrip
          .locator(
            `[data-preview-viewport="${slug}"]:not([data-compact-choice-overflow-option="true"])`,
          )
          .first(),
      ).toBeVisible();
    }
    await expect(
      viewportStrip.locator('[data-preview-viewport-overflow="true"]'),
    ).toBeVisible();
  });
});
