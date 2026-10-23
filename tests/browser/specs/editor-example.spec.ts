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
      ".editor-inspector [role=button]",
      ".editor-chat [role=button]",
      ".editor-inspector input",
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
    .getByRole("button", { name: "Switch to edit mode" })
    .click();
  await expect(page.locator(".editor-inspector")).toBeVisible();
}

// Saving is automatic: assert admission and the actual authored adapter's
// source bytes, not a removed dirty badge. The demo adapter is project-owned;
// real filesystem writes/refusals are additionally covered by test-editor-source.
async function pendingSourceEdits(page: Page) {
  return page.evaluate(() => (window as any).__isonimEditor.pendingSourceEdits());
}
async function expectAutomaticWrite(page: Page, previous: string, file = demoFoundationSource) {
  await expect.poll(() => demoSourceContent(page, file)).not.toBe(previous);
  await expect.poll(() => pendingSourceEdits(page)).toBe(0);
  await expect(page.locator("[data-save-error]")).toBeHidden();
}

async function openSourcePropertyRows(page: Page) {
  const header = page.locator('[data-inspector-section-header="component-properties"]');
  const body = page.locator('[data-inspector-section-body="component-properties"]');
  if (!(await body.isVisible())) await header.click();
  await expect(body).toBeVisible();
  const sourceBody = page.locator('[data-inspector-section-body="source"]');
  if (!(await sourceBody.isVisible())) await page.locator('[data-inspector-section-header="source"]').click();
}
async function resizeRightPanel(page: Page, width: number) {
  const panel = page.locator(".editor-inspector");
  const before = await panel.boundingBox();
  expect(before).not.toBeNull();
  const handle = page.locator('[data-resize-handle="right-panel"]:visible');
  const box = await handle.boundingBox();
  expect(box).not.toBeNull();
  await page.mouse.move(box!.x + box!.width / 2, box!.y + 40);
  await page.mouse.down();
  await page.mouse.move(box!.x + box!.width / 2 + before!.width - width, box!.y + 40);
  await page.mouse.up();
}

async function sourcePropertyInput(page: Page, property: string) {
  await openSourcePropertyRows(page);
  const row = page.locator(`[data-component-props-list] [data-property-row-css-property="${property}"]`).first();
  await expect(row).toBeVisible();
  return row.locator('[data-property-row-input="true"]');
}

async function setInspectorProperty(
  page: Page,
  tab: string,
  property: string,
  value: string,
  expectAccepted = true,
) {
  await openSourcePropertyRows(page);
  const input = await sourcePropertyInput(page, property);
  await expect(input).toBeVisible();
  await input.evaluate((node: HTMLInputElement, nextValue) => {
    node.value = String(nextValue);
    node.dispatchEvent(new Event("input", { bubbles: true }));
    node.dispatchEvent(new Event("change", { bubbles: true }));
    node.dispatchEvent(new Event("blur", { bubbles: true }));
  }, value);
  if (expectAccepted) {
    const numeric = await input.evaluate(node => node.closest("[data-property-row-kind]")?.getAttribute("data-property-row-kind") === "numeric");
    const numberAndUnit = value.match(/^(-?[0-9.]+)(px|ms|s)?$/);
    await expect(input).toHaveValue(numeric && numberAndUnit ? numberAndUnit[1] : value);
    if (numeric && numberAndUnit?.[2]) {
      await expect(input.locator('xpath=ancestor::*[@data-property-row-css-property][1]').locator('[data-property-row-unit]')).toContainText(numberAndUnit[2]);
    }
    await expect.poll(() => pendingSourceEdits(page)).toBeGreaterThan(0);
    await expect(page.locator("[data-save-error]")).toBeHidden();
  }
}

