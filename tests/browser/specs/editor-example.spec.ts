import { test, expect, type Locator, type Page } from "@playwright/test";

const desktop = { width: 1440, height: 900 };
const laptop = { width: 1280, height: 800 };
const tablet = { width: 1024, height: 768 };
const mobileWidth = { width: 390, height: 844 };
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
  await page
    .getByRole("button", { name: "Open selected component in edit mode" })
    .click();
  await expect(page.locator(".editor-manual-inspector")).toBeVisible();
}

async function setInspectorProperty(
  page: Page,
  tab: string,
  property: string,
  value: string,
  expectAccepted = true,
) {
  await page.getByRole("tab", { name: `Show ${tab} edit controls` }).click();
  const input = page
    .getByRole("textbox", { name: `Edit inspector property ${property}` })
    .first();
  await expect(input).toBeVisible();
  await input.evaluate((node: HTMLInputElement, nextValue) => {
    node.value = String(nextValue);
    node.dispatchEvent(new Event("input", { bubbles: true }));
    node.dispatchEvent(new Event("change", { bubbles: true }));
    node.dispatchEvent(new Event("blur", { bubbles: true }));
  }, value);
  if (expectAccepted) {
    await expect(input).toHaveValue(value);
    await expect(page.getByText("Unsaved source edit")).toBeVisible();
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
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await expect(page.getByText("IsoNim Editor")).toBeVisible();
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
    await expect(page.getByText("AI Designer: Fake adapter")).toHaveCount(0);
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

    await expect(page.getByText("You: Apply the spacing edit")).toBeVisible();
    await expect(page.getByText("AI Designer: Fake adapter")).toBeVisible();
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
    await expect(page.getByText("agent-permission-1=granted")).toBeVisible();
    await page
      .getByRole("button", { name: "Accept agent edit agent-proposal-1" })
      .click();
    await expect(page.getByText("agent-proposal-1=accepted")).toBeVisible();
    await page
      .getByRole("button", { name: "Revert agent edit agent-proposal-1" })
      .click();
    await expect(page.getByText("agent-proposal-1=reverted")).toBeVisible();
    await expect(page.getByText("Connected / ready")).toBeVisible();
  });

  test("e2e_comment_review_ai_prompt_and_acceptance_flow", async ({ page }) => {
    await page.getByRole("button", { name: "Open Components section" }).click();
    await page
      .getByRole("button", { name: "Toggle DestinationCard stories" })
      .click();
    await page
      .getByRole("button", { name: "Select story DestinationCard / Default" })
      .click();
    await page
      .getByRole("button", { name: "Open selected component in edit mode" })
      .click();
    await expect(page.locator(".editor-manual-inspector")).toBeVisible();

    await page.getByRole("button", { name: "Switch to comment mode" }).click();
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
      page.getByText("review-annotation-1=open:included"),
    ).toBeVisible();

    await page
      .getByRole("button", {
        name: "Exclude review comment review-annotation-1",
      })
      .click();
    await expect(
      page.getByText("review-annotation-1=open:excluded"),
    ).toBeVisible();
    await page
      .getByRole("button", {
        name: "Include review comment review-annotation-1",
      })
      .click();
    await expect(
      page.getByText("review-annotation-1=open:included"),
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
    await expect(page.getByText("agent-proposal-1=accepted")).toBeVisible();
    await page
      .getByRole("button", {
        name: "Resolve review comment review-annotation-1",
      })
      .click();
    await expect(
      page.getByText("review-annotation-1=resolved:included"),
    ).toBeVisible();
  });

  test("e2e_editor_edit_buttons_keyboard_and_pointer", async ({ page }) => {
    await page
      .getByRole("button", { name: "Select story Pages / Destination Detail" })
      .click();

    const edit = page.getByRole("button", { name: "Switch to edit mode" });
    const view = page.getByRole("button", { name: "Switch to view mode" });

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
    await expect(
      page.getByRole("button", { name: "Switch to comment mode" }),
    ).toHaveAttribute("aria-pressed", "true");
    await page.keyboard.press("E");
    await expect(
      page.getByRole("button", { name: "Switch to edit mode" }),
    ).toHaveAttribute("aria-pressed", "true");

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
    const editModeButton = page.getByRole("button", {
      name: "Switch to edit mode",
    });
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
      .locator('[data-isonim-layer-selected="true"]')
      .first();
    const selectedBefore = await selectedLayer.getAttribute(
      "data-isonim-layer-id",
    );
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
          .locator('[data-isonim-layer-selected="true"]')
          .first()
          .getAttribute("data-isonim-layer-id"),
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
          .locator('[data-isonim-layer-selected="true"]')
          .first()
          .getAttribute("data-isonim-layer-id"),
      )
      .toBe(selectedBefore);

    await editModeButton.evaluate((node: HTMLElement) =>
      node.focus({ preventScroll: true }),
    );
    await expect(editModeButton).toBeFocused();
    await page.keyboard.press("V");
    await expect(
      page.getByRole("button", { name: "Switch to view mode" }),
    ).toHaveAttribute("aria-pressed", "true");

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

    const storyDuration = await page.evaluate(async () => {
      const target = document.querySelector<HTMLElement>(
        '[aria-label="Select story DestinationCard / Default"]',
      );
      const started = performance.now();
      target?.click();
      await new Promise((resolve) => requestAnimationFrame(resolve));
      return performance.now() - started;
    });
    expect(storyDuration).toBeLessThan(await budgetMs("epbkStorySelection"));

    const modeDuration = await page.evaluate(async () => {
      const target = document.querySelector<HTMLElement>(
        '[aria-label="Open selected component in edit mode"]',
      );
      const started = performance.now();
      target?.click();
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

    await page.getByRole("tab", { name: "Show Space edit controls" }).click();
    await page.evaluate(async () => {
      const input = document.querySelector<HTMLInputElement>(
        'input[aria-label="Edit inspector property padding"]',
      );
      if (input) {
        input.value = "28px";
        input.dispatchEvent(new Event("change", { bubbles: true }));
      }
      await new Promise((resolve) => requestAnimationFrame(resolve));
    });
    await expect(page.getByText("Unsaved source edit")).toBeVisible();
    await page
      .getByRole("button", { name: "Save inspector source edits" })
      .click();
    await expect(
      page.locator('[data-editor-telemetry-event="save and reload"]'),
    ).toBeVisible();
    const saveDetail = await page
      .locator('[data-editor-telemetry-event="save and reload"]')
      .last()
      .getAttribute("data-editor-telemetry-detail");
    expect(saveDetail ?? "").toMatch(/bridge-error:|preview-reload:/);
    await expect(page.locator(".editor-statusbar")).toContainText(
      saveDetail?.startsWith("bridge-error:") ? "write failed" : "clean",
    );

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
      .getByRole("textbox", { name: "Edit inspector property letter-spacing" })
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
        name: "Edit inspector property outline-offset",
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

    await setInspectorProperty(page, "Effects", "filter", "glow(4px)", false);
    await page.getByRole("tab", { name: "Show Fill edit controls" }).click();
    await page.getByRole("tab", { name: "Show Effects edit controls" }).click();
    await expect(
      page.locator('[data-isonim-edit-diagnostics="true"]'),
    ).toContainText("Filter values must use supported CSS filter functions");

    const afterShot = await page.screenshot({ fullPage: true });
    expect(
      afterShot.length,
      "long-tail evidence screenshot has bytes",
    ).toBeGreaterThan(20000);
    expect(
      Buffer.compare(beforeShot, afterShot),
      "long-tail edits produce a changed screenshot",
    ).not.toBe(0);
    await expect(page.getByText("Unsaved source edit")).toBeVisible();
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

    await page.getByRole("button", { name: "Vector set-fill" }).click();
    await expect(host).toHaveAttribute("data-vector-active-fill", "#EF4444");
    await page.getByRole("button", { name: "Vector set-stroke" }).click();
    await expect(host).toHaveAttribute("data-vector-active-stroke", "#22C55E");
    await expect(host).toHaveAttribute("data-vector-source-dirty", "true");

    const saveVector = page.getByRole("button", {
      name: "Save vector source edits",
    });
    await expect
      .poll(async () =>
        Number(
          await saveVector.evaluate((node) =>
            node.getAttribute("data-vector-pending-source-edits"),
          ),
        ),
      )
      .toBeGreaterThan(0);
    await saveVector.click();
    await expect(saveVector).toHaveAttribute(
      "data-vector-source-stage",
      "wesClean",
    );
    await expect(saveVector).toHaveAttribute(
      "data-vector-pending-source-edits",
      "0",
    );
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

    await page.getByRole("button", { name: "Vector move-segment" }).click();
    await expect(host).toHaveAttribute(
      "data-vector-path-operation",
      "move-segment",
    );
    await expect
      .poll(async () =>
        Number(
          await saveVector.evaluate((node) =>
            node.getAttribute("data-vector-pending-source-edits"),
          ),
        ),
      )
      .toBeGreaterThan(0);
    await saveVector.click();
    await expect(saveVector).toHaveAttribute(
      "data-vector-source-stage",
      "wesClean",
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
    await expect(
      page.getByLabel("Token manager", { exact: true }),
    ).toBeVisible();
    await expect(
      page.getByLabel(/Style class cascade token manager/),
    ).toBeVisible();
    await expect(page.getByLabel(/Element tree selected/)).toBeVisible();
    await expectStableVisualSnapshot(page, "m55-compact-inspector.png");
    await expectStableVisualSnapshot(
      page,
      "m43-edit-inspector-token-style-layers.png",
    );

    await page.getByRole("tab", { name: "Show Space edit controls" }).click();
    const paddingScopeGroup = page.getByRole("group", {
      name: "Choose source scope for padding",
      exact: true,
    });
    await expect(
      paddingScopeGroup.getByRole("button", {
        name: "Apply Shared class source scope for padding",
        exact: true,
      }),
    ).toBeVisible();
    await expectStableVisualSnapshot(page, "m55-scope-selector.png");
    await page.keyboard.press("Escape");

    const impact = page.locator('[data-design-system-impact="true"]');
    await expect(impact).toHaveAttribute(
      "data-shared-design-editor-count",
      /[1-9]/,
    );
    await expect(page.getByLabel("Shared design-system editors")).toContainText(
      "padding | Spacing",
    );
    await expect(impact).toContainText(/destination-card/i);
    await expect(impact).not.toContainText("+ padding: 24px");
    const initialCommitPreviewCount = Number(
      (await impact.getAttribute("data-shared-design-commit-preview-count")) ??
        "0",
    );
    await expectStableElementSnapshot(page, impact, "m55-impact-panel.png");

    const paddingInput = page
      .getByRole("textbox", {
        name: "Edit inspector property padding",
        exact: true,
      })
      .first();
    await expect(paddingInput).toBeVisible();
    await paddingInput.fill("");
    await paddingInput.fill("24px");
    await paddingInput.blur();
    await paddingScopeGroup
      .getByRole("button", {
        name: "Apply Shared class source scope for padding",
        exact: true,
      })
      .click();
    await expect(page.getByText("Unsaved source edit")).toBeVisible();
    await expect
      .poll(async () => (await previewStyle(page))?.padding)
      .toBe("24px");
    await expect(
      page.locator('[data-design-system-impact="true"]'),
    ).toContainText("DestinationCard");
    await expect
      .poll(async () =>
        Number(
          (await page
            .locator('[data-design-system-impact="true"]')
            .getAttribute("data-shared-design-commit-preview-count")) ?? "0",
        ),
      )
      .toBeGreaterThan(initialCommitPreviewCount);
    const sharedReview = page.locator('[data-design-system-impact="true"]');
    await expect(sharedReview).toBeVisible();
    await expect(sharedReview).toContainText("padding | Shared class");
    await expect(sharedReview).toContainText("+ padding: 24px");
    await expect(sharedReview).toContainText(
      "Affected components: DestinationCard",
    );
    await expect(sharedReview).toContainText("live preview: selected element");
    await expect(sharedReview).toContainText("Regeneration: required");
    await expectStableElementSnapshot(
      page,
      sharedReview,
      "m55-shared-edit-review.png",
    );
    await page
      .getByRole("button", { name: "Revert inspector source edits" })
      .click();

    await page.getByRole("button", { name: "Narrow right panel" }).click();
    await expect(page.locator(".editor-manual-inspector")).toHaveAttribute(
      "data-right-panel-width",
      "280",
    );
    await expectStableVisualSnapshot(page, "m43-narrow-right-panel.png");

    await openDestinationComponentEdit(page);
    await page.getByRole("button", { name: "Switch to comment mode" }).click();
    const editFrame = page.frameLocator(
      'iframe[title="Editable component preview"]',
    );
    await editFrame
      .getByTestId("component-edit-preview")
      .click({ force: true });
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
    await expectStableVisualSnapshot(page, "m43-ai-mode-proposals.png");

    await openDestinationComponentDetail(page);
    await expectStableVisualSnapshot(page, "m55-component-api-editor.png");
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
    await markPreviewSelected(page);
    await expect(
      editFrame.locator('[data-isonim-selected="true"]'),
    ).toBeVisible();
    const initialStyle = await previewStyle(page);
    expect(initialStyle, "initial preview style").not.toBeNull();
    expect(initialStyle!.padding).toBe("18px");
    expect(initialStyle!.source).not.toBe("");

    await page.getByRole("tab", { name: "Show Space edit controls" }).click();

    const impact = page.locator('[data-design-system-impact="true"]');
    await expect(impact).toHaveAttribute(
      "data-shared-design-editor-count",
      /[1-9]/,
    );
    await expect(page.getByLabel("Shared design-system editors")).toContainText(
      "padding | Spacing",
    );

    const input = page
      .getByRole("textbox", { name: "Edit inspector property padding" })
      .first();
    await expect(input).toBeVisible();
    await input.evaluate((node: HTMLInputElement) => {
      node.value = "24px";
    });
    await page
      .getByRole("group", {
        name: "Choose source scope for padding",
        exact: true,
      })
      .click();
    await page
      .getByRole("button", {
        name: "Apply Shared class source scope for padding",
        exact: true,
      })
      .click();

    await expect(page.getByText("Unsaved source edit")).toBeVisible();
    await expect
      .poll(async () => (await previewStyle(page))?.padding)
      .toBe("24px");
    const editedStyle = await previewStyle(page);
    expect(editedStyle!.height).toBeGreaterThan(initialStyle!.height);
    const commitPreview = page.locator(
      '[data-shared-design-commit-preview="padding"]',
    );
    await expect(commitPreview).toBeVisible();
    await expect(commitPreview).toContainText("+ padding: 24px");
    await expect(commitPreview).toContainText(
      "Affected components: DestinationCard",
    );
    await expect(commitPreview).toContainText("live preview: selected element");
    await expect(commitPreview).toContainText("commit: rebuild + full reload");
    await expect(commitPreview).toContainText("Regeneration: required");

    await page
      .getByRole("button", { name: "Save inspector source edits" })
      .click();
    await expect(page.locator(".editor-statusbar")).toContainText("clean");
    await expect(page.locator(".editor-statusbar")).toContainText(
      "write writable",
    );
    await expect
      .poll(() => demoSourceContent(page, demoFoundationSource))
      .toContain(".destination-card { padding: 24px; }");
    await expect
      .poll(async () => (await previewStyle(page))?.padding)
      .toBe("24px");
    await markPreviewSelected(page);

    await input.evaluate((node: HTMLInputElement) => {
      node.value = "30px";
    });
    await page
      .getByRole("group", {
        name: "Choose source scope for padding",
        exact: true,
      })
      .click();
    await page
      .getByRole("button", {
        name: "Apply Shared class source scope for padding",
        exact: true,
      })
      .click();
    await expect(page.getByText("Unsaved source edit")).toBeVisible();
    await expect
      .poll(async () => (await previewStyle(page))?.padding)
      .toBe("30px");
    await page
      .getByRole("button", { name: "Revert inspector source edits" })
      .click();
    await expect(page.getByText("Unsaved source edit")).toHaveCount(0);
    await expect
      .poll(async () => (await previewStyle(page))?.padding)
      .toBe("24px");
    await expect
      .poll(() => demoSourceContent(page, demoFoundationSource))
      .toContain(".destination-card { padding: 24px; }");
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
    await assertVisibleBox(
      page.getByLabel("Token manager", { exact: true }),
      "token manager",
    );
    await assertVisibleBox(
      page.getByLabel(/Style class cascade token manager/),
      "style manager",
    );
    await assertVisibleBox(
      page.getByLabel(/Element tree selected/),
      "layers panel",
    );
    await assertNoBodyScrollbar(page);
    await assertNoEssentialOverlaps(page, [
      ".editor-manual-inspector",
      ".editor-preview",
      ".editor-preview iframe",
    ]);
    await assertNoClippedEssentialText(page);

    const frame = page.frameLocator(
      'iframe[title="Editable component preview"]',
    );
    await frame.getByTestId("component-edit-preview").click({ force: true });
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
    await page.getByRole("button", { name: "Switch to comment mode" }).click();
    await expect(page.locator(".editor-chat")).toBeVisible();
    await page.getByRole("button", { name: "Switch to edit mode" }).click();
    await expect(page.locator(".editor-manual-inspector")).toBeVisible();
    const after = await page.locator(".editor-manual-inspector").boundingBox();
    expect(after!.width, "mode switch keeps right panel width stable").toBe(
      before!.width,
    );

    await page.getByRole("button", { name: "Narrow right panel" }).click();
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
    await expect(page.getByText("Unsaved token edit")).toBeVisible();

    await page
      .getByRole("button", { name: "Revert foundation source edits" })
      .click();
    await expect(
      page.getByRole("textbox", { name: "Foundation token value" }),
    ).toHaveValue("#2563EB");

    await page
      .getByRole("textbox", { name: "Foundation token value" })
      .fill("#1D4ED8");
    await page
      .getByRole("button", { name: "Apply foundation token value" })
      .click();
    await page
      .getByRole("button", { name: "Save foundation source edits" })
      .click();
    await expect(page.getByText("Clean - source ready")).toBeVisible();

    const desktopShot = await page.screenshot({ fullPage: true });
    expect(desktopShot.length).toBeGreaterThan(10000);
    await page.setViewportSize(mobileWidth);
    const narrowShot = await page.screenshot({ fullPage: true });
    expect(narrowShot.length).toBeGreaterThan(5000);
  });
});
