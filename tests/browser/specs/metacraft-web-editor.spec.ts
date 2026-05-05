import { test, expect } from "@playwright/test";

test.describe("metacraft-web IsoNim editor consumer", () => {
  test("mounts the live consumer workspace through public editor APIs", async ({
    page,
  }) => {
    await page.goto("/");

    await expect(page.getByText("IsoNim Editor")).toBeVisible();
    await expect(
      page
        .frameLocator('iframe[title="Project preview"]')
        .getByTestId("back-office-app"),
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Open Flow editor view" }),
    ).toHaveCount(0);

    const userJourneysSection = page.getByRole("button", {
      name: "Open User Journeys section",
    });
    const pagesSection = page.getByRole("button", {
      name: "Open Pages section",
    });
    await expect(userJourneysSection).toBeVisible();
    await expect(pagesSection).toBeVisible();
    const userJourneysBox = await userJourneysSection.boundingBox();
    const pagesBox = await pagesSection.boundingBox();
    if (!userJourneysBox || !pagesBox) {
      throw new Error("Sidebar sections are not visible");
    }
    expect(userJourneysBox.y).toBeLessThan(pagesBox.y);

    await page
      .getByRole("button", { name: "Toggle User Journeys section" })
      .click();
    await expect(
      page.getByRole("button", {
        name: "Select story Partner operations / Partner invitation",
      }),
    ).toHaveCount(0);
    await page
      .getByRole("button", { name: "Toggle User Journeys section" })
      .click();

    await page
      .getByRole("button", { name: "Open User Journeys section" })
      .click();
    await expect(page.locator('[data-figma-canvas="true"]')).toBeVisible();
    await expect(
      page.locator('iframe[title="Flow preview Issue CodeTracer license"]'),
    ).toHaveAttribute("srcdoc", /customer-detail/);
    await page
      .getByRole("button", {
        name: "Select flow step Issue CodeTracer license",
      })
      .click();
    await expect(
      page.getByRole("button", {
        name: "Select story Back-office pages / Customer detail",
      }),
    ).toHaveAttribute("aria-current", "true");
    await expect(page).toHaveURL(/kind=page/);
    await expect(page).toHaveURL(/story=Customer%20detail/);
    await page.getByRole("button", { name: "Open Pages section" }).click();
    await page
      .getByRole("button", {
        name: "Select story Back-office pages / Operations dashboard",
      })
      .click();
    await expect(
      page
        .frameLocator('iframe[title="Project preview"]')
        .getByTestId("back-office-app"),
    ).toBeVisible();

    const frame = page.getByLabel("Preview device frame");
    await expect(frame).toHaveCSS("width", "1280px");
    await expect(frame).toHaveCSS("height", "900px");

    await page
      .getByRole("textbox", { name: "Search stories" })
      .fill("customer detail");
    await expect(
      page.getByRole("button", {
        name: "Select story Back-office pages / Customer detail",
      }),
    ).toBeVisible();
    await expect(
      page.getByRole("button", {
        name: "Select story Partner operations / Partner invitation",
      }),
    ).toHaveCount(0);
    await page.getByRole("textbox", { name: "Search stories" }).fill("");

    await expect(
      page.getByRole("button", { name: "Preview Desktop viewport" }),
    ).toHaveAttribute("aria-pressed", "true");

    await page.getByRole("button", { name: "Preview Tablet viewport" }).click();
    await expect(
      page.getByRole("button", { name: "Preview Tablet viewport" }),
    ).toHaveAttribute("aria-pressed", "true");
    await expect(
      page.getByRole("button", { name: "Preview Desktop viewport" }),
    ).toHaveAttribute("aria-pressed", "false");
    await expect(frame).toHaveCSS("width", "834px");
    await expect(frame).toHaveCSS("height", "1112px");

    await page.getByRole("button", { name: "Preview Mobile viewport" }).click();
    await expect(
      page.getByRole("button", { name: "Preview Mobile viewport" }),
    ).toHaveAttribute("aria-pressed", "true");
    await expect(frame).toHaveCSS("width", "390px");
    await expect(frame).toHaveCSS("height", "844px");

    await page
      .getByRole("button", { name: "Preview Desktop viewport" })
      .click();
    await expect(frame).toHaveCSS("width", "1280px");

    await expect(page).toHaveURL(/view=page/);
    await expect(page).toHaveURL(/viewport=desktop/);
    await expect(page.locator(".editor-statusbar")).toContainText(
      "IsoNim Editor v0.1.0",
    );

    await page.getByRole("button", { name: "Toggle left sidebar" }).click();
    await expect(page.locator(".editor-sidebar")).toBeHidden();
    await page.getByRole("button", { name: "Toggle right sidebar" }).click();
    await expect(page.locator(".editor-chat")).toBeHidden();
    await page.getByRole("button", { name: "Toggle left sidebar" }).click();
    await page.getByRole("button", { name: "Toggle right sidebar" }).click();
    await expect(page.locator(".editor-sidebar")).toBeVisible();
    await expect(page.locator(".editor-chat")).toBeVisible();

    await page.getByRole("button", { name: "Switch to edit mode" }).click();
    await expect(
      page.getByRole("button", { name: "Switch to edit mode" }),
    ).toHaveAttribute("aria-pressed", "true");
    await expect(
      page.getByRole("button", { name: "Switch to view mode" }),
    ).toHaveAttribute("aria-pressed", "false");
    await expect(page.getByText("Click an element to select it")).toBeVisible();
    await expect(page.getByText("Project component preview")).toHaveCount(0);

    await expect(
      page.getByRole("button", {
        name: "Select story Back-office pages / Operations dashboard",
      }),
    ).toHaveAttribute("aria-current", "true");

    await page
      .getByRole("button", {
        name: "Select story Back-office pages / Customer detail",
      })
      .click();

    await expect(
      page.getByRole("button", {
        name: "Select story Back-office pages / Customer detail",
      }),
    ).toHaveAttribute("aria-current", "true");
    await expect(
      page
        .frameLocator('iframe[title="Project preview"]')
        .getByTestId("customer-detail"),
    ).toBeVisible();
    await expect(
      page
        .getByText("apps/back-office/src/backoffice_ui/components.nim")
        .last(),
    ).toBeVisible();

    await page.getByRole("button", { name: "Open Components section" }).click();
    await page
      .getByRole("button", {
        name: "Select story Operational components / Back-office navigation",
      })
      .click();
    await expect(
      page
        .frameLocator(
          'iframe[title="Component preview Operational components / Back-office navigation"]',
        )
        .getByTestId("component-sidebar-nav"),
    ).toBeVisible();
    await page
      .getByRole("button", {
        name: "Select story Operational components / Topbar",
      })
      .click();
    await expect(
      page
        .frameLocator(
          'iframe[title="Component preview Operational components / Topbar"]',
        )
        .getByTestId("component-topbar"),
    ).toBeVisible();
    const topbarFrame = page.locator(
      'iframe[title="Component preview Operational components / Topbar"]',
    );
    await expect(topbarFrame).toHaveAttribute("scrolling", "no");
    await expect
      .poll(async () =>
        topbarFrame.evaluate((node) => {
          const frame = node as HTMLIFrameElement;
          const doc = frame.contentDocument;
          return {
            frameHeight: frame.clientHeight,
            bodyScrollHeight: doc?.body?.scrollHeight ?? 0,
            bodyOverflow: doc?.body?.style.overflow ?? "",
          };
        }),
      )
      .toEqual(
        expect.objectContaining({
          bodyOverflow: "hidden",
        }),
      );
    await expect
      .poll(async () =>
        topbarFrame.evaluate((node) => {
          const frame = node as HTMLIFrameElement;
          const doc = frame.contentDocument;
          return frame.clientHeight >= (doc?.body?.scrollHeight ?? 0);
        }),
      )
      .toBe(true);
    await expect(
      page
        .getByText(
          "Topbar renders from the same IsoNim component function used by the back-office pages.",
        )
        .first(),
    ).toBeVisible();
    await expect(
      page
        .frameLocator(
          'iframe[title="Component preview Operational components / Topbar"]',
        )
        .getByText("Rendered from the same IsoNim component functions"),
    ).toHaveCount(0);
    await page
      .getByRole("button", {
        name: "Select story Operational components / Status badge tones",
      })
      .click();
    await expect(
      page
        .frameLocator(
          'iframe[title="Component preview Operational components / Status badge tones"]',
        )
        .getByTestId("component-status-badges"),
    ).toBeVisible();
    await page
      .getByRole("button", {
        name: "Select story Operational components / Responsive data table",
      })
      .click();
    await expect(
      page
        .frameLocator(
          'iframe[title="Component preview Operational components / Responsive data table"]',
        )
        .getByTestId("component-data-table"),
    ).toBeVisible();

    await page
      .getByRole("button", { name: "Open User Journeys section" })
      .click();
    await page
      .getByRole("button", {
        name: "Select flow step Issue CodeTracer license",
      })
      .click();
    await expect(
      page.getByRole("button", {
        name: "Select story Back-office pages / Customer detail",
      }),
    ).toHaveAttribute("aria-current", "true");
    await expect(
      page
        .frameLocator('iframe[title="Project preview"]')
        .getByTestId("customer-detail"),
    ).toBeVisible();
    await expect(
      page
        .getByText("apps/back-office/src/backoffice_ui/components.nim")
        .last(),
    ).toBeVisible();

    await page.goto("/?view=vector#vector-editor");
    await expect(page.getByText("Vector Editor")).toBeVisible();
    const vectorHost = page.locator('[data-vector-adapter="fabric"]').first();
    await expect(vectorHost).toHaveAttribute(
      "data-vector-library-backed",
      "true",
    );
    await expect(vectorHost).toHaveAttribute("data-vector-svgo-backed", "true");
    await page
      .getByRole("button", { name: "Select Rectangle vector tool" })
      .click();
    await expect(
      page.getByRole("button", { name: "Select Rectangle vector tool" }),
    ).toHaveAttribute("aria-pressed", "true");
  });

  test("edits real metacraft component DOM through the inspector", async ({
    page,
  }) => {
    await page.goto("/");

    await page.getByRole("button", { name: "Open Components section" }).click();
    await page
      .getByRole("button", {
        name: "Select story Operational components / Topbar",
      })
      .click();
    await expect(
      page
        .frameLocator(
          'iframe[title="Component preview Operational components / Topbar"]',
        )
        .getByTestId("component-topbar"),
    ).toBeVisible();

    await page
      .getByRole("button", { name: "Open selected component in edit mode" })
      .click();
    await expect(page).toHaveURL(/view=edit/);
    await expect(
      page.getByRole("button", { name: "Switch to edit mode" }),
    ).toHaveAttribute("aria-pressed", "true");
    await expect(page.getByText("Project component preview")).toHaveCount(0);
    await expect(page.locator(".editor-chat")).toBeHidden();
    await expect(page.locator(".editor-manual-inspector")).toBeVisible();

    const editFrame = page.frameLocator(
      'iframe[title="Editable component preview"]',
    );
    const topbar = editFrame.getByTestId("component-topbar");
    await expect(topbar).toBeVisible();
    await expect(topbar.getByText("Operations")).toBeVisible();

    const title = topbar.locator("h1.bo-title");
    await title.click({ force: true });
    await expect(title).toHaveAttribute("data-isonim-selected", "true");
    await expect(page.getByText("h1", { exact: true })).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Select breadcrumb header" }),
    ).toBeVisible();
    await page
      .getByRole("button", { name: "Select breadcrumb header" })
      .click();
    await expect(topbar).toHaveAttribute("data-isonim-selected", "true");

    await title.click({ force: true, modifiers: ["Shift"] });
    await expect(topbar).toHaveAttribute("data-isonim-selected", "true");
    await expect(page.getByText("Selection", { exact: true })).toBeVisible();
    await expect(page.getByText("header", { exact: true })).toBeVisible();
    await expect(
      page.getByRole("tab", { name: "Show Layout edit controls" }),
    ).toBeVisible();
    await expect(
      page.getByRole("tab", { name: "Show Size edit controls" }),
    ).toBeVisible();
    await expect(
      page.getByRole("tab", { name: "Show Space edit controls" }),
    ).toBeVisible();
    await expect(
      page.getByRole("tab", { name: "Show Fill edit controls" }),
    ).toBeVisible();
    await expect(
      page.getByRole("tab", { name: "Show Stroke edit controls" }),
    ).toBeVisible();
    await expect(
      page.getByRole("tab", { name: "Show Type edit controls" }),
    ).toBeVisible();
    await expect(
      page.getByRole("tab", { name: "Show Effects edit controls" }),
    ).toBeVisible();
    await expect(
      page
        .getByText("apps/back-office/src/backoffice_ui/components.nim:51")
        .nth(1),
    ).toBeVisible();

    await page.getByRole("tab", { name: "Show Fill edit controls" }).click();
    const colorInput = page.getByLabel("Edit inspector property color").first();
    await expect(colorInput).toBeVisible();
    await expect(page.getByLabel("Cascade origin for color")).toBeVisible();
    await expect(
      page.getByLabel("Edit raw CSS for Fill section"),
    ).toBeVisible();
    await page.getByLabel("Show advanced color controls").click();
    await expect(
      page.getByLabel("Set color from saturation brightness field"),
    ).toBeVisible();
    await expect(page.getByLabel("Set color hue")).toBeVisible();
    await expect(
      page.getByLabel("Choose design token for color"),
    ).toBeVisible();
    await expect(page.getByLabel("Element tree selected header")).toBeVisible();
    const originalColor = await topbar.evaluate(
      (node) => getComputedStyle(node).color,
    );
    const originalBackground = await topbar.evaluate(
      (node) => getComputedStyle(node).backgroundColor,
    );
    await colorInput.fill("");
    await colorInput.fill("#F8FAFC");
    await expect
      .poll(() => topbar.evaluate((node) => getComputedStyle(node).color))
      .toBe("rgb(248, 250, 252)");
    await colorInput.blur();
    await expect(page.getByText("Unsaved source edit")).toBeVisible();
    await expect(page.getByText("1 source plan(s) staged")).toBeVisible();
    await page.getByRole("button", { name: "Copy color property" }).click();
    await page
      .getByRole("button", { name: "Paste into background-color property" })
      .click();
    await expect
      .poll(() =>
        topbar.evaluate((node) => getComputedStyle(node).backgroundColor),
      )
      .toBe("rgb(248, 250, 252)");
    await page
      .getByRole("button", { name: "Revert inspector source edits" })
      .click();
    await expect
      .poll(() => topbar.evaluate((node) => getComputedStyle(node).color))
      .toBe(originalColor);
    await expect
      .poll(() =>
        topbar.evaluate((node) => getComputedStyle(node).backgroundColor),
      )
      .toBe(originalBackground);
    await expect(page.getByText("Unsaved source edit")).toHaveCount(0);

    await title.click({ force: true, modifiers: ["Shift"] });
    await expect(topbar).toHaveAttribute("data-isonim-selected", "true");
    await page.getByRole("tab", { name: "Show Space edit controls" }).click();
    await expect(page.getByText("Box Model", { exact: true })).toBeVisible();
    const rawSpace = page.getByLabel("Edit raw CSS for Space section");
    await expect(rawSpace).toBeVisible();
    await page.getByLabel("Show advanced padding-top controls").click();
    await expect(page.getByLabel("Scrub padding-top value")).toBeVisible();
    const originalPadding = await topbar.evaluate(
      (node) => getComputedStyle(node).paddingTop,
    );
    await page
      .getByRole("button", { name: "Increase padding-top by one" })
      .click();
    await expect
      .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
      .toBe("1px");
    await page
      .getByRole("button", { name: "Revert inspector source edits" })
      .click();
    await expect
      .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
      .toBe(originalPadding);
    await title.click({ force: true, modifiers: ["Shift"] });
    await page.getByRole("tab", { name: "Show Space edit controls" }).click();
    const paddingInput = page.getByRole("textbox", {
      name: "Edit inspector property padding",
      exact: true,
    });
    await paddingInput.fill("");
    await paddingInput.fill("20px");
    await expect
      .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
      .toBe("20px");
    await paddingInput.blur();
    await expect(page.getByText("Unsaved source edit")).toBeVisible();

    await page
      .getByRole("button", { name: "Revert inspector source edits" })
      .click();
    await expect
      .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
      .toBe(originalPadding);
    await page.getByRole("tab", { name: "Show Layout edit controls" }).click();
    await page.getByRole("button", { name: "Set display to flex" }).click();
    await expect
      .poll(() => topbar.evaluate((node) => getComputedStyle(node).display))
      .toBe("flex");
    await expect(page.getByText("Unsaved source edit")).toBeVisible();

    await page
      .getByRole("button", { name: "Save inspector source edits" })
      .click();
    await expect(page.getByText("Unsaved source edit")).toHaveCount(0);
  });

  test("e2e_style_manager_scope_choices_update_real_preview", async ({
    page,
  }) => {
    await page.goto("/");

    await page.getByRole("button", { name: "Open Components section" }).click();
    await page
      .getByRole("button", {
        name: "Select story Operational components / Topbar",
      })
      .click();
    await page
      .getByRole("button", { name: "Open selected component in edit mode" })
      .click();

    const editFrame = page.frameLocator(
      'iframe[title="Editable component preview"]',
    );
    const topbar = editFrame.getByTestId("component-topbar");
    await topbar
      .locator("h1.bo-title")
      .click({ force: true, modifiers: ["Shift"] });
    await expect(topbar).toHaveAttribute("data-isonim-selected", "true");

    await page.getByRole("tab", { name: "Show Space edit controls" }).click();
    await expect(
      page.getByLabel("Style class cascade token manager for padding"),
    ).toBeVisible();
    await expect(page.getByLabel("Current class stack")).toBeVisible();
    await expect(page.getByLabel("Safe style scope choices")).toBeVisible();
    await expect(page.getByLabel("Cascade source layers")).toBeVisible();
    await expect(
      page.getByLabel("Token manager", { exact: true }),
    ).toBeVisible();
    await expect(page.getByLabel("Style diagnostics")).toBeVisible();
    await expect(page.getByLabel("Search reusable styles")).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Create reusable class for padding" }),
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Detach reusable class for padding" }),
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Promote local override for padding" }),
    ).toBeVisible();

    await page
      .getByRole("button", { name: "Apply local instance scope for padding" })
      .click();
    await expect
      .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
      .toBe("20px");
    await expect(page.getByText("Unsaved source edit")).toBeVisible();
    await page
      .getByRole("button", { name: "Save inspector source edits" })
      .click();
    await expect(page.getByText("Unsaved source edit")).toHaveCount(0);

    await page
      .getByRole("button", { name: "Apply shared class scope for padding" })
      .click();
    await expect
      .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
      .toBe("24px");
    await expect(page.getByText("Unsaved source edit")).toBeVisible();
    await page
      .getByRole("button", { name: "Revert inspector source edits" })
      .click();
    await expect
      .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
      .toBe("20px");
    await expect(page.getByText("Unsaved source edit")).toHaveCount(0);
  });

  test("e2e_component_variant_matrix_and_state_controls", async ({ page }) => {
    await page.goto("/");

    await page.getByRole("button", { name: "Open Components section" }).click();
    await page
      .getByRole("button", {
        name: "Select story Operational components / Topbar",
      })
      .click();

    const propertyPanel = page
      .getByLabel("Component property schema and variant matrix")
      .first();
    await expect(propertyPanel).toBeVisible();
    await expect(
      propertyPanel.locator('[data-component-variant-matrix="true"]').first(),
    ).toBeVisible();
    await expect(
      propertyPanel.locator("[data-component-variant-matrix-cell]"),
    ).toHaveCount(13);
    await expect(
      propertyPanel.getByLabel("Edit component property size"),
    ).toHaveValue("md");
    await expect(
      propertyPanel.getByLabel("Cycle component property density"),
    ).toHaveAttribute("title", /density/);

    await propertyPanel.getByLabel("Cycle component property size").click();
    await expect(page.getByText("dirty")).toBeVisible();
    await expect(
      propertyPanel.getByText("1 component plan(s) staged"),
    ).toBeVisible();

    await propertyPanel
      .getByRole("button", { name: "Set component state loading" })
      .click();
    await expect(
      propertyPanel.getByText("2 component plan(s) staged"),
    ).toBeVisible();
    await expect(
      propertyPanel
        .locator('[data-component-variant-matrix-cell*="loading"]')
        .first(),
    ).toContainText("missing story");

    await page
      .getByRole("button", {
        name: "Create story for Operational components loading state",
      })
      .click();
    await expect(
      propertyPanel.getByText("3 component plan(s) staged"),
    ).toBeVisible();
    await expect(
      propertyPanel
        .locator('[data-component-variant-matrix-cell*="loading"]')
        .first(),
    ).toContainText("covered");

    await page
      .getByRole("button", { name: "Revert component property source edits" })
      .click();
    await expect(page.getByText("dirty")).toHaveCount(0);

    await propertyPanel.getByLabel("Cycle component property size").click();
    await page
      .getByRole("button", { name: "Save component property source edits" })
      .click();
    await expect(page.getByText("dirty")).toHaveCount(0);
  });

  test("comment mode routes selected element notes into the AI prompt", async ({
    page,
  }) => {
    await page.goto("/");

    await page.getByRole("button", { name: "Open Components section" }).click();
    await page
      .getByRole("button", {
        name: "Select story Operational components / Topbar",
      })
      .click();
    await page
      .getByRole("button", { name: "Open selected component in edit mode" })
      .click();

    await page.getByRole("button", { name: "Switch to comment mode" }).click();
    await expect(
      page.getByRole("button", { name: "Switch to comment mode" }),
    ).toHaveAttribute("aria-pressed", "true");
    await expect(page.locator(".editor-chat")).toBeVisible();
    await expect(page.locator(".editor-manual-inspector")).toBeHidden();

    const editFrame = page.frameLocator(
      'iframe[title="Editable component preview"]',
    );
    await editFrame.locator("h1.bo-title").first().click({ force: true });
    const comment = editFrame.getByLabel("Comment on selected element");
    await expect(comment).toBeVisible();
    await comment.fill("Make the title hierarchy feel calmer.");
    await comment.press("ArrowLeft");
    await expect(editFrame.locator("h1.bo-title").first()).toHaveAttribute(
      "data-isonim-selected",
      "true",
    );
    await expect(comment).toHaveValue("Make the title hierarchy feel calmer.");
    await editFrame.getByRole("button", { name: "Add" }).click();

    const prompt = page.getByRole("textbox", { name: "Agent prompt" });
    await expect(prompt).toHaveValue(/Design review comments:/);
    await expect(prompt).toHaveValue(/Make the title hierarchy feel calmer/);
  });

  test("e2e_right_panel_width_does_not_jump_between_ai_comment_edit", async ({
    page,
  }) => {
    await page.goto("/");

    const visibleRightPanel = () =>
      page.locator(".editor-chat:visible, .editor-manual-inspector:visible");
    const width = async () => {
      const box = await visibleRightPanel().boundingBox();
      if (!box) throw new Error("right panel is not visible");
      return Math.round(box.width);
    };

    await expect(page.locator(".editor-chat")).toBeVisible();
    const initial = await width();
    await page.getByRole("button", { name: "Widen right panel" }).click();
    await page.getByRole("button", { name: "Widen right panel" }).click();
    const widened = await width();
    expect(widened).toBeGreaterThan(initial);

    await page.getByRole("button", { name: "Switch to edit mode" }).click();
    await expect(page.locator(".editor-manual-inspector")).toBeVisible();
    expect(await width()).toBe(widened);

    await page.getByRole("button", { name: "Widen right panel" }).click();
    const editWidth = await width();
    expect(editWidth).toBeGreaterThan(widened);

    await page.getByRole("button", { name: "Switch to comment mode" }).click();
    await expect(page.locator(".editor-chat")).toBeVisible();
    expect(await width()).toBe(editWidth);

    await page.getByRole("button", { name: "Switch to edit mode" }).click();
    await expect(page.locator(".editor-manual-inspector")).toBeVisible();
    expect(await width()).toBe(editWidth);
  });

  test("e2e_inspector_sections_are_keyboard_and_pointer_operable", async ({
    page,
  }) => {
    await page.goto("/");

    await page.getByRole("button", { name: "Open Components section" }).click();
    await page
      .getByRole("button", {
        name: "Select story Operational components / Topbar",
      })
      .click();
    await page
      .getByRole("button", { name: "Open selected component in edit mode" })
      .click();

    const editFrame = page.frameLocator(
      'iframe[title="Editable component preview"]',
    );
    await editFrame.locator("h1.bo-title").first().click({ force: true });

    const sectionSearch = page.getByRole("textbox", {
      name: "Search inspector sections",
    });
    await expect(sectionSearch).toBeVisible();
    await sectionSearch.fill("fill");
    await expect(
      page.getByRole("button", { name: "Toggle Fill inspector section" }),
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Toggle Layout inspector section" }),
    ).toHaveCount(0);

    const fillSection = page.getByRole("button", {
      name: "Toggle Fill inspector section",
    });
    await fillSection.click();
    await expect(fillSection).toHaveAttribute("aria-expanded", "true");
    await expect(
      page
        .getByRole("textbox", { name: "Edit inspector property color" })
        .first(),
    ).toBeVisible();
    await fillSection.press("Enter");
    await expect(fillSection).toHaveAttribute("aria-expanded", "false");
    await expect(page.getByText("Section collapsed")).toBeVisible();
    await fillSection.press("Enter");
    await expect(fillSection).toHaveAttribute("aria-expanded", "true");
    await expect(
      page
        .getByRole("textbox", { name: "Edit inspector property color" })
        .first(),
    ).toBeVisible();
    await page
      .getByRole("button", { name: "Collapse all inspector sections" })
      .click();
    await expect(page.getByText("Section collapsed")).toBeVisible();
    await page
      .getByRole("button", { name: "Expand relevant inspector sections" })
      .press("Enter");
    await expect(
      page
        .getByRole("textbox", { name: "Edit inspector property color" })
        .first(),
    ).toBeVisible();

    await page.getByRole("tab", { name: "Show Space edit controls" }).click();
    await sectionSearch.fill("space");
    await expect(
      page.getByRole("button", { name: "Toggle Space inspector section" }),
    ).toBeVisible();
    await expect(page.getByLabel("Show box model controls")).toBeVisible();
    await expect(page.getByLabel("Show raw CSS controls")).toBeVisible();
    await expect(
      page.getByLabel("Show source and cascade controls"),
    ).toBeVisible();

    const inspectorOverflow = await page
      .locator(".editor-manual-inspector")
      .evaluate((node) => node.scrollWidth <= node.clientWidth + 1);
    expect(inspectorOverflow).toBe(true);

    await page.setViewportSize({ width: 900, height: 800 });
    const tabletOverflow = await page
      .locator(".editor-manual-inspector")
      .evaluate((node) => node.scrollWidth <= node.clientWidth + 1);
    expect(tabletOverflow).toBe(true);
  });

  test("e2e_canvas_selection_matches_layer_tree_and_breadcrumbs", async ({
    page,
  }) => {
    await page.goto("/");

    await page.getByRole("button", { name: "Open Components section" }).click();
    await page
      .getByRole("button", {
        name: "Select story Operational components / Topbar",
      })
      .click();
    await page
      .getByRole("button", { name: "Open selected component in edit mode" })
      .click();

    const editFrame = page.frameLocator(
      'iframe[title="Editable component preview"]',
    );
    const topbar = editFrame.getByTestId("component-topbar");
    const title = topbar.locator("h1.bo-title");
    await title.click({ force: true });

    await expect(title).toHaveAttribute("data-isonim-selected", "true");
    const titleId = await title.getAttribute("data-isonim-element-id");
    if (!titleId) {
      throw new Error("Selected title did not receive a stable element id");
    }
    const headerId = await topbar.getAttribute("data-isonim-element-id");
    if (!headerId) {
      throw new Error("Topbar ancestor did not receive a stable element id");
    }
    const headerLayerRow = page.locator(`[data-isonim-layer-id="${headerId}"]`);
    await expect(headerLayerRow).toContainText(/components\.nim:\d+/);
    const titleLayerRow = page.locator(`[data-isonim-layer-id="${titleId}"]`);
    const titleLayer = titleLayerRow.getByRole("button", {
      name: "Select layer h1.bo-title",
    });
    await expect(titleLayer).toBeVisible();
    await expect(titleLayerRow).toContainText(/components\.nim:\d+/);
    await expect(
      page.locator('[data-isonim-layer-selected="true"]'),
    ).toContainText("h1.bo-title");
    await expect(
      page.getByRole("button", { name: /Select breadcrumb h1\.bo-title/ }),
    ).toBeVisible();

    const headerToggle = headerLayerRow.getByRole("button", {
      name: /Toggle layer header/,
    });
    await headerToggle.click();
    await expect(titleLayer).toHaveCount(0);
    await headerToggle.click();
    await expect(titleLayer).toBeVisible();

    await title.click({ force: true });
    await title.click({ force: true });
    await expect(topbar).toHaveAttribute("data-isonim-selected", "true");
    await expect(topbar).toHaveAttribute("data-isonim-element-id", headerId);
    await expect(
      page.locator('[data-isonim-layer-selected="true"]'),
    ).toContainText(/header/);

    await page
      .getByRole("textbox", { name: "Search element layers" })
      .fill("h1");
    await titleLayer.click();
    await expect(title).toHaveAttribute("data-isonim-selected", "true");
    await expect(title).toHaveAttribute("data-isonim-element-id", titleId);
    await expect(titleLayerRow).toHaveAttribute(
      "data-isonim-layer-selected",
      "true",
    );

    await page.getByRole("textbox", { name: "Search element layers" }).fill("");
    await page
      .getByRole("button", { name: /Select breadcrumb header/ })
      .click();
    await expect(topbar).toHaveAttribute("data-isonim-selected", "true");
    await expect(topbar).toHaveAttribute("data-isonim-element-id", headerId);
    await expect(headerLayerRow).toHaveAttribute(
      "data-isonim-layer-selected",
      "true",
    );
  });

  test("e2e_selection_survives_mode_viewport_and_save_cycles", async ({
    page,
  }) => {
    await page.goto("/");

    await page.getByRole("button", { name: "Open Components section" }).click();
    await page
      .getByRole("button", {
        name: "Select story Operational components / Topbar",
      })
      .click();
    await page
      .getByRole("button", { name: "Open selected component in edit mode" })
      .click();

    const editFrame = page.frameLocator(
      'iframe[title="Editable component preview"]',
    );
    const topbar = editFrame.getByTestId("component-topbar");
    const title = topbar.locator("h1.bo-title");
    await title.click({ force: true });
    await expect(title).toHaveAttribute("data-isonim-selected", "true");

    await page.getByRole("button", { name: "Switch to comment mode" }).click();
    await expect(title).toHaveAttribute("data-isonim-selected", "true");
    await page.getByRole("button", { name: "Switch to edit mode" }).click();
    await expect(title).toHaveAttribute("data-isonim-selected", "true");

    await page.setViewportSize({ width: 900, height: 900 });
    await expect(title).toHaveAttribute("data-isonim-selected", "true");
    await page.setViewportSize({ width: 430, height: 900 });
    await expect(title).toHaveAttribute("data-isonim-selected", "true");
    await page.setViewportSize({ width: 1280, height: 900 });
    await expect(title).toHaveAttribute("data-isonim-selected", "true");

    await page.getByRole("tab", { name: "Show Fill edit controls" }).click();
    const colorInput = page.getByLabel("Edit inspector property color").first();
    await colorInput.fill("#F8FAFC");
    await colorInput.blur();
    await expect(page.getByText("Unsaved source edit")).toBeVisible();
    await expect(title).toHaveAttribute("data-isonim-selected", "true");

    await page
      .getByRole("button", { name: "Revert inspector source edits" })
      .click();
    await expect(page.getByText("Unsaved source edit")).toHaveCount(0);
    await expect(title).toHaveAttribute("data-isonim-selected", "true");

    await page.getByRole("tab", { name: "Show Layout edit controls" }).click();
    await page.getByRole("button", { name: "Set display to flex" }).click();
    await page
      .getByRole("button", { name: "Save inspector source edits" })
      .click();
    await expect(page.getByText("Unsaved source edit")).toHaveCount(0);
    await expect(title).toHaveAttribute("data-isonim-selected", "true");
  });

  test("e2e_canvas_layout_handles_measurement_and_responsive_overrides", async ({
    page,
  }) => {
    await page.goto("/");

    await page.getByRole("button", { name: "Open Components section" }).click();
    await page
      .getByRole("button", {
        name: "Select story Operational components / Topbar",
      })
      .click();
    await page
      .getByRole("button", { name: "Open selected component in edit mode" })
      .click();

    const editFrame = page.frameLocator(
      'iframe[title="Editable component preview"]',
    );
    const topbar = editFrame.getByTestId("component-topbar");
    await topbar
      .locator("h1.bo-title")
      .click({ force: true, modifiers: ["Shift"] });
    await expect(topbar).toHaveAttribute("data-isonim-selected", "true");
    await expect(
      editFrame.getByLabel("Canvas spacing measurement"),
    ).toBeVisible();
    await expect(editFrame.getByLabel("Canvas gap overlay")).toBeVisible();
    await expect(editFrame.getByLabel("Canvas snap lines")).toBeVisible();
    await expect(editFrame.getByLabel("Resize selected element")).toBeVisible();

    await page.getByRole("tab", { name: "Show Layout edit controls" }).click();
    await expect(
      page.getByLabel("Show layout auto grid constraint controls"),
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Enable flex wrap" }),
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Set grid template tracks" }),
    ).toBeVisible();
    await expect(
      page.getByRole("button", {
        name: "Set left right top bottom constraints",
      }),
    ).toBeVisible();

    await page
      .getByRole("button", { name: "Set auto layout gap to 24px" })
      .click();
    await expect
      .poll(() => topbar.evaluate((node) => getComputedStyle(node).gap))
      .toBe("24px");
    await expect(page.getByText("Unsaved source edit")).toBeVisible();

    const beforeWidth = await topbar.evaluate((node) =>
      Math.round(node.getBoundingClientRect().width),
    );
    const resizeHandle = editFrame.getByLabel("Resize selected element");
    const box = await resizeHandle.boundingBox();
    if (!box) throw new Error("resize handle is not visible");
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width / 2 + 36, box.y + box.height / 2);
    await page.mouse.up();
    await expect
      .poll(() =>
        topbar.evaluate((node) =>
          Math.round(node.getBoundingClientRect().width),
        ),
      )
      .toBeGreaterThan(beforeWidth);

    const gapBeforeMobileOverride = await topbar.evaluate(
      (node) => getComputedStyle(node).gap,
    );
    await page
      .getByRole("button", { name: "Set responsive override for Mobile mode" })
      .click();
    await expect
      .poll(() => topbar.evaluate((node) => getComputedStyle(node).gap))
      .toBe(gapBeforeMobileOverride);
    await expect(page.getByText(/source plan\(s\) staged/)).toBeVisible();

    await page
      .getByRole("button", { name: "Revert inspector source edits" })
      .click();
    await expect(page.getByText("Unsaved source edit")).toHaveCount(0);

    await page.goto("/");
    await page.getByRole("button", { name: "Preview Mobile viewport" }).click();
    await expect(
      page.getByRole("button", { name: "Preview Mobile viewport" }),
    ).toHaveAttribute("aria-pressed", "true");
    await page.getByRole("button", { name: "Open Components section" }).click();
    await page
      .getByRole("button", {
        name: "Select story Operational components / Topbar",
      })
      .click();
    await page
      .getByRole("button", { name: "Open selected component in edit mode" })
      .click();
    const mobileTopbar = editFrame.getByTestId("component-topbar");
    await mobileTopbar
      .locator("h1.bo-title")
      .click({ force: true, modifiers: ["Shift"] });
    await page.getByRole("tab", { name: "Show Layout edit controls" }).click();
    await expect(page.getByText("mobile").first()).toBeVisible();
    await page
      .getByRole("button", { name: "Set responsive override for Mobile mode" })
      .click();
    await expect
      .poll(() => mobileTopbar.evaluate((node) => getComputedStyle(node).gap))
      .toBe("28px");

    const mobileGap = await mobileTopbar.evaluate(
      (node) => getComputedStyle(node).gap,
    );
    await page
      .getByRole("button", { name: "Set responsive override for Tablet mode" })
      .click();
    await expect
      .poll(() => mobileTopbar.evaluate((node) => getComputedStyle(node).gap))
      .toBe(mobileGap);
  });

  test("e2e_figma_grade_numeric_color_shadow_typography_controls", async ({
    page,
  }) => {
    await page.goto("/");

    await page.getByRole("button", { name: "Open Components section" }).click();
    await page
      .getByRole("button", {
        name: "Select story Operational components / Topbar",
      })
      .click();
    await page
      .getByRole("button", { name: "Open selected component in edit mode" })
      .click();

    const editFrame = page.frameLocator(
      'iframe[title="Editable component preview"]',
    );
    const topbar = editFrame.getByTestId("component-topbar");
    const title = topbar.locator("h1.bo-title");

    await title.click({ force: true, modifiers: ["Shift"] });
    await expect(topbar).toHaveAttribute("data-isonim-selected", "true");

    await page.getByRole("tab", { name: "Show Space edit controls" }).click();
    const paddingInput = page.getByLabel("Edit inspector property padding-top");
    await paddingInput.focus();
    await expect(paddingInput).toBeFocused();
    const originalPadding = await topbar.evaluate(
      (node) => getComputedStyle(node).paddingTop,
    );
    await paddingInput.press("ArrowUp");
    await expect
      .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
      .toBe("1px");
    await page
      .getByRole("button", { name: "Cycle unit for padding-top" })
      .click();
    await expect(paddingInput).toHaveValue(/rem$/);
    await paddingInput.fill("6*4px");
    await paddingInput.blur();
    await expect
      .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
      .toBe("24px");
    await expect(page.getByText("Unsaved source edit")).toBeVisible();
    await page
      .getByRole("button", { name: "Revert inspector source edits" })
      .click();
    await expect
      .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
      .toBe(originalPadding);
    await expect(page.getByText("Unsaved source edit")).toHaveCount(0);

    await title.click({ force: true, modifiers: ["Shift"] });
    await expect(topbar).toHaveAttribute("data-isonim-selected", "true");

    await page.getByRole("tab", { name: "Show Fill edit controls" }).click();
    await page.getByLabel("Show advanced color controls").click();
    await expect(page.getByLabel("Use RGB format for color")).toBeVisible();
    await expect(page.getByLabel("Use HSL format for color")).toBeVisible();
    await expect(page.getByLabel("Preview contrast for color")).toBeVisible();
    await expect(
      page.getByLabel("Choose variable mode for color"),
    ).toBeVisible();
    await page.getByLabel("Use RGB format for color").click();
    await expect
      .poll(() => topbar.evaluate((node) => getComputedStyle(node).color))
      .toBe("rgb(59, 130, 246)");
    await expect(page.getByText("Unsaved source edit")).toBeVisible();
    await page
      .getByRole("button", { name: "Save inspector source edits" })
      .click();
    await expect(page.getByText("Unsaved source edit")).toHaveCount(0);

    await page.getByLabel("Show advanced background-image controls").click();
    await expect(page.getByLabel("Edit gradient stops")).toBeVisible();
    await expect(
      page.getByLabel("Set background-image to linear gradient"),
    ).toBeVisible();
    await expect(
      page.getByLabel("Set background-image to radial gradient"),
    ).toBeVisible();
    await page.getByLabel("Scrub background-image gradient angle").click();
    await expect
      .poll(() =>
        topbar.evaluate((node) => (node as HTMLElement).style.backgroundImage),
      )
      .toContain("135deg");

    await page.getByRole("tab", { name: "Show Stroke edit controls" }).click();
    await page.getByLabel("Show advanced border-radius controls").click();
    await expect(page.getByLabel("Edit border radius corners")).toBeVisible();
    await page.getByLabel("Toggle linked border radius corners").click();
    await expect
      .poll(() =>
        topbar.evaluate((node) => (node as HTMLElement).style.borderRadius),
      )
      .toBe("12px");

    await page
      .getByRole("tab", { name: "Show Transitions edit controls" })
      .click();
    await page
      .getByLabel("Show advanced transition-timing-function controls")
      .click();
    await expect(page.getByLabel("Edit transition timing curve")).toBeVisible();
    await expect(
      page.getByLabel("Run reduced-motion diagnostics"),
    ).toBeVisible();
    await page.getByLabel("Set transition timing to ease-in-out").click();
    await expect
      .poll(() =>
        topbar.evaluate(
          (node) => (node as HTMLElement).style.transitionTimingFunction,
        ),
      )
      .toBe("ease-in-out");
    await expect(page.getByText("Unsaved source edit")).toBeVisible();

    await page.getByRole("tab", { name: "Show Effects edit controls" }).click();
    await page.getByLabel("Show advanced box-shadow controls").click();
    await expect(page.getByLabel("Edit shadow with crosshair")).toBeVisible();
    await expect(page.getByLabel("Bind elevation token")).toBeVisible();
    await expect(page.getByLabel("Add shadow layer")).toBeVisible();
    await page.getByLabel("Apply soft shadow preset").click();
    await expect
      .poll(() =>
        topbar.evaluate((node) => (node as HTMLElement).style.boxShadow),
      )
      .toContain("rgba(15, 23, 42");

    await title.click({ force: true });
    await page.getByRole("tab", { name: "Show Type edit controls" }).click();
    await page.getByLabel("Show advanced font-weight controls").click();
    const fontWeightDetails = page
      .getByRole("group", { name: "Show advanced font-weight" })
      .getByLabel("Edit typography details");
    await expect(fontWeightDetails).toBeVisible();
    await expect(
      page
        .getByRole("group", { name: "Show advanced font-weight" })
        .getByLabel("Bind body text style"),
    ).toBeVisible();
    await expect(
      page
        .getByRole("group", { name: "Show advanced font-weight" })
        .getByLabel("Set responsive text mode fluid"),
    ).toBeVisible();
    await expect(
      page
        .getByRole("group", { name: "Show advanced font-weight" })
        .getByLabel("Set text truncation"),
    ).toBeVisible();
    await page
      .getByRole("group", { name: "Show advanced font-weight" })
      .getByLabel("Set font weight to 700")
      .click();
    await expect
      .poll(() => title.evaluate((node) => getComputedStyle(node).fontWeight))
      .toBe("700");

    await expect(page.getByText("Unsaved source edit")).toBeVisible();
    await page
      .getByRole("button", { name: "Revert inspector source edits" })
      .click();
    await expect(page.getByText("Unsaved source edit")).toHaveCount(0);
  });

  test("e2e_property_controls_no_layout_overlap", async ({ page }) => {
    await page.goto("/");

    await page.getByRole("button", { name: "Open Components section" }).click();
    await page
      .getByRole("button", {
        name: "Select story Operational components / Topbar",
      })
      .click();
    await page
      .getByRole("button", { name: "Open selected component in edit mode" })
      .click();

    const editFrame = page.frameLocator(
      'iframe[title="Editable component preview"]',
    );
    const title = editFrame
      .getByTestId("component-topbar")
      .locator("h1.bo-title");
    await title.click({ force: true });

    for (const viewport of [
      { width: 1280, height: 900 },
      { width: 900, height: 900 },
      { width: 430, height: 900 },
    ]) {
      await page.setViewportSize(viewport);
      await page
        .locator('[role="tab"][aria-label="Show Type edit controls"]')
        .evaluate((node) => (node as HTMLElement).click());
      await page
        .locator('[aria-label="Show advanced font-size controls"]')
        .evaluate((node) => {
          (node as HTMLDetailsElement).open = true;
        });
      const inspector = page.locator(".editor-manual-inspector");
      if (!(await inspector.isVisible())) {
        await expect
          .poll(() =>
            page.evaluate(
              () => document.documentElement.scrollWidth <= window.innerWidth,
            ),
          )
          .toBe(true);
        await expect(
          page.locator('[data-inspector-dense-row="true"]:visible'),
        ).toHaveCount(0);
        continue;
      }
      await expect(inspector).toBeVisible();
      const typographyDetails = page
        .getByRole("group", { name: "Show advanced font-size" })
        .getByLabel("Edit typography details");
      await expect(typographyDetails).toBeVisible();

      const rows = await page
        .locator('[data-inspector-dense-row="true"]')
        .evaluateAll((nodes) =>
          nodes.map((node) => {
            const rect = node.getBoundingClientRect();
            const children = Array.from(node.children).map((child) => {
              const childRect = child.getBoundingClientRect();
              return {
                left: childRect.left,
                top: childRect.top,
                right: childRect.right,
                bottom: childRect.bottom,
                width: childRect.width,
                height: childRect.height,
              };
            });
            let overlaps = 0;
            for (let i = 0; i < children.length; i += 1) {
              for (let j = i + 1; j < children.length; j += 1) {
                const a = children[i];
                const b = children[j];
                if (
                  a.width > 0 &&
                  b.width > 0 &&
                  a.left < b.right &&
                  a.right > b.left &&
                  a.top < b.bottom &&
                  a.bottom > b.top
                ) {
                  overlaps += 1;
                }
              }
            }
            return {
              left: rect.left,
              right: rect.right,
              width: rect.width,
              overlaps,
            };
          }),
        );
      expect(rows.length).toBeGreaterThan(0);
      for (const row of rows) {
        expect(row.width).toBeGreaterThan(180);
        expect(row.left).toBeGreaterThanOrEqual(0);
        expect(row.right).toBeLessThanOrEqual(viewport.width + 1);
        expect(row.overlaps).toBe(0);
      }

      const inspectorBox = await inspector.boundingBox();
      const advancedBox = await typographyDetails.boundingBox();
      if (!inspectorBox || !advancedBox) {
        throw new Error("Inspector primitive control boxes are not visible");
      }
      expect(advancedBox.x).toBeGreaterThanOrEqual(inspectorBox.x);
      expect(advancedBox.x + advancedBox.width).toBeLessThanOrEqual(
        inspectorBox.x + inspectorBox.width + 1,
      );
    }
  });

  test("keeps editor state in browser history", async ({ page }) => {
    await page.goto("/");

    await expect(page).toHaveURL(/view=page/);
    await expect(
      page
        .frameLocator('iframe[title="Project preview"]')
        .getByTestId("back-office-app"),
    ).toBeVisible();

    await page
      .getByRole("button", { name: "Open User Journeys section" })
      .click();
    await expect(page).toHaveURL(/view=flow/);
    await expect(page.locator('[data-figma-canvas="true"]')).toBeVisible();

    await page.getByRole("button", { name: "Open Pages section" }).click();
    await expect(page).toHaveURL(/view=page/);
    await expect(
      page
        .frameLocator('iframe[title="Project preview"]')
        .getByTestId("back-office-app"),
    ).toBeVisible();

    await page.getByRole("button", { name: "Preview Mobile viewport" }).click();
    await expect(page).toHaveURL(/viewport=mobile/);
    await expect(page.getByLabel("Preview device frame")).toHaveCSS(
      "width",
      "390px",
    );

    await page
      .getByRole("button", {
        name: "Select story Back-office pages / Customer detail",
      })
      .click();
    await expect(page).toHaveURL(/story=Customer%20detail/);
    await expect(
      page
        .frameLocator('iframe[title="Project preview"]')
        .getByTestId("customer-detail"),
    ).toBeVisible();

    await page.goBack();
    await expect(page).toHaveURL(/viewport=mobile/);
    await expect(page).not.toHaveURL(/story=Customer%20detail/);
    await expect(
      page
        .frameLocator('iframe[title="Project preview"]')
        .getByTestId("back-office-app"),
    ).toBeVisible();

    await page.goBack();
    await expect(page).toHaveURL(/view=page/);
    await expect(page).toHaveURL(/viewport=desktop/);
    await expect(page.getByLabel("Preview device frame")).toHaveCSS(
      "width",
      "1280px",
    );

    await page.goBack();
    await expect(page).toHaveURL(/view=flow/);
    await expect(page.locator('[data-figma-canvas="true"]')).toBeVisible();

    await page.goForward();
    await expect(page).toHaveURL(/view=page/);
    await page.goForward();
    await expect(page).toHaveURL(/viewport=mobile/);
    await page.goForward();
    await expect(page).toHaveURL(/story=Customer%20detail/);
    await expect(
      page
        .frameLocator('iframe[title="Project preview"]')
        .getByTestId("customer-detail"),
    ).toBeVisible();
  });

  test("supports figma-style zooming and panning on flow pages", async ({
    page,
  }) => {
    await page.goto("/");
    await page
      .getByRole("button", { name: "Open User Journeys section" })
      .click();
    await expect(page.locator('[data-figma-canvas="true"]')).toBeVisible();

    const canvas = page.locator('[data-figma-canvas="true"]');
    const content = page.locator('[data-figma-canvas-content="true"]');
    const inlineTransform = async () =>
      await content.evaluate((node) => (node as HTMLElement).style.transform);
    await expect(canvas).toBeVisible();
    await expect.poll(inlineTransform).toBe("translate(0px, 0px) scale(1)");

    await page.getByRole("button", { name: "Zoom storyboard in" }).click();
    await expect.poll(inlineTransform).not.toBe("translate(0px, 0px) scale(1)");

    await page.getByRole("button", { name: "Fit storyboard" }).click();
    await expect.poll(inlineTransform).toBe("translate(0px, 0px) scale(1)");

    const box = await canvas.boundingBox();
    if (!box) throw new Error("Flow canvas is not visible");
    await page.mouse.move(box.x + 20, box.y + 20);
    await page.mouse.down();
    await page.mouse.move(box.x + 100, box.y + 60);
    await page.mouse.up();
    await expect.poll(inlineTransform).toBe("translate(80px, 40px) scale(1)");

    await page.keyboard.down("Control");
    await page.mouse.wheel(0, -240);
    await page.keyboard.up("Control");
    await expect
      .poll(inlineTransform)
      .not.toBe("translate(80px, 40px) scale(1)");
  });
});
