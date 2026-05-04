import { test, expect } from "@playwright/test";

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
      page.getByText("Pages / Destination Detail").first(),
    ).toBeVisible();
    await expect(page.getByText("Santorini detail with reviews")).toBeVisible();
    await expect(
      page.getByText("examples/wanderlust/components/views.nim:42"),
    ).toBeVisible();

    await page.getByLabel("Edit inspector property padding").fill("24");
    await page.getByLabel("Edit inspector property padding").blur();

    await page
      .getByRole("button", {
        name: "Select story Plan a Trip / Taps Santorini card to see details",
      })
      .click();
    await expect(
      page
        .getByText(
          "Flow action renders project screen Pages / Destination Detail",
        )
        .first(),
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

  test("e2e_editor_agent_fake_adapter_prompt_turn", async ({ page }) => {
    await page.getByLabel("Edit inspector property padding").fill("28");
    await page.getByLabel("Edit inspector property padding").blur();

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
    await expect(page.getByText("1 inspector edit(s)")).toBeVisible();
    await expect(page.getByText("Connected / ready")).toBeVisible();
  });
});
