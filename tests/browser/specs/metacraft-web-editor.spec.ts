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
    ).toBeHidden();
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
      page.getByText("Back-office pages / Customer detail").first(),
    ).toBeVisible();
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

    await page
      .getByRole("button", {
        name: "Select story Customer and license flows / Issue CodeTracer license",
      })
      .click();
    await expect(
      page.getByText("Customer and license flows / Issue CodeTracer license").first(),
    ).toBeVisible();
    await expect(
      page
        .frameLocator('iframe[title="Project preview"]')
        .getByTestId("customer-detail"),
    ).toBeVisible();
    await expect(
      page.getByText("apps/back-office/src/backoffice_server/router.nim").first(),
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
});
