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
      .getByRole("button", { name: "Open User Journeys section" })
      .click();
    await page
      .getByRole("button", {
        name: "Select flow step Taps Santorini card to see details",
      })
      .click();
    await expect(
      page.getByText("Pages / Destination Detail").first(),
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
    await expect(page.getByText("No agent messages")).toBeVisible();
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
});