async function applyRawInspectorCss(page: Page, tab: string, cssText: string) {
  const sourceBefore = await demoSourceContent(page, demoFoundationSource);
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
  await expectAutomaticWrite(page, sourceBefore);
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
  // A physical selection must bind the real DOM identity to the VM. Merely
  // painting a selected attribute leaves the source writer targeting another node.
  const frame = page.frameLocator('iframe[title="Editable component preview"]');
  await frame.getByTestId("component-edit-preview").click({ force: true });
  await expect(frame.locator('[data-isonim-selected="true"]')).toBeVisible();
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

    await page.getByRole("button", { name: "Toggle right sidebar", exact: true }).click();
    await expect(page.locator(".editor-chat")).toBeHidden();
  });

  test("e2e_agent_assisted_edit_flow", async ({ page }) => {
    await expect(page.getByText("Ask for design-system changes")).toBeVisible();
    await expect(page.getByText("Fake adapter streamed response", { exact: false })).toHaveCount(0);
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

    const conversation = page.locator('.editor-chat[data-chat-local-id="chat-1"]');
    const userTurn = conversation.locator('[data-chat-role="arUser"][data-chat-turn="1"]');
    await expect(conversation).toBeVisible();
    await expect(userTurn).toHaveCount(1);
    await expect(userTurn).toBeVisible();
    await expect(userTurn.locator('[data-chat-markdown="paragraph"]')).toHaveText("Apply the spacing edit");
    await expect(conversation.locator('[data-chat-role="arAssistant"]')).toBeVisible();
    await expect(conversation.locator('[data-chat-role="arAssistant"] [data-chat-activity-status="true"]')).toHaveText("completed");
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
    await expect(page.locator('[data-agent-permission="agent-permission-1"]')).toHaveAttribute("data-agent-permission-status", "granted");
    await expect(page.getByText("Write workspace source - granted", { exact: true })).toBeVisible();
    await page
      .getByRole("button", { name: "Accept agent edit agent-proposal-1" })
      .click();
    await expect(page.locator('[data-agent-proposal="agent-proposal-1"]')).toHaveAttribute("data-agent-proposal-status", "accepted");
    await expect(page.locator('[data-agent-proposal="agent-proposal-1"]')).toContainText(" - accepted - ");
    await page
      .getByRole("button", { name: "Revert agent edit agent-proposal-1" })
      .click();
    await expect(page.locator('[data-agent-proposal="agent-proposal-1"]')).toHaveAttribute("data-agent-proposal-status", "reverted");
    await expect(page.locator('[data-agent-proposal="agent-proposal-1"]')).toContainText(" - reverted - ");
    await expect(page.locator("[data-chat-session-summary]")).toContainText("Ready for next message");
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
      .getByRole("button", { name: "Switch to edit mode" })
      .click();
    await expect(page.locator(".editor-inspector")).toBeVisible();

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
    await expect(page.locator('[data-agent-proposal="agent-proposal-1"]')).toHaveAttribute("data-agent-proposal-status", "accepted");
    await expect(page.locator('[data-agent-proposal="agent-proposal-1"]')).toContainText(" - accepted - ");
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
    await expect(page.locator(".editor-inspector")).toBeHidden();
    await sidebarToggle.evaluate((node: HTMLElement) =>
      node.focus({ preventScroll: true }),
    );
    await page.keyboard.press("I");
    await expect(page.locator(".editor-inspector")).toBeVisible();
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
      .locator('[data-scene-graph-row][data-selected="true"]')
      .first();
    const selectedBefore = await selectedLayer.getAttribute(
      "data-scene-graph-row",
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
        '[aria-label="Switch to edit mode"]',
      );
      const started = performance.now();
      target?.click();
      await new Promise((resolve) => requestAnimationFrame(resolve));
      return performance.now() - started;
    });
    expect(modeDuration).toBeLessThan(await budgetMs("epbkModeSwitch"));
    await expect(page.locator(".editor-inspector")).toBeVisible();

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

    await openSourcePropertyRows(page);
    await page.evaluate(async () => {
      const input = document.querySelector<HTMLInputElement>(
        '[data-component-props-list] [data-property-row-css-property="padding"] input',
      );
      if (input) {
        input.value = "28px";
        input.dispatchEvent(new Event("change", { bubbles: true }));
      }
      await new Promise((resolve) => requestAnimationFrame(resolve));
    });
    await expect(page.locator("[data-save-error]")).toBeHidden();
    await expect.poll(() => pendingSourceEdits(page)).toBe(0);
    await expect(
      page.locator('[data-editor-telemetry-event="save and reload"]'),
    ).toBeVisible();
    const saveDetail = await page
      .locator('[data-editor-telemetry-event="save and reload"]')
      .last()
      .getAttribute("data-editor-telemetry-detail");
    expect(saveDetail ?? "").toMatch(/^preview-reload:/);
    await expect(page.locator("[data-save-error]")).toBeHidden();
    await expect.poll(() => demoSourceContent(page, demoFoundationSource)).toContain("padding: 28px");

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

    const letterSpacingInput = await sourcePropertyInput(page, "letter-spacing");
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
      await sourcePropertyInput(page, "outline-offset"),
    ).toHaveValue("4");

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
    await openSourcePropertyRows(page);
    await openSourcePropertyRows(page);
    await expect(
      page.locator('[data-component-props-list] [data-property-row-css-property="filter"]'),
    ).toContainText("Filter values must use supported CSS filter functions");

    // The user's sequence is debounced as one write, rather than waiting a
    // debounce after every gesture. Verify EVERY declaration in the actual
    // authored source and rejection of the invalid filter before capturing.
    for (const declaration of [
      "letter-spacing: 2px;", "text-transform: uppercase;",
      "background-image: linear-gradient(90deg, rgb(59, 130, 246), rgb(34, 197, 94));",
      "background-size: contain;", "border-style: dashed;", "outline-offset: 4px;",
      "filter: brightness(1.08) contrast(1.1);", "transform: translateX(8px) scale(1.02);",
      "transition-duration: 180ms;", "flex-wrap: wrap;", "overflow: auto;", "aspect-ratio: 4 / 3;",
    ]) {
      await expect.poll(() => demoSourceContent(page, demoFoundationSource)).toContain(" " + declaration);
    }
    await expect.poll(() => pendingSourceEdits(page)).toBe(0);
    expect(await demoSourceContent(page, demoFoundationSource)).not.toContain("glow(");
    const afterShot = await page.screenshot({ fullPage: true });
    expect(
      afterShot.length,
      "long-tail evidence screenshot has bytes",
    ).toBeGreaterThan(20000);
    expect(
      Buffer.compare(beforeShot, afterShot),
      "long-tail edits produce a changed screenshot",
    ).not.toBe(0);
    await expect(page.locator("[data-save-error]")).toBeHidden();
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
    await expect.poll(() => pendingSourceEdits(page)).toBeGreaterThan(0);

    const saveVector = page.locator("[data-vector-editor-toolbar]");
    await expect
      .poll(async () =>
        Number(
          await saveVector.evaluate((node) =>
            node.getAttribute("data-vector-pending-source-edits"),
          ),
        ),
      )
      .toBeGreaterThan(0);
    await expect.poll(() => demoSourceContent(page, "examples/wanderlust/design-system/vector-symbols.svg")).toMatch(/stroke:\s*(?:#22C55E|rgb\(34,\s*197,\s*94\))/i);
    await expect(saveVector).toHaveAttribute(
      "data-vector-source-stage",
      "wesClean",
    );
    await expect(saveVector).toHaveAttribute(
      "data-vector-pending-source-edits",
      "0",
    );
    await expect.poll(() => pendingSourceEdits(page)).toBe(0);
    await expect(page.locator("[data-save-error]")).toBeHidden();

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
    await expect.poll(() => demoSourceContent(page, "examples/wanderlust/design-system/vector-symbols.svg")).toMatch(/stroke:\s*(?:#22C55E|rgb\(34,\s*197,\s*94\))/i);
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
    const mobileHistory = page.locator('[data-design-review-history-button-sidebar="true"]');
    const historyHitBox = await mobileHistory.boundingBox();
    const historyGlyphBox = await mobileHistory.locator("svg").boundingBox();
    expect(historyHitBox).not.toBeNull();
    expect(historyGlyphBox).not.toBeNull();
    expect(historyHitBox!.width).toBeGreaterThanOrEqual(44);
    expect(historyHitBox!.height).toBeGreaterThanOrEqual(44);
    expect(historyGlyphBox!.width).toBe(18);
    expect(historyGlyphBox!.height).toBe(18);
    await expectStableVisualSnapshot(page, "m43-shell-mobile-width.png");

    await page.setViewportSize(desktop);
    await openDestinationComponentEdit(page);
    await markPreviewSelected(page);
    await openSourcePropertyRows(page);
    await expect(
      page.locator('[data-component-props-list] [data-property-row-css-property="padding"]').getByRole("button", { name: "Bind padding to variable", exact: true }),
    ).toBeVisible();
    await expect(
      page.locator('[data-component-props-list] [data-property-row-css-property="padding"]').getByRole("group", { name: "Choose source scope for padding", exact: true }),
    ).toBeVisible();
    await expect(page.locator('[data-scene-graph="true"]')).toBeVisible();
    await expectStableVisualSnapshot(page, "m55-compact-inspector.png");
    await expectStableVisualSnapshot(
      page,
      "m43-edit-inspector-token-style-layers.png",
    );

    await openSourcePropertyRows(page);
    const paddingScopeGroup = page.locator('[data-component-props-list] [data-property-row-css-property="padding"]').getByRole("group", {
      name: "Choose source scope for padding",
      exact: true,
    });
    await expect(
      paddingScopeGroup.getByRole("button", {
        name: "Apply shared class scope for padding",
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

    const paddingInput = await sourcePropertyInput(page, "padding");
    await expect(paddingInput).toBeVisible();
    await paddingScopeGroup
      .getByRole("button", {
        name: "Apply shared class scope for padding",
        exact: true,
      })
      .click();
    await paddingInput.fill("24px");
    await paddingInput.press("Enter");
    await expect(page.locator("[data-save-error]")).toBeHidden();
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
    await page.keyboard.press(process.platform === "darwin" ? "Meta+z" : "Control+z");

    await resizeRightPanel(page, 280);
    await expect(page.locator(".editor-inspector")).toHaveAttribute(
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

  // Editor spec "Universal Patterns": "Raw CSS toggle — switch to raw CSS
  // text editing for any section", and its clause on what the raw CSS shows,
  // commits and refuses; "Saving" for act-time refusals, the automatic write
  // and undo across writes. The packaged example's own writer
  // (demo_workspace.demoVectorEditAdapter) writes the foundation source the
  // page exposes as window.__isonimDemoSources. Physical pointer and keyboard
  // input; nothing is mocked.
  test("e2e_section_raw_css_toggle_commits_refuses_and_undoes", async ({
    page,
  }) => {
    await page.setViewportSize(desktop);
    await openDestinationComponentEdit(page);
    await markPreviewSelected(page);
    const selected = page
      .frameLocator('iframe[title="Editable component preview"]')
      .locator('[data-isonim-selected="true"]')
      .first();
    const undoCount = () =>
      page.evaluate(() => (window as any).__isonimEditorVm.inspector.undoStack.value.length);
    const effects = page.locator('[data-inspector-section-header="effects"]');
    if ((await effects.getAttribute("aria-expanded")) !== "true") await effects.click();
    const field = page.getByRole("textbox", { name: "Edit raw CSS for Effects section" });
    const toggle = page.getByRole("button", { name: "Show raw CSS for Effects section" });
    const rows = page.locator('[data-inspector-section-rows="effects"]');
    const message = page.locator('[data-section-raw-css-message="effects"]');
    // On its rows, the section ends with an empty raw CSS entry.
    await expect(field).toBeVisible();
    await expect(field).toHaveValue("");
    await expect(toggle).toHaveAttribute("aria-pressed", "false");
    await expect(rows).toBeVisible();
    await expect(page.locator('[data-property-row-css-property="filter"]').first()).toBeVisible();

    // The toggle switches the section to its declarations as CSS text.
    await toggle.click();
    await expect(toggle).toHaveAttribute("aria-pressed", "true");
    await expect(rows).toBeHidden();
    await expect(field).toHaveValue(
      "filter: none;\ntransform: none;\ntransition-duration: 0s;\n");

    // Edit the text: two changed declarations, one unchanged. Enter commits;
    // both are written inside the rule that owns them, and each is an edit.
    const original = await demoSourceContent(page, demoFoundationSource);
    expect(original).toContain(" transform: none; transition-duration: 0s;");
    const start = await undoCount();
    await field.fill("filter: none;\ntransform: translateX(8px) scale(1.02);\ntransition-duration: 180ms;");
    await field.press("Enter");
    await expect.poll(() => pendingSourceEdits(page)).toBe(0);
    await expect(page.locator("[data-save-error]")).toBeHidden();
    const written = original
      .replace(" transform: none;", " transform: translateX(8px) scale(1.02);")
      .replace(" transition-duration: 0s;", " transition-duration: 180ms;");
    await expect.poll(() => demoSourceContent(page, demoFoundationSource)).toBe(written);
    expect(await undoCount()).toBe(start + 2);
    await expect.poll(() => selected.evaluate((node) => getComputedStyle(node).transform))
      .not.toBe("none");
    await expect.poll(() => selected.evaluate((node) => getComputedStyle(node).transitionDuration))
      .toBe("0.18s");
    await expect(field).toHaveValue(
      "filter: none;\ntransform: translateX(8px) scale(1.02);\ntransition-duration: 180ms;\n");
    await expect(message).toBeHidden();

    // Invalid text is refused at the commit with the reason; nothing moves,
    // and Escape gives the field back to the model.
    await field.fill("filter brightness(2)");
    await field.press("Enter");
    await expect(message).toBeVisible();
    await expect(message).toContainText("is not a declaration");
    await expect(field).toHaveAttribute("aria-invalid", "true");
    await field.fill("transform: scale(2); filter: glow(4px)");
    await field.press("Enter");
    await expect(message).toContainText("Filter values must use supported CSS filter functions");
    expect(await undoCount()).toBe(start + 2);
    expect(await pendingSourceEdits(page)).toBe(0);
    expect(await demoSourceContent(page, demoFoundationSource)).toBe(written);
    await field.press("Escape");
    await expect(message).toBeHidden();
    await expect(field).toHaveValue(
      "filter: none;\ntransform: translateX(8px) scale(1.02);\ntransition-duration: 180ms;\n");

    // A scope no project schema entry can write is refused at the act: the
    // card's heading is captured off the preview, and no rule of the
    // example's writer owns its gap.
    await page
      .frameLocator('iframe[title="Editable component preview"]')
      .locator('[data-testid="component-edit-preview"] h1')
      .first()
      .click({ force: true });
    const layout = page.locator('[data-inspector-section-header="layout"]');
    if ((await layout.getAttribute("aria-expanded")) !== "true") await layout.click();
    const layoutField = page.getByRole("textbox", { name: "Edit raw CSS for Layout section" });
    await layoutField.fill("gap: 4px");
    await layoutField.press("Enter");
    const layoutMessage = page.locator('[data-section-raw-css-message="layout"]');
    await expect(layoutMessage).toBeVisible();
    await expect(layoutMessage).toContainText(
      "gap: No project schema or source map entry can safely represent this edit.");
    expect(await undoCount()).toBe(start + 2);
    expect(await pendingSourceEdits(page)).toBe(0);
    expect(await demoSourceContent(page, demoFoundationSource)).toBe(written);

    // Undo across the write, one declaration at a time, to the exact bytes.
    await markPreviewSelected(page);
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await page.keyboard.press("ControlOrMeta+Z");
    await expect.poll(undoCount).toBe(start + 1);
    await expect.poll(() => pendingSourceEdits(page)).toBe(0);
    await expect.poll(() => demoSourceContent(page, demoFoundationSource)).toBe(
      original.replace(" transform: none;", " transform: translateX(8px) scale(1.02);"));
    await page.keyboard.press("ControlOrMeta+Z");
    await expect.poll(undoCount).toBe(start);
    await expect.poll(() => pendingSourceEdits(page)).toBe(0);
    await expect.poll(() => demoSourceContent(page, demoFoundationSource)).toBe(original);
    await expect.poll(() => selected.evaluate((node) => getComputedStyle(node).transform))
      .toBe("none");
    await expect(field).toHaveValue(
      "filter: none;\ntransform: none;\ntransition-duration: 0s;\n");

    // Toggling back shows the rows and the empty entry again.
    await toggle.click();
    await expect(toggle).toHaveAttribute("aria-pressed", "false");
    await expect(rows).toBeVisible();
    await expect(field).toHaveValue("");
    await expect(page.locator('[data-property-row-css-property="filter"]').first()).toBeVisible();
    await expect(page.locator("[data-save-error]")).toBeHidden();
  });

  // Editor spec "Specialized Editors": "Visual box model -- nested
  // rectangles for margin/padding/content; click any segment to type a value;
  // click center to set all sides uniformly", and the clause under it (the
  // Layout section's `Show box model controls` disclosure; each field commits
  // through its property's row pipeline). The example's writer maps the
  // card's `padding` shorthand and no side, so the centre writes and a side
  // is refused at the act with the writer's reason.
  test("e2e_box_model_edits_margin_and_padding_by_keyboard_and_pointer", async ({
    page,
  }) => {
    await page.setViewportSize(desktop);
    await openDestinationComponentEdit(page);
    await markPreviewSelected(page);
    const selected = page
      .frameLocator('iframe[title="Editable component preview"]')
      .locator('[data-isonim-selected="true"]')
      .first();
    const undoCount = () =>
      page.evaluate(() => (window as any).__isonimEditorVm.inspector.undoStack.value.length);
    const layout = page.locator('[data-inspector-section-header="layout"]');
    if ((await layout.getAttribute("aria-expanded")) !== "true") await layout.click();
    const toggle = page.getByRole("button", { name: "Show box model controls" });
    const box = page.locator('[data-box-model="true"]');
    const message = page.locator("[data-box-model-message]");
    const field = (name: string) => page.getByRole("textbox", { name, exact: true });
    const centre = field("Padding, all sides");
    const top = field("Padding top");

    // The disclosure, by keyboard and by pointer.
    await expect(toggle).toHaveAttribute("aria-expanded", "false");
    await expect(box).toBeHidden();
    await toggle.focus();
    await page.keyboard.press("Enter");
    await expect(toggle).toHaveAttribute("aria-expanded", "true");
    await expect(box).toBeVisible();
    await page.keyboard.press(" ");
    await expect(toggle).toHaveAttribute("aria-expanded", "false");
    await expect(box).toBeHidden();
    await toggle.click();
    await expect(toggle).toHaveAttribute("aria-expanded", "true");
    await expect(box).toBeVisible();

    // The rings show the selection's box.
    await expect(top).toHaveValue("18");
    await expect(centre).toHaveValue("18");
    await expect(field("Margin left")).toHaveValue("0");
    await expect(page.locator("[data-box-model-border]")).toHaveText("Border 1");

    // Click the centre and type: every side at once, through the padding
    // shorthand's own pipeline -- written inside its rule, previewed, one undo
    // entry.
    const original = await demoSourceContent(page, demoFoundationSource);
    expect(original).toContain(".destination-card { padding: 18px; }");
    const start = await undoCount();
    await centre.click();
    expect(await centre.evaluate((node: HTMLInputElement) =>
      [node.selectionStart, node.selectionEnd])).toEqual([0, 2]);
    await page.keyboard.type("20+4");
    await page.keyboard.press("Enter");
    await expect.poll(() => pendingSourceEdits(page)).toBe(0);
    await expect(page.locator("[data-save-error]")).toBeHidden();
    const at24 = original.replace(".destination-card { padding: 18px; }",
      ".destination-card { padding: 24px; }");
    await expect.poll(() => demoSourceContent(page, demoFoundationSource)).toBe(at24);
    expect(await undoCount()).toBe(start + 1);
    await expect.poll(() => selected.evaluate((node) => getComputedStyle(node).paddingTop))
      .toBe("24px");
    await expect(centre).toHaveValue("24");
    await expect(top).toHaveValue("24");
    await expect(page.locator('[data-property-row="pad-top"] [data-property-row-input="true"]').first())
      .toHaveValue("24");
    await expect(message).toBeHidden();

    // A side the project maps no entry for is refused at the act with the
    // writer's reason; the field is put back and nothing is written.
    await top.click();
    await page.keyboard.type("30");
    await page.keyboard.press("Enter");
    await expect(message).toBeVisible();
    await expect(message).toContainText(
      "Padding top: No project schema or source map entry can safely represent this edit.");
    await expect(top).toHaveValue("24");
    expect(await undoCount()).toBe(start + 1);
    expect(await demoSourceContent(page, demoFoundationSource)).toBe(at24);

    // Escape restores the committed value without an edit.
    await centre.click();
    await page.keyboard.type("99");
    await page.keyboard.press("Escape");
    await expect(centre).toHaveValue("24");
    // ArrowUp steps by one and commits.
    await page.keyboard.press("ArrowUp");
    const at25 = original.replace(".destination-card { padding: 18px; }",
      ".destination-card { padding: 25px; }");
    await expect.poll(() => demoSourceContent(page, demoFoundationSource)).toBe(at25);
    expect(await undoCount()).toBe(start + 2);
    await expect(message).toBeHidden();

    // Drag right on the centre scrubs it: two units a pixel near the row,
    // one edit on release.
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    const rect = await centre.boundingBox();
    if (!rect) throw new Error("the all-sides padding field has no box");
    const x = rect.x + rect.width / 2;
    const y = rect.y + rect.height / 2;
    await page.mouse.move(x, y);
    await page.mouse.down();
    await page.mouse.move(x + 6, y, { steps: 3 });
    await page.mouse.move(x + 10, y, { steps: 2 });
    await expect(centre).toHaveValue("45");
    expect(await undoCount()).toBe(start + 2);
    await page.mouse.up();
    const at45 = original.replace(".destination-card { padding: 18px; }",
      ".destination-card { padding: 45px; }");
    await expect.poll(() => demoSourceContent(page, demoFoundationSource)).toBe(at45);
    expect(await undoCount()).toBe(start + 3);
    await expect.poll(() => selected.evaluate((node) => getComputedStyle(node).paddingLeft))
      .toBe("45px");

    // Escape during a drag puts back the value from before it.
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await page.mouse.move(x, y);
    await page.mouse.down();
    await page.mouse.move(x - 8, y, { steps: 3 });
    await expect(centre).toHaveValue("29");
    await page.keyboard.press("Escape");
    await expect(centre).toHaveValue("45");
    await page.mouse.up();
    expect(await undoCount()).toBe(start + 3);
    expect(await demoSourceContent(page, demoFoundationSource)).toBe(at45);

    // The drag holds pointer capture, so it keeps scrubbing once the pointer
    // has left the field (40px right of its centre is past its edge); losing
    // the capture cancels the drag and puts back the value from before it.
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await centre.evaluate((node) => node.addEventListener("pointerdown",
      (event) => { (window as any).__boxPointerId = (event as PointerEvent).pointerId; },
      { once: true }));
    await page.mouse.move(x, y);
    await page.mouse.down();
    await page.mouse.move(x + 40, y, { steps: 5 });
    await expect(centre).toHaveValue("125");
    expect(await centre.evaluate((node) =>
      node.hasPointerCapture((window as any).__boxPointerId))).toBe(true);
    await centre.evaluate((node) =>
      node.releasePointerCapture((window as any).__boxPointerId));
    // The browser reports the loss with the next pointer event.
    await page.mouse.move(x + 44, y);
    await expect(centre).toHaveValue("45");
    await page.mouse.up();
    expect(await undoCount()).toBe(start + 3);
    expect(await demoSourceContent(page, demoFoundationSource)).toBe(at45);

    // The box fits the panel.
    const inspector = page.locator('[data-sidebar-content="inspector"]');
    expect(await inspector.evaluate((node) => node.scrollWidth <= node.clientWidth + 1))
      .toBe(true);

    // Undo across the writes, to the exact bytes.
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    for (const expected of [at25, at24, original]) {
      await page.keyboard.press("ControlOrMeta+Z");
      await expect.poll(() => pendingSourceEdits(page)).toBe(0);
      await expect.poll(() => demoSourceContent(page, demoFoundationSource)).toBe(expected);
    }
    expect(await undoCount()).toBe(start);
    await expect(centre).toHaveValue("18");
    await expect.poll(() => selected.evaluate((node) => getComputedStyle(node).paddingTop))
      .toBe("18px");
    await expect(page.locator("[data-save-error]")).toBeHidden();
  });

  // Editor spec "Full CSS Property Inspector": the Layout section exposes
  // display, flex, grid, positioning, sizing, constraints and responsive
  // overrides as source-backed CSS concepts; "Section catalogue": "W/H +
  // constraint"; "Contextual sub-panels"; and the clauses under "Layout auto
  // layout, grid, constraint and responsive controls". The example's real
  // writer holds the card's layout declarations in `.long-tail-card` and its
  // breakpoint in `@media (max-width: 640px)`.
  async function openLayoutControls(page: Page) {
    await page.setViewportSize(desktop);
    await openDestinationComponentEdit(page);
    await markPreviewSelected(page);
    const frame = page.frameLocator('iframe[title="Editable component preview"]');
    const card = () => frame.getByTestId("component-edit-preview");
    const layout = page.locator('[data-inspector-section-header="layout"]');
    if ((await layout.getAttribute("aria-expanded")) !== "true") await layout.click();
    const controls = page.locator('[data-layout-controls="true"]');
    return {
      style: (property: string) => card().evaluate(
        (node, name) => getComputedStyle(node).getPropertyValue(name), property),
      undoCount: () =>
        page.evaluate(() => (window as any).__isonimEditorVm.inspector.undoStack.value.length),
      source: () => demoSourceContent(page, demoFoundationSource),
      written: async (text: string) => {
        await expect.poll(() => pendingSourceEdits(page)).toBe(0);
        await expect(page.locator("[data-save-error]")).toBeHidden();
        await expect.poll(() => demoSourceContent(page, demoFoundationSource)).toContain(text);
      },
      toggle: page.getByRole("button", {
        name: "Show layout auto grid constraint controls", exact: true }),
      controls,
      row: (slug: string) => controls.locator(`[data-property-row="${slug}"]`).first(),
    };
  }

  async function undoTo(page: Page, undoCount: () => Promise<number>, length: number) {
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    while ((await undoCount()) > length) {
      const before = await undoCount();
      await page.keyboard.press("ControlOrMeta+Z");
      await expect.poll(undoCount).toBeLessThan(before);
      await expect.poll(() => pendingSourceEdits(page)).toBe(0);
    }
  }

  test("e2e_layout_controls_auto_layout_grid_and_constraints", async ({ page }) => {
    const { style, undoCount, source, written, toggle, controls, row } =
      await openLayoutControls(page);
    const wrap = page.getByRole("button", { name: "Enable flex wrap", exact: true });
    const tracks = page.getByRole("button", { name: "Set grid template tracks", exact: true });
    const constraints = page.getByRole("button", {
      name: "Set left right top bottom constraints", exact: true });
    const layoutMessage = page.locator('[data-layout-mode-message="true"]');
    const original = await source();
    const start = await undoCount();
    const initialMinWidth = await style("min-width");

    // The entry points: wrap and tracks say why they do not apply to a block.
    await expect(wrap).toHaveAttribute("aria-pressed", "false");
    await expect(wrap).toHaveAttribute("aria-disabled", "true");
    await expect(wrap).toHaveAttribute("title",
      "Flex wrap applies to a flex layout. Set the layout to vertical or horizontal first.");
    await expect(tracks).toHaveAttribute("aria-disabled", "true");
    await expect(constraints).toContainText("Constraints \u00b7 static");
    await expect(toggle).toHaveAttribute("aria-expanded", "false");
    await expect(toggle).toContainText("desktop");
    await expect(controls).toBeHidden();
    await wrap.dispatchEvent("click");
    await expect(layoutMessage).toHaveText(
      "Flex wrap applies to a flex layout. Set the layout to vertical or horizontal first.");
    expect(await undoCount()).toBe(start);
    expect(await source()).toBe(original);

    // A horizontal layout; Enable flex wrap by pointer and by keyboard.
    await page.locator('[data-layout-source-scope-property="display"]')
      .getByRole("button", { name: "Apply local instance scope for display", exact: true }).click();
    await page.getByRole("button", { name: "Set layout to horizontal", exact: true }).click();
    await expect.poll(() => style("display")).toBe("flex");
    await written(" display: flex;");
    await expect(wrap).toHaveAttribute("aria-disabled", "false");
    await wrap.click();
    await expect.poll(() => style("flex-wrap")).toBe("wrap");
    await expect(wrap).toHaveAttribute("aria-pressed", "true");
    await written(" flex-wrap: wrap;");
    expect(await undoCount()).toBe(start + 2);
    await wrap.focus();
    await page.keyboard.press("Enter");
    await expect.poll(() => style("flex-wrap")).toBe("nowrap");
    await expect(wrap).toHaveAttribute("aria-pressed", "false");
    await written(" flex-wrap: nowrap;");
    expect(await undoCount()).toBe(start + 3);

    // The disclosure, by keyboard; the auto layout rows for a flex layout.
    await toggle.focus();
    await page.keyboard.press("Enter");
    await expect(toggle).toHaveAttribute("aria-expanded", "true");
    await expect(controls).toBeVisible();
    await expect(row("align")).toBeVisible();
    await expect(controls.locator('[data-layout-controls-note="grid"]')).toBeVisible();
    await row("justify").locator("[data-choice-group-trigger]").click();
    await page.getByRole("option", { name: "Between", exact: true }).click();
    await expect.poll(() => style("justify-content")).toBe("space-between");
    await written(" justify-content: space-between;");

    // Grid tracks: refused for flex with the reason, opened for grid.
    await tracks.dispatchEvent("click");
    await expect(layoutMessage).toHaveText(
      "Grid tracks apply to a grid layout. Set the layout to grid first.");
    await page.getByRole("button", { name: "Set layout to grid", exact: true }).click();
    await expect.poll(() => style("display")).toBe("grid");
    await written(" display: grid;");
    await toggle.click();
    await expect(controls).toBeHidden();
    await tracks.click();
    await expect(controls).toBeVisible();
    await expect(controls.locator('[data-layout-controls-group="grid"]')).toBeFocused();
    await expect(row("align")).toBeHidden();
    const columns = row("columns").locator('[data-property-row-input="true"]');
    await columns.fill("repeat(2, minmax(0, 1fr))");
    await columns.press("Enter");
    await expect.poll(() => style("grid-template-columns")).toMatch(/^\S+px \S+px$/);
    await written(" grid-template-columns: repeat(2, minmax(0, 1fr));");
    const withColumns = await source();

    // Constraints: opened at their group; a minimum width.
    await constraints.click();
    await expect(controls.locator('[data-layout-controls-group="constraints"]')).toBeFocused();
    const minWidth = row("min-w").locator('[data-property-row-input="true"]');
    await minWidth.fill("120px");
    await minWidth.press("Enter");
    await expect.poll(() => style("min-width")).toBe("120px");
    await written(" min-width: 120px;");
    expect(await undoCount()).toBe(start + 7);

    // The panel stays within the sidebar.
    const inspector = page.locator('[data-sidebar-content="inspector"]');
    expect(await inspector.evaluate((node) => node.scrollWidth <= node.clientWidth + 1))
      .toBe(true);

    // Undo across the writes puts back the exact bytes.
    await undoTo(page, undoCount, start + 6);
    await expect.poll(source).toBe(withColumns);
    await expect.poll(() => style("min-width")).toBe(initialMinWidth);
    await expect(page.locator("[data-save-error]")).toBeHidden();
  });

  test("e2e_layout_responsive_override_is_written_in_the_breakpoint", async ({ page }) => {
    const { style, undoCount, source, written, toggle, controls } =
      await openLayoutControls(page);
    const original = await source();
    const start = await undoCount();
    await toggle.click();
    await expect(controls).toBeVisible();

    // An override of gap for Mobile: written in the breakpoint; Desktop keeps
    // its value.
    const overrides = controls.locator('[data-layout-controls-group="responsive"]');
    await overrides.getByRole("button", { name: "Override gap", exact: true }).click();
    const overrideValue = page.getByRole("textbox", { name: "Responsive override value" });
    await expect(overrideValue).toHaveValue("normal");
    await overrideValue.fill("12px");
    const mobile = page.getByRole("button", { name: "Set responsive override for Mobile mode" });
    const tablet = page.getByRole("button", { name: "Set responsive override for Tablet mode" });
    await expect(mobile).toContainText("\u2264 640px");
    await expect(tablet).toContainText("no breakpoint");
    await mobile.click();
    const overrideMessage = page.locator('[data-layout-override-message="true"]');
    await expect(overrideMessage).toHaveText(
      "Mobile: gap set to 12px inside @media (max-width: 640px).");
    const withOverride = original.replace(
      "  .destination-card { font-size: 13px; }\n",
      "  .destination-card { font-size: 13px; }\n  .long-tail-card { gap: 12px; }\n");
    await written("  .long-tail-card { gap: 12px; }");
    expect(await source()).toBe(withOverride);
    expect(await undoCount()).toBe(start + 1);
    expect(await style("gap")).toBe("normal");

    // Tablet has no breakpoint in this stylesheet: the press says so and
    // changes nothing.
    await tablet.click();
    await expect(overrideMessage).toHaveText("Tablet: No breakpoint in the project's " +
      "stylesheet applies to Tablet (1024px wide), so there is nowhere to write its override.");
    expect(await undoCount()).toBe(start + 1);
    expect(await source()).toBe(withOverride);

    // In the Phone preview the override applies.
    const phone = page.locator('[data-toolbar-cluster="viewport"]')
      .getByRole("button", { name: "Preview viewport Phone", exact: true });
    await phone.click();
    await expect(phone).toHaveAttribute("aria-pressed", "true");
    await expect(toggle).toContainText("mobile");
    await expect.poll(() => style("gap")).toBe("12px");

    // Undo takes it back, in the file and in the preview.
    await undoTo(page, undoCount, start);
    await expect.poll(source).toBe(original);
    await expect.poll(() => style("gap")).toBe("normal");
    await expect(page.locator("[data-save-error]")).toBeHidden();
  });

  // Editor spec "Planned interaction parity": dragging previews, releasing
  // commits one undoable operation, and Escape or pointer cancellation puts
  // back the value from before the gesture. The selection overlay's spacing
  // handle (uniform padding on the example's card) and resize handle follow
  // it: they used to commit on every pointer move.
  test("e2e_canvas_spacing_and_resize_handles_commit_once_and_cancel", async ({
    page,
  }) => {
    await page.setViewportSize(desktop);
    await openDestinationComponentEdit(page);
    await markPreviewSelected(page);
    const frame = page.frameLocator('iframe[title="Editable component preview"]');
    const card = frame.getByTestId("component-edit-preview");
    await expect(card).toHaveAttribute("data-isonim-selected", "true");
    const undoCount = () =>
      page.evaluate(() => (window as any).__isonimEditorVm.inspector.undoStack.value.length);
    const used = (property: string) =>
      card.evaluate((node, name) => getComputedStyle(node).getPropertyValue(name), property);
    const scale = await page.evaluate(() => {
      const node = document.querySelector('iframe[title="Editable component preview"]') as HTMLIFrameElement;
      return node.getBoundingClientRect().width / node.contentWindow!.innerWidth;
    });
    const px = (n: number) => n * scale;
    async function press(label: string) {
      const box = await frame.getByLabel(label, { exact: true }).boundingBox();
      if (!box) throw new Error(`the ${label} handle has no box`);
      const x = box.x + box.width / 2;
      const y = box.y + box.height / 2;
      await page.mouse.move(x, y);
      await page.mouse.down();
      return { x, y };
    }
    const original = await demoSourceContent(page, demoFoundationSource);
    expect(original).toContain(".destination-card { padding: 18px; }");
    const start = await undoCount();

    // The spacing handle previews in several steps and commits once.
    let p = await press("Adjust selected spacing");
    await page.mouse.move(p.x, p.y + px(3), { steps: 3 });
    await page.mouse.move(p.x, p.y + px(6), { steps: 3 });
    await expect.poll(() => used("padding-top")).toBe("24px");
    expect(await undoCount()).toBe(start);
    expect(await demoSourceContent(page, demoFoundationSource)).toBe(original);
    await page.mouse.up();
    await expect.poll(() => demoSourceContent(page, demoFoundationSource))
      .toBe(original.replace("padding: 18px;", "padding: 24px;"));
    await expect.poll(undoCount).toBe(start + 1);
    await expect.poll(() => pendingSourceEdits(page)).toBe(0);

    // Escape puts the spacing handle's preview back and commits nothing.
    p = await press("Adjust selected spacing");
    await page.mouse.move(p.x, p.y + px(8), { steps: 3 });
    await expect.poll(() => used("padding-top")).toBe("32px");
    await page.keyboard.press("Escape");
    await expect.poll(() => used("padding-top")).toBe("24px");
    await page.mouse.move(p.x, p.y + px(12));
    expect(await used("padding-top")).toBe("24px");
    await page.mouse.up();
    await expect(card).toHaveAttribute("data-isonim-selected", "true");
    expect(await undoCount()).toBe(start + 1);

    // So does pointer cancellation of the resize handle's drag.
    const width = await used("width");
    await frame.getByLabel("Resize selected element", { exact: true }).evaluate((node) =>
      node.addEventListener("pointerdown", (event) => {
        (window as any).__resizePointer = (event as PointerEvent).pointerId;
      }));
    // (The handle sets `width` from the border box, and the card has a
    // max-width: a long drag inwards is one that shows.)
    p = await press("Resize selected element");
    await page.mouse.move(p.x - px(100), p.y, { steps: 3 });
    await expect.poll(() => used("width")).not.toBe(width);
    expect(await undoCount()).toBe(start + 1);
    await card.evaluate(() => window.dispatchEvent(new PointerEvent("pointercancel",
      { pointerId: (window as any).__resizePointer, bubbles: true })));
    await expect.poll(() => used("width")).toBe(width);
    await page.mouse.up();
    expect(await undoCount()).toBe(start + 1);
    expect(await demoSourceContent(page, demoFoundationSource))
      .toBe(original.replace("padding: 18px;", "padding: 24px;"));

    // Undo puts the bytes back.
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await page.locator('[data-sidebar-content="inspector"]').click({ position: { x: 4, y: 4 } });
    await page.keyboard.press("ControlOrMeta+Z");
    await expect.poll(undoCount).toBe(start);
    await expect.poll(() => demoSourceContent(page, demoFoundationSource)).toBe(original);
    await expect.poll(() => used("padding-top")).toBe("18px");
  });

  // Editor spec "Specialized Editors" -> "Visual box model": "drag handles on
  // canvas for live preview", and the clause under it for the selection
  // overlay's margin and padding handles: a drag previews in the frame and in
  // the box model's field as it moves, the release commits one edit through
  // the field's own pipeline, and Escape, pointer cancellation, a lost
  // capture or another selection put back the value from before it. The
  // example's writer maps the card's `padding` shorthand and no side, so a
  // Shift-drag (every side, the shorthand) writes, and a side's drag is
  // refused at the act with the writer's reason and restored.
  test("e2e_canvas_box_handles_preview_commit_cancel_and_refusal", async ({
    page,
  }) => {
    await page.setViewportSize(desktop);
    await openDestinationComponentEdit(page);
    await markPreviewSelected(page);
    const frame = page.frameLocator('iframe[title="Editable component preview"]');
    const card = frame.getByTestId("component-edit-preview");
    await expect(card).toHaveAttribute("data-isonim-selected", "true");
    const undoCount = () =>
      page.evaluate(() => (window as any).__isonimEditorVm.inspector.undoStack.value.length);
    const used = (property: string) =>
      card.evaluate((node, name) => getComputedStyle(node).getPropertyValue(name), property);
    const layout = page.locator('[data-inspector-section-header="layout"]');
    if ((await layout.getAttribute("aria-expanded")) !== "true") await layout.click();
    await page.getByRole("button", { name: "Show box model controls" }).click();
    const field = (name: string) => page.getByRole("textbox", { name, exact: true });
    const centre = field("Padding, all sides");
    const boxMessage = page.locator("[data-box-model-message]");
    const handle = (name: string) => frame.getByLabel(`Adjust ${name}`, { exact: true });
    const canvasMessage = frame.locator("#isonim-editor-box-drag-message");
    const original = await demoSourceContent(page, demoFoundationSource);
    expect(original).toContain(".destination-card { padding: 18px; }");
    const at = (px: number) => original.replace(".destination-card { padding: 18px; }",
      `.destination-card { padding: ${px}px; }`);
    const start = await undoCount();

    // One handle per margin and padding side, in Edit mode.
    for (const side of ["top", "right", "bottom", "left"]) {
      await expect(handle(`margin ${side}`)).toBeVisible();
      await expect(handle(`padding ${side}`)).toBeVisible();
    }

    // The preview is scaled to fit its pane; a handle follows the pointer in
    // the frame's own CSS pixels, so the moves below are in those.
    const scale = await page.evaluate(() => {
      const node = document.querySelector('iframe[title="Editable component preview"]') as HTMLIFrameElement;
      return node.getBoundingClientRect().width / node.contentWindow!.innerWidth;
    });
    const px = (n: number) => n * scale;
    async function press(name: string, shift = false) {
      const box = await handle(name).boundingBox();
      if (!box) throw new Error(`the ${name} handle has no box`);
      const x = box.x + box.width / 2;
      const y = box.y + box.height / 2;
      await page.mouse.move(x, y);
      if (shift) await page.keyboard.down("Shift");
      await page.mouse.down();
      if (shift) await page.keyboard.up("Shift");
      return { x, y };
    }

    // Shift-drag the top padding handle down 6px: every side previews at 24px
    // in the frame and in the box model while the pointer moves, nothing is
    // committed until release, and the release writes one edit.
    let p = await press("padding top", true);
    await page.mouse.move(p.x, p.y + px(3), { steps: 2 });
    await page.mouse.move(p.x, p.y + px(6), { steps: 2 });
    await expect.poll(() => used("padding-top")).toBe("24px");
    expect(await used("padding-left")).toBe("24px");
    await expect(centre).toHaveValue("24");
    await expect(centre).toHaveAttribute("data-box-model-draft", "true");
    await expect(frame.getByLabel("Canvas spacing measurement")).toHaveText("padding: 24px");
    expect(await undoCount()).toBe(start);
    expect(await demoSourceContent(page, demoFoundationSource)).toBe(original);
    await page.mouse.up();
    await expect.poll(() => demoSourceContent(page, demoFoundationSource)).toBe(at(24));
    await expect.poll(() => pendingSourceEdits(page)).toBe(0);
    expect(await undoCount()).toBe(start + 1);
    expect(await used("padding-bottom")).toBe("24px");
    await expect(card).not.toHaveAttribute("data-isonim-box-drag-preview", /.*/);
    await expect(centre).toHaveValue("24");
    await expect(centre).toHaveAttribute("data-box-model-draft", "false");
    await expect(page.locator("[data-save-error]")).toBeHidden();

    // Escape during a drag puts back the value from before it.
    p = await press("padding bottom", true);
    await page.mouse.move(p.x, p.y - px(4), { steps: 3 });
    await expect.poll(() => used("padding-bottom")).toBe("28px");
    await expect(centre).toHaveValue("28");
    await page.keyboard.press("Escape");
    await expect.poll(() => used("padding-bottom")).toBe("24px");
    await expect(centre).toHaveValue("24");
    await page.mouse.move(p.x, p.y - px(8));
    expect(await used("padding-bottom")).toBe("24px");
    await page.mouse.up();
    // Escape ended the drag, not the selection.
    await expect(card).toHaveAttribute("data-isonim-selected", "true");
    expect(await undoCount()).toBe(start + 1);
    expect(await demoSourceContent(page, demoFoundationSource)).toBe(at(24));

    // Pointer cancellation, and a lost pointer capture, do the same.
    await handle("padding left").evaluate((node) => node.addEventListener("pointerdown",
      (event) => { (window as any).__boxHandlePointer = (event as PointerEvent).pointerId; }));
    p = await press("padding left", true);
    await page.mouse.move(p.x + px(5), p.y, { steps: 2 });
    await expect.poll(() => used("padding-left")).toBe("29px");
    await handle("padding left").evaluate((node) => {
      const pointerId = (window as any).__boxHandlePointer;
      window.dispatchEvent(new PointerEvent("pointercancel", { pointerId, bubbles: true }));
    });
    await expect.poll(() => used("padding-left")).toBe("24px");
    await expect(centre).toHaveValue("24");
    await page.mouse.up();
    p = await press("padding left", true);
    await page.mouse.move(p.x + px(40), p.y, { steps: 4 });
    await expect.poll(() => used("padding-left")).toBe("64px");
    expect(await handle("padding left").evaluate((node) =>
      node.hasPointerCapture((window as any).__boxHandlePointer))).toBe(true);
    await handle("padding left").evaluate((node) =>
      node.releasePointerCapture((window as any).__boxHandlePointer));
    await page.mouse.move(p.x + px(44), p.y);
    await expect.poll(() => used("padding-left")).toBe("24px");
    await page.mouse.up();
    expect(await undoCount()).toBe(start + 1);
    expect(await demoSourceContent(page, demoFoundationSource)).toBe(at(24));

    // Another selection discards the drag: the arrow key selects the card's
    // heading mid-drag, the card's preview goes back, and the release commits
    // nothing to either element.
    p = await press("padding top", true);
    await page.mouse.move(p.x, p.y + px(6), { steps: 2 });
    await expect.poll(() => used("padding-top")).toBe("30px");
    await page.keyboard.press("ArrowRight");
    await expect(frame.locator("h1")).toHaveAttribute("data-isonim-selected", "true");
    await expect.poll(() => used("padding-top")).toBe("24px");
    await page.mouse.move(p.x, p.y + px(10));
    await page.mouse.up();
    expect(await used("padding-top")).toBe("24px");
    expect(await undoCount()).toBe(start + 1);
    expect(await demoSourceContent(page, demoFoundationSource)).toBe(at(24));
    await markPreviewSelected(page);

    // A side the project maps no entry for: the drag previews that side only,
    // and the release is refused at the act with the writer's reason, on the
    // canvas and under the box; the preview and the field go back.
    p = await press("padding top");
    await page.mouse.move(p.x, p.y + px(6), { steps: 3 });
    await expect.poll(() => used("padding-top")).toBe("30px");
    expect(await used("padding-left")).toBe("24px");
    await expect(field("Padding top")).toHaveValue("30");
    await page.mouse.up();
    await expect.poll(() => used("padding-top")).toBe("24px");
    await expect(field("Padding top")).toHaveValue("24");
    await expect(canvasMessage).toBeVisible();
    await expect(canvasMessage).toContainText(
      "No project schema or source map entry can safely represent this edit.");
    await expect(boxMessage).toContainText(
      "Padding top: No project schema or source map entry can safely represent this edit.");
    expect(await undoCount()).toBe(start + 1);
    expect(await demoSourceContent(page, demoFoundationSource)).toBe(at(24));

    // A margin handle moves its margin edge away from the element.
    p = await press("margin bottom");
    await page.mouse.move(p.x, p.y + px(10), { steps: 3 });
    await expect.poll(() => used("margin-bottom")).toBe("10px");
    await expect(field("Margin bottom")).toHaveValue("10");
    await page.mouse.up();
    await expect.poll(() => used("margin-bottom")).toBe("0px");
    await expect(boxMessage).toContainText(
      "Margin bottom: No project schema or source map entry can safely represent this edit.");
    await expect(canvasMessage).toBeVisible();
    expect(await undoCount()).toBe(start + 1);

    // The overlay's spacing handle keeps its own commit, and Escape now puts
    // its preview back too.
    p = await press("selected spacing");
    await page.mouse.move(p.x, p.y + px(6), { steps: 2 });
    await expect.poll(() => used("padding-top")).toBe("30px");
    await page.keyboard.press("Escape");
    await expect.poll(() => used("padding-top")).toBe("24px");
    await page.mouse.up();
    expect(await undoCount()).toBe(start + 1);

    // A release still waiting for the project's answer (held here, as a
    // native project answers later) keeps its own preview only: a newer
    // drag previews over it, and the late answer leaves the newer one alone.
    // The frame sends its requests with `parent.dispatchEvent`; wrapping it
    // here reaches the request before the editor answers it.
    await page.evaluate(() => {
      const w = window as any;
      w.__heldBoxSettles = [];
      const dispatch = EventTarget.prototype.dispatchEvent;
      w.dispatchEvent = function (event: Event) {
        const d = (event as CustomEvent).detail || {};
        if (event.type === "isonim-preview-box-drag" && d.phase === "commit" &&
            typeof d.settle === "function") {
          const settle = d.settle;
          d.settle = (ok: boolean, message: string) =>
            w.__heldBoxSettles.push(() => settle(ok, message));
        }
        return dispatch.call(window, event);
      };
    });
    p = await press("padding top");
    await page.mouse.move(p.x, p.y + px(6), { steps: 2 });
    await expect.poll(() => used("padding-top")).toBe("30px");
    await page.mouse.up();
    await expect.poll(() => page.evaluate(() => (window as any).__heldBoxSettles.length)).toBe(1);
    expect(await used("padding-top")).toBe("30px");
    p = await press("padding left");
    await page.mouse.move(p.x + px(5), p.y, { steps: 2 });
    await expect.poll(() => used("padding-left")).toBe("29px");
    await page.evaluate(() => {
      const w = window as any;
      delete w.dispatchEvent;
      for (const settle of w.__heldBoxSettles.splice(0)) settle();
    });
    expect(await used("padding-left")).toBe("29px");
    expect(await used("padding-top")).toBe("24px");
    await page.keyboard.press("Escape");
    await expect.poll(() => used("padding-left")).toBe("24px");
    await page.mouse.up();
    await expect(card).not.toHaveAttribute("data-isonim-box-drag-preview", /.*/);
    expect(await undoCount()).toBe(start + 1);

    // A drag keeps the side's authored unit: 1.5rem previews and writes rem.
    await centre.click();
    await centre.fill("1.5rem");
    await centre.press("Enter");
    await expect.poll(() => demoSourceContent(page, demoFoundationSource))
      .toBe(original.replace("padding: 18px;", "padding: 1.5rem;"));
    await expect.poll(undoCount).toBe(start + 2);
    p = await press("padding top", true);
    await page.mouse.move(p.x, p.y + px(6), { steps: 2 });
    await expect.poll(() => used("padding-top")).toBe("30px");
    await expect(frame.getByLabel("Canvas spacing measurement")).toHaveText("padding: 1.875rem");
    await expect(centre).toHaveValue("1.875rem");
    await page.mouse.up();
    await expect.poll(() => demoSourceContent(page, demoFoundationSource))
      .toBe(original.replace("padding: 18px;", "padding: 1.875rem;"));
    await expect.poll(undoCount).toBe(start + 3);

    // Undo puts the bytes back.
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await page.locator('[data-sidebar-content="inspector"]').click({ position: { x: 4, y: 4 } });
    for (let n = 3; n > 0; n--) {
      await page.keyboard.press("ControlOrMeta+Z");
      await expect.poll(undoCount).toBe(start + n - 1);
    }
    await expect.poll(() => pendingSourceEdits(page)).toBe(0);
    await expect.poll(() => demoSourceContent(page, demoFoundationSource)).toBe(original);
    await expect.poll(() => used("padding-top")).toBe("18px");
    await expect(centre).toHaveValue("18");
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

    await openSourcePropertyRows(page);

    const impact = page.locator('[data-design-system-impact="true"]');
    await expect(impact).toHaveAttribute(
      "data-shared-design-editor-count",
      /[1-9]/,
    );
    await expect(page.getByLabel("Shared design-system editors")).toContainText(
      "padding | Spacing",
    );

    const input = await sourcePropertyInput(page, "padding");
    await expect(input).toBeVisible();
    await page.locator('[data-component-props-list] [data-property-row-css-property="padding"]').getByRole("button", { name: "Apply shared class scope for padding", exact: true }).click();
    await input.fill("24px");
    await input.press("Enter");

    await expect(page.locator("[data-save-error]")).toBeHidden();
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

    await expect.poll(() => pendingSourceEdits(page)).toBe(0);
    await expect(page.locator("[data-save-error]")).toBeHidden();
    await expect
      .poll(() => demoSourceContent(page, demoFoundationSource))
      .toContain(".destination-card { padding: 24px; }");
    await expect
      .poll(async () => (await previewStyle(page))?.padding)
      .toBe("24px");
    await markPreviewSelected(page);

    await input.fill("30px");
    await input.press("Enter");
    await expect(page.locator("[data-save-error]")).toBeHidden();
    await expect.poll(() => demoSourceContent(page, demoFoundationSource)).toContain("padding: 30px");
    await expect
      .poll(async () => (await previewStyle(page))?.padding)
      .toBe("30px");
    await page.keyboard.press(process.platform === "darwin" ? "Meta+z" : "Control+z");
    await expect.poll(() => pendingSourceEdits(page)).toBe(0);
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
    await openSourcePropertyRows(page);
    await assertVisibleBox(
      page.locator('iframe[title="Editable component preview"]'),
      "component edit preview iframe",
    );
    await assertVisibleBox(
      page.locator(".editor-inspector"),
      "manual inspector",
    );
    await assertVisibleBox(
      page.locator('[data-component-props-list] [data-property-row-css-property="padding"]'),
      "source-aware variable property row",
    );
    await assertVisibleBox(
      page.locator('[data-component-props-list] [data-property-row-css-property="padding"]').getByRole("group", { name: "Choose source scope for padding", exact: true }),
      "style manager",
    );
    await assertVisibleBox(
      page.locator('[data-scene-graph="true"]'),
      "layers panel",
    );
    const bind = page.locator('[data-component-props-list] [data-property-row-css-property="padding"]').getByRole("button", { name: "Bind padding to variable", exact: true });
    await bind.click();
    await assertVisibleBox(page.locator('[data-variable-picker="true"]'), "variable picker");
    await page.keyboard.press("Escape");
    await expect(page.locator('[data-variable-picker="true"]')).toBeHidden();
    await assertNoBodyScrollbar(page);
    await assertNoEssentialOverlaps(page, [
      ".editor-inspector",
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

    const before = await page.locator(".editor-inspector").boundingBox();
    await page.getByRole("button", { name: "Switch to comment mode" }).click();
    await expect(page.locator(".editor-chat")).toBeVisible();
    await page.getByRole("button", { name: "Switch to edit mode" }).click();
    await expect(page.locator(".editor-inspector")).toBeVisible();
    const after = await page.locator(".editor-inspector").boundingBox();
    expect(after!.width, "mode switch keeps right panel width stable").toBe(
      before!.width,
    );

    await resizeRightPanel(page, 280);
    await expect(page.locator(".editor-inspector")).toHaveAttribute(
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
    await expect.poll(() => demoSourceContent(page, demoFoundationSource)).toContain("--wl-color-blue-600: #1D4ED8;");
    await expect.poll(() => pendingSourceEdits(page)).toBe(0);

    await page
      .getByRole("button", { name: "Undo foundation token edit" })
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
    await expect.poll(() => demoSourceContent(page, demoFoundationSource)).toContain("--wl-color-blue-600: #1D4ED8;");
    await expect.poll(() => pendingSourceEdits(page)).toBe(0);
    await expect(page.locator("[data-save-error]")).toBeHidden();
    await page.getByRole("button", { name: "Select foundation category Spacing" }).click();
    await page.getByRole("button", { name: "Select foundation category Color" }).click();
    await page.getByRole("button", { name: "Select foundation token color.blue.600" }).click();
    await expect(page.getByRole("textbox", { name: "Foundation token value" })).toHaveValue("#1D4ED8");

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
      viewportStrip.locator('[data-compact-choice-overflow="true"]'),
    ).toBeVisible();
  });
});
