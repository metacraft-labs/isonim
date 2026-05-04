import { test, expect } from "@playwright/test";

test.describe("metacraft-web IsoNim editor consumer", () => {
  test("mounts the live consumer workspace through public editor APIs", async ({
    page,
  }) => {
    await page.goto("/");

    await expect(page.getByText("IsoNim Editor")).toBeVisible();
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
      page.getByText("Back-office pages / Customer detail"),
    ).toBeVisible();
    await expect(page.getByText("Customer billing, entitlement")).toBeVisible();
    await expect(
      page.getByText("apps/back-office/src/backoffice_ui/components.nim"),
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
