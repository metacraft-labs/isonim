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
    await expect(page.getByText("Project component preview")).toBeVisible();

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
        .first(),
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
        .first(),
    ).toBeVisible();

    await page.goto("/?view=vector#vector-editor");
    await expect(page.getByText("Vector Editor")).toBeVisible();
    await page
      .getByRole("button", { name: "Select Rectangle vector tool" })
      .click();
    await expect(
      page.getByRole("button", { name: "Select Rectangle vector tool" }),
    ).toHaveAttribute("aria-pressed", "true");
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
