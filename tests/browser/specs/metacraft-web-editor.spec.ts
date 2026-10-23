import { readFileSync, realpathSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { test, expect } from "@playwright/test";

const devBridgeSourceFile = resolve(
  "../../../metacraft-web/dist/editor-dev-workspace/apps/back-office/src/backoffice_ui/components.nim",
);
const devBridgeTokenFile = resolve(
  "../../../metacraft-web/dist/editor-dev-workspace/packages/metacraft-design/src/metacraft_design/tokens.nim",
);
const devBridgeComponentSchemaFile = resolve(
  "../../../metacraft-web/dist/editor-dev-workspace/apps/back-office/src/backoffice_editor/component_schema.schema",
);
const componentSchemaBridgeFile =
  "apps/back-office/src/backoffice_editor/component_schema.schema";

async function fillInspectorInputValue(page, input, value: string) {
  await input.fill("");
  await input.fill(value);
  await expect(input).toHaveValue(value);
  const focusTarget = page.getByRole("button", {
    name: "Reset right panel width",
  });
  await focusTarget.focus();
  await expect(focusTarget).toBeFocused();
  await expect(input).toHaveValue(value);
  await expect(page.getByText("Unsaved source edit")).toBeVisible();
}

async function setInspectorProperty(
  page,
  tab: string,
  property: string,
  value: string,
) {
  const tabButton = page.getByRole("tab", {
    name: `Show ${tab} edit controls`,
  });
  await tabButton.click();
  const input = page
    .getByRole("textbox", { name: `Edit inspector property ${property}` })
    .first();
  await expect(input).toBeVisible();
  await fillInspectorInputValue(page, input, value);
}

// The status bar used to carry a "write writable" badge rendering
// `vm.workspacePermissions.writeSource`. The editor specification now keeps
// the status bar to the selection path, mode and save failures only
// ("Saving" / "Only failures surface"), so the same signal is read directly:
// a degraded or absent bridge still yields `writeSource == false`.
async function expectWritableBridge(page) {
  await expect.poll(() => page.evaluate(() =>
    (window as any).__isonimEditorVm.workspacePermissions.value.writeSource)).toBe(true);
  await expect(page.locator('[data-save-error="true"]')).toBeHidden();
}

// Edits are staged and then written automatically after the editor's ~900 ms
// debounce; nothing is pending once the write has landed.
async function expectNoPendingSourceEdits(page) {
  await expect.poll(() => page.evaluate(() =>
    (window as any).__isonimEditorVm.inspector.pendingSourceEdits.value.length)).toBe(0);
  await expect(page.locator('[data-save-error="true"]')).toBeHidden();
}

// The per-view "Open selected component in edit mode" / "Switch to … mode"
// buttons were removed with the per-view inner top bars (M-EVP-6, 00c9fe0):
// the single chrome bar's mode cluster (Spec | View | Comment | Edit) is the
// only mode control (editor spec "Preview-pane chrome layout", item 5). Its
// pills now carry the "Switch to … mode" accessible names themselves; see
// `modeButton` below.
function modeChip(page, mode: "Spec" | "View" | "Comment" | "Edit") {
  return page.locator(`[data-toolbar-cluster="mode"] [data-choice-group-label="${mode}"]`);
}

async function switchMode(page, mode: "Spec" | "View" | "Comment" | "Edit") {
  await modeChip(page, mode).click();
  await expect(modeChip(page, mode)).toHaveAttribute("aria-pressed", "true");
}

// The canonical chrome's segmented pills carry host-supplied accessible names
// (IsoNim a9913b4, "preserve canonical chrome control metadata"): a viewport
// pill is named "Preview viewport <label>" and a mode pill
// "Switch to <mode> mode", while the pill still shows the plain label. These
// role queries are the path assistive technology takes to the controls.
// `expectChromePill` pins the visible label and the domain slug behind such a
// name, so the accessible name, what is shown and what is selected cannot
// drift apart unnoticed.
type ViewportLabel = "Desktop" | "Laptop" | "Tablet" | "Phone";

function viewportButton(page, label: ViewportLabel) {
  return page.locator('[data-toolbar-cluster="viewport"]')
    .getByRole("button", { name: `Preview viewport ${label}`, exact: true });
}

function modeButton(page, mode: "Spec" | "View" | "Comment" | "Edit") {
  return page.locator('[data-toolbar-cluster="mode"]')
    .getByRole("button", { name: `Switch to ${mode.toLowerCase()} mode`, exact: true });
}

async function expectChromePill(pill, label: string, slugAttribute: string, slug: string,
                                rendering: "text" | "icon") {
  await expect(pill).toHaveAttribute("data-choice-group-label", label);
  // A text pill (the viewport cluster) shows its label; an icon-only pill
  // (the mode cluster) shows a glyph and surfaces the label as its tooltip.
  // The caller states which one it expects, so a cluster that silently
  // switches rendering fails here instead of being followed.
  if (rendering === "icon") {
    await expect(pill).toHaveAttribute("data-choice-group-has-icon", "true");
    await expect(pill).toHaveAttribute("title", label);
  } else {
    await expect(pill).not.toHaveAttribute("data-choice-group-has-icon", /.*/);
    await expect(pill).toHaveText(label);
  }
  await expect(pill).toHaveAttribute(slugAttribute, slug);
}

async function openTopbarInEditMode(page) {
  await page.getByRole("button", { name: "Open Components section" }).click();
  await page.getByRole("button", {
    name: "Select story Operational components / Topbar", exact: true,
  }).click();
  await switchMode(page, "Edit");
  const editFrame = page.frameLocator('iframe[title="Editable component preview"]');
  const topbar = editFrame.getByTestId("component-topbar");
  await expect(topbar).toBeVisible();
  await expect.poll(() => topbar.evaluate(node => node.ownerDocument.readyState)).toBe("complete");
  return { editFrame, topbar, title: topbar.locator("h1.bo-title") };
}

// Undo/Redo shortcuts are ignored while a text field owns the keys, so the
// shortcut is pressed from a real, non-editable control: the active Edit
// chip of the chrome-bar mode cluster.
async function pressHistoryShortcut(page, redo = false) {
  const target = modeChip(page, "Edit");
  await target.focus();
  await expect(target).toBeFocused();
  await page.keyboard.press(redo ? "ControlOrMeta+Shift+Z" : "ControlOrMeta+Z");
}

async function undoInspectorHistoryTo(page, length: number) {
  const history = () => page.evaluate(() =>
    (window as any).__isonimEditorVm.inspector.undoStack.value.length);
  while ((await history()) > length) {
    const before = await history();
    await pressHistoryShortcut(page);
    await expect.poll(history).toBeLessThan(before);
  }
}

// Shift-click used to climb from the title to the topbar because the title
// carried no source stamp. The consumer bundle now carries genuine compiler
// stamps, so the stamped title is itself the nearest source-bearing element;
// the Layers row is the deterministic way to select the topbar.
async function selectTopbarElement(page, topbar) {
  await page.getByRole("button", {
    name: "header[data-testid=component-topbar]", exact: true,
  }).click();
  await expect(topbar).toHaveAttribute("data-isonim-selected", "true");
}

// Inspector rows are addressed by their stable `data-property-row` key.
function propertyRowInput(page, row: string) {
  return page.locator(`[data-property-row="${row}"] input[data-property-row-input]`);
}

// Restore a generated dev-workspace source after a case. If the page is gone
// (e.g. a timeout closed it), write the copy directly so a failure here cannot
// leak into later cases -- the same fallback as the sibling-undo case.
async function restoreDevBridgeFile(page, file: string, path: string, beforeText: string) {
  const current = readFileSync(path, "utf8");
  if (current === beforeText) return;
  try {
    await revertDevBridgeFiles(page, [{ file, beforeText, afterText: current }]);
  } catch (error) {
    writeFileSync(path, beforeText);
    throw error;
  }
}

// The consumer bridge is engaged unless `?writeBridge=0`, so a case at "/"
// writes the generated dev-workspace copies too. Cases that can write take a
// snapshot of all four owned copies and restore them exactly afterwards,
// whatever happened, so no marker leaks into a later case.
const devWorkspaceFiles: Array<[string, string]> = [
  ["apps/back-office/src/backoffice_ui/components.nim", devBridgeSourceFile],
  ["packages/metacraft-design/src/metacraft_design/tokens.nim", devBridgeTokenFile],
  [componentSchemaBridgeFile, devBridgeComponentSchemaFile],
  ["apps/back-office/src/backoffice_editor/story_fixtures.schema", resolve(
    "../../../metacraft-web/dist/editor-dev-workspace/apps/back-office/src/backoffice_editor/story_fixtures.schema")],
];

function snapshotDevWorkspace(): string[] {
  return devWorkspaceFiles.map(([, path]) => readFileSync(path, "utf8"));
}

async function restoreDevWorkspace(page, before: string[]) {
  for (let i = 0; i < devWorkspaceFiles.length; i += 1) {
    const [file, path] = devWorkspaceFiles[i];
    await restoreDevBridgeFile(page, file, path, before[i]);
  }
  for (let i = 0; i < devWorkspaceFiles.length; i += 1) {
    expect(readFileSync(devWorkspaceFiles[i][1], "utf8")).toBe(before[i]);
  }
}

async function revertDevBridgeFiles(page, files) {
  const response = await page.evaluate(async (changes) => {
    const reverted = await fetch("/__isonim-dev-bridge/transaction", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        mode: "revert",
        files: changes,
      }),
    });
    return await reverted.json();
  }, files);
  expect(response.ok).toBe(true);
}

// `vm.livePreviewReloadGeneration` is stamped into each preview document as
// `<meta name="isonim-rendered-generation">` (preview_identity.nim); the
// former `isonim-reload:N` comment carried the same counter.
async function iframeReloadGeneration(frame) {
  const srcdoc = (await frame.getAttribute("srcdoc")) ?? "";
  const match = srcdoc.match(/<meta name="isonim-rendered-generation" content="(\d+)">/);
  return match ? Number(match[1]) : -1;
}

async function computedBackground(locator) {
  return await locator.evaluate(
    (node) => getComputedStyle(node).backgroundColor,
  );
}

function currentTopbarPaddingMarker() {
  const matches = [
    ...readFileSync(devBridgeSourceFile, "utf8").matchAll(
      /^# isonim-editor .* padding=([^\n]+)/gm,
    ),
  ];
  return matches.length > 0 ? matches[matches.length - 1][1].trim() : "0px";
}

// The Topbar's shared class is the top-level `.bo-topbar` rule of
// metacraft-design's tokens.nim (metacraft-web `ClassRuleOwner`): its
// unindented `.bo-topbar {` line through the first unindented `}`. An indented
// `.bo-topbar {` belongs to an `@media` block and is not this rule.
function topLevelTopbarRule(tokens: string): string {
  const lines = tokens.split("\n");
  const open = lines.findIndex((line) => line === ".bo-topbar {");
  if (open < 0) return "";
  const close = lines.findIndex((line, i) => i > open && line === "}");
  return close < 0 ? "" : lines.slice(open, close + 1).join("\n");
}

test.describe("metacraft-web IsoNim editor consumer", () => {
  // Current case1 keeps the real consumer file/preview/CAS responsibility.
  // The frontend is compiled; consumer post-write compile callbacks are
  // declarative descriptors, not evidence of a subsequent compiler execution.
  test("e2e_metacraft_editor_writes_real_design_schema_files", async ({ page }) => {
    await page.goto("/?writeBridge=1");
    await expect.poll(() => readFileSync(devBridgeSourceFile, "utf8"))
      .toContain("component-topbar");
    const beforeText = readFileSync(devBridgeSourceFile, "utf8");
    const errors: string[] = [];
    page.on("pageerror", error => errors.push(error.message));
    const applies: any[] = [];
    page.on("request", request => {
      if (request.url().endsWith("/__isonim-dev-bridge/transaction")) {
        const body = request.postDataJSON();
        if (body.mode === "apply") applies.push(body);
      }
    });
    try {
      await page.getByRole("button", { name: "Open Components section" }).click();
      await page.getByRole("button", {
        name: "Select story Operational components / Topbar", exact: true,
      }).click();
      await page.locator('[data-toolbar-cluster="mode"] [data-choice-group-label="View"]').click();
      await page.locator('[data-toolbar-cluster="mode"] [data-choice-group-label="Edit"]').click();
      const topbar = page.frameLocator('iframe[title="Editable component preview"]')
        .getByTestId("component-topbar");
      await expect(topbar).toBeVisible();
      await page.getByRole("button", {
        name: "header[data-testid=component-topbar]", exact: true,
      }).click();
      await expect(topbar).toHaveAttribute("data-isonim-selected", "true");
      await expect.poll(() => topbar.evaluate(node => getComputedStyle(node).display)).toBe("flex");
      const beforeHistory = await page.evaluate(() => {
        const inspector = (window as any).__isonimEditorVm.inspector;
        if (!Array.isArray(inspector.undoStack.value)) throw new Error("Missing actual history");
        return inspector.undoStack.value.length;
      });
      await page.locator('[data-layout-source-scope-property="display"]')
        .getByRole("button", { name: "Apply local instance scope for display", exact: true }).click();
      const displayImpact = page.locator('[data-layout-source-impact-property="display"]');
      await expect(displayImpact).toContainText("display · Local instance");
      await expect(displayImpact).toContainText("Owner: Selected instance");
      await expect(displayImpact).toContainText("Known uses: 1");
      const compilerStamp = await topbar.getAttribute("data-isonim-src");
      const compilerLocation = compilerStamp?.match(/^(.*):(\d+):\d+$/);
      if (!compilerLocation) throw new Error("Missing actual compiler source location");
      expect(realpathSync(compilerLocation[1])).toBe(realpathSync(resolve("../../../metacraft-web/apps/back-office/src/backoffice_ui/components.nim")));
      await expect(displayImpact).toContainText(`Source: ${compilerLocation[1]}:${compilerLocation[2]}`);
      await expect(displayImpact).not.toContainText("Changes the shared source definition");
      // 'flex' is already the authored value; choose a genuinely different
      // supported mode instead of demanding a source write for a valid no-op.
      await page.getByRole("button", { name: "Set layout to none", exact: true }).click();
      await expect.poll(() => topbar.evaluate(node => getComputedStyle(node).display)).toBe("block");
      await expect.poll(() => readFileSync(devBridgeSourceFile, "utf8"))
        .toContain("# isonim-editor dom.component-topbar.display display=block");
      await expect.poll(() => page.evaluate(() => (window as any).__isonimEditor.pendingSourceEdits())).toBe(0);
      await expect(page.locator('[data-save-error="true"]')).toBeHidden();
      await expect(topbar).toHaveAttribute("data-isonim-selected", "true");
      expect(await page.evaluate(() => (window as any).__isonimEditorVm.inspector.undoStack.value.length))
        .toBe(beforeHistory + 1);
      expect(applies).toHaveLength(1);
      expect(applies[0].files).toHaveLength(1);
      expect(applies[0].files[0].file).toBe("apps/back-office/src/backoffice_ui/components.nim");
      expect(readFileSync(devBridgeSourceFile, "utf8")).not.toBe(beforeText);
      expect(errors).toEqual([]);
    } finally {
      const afterText = readFileSync(devBridgeSourceFile, "utf8");
      if (afterText !== beforeText) {
        await revertDevBridgeFiles(page, [{
          file: "apps/back-office/src/backoffice_ui/components.nim", beforeText, afterText,
        }]);
      }
      expect(readFileSync(devBridgeSourceFile, "utf8")).toBe(beforeText);
    }
    await page.goto("/?writeBridge=1");
    await page.getByRole("button", { name: "Select story Operational components / Topbar", exact: true }).click();
    await page.locator('[data-toolbar-cluster="mode"] [data-choice-group-label="View"]').click();
    await page.locator('[data-toolbar-cluster="mode"] [data-choice-group-label="Edit"]').click();
    const restoredTopbar = page.frameLocator('iframe[title="Editable component preview"]')
      .getByTestId("component-topbar");
    await expect(restoredTopbar).toBeVisible();
    await expect.poll(() => restoredTopbar.evaluate(node => getComputedStyle(node).display)).toBe("flex");
    expect(errors).toEqual([]);
  });

  test("e2e_metacraft_foundations_page_file_backed_edit_revert", async ({
    page,
  }) => {
    await page.goto("/?writeBridge=1&view=foundations");
    await expect
      .poll(() => readFileSync(devBridgeTokenFile, "utf8"))
      .toContain("--mcl-space-3");
    await expect(page.locator('[data-foundations-page="true"]')).toBeVisible();

    const beforeText = readFileSync(devBridgeTokenFile, "utf8");
    try {
      await page
        .getByRole("button", { name: "Select foundation category Spacing" })
        .click();
      await page
        .getByRole("button", { name: "Select foundation token space.table.cell" })
        .click();
      await page
        .getByRole("textbox", { name: "Foundation token value" })
        .fill("1rem");
      await page
        .getByRole("button", { name: "Apply foundation token value" })
        .click();
      await expect(page.locator("[data-foundation-impact]")).toContainText(
        "space.table.cell",
      );
      // Saving is automatic (editor spec "Saving"; the Save control is gone):
      // the token commit is written without a further gesture.
      await expect.poll(() => page.evaluate(() => (window as any).__isonimEditor.pendingSourceEdits())).toBe(0);
      await expect(page.locator('[data-save-error="true"]')).toBeHidden();
      await expect
        .poll(() => readFileSync(devBridgeTokenFile, "utf8"))
        .toContain("--mcl-space-3: 1rem");

      await page
        .getByRole("textbox", { name: "Foundation token value" })
        .fill("0.75rem");
      await page
        .getByRole("button", { name: "Apply foundation token value" })
        .click();
      await expect
        .poll(() => readFileSync(devBridgeTokenFile, "utf8"))
        .toContain("--mcl-space-3: 0.75rem");

      const revertedText = readFileSync(devBridgeTokenFile, "utf8");
      expect(revertedText.trimEnd()).toBe(beforeText.trimEnd());
    } finally {
      const afterText = readFileSync(devBridgeTokenFile, "utf8");
      if (afterText !== beforeText) {
        await revertDevBridgeFiles(page, [{
          file: "packages/metacraft-design/src/metacraft_design/tokens.nim",
          beforeText, afterText,
        }]);
      }
      expect(readFileSync(devBridgeTokenFile, "utf8")).toBe(beforeText);
    }
  });

  // Reconciled 2026-10-14. Retired: the status-bar "write writable" badge,
  // the per-view edit button, tabbed `Edit inspector property X` textboxes,
  // the Save button and "Unsaved source edit" (editor spec "Saving",
  // "Section-Based Design"). Current mapping: `overflow` and
  // `letter-spacing` are Layout/Typography rows; the remaining long-tail
  // declarations (filter, transform, transition-duration, aspect-ratio,
  // background-size) have no dedicated row and go through the spec's
  // per-section Raw CSS editor ("Universal Patterns — Raw CSS toggle";
  // Effects consolidates Transitions + Filters). Every write, preview and
  // source-marker assertion is retained, followed by exact revert.
  test("metacraft_long_tail_properties_validate_real_components", async ({
    page,
  }) => {
    await page.goto("/?writeBridge=1");
    await expectWritableBridge(page);
    const beforeText = readFileSync(devBridgeSourceFile, "utf8");

    const { topbar } = await openTopbarInEditMode(page);
    await selectTopbarElement(page, topbar);

    const setRawCss = async (section: string, declaration: string) => {
      const header = page.locator(`[data-inspector-section-header="${section}"]`);
      if ((await header.getAttribute("aria-expanded")) !== "true") await header.click();
      const label = section[0].toUpperCase() + section.slice(1);
      const raw = page.getByRole("textbox", { name: `Edit raw CSS for ${label} section` });
      await expect(raw).toBeVisible();
      await raw.fill(declaration);
      await raw.press("Enter");
    };
    const setChoice = async (row: string, option: string) => {
      const target = page.locator(`[data-property-row="${row}"]`);
      await target.locator("[data-choice-group-trigger]").click();
      await page.locator("[data-choice-group-option]").filter({
        hasText: new RegExp(`^${option}$`, "i"),
      }).first().click();
    };
    const setNumeric = async (row: string, value: string) => {
      const input = propertyRowInput(page, row);
      await input.click();
      await input.fill(value);
      await input.press("Enter");
    };

    try {
      await setRawCss("effects", "filter: brightness(1.08) contrast(1.1)");
      await expect
        .poll(() => topbar.evaluate((node) => getComputedStyle(node).filter))
        .toContain("brightness");
      await setRawCss("effects", "transform: translateX(8px) scale(1.02)");
      await expect
        .poll(() => topbar.evaluate((node) => getComputedStyle(node).transform))
        .not.toBe("none");
      await setRawCss("effects", "transition-duration: 180ms");
      await setChoice("overflow", "hidden");
      await setRawCss("layout", "aspect-ratio: 4 / 3");
      await setRawCss("fill", "background-size: contain");
      // Typography is shown only for a text element (spec "Section
      // catalogue"), so letter-spacing is set on the topbar's title.
      await topbar.locator("h1.bo-title").click({ force: true });
      await setNumeric("letter-spacing", "0.03em");
      await expectNoPendingSourceEdits(page);

      await expect
        .poll(() => readFileSync(devBridgeSourceFile, "utf8"))
        .toContain("filter=brightness(1.08) contrast(1.1)");
      const afterText = readFileSync(devBridgeSourceFile, "utf8");
      expect(afterText).toContain("transform=translateX(8px) scale(1.02)");
      expect(afterText).toContain("transition-duration=180ms");
      expect(afterText).toContain("overflow=hidden");
      expect(afterText).toContain("aspect-ratio=4 / 3");
      expect(afterText).toContain("background-size=contain");
      expect(afterText).toContain("letter-spacing=0.03em");
    } finally {
      await restoreDevBridgeFile(page, "apps/back-office/src/backoffice_ui/components.nim",
        devBridgeSourceFile, beforeText);
    }
    await expect
      .poll(() => readFileSync(devBridgeSourceFile, "utf8"))
      .toBe(beforeText);
  });

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
        name: "Open Partner operations journey", exact: true,
      }),
    ).toBeHidden();
    await page
      .getByRole("button", { name: "Toggle User Journeys section" })
      .click();
    await expect(page.getByRole("button", {
      name: "Open Partner operations journey", exact: true,
    })).toBeVisible();

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
    await page
      .getByRole("button", {
        name: "Select story Back-office pages / Operations dashboard",
      })
      .click();
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

    // Exact preset dimensions are the approved viewport table (desktop,
    // tablet, phone), superseding the former 1280/834/mobile vocabulary.
    const frame = page.getByLabel("Preview device frame");
    await expect(frame).toHaveCSS("width", "1440px");
    await expect(frame).toHaveCSS("height", "900px");

    const dashboardStory = page.getByRole("button", {
      name: "Select story Back-office pages / Operations dashboard", exact: true,
    });
    await expect(dashboardStory).toBeVisible();
    await expect(dashboardStory).toHaveAttribute("aria-current", "true");
    await page
      .getByRole("textbox", { name: "Search stories" })
      .fill("customer detail");
    // Search must hide a row proven present, while leaving the actual preview
    // selection intact; an already absent journey story is not that oracle.
    await expect(dashboardStory).toHaveCount(0);
    await expect(page.frameLocator('iframe[title="Project preview"]')
      .getByTestId("back-office-app")).toBeVisible();
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
    await expect(dashboardStory).toBeVisible();
    await expect(dashboardStory).toHaveAttribute("aria-current", "true");

    for (const [label, slug] of [
      ["Desktop", "desktop"], ["Laptop", "laptop"], ["Tablet", "tablet"], ["Phone", "phone"],
    ] as [ViewportLabel, string][]) {
      await expectChromePill(viewportButton(page, label), label, "data-preview-viewport", slug, "text");
    }
    await expect(viewportButton(page, "Desktop")).toHaveAttribute("aria-pressed", "true");

    await viewportButton(page, "Tablet").click();
    await expect(viewportButton(page, "Tablet")).toHaveAttribute("aria-pressed", "true");
    await expect(viewportButton(page, "Desktop")).toHaveAttribute("aria-pressed", "false");
    await expect(frame).toHaveCSS("width", "1024px");
    await expect(frame).toHaveCSS("height", "768px");

    await viewportButton(page, "Phone").click();
    await expect(viewportButton(page, "Phone")).toHaveAttribute("aria-pressed", "true");
    await expect(frame).toHaveCSS("width", "390px");
    await expect(frame).toHaveCSS("height", "844px");

    await viewportButton(page, "Desktop").click();
    await expect(frame).toHaveCSS("width", "1440px");

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

    for (const mode of ["Spec", "View", "Comment", "Edit"] as const) {
      await expectChromePill(modeButton(page, mode), mode, "data-preview-mode", mode.toLowerCase(), "icon");
    }
    await modeButton(page, "Edit").click();
    await expect(modeButton(page, "Edit")).toHaveAttribute("aria-pressed", "true");
    await expect(modeButton(page, "View")).toHaveAttribute("aria-pressed", "false");
    await expect(page.locator('[data-sidebar-content="inspector"]')).toBeVisible();
    await expect(page.locator('[data-sidebar-content="ai-assistant"]')).toHaveCount(0);
    await expect(page.locator('[data-inspector-section-header]').first()).toBeVisible();
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
    const pageSource = page.locator('[data-scene-graph-source]')
      .filter({ hasText: /components\.nim:\d+/ }).first();
    await expect(pageSource).toBeVisible();
    await expect(pageSource).toHaveAttribute("title", /apps\/back-office\/src\/backoffice_ui\/components\.nim:\d+$/);

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
    await expect(topbarFrame).toHaveAccessibleDescription(
      "Topbar renders from the same IsoNim component function used by the back-office pages.",
    );
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
    await expect(pageSource).toBeVisible();
    await expect(pageSource).toHaveAttribute("title", /apps\/back-office\/src\/backoffice_ui\/components\.nim:\d+$/);

    await page.goto("/?view=vector#vector-editor");
    await expect(page.getByText("Vector Editor")).toBeVisible();
    const vectorHost = page.locator('[data-vector-adapter="fabric"]').first();
    await expect(vectorHost).toHaveAttribute(
      "data-vector-symbol-name",
      "Status badge",
    );
    await expect(vectorHost).toHaveAttribute(
      "data-vector-library-backed",
      "true",
    );
    await expect(vectorHost).toHaveAttribute("data-vector-svgo-backed", "true");
    await expect(vectorHost).toHaveAttribute(
      "data-vector-path-library-backed",
      "true",
    );
    await page
      .getByRole("button", { name: "Select Rectangle vector tool" })
      .click();
    await expect(
      page.getByRole("button", { name: "Select Rectangle vector tool" }),
    ).toHaveAttribute("aria-pressed", "true");
    await expect(vectorHost).toHaveAttribute(
      "data-vector-path-overlay-visible",
      "true",
    );
    await page
      .getByRole("button", { name: "Vector path-convert-smooth" })
      .click();
    await expect(vectorHost).toHaveAttribute(
      "data-vector-path-operation",
      "convert-smooth",
    );
    await page.getByRole("button", { name: "Vector export" }).click();
    await expect(vectorHost).toHaveAttribute(
      "data-vector-export-has-svg",
      "true",
    );
  });

  // Reconciled 2026-10-14 to the current editor (spec "Preview-pane chrome
  // layout", "Mode-driven right sidebar", "Section-Based Design", "Property
  // row pattern", "Saving", "Universal Patterns"): Edit via the mode
  // cluster; the Inspector replaces the AI assistant in Edit; the selected
  // tag shows in the status bar and the breadcrumb is the status-bar
  // selection path; tabs became sections (Size/Space rows live in Layout);
  // the element's source location is in the Source section; on a non-text
  // element Fill's first entry is `background-color` and its colour editor
  // is the shared picker; "Increase by one" became the spec's ArrowUp step;
  // copy is right-click on the fill entry and paste is the Stroke Color
  // row's More (⫶) menu; raw CSS for the former Space section is Layout's;
  // "Scrub padding-top value" is a physical drag on the row label;
  // Revert/Save became Undo and automatic saving. Shift-click is replaced by
  // the Layers row (see `selectTopbarElement`). Behaviour and presence
  // assertions are kept or mapped; none is dropped.
  test("edits real metacraft component DOM through the inspector", async ({
    page,
  }) => {
    await page.goto("/");
    const workspaceBefore = snapshotDevWorkspace();
    try {

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

      await switchMode(page, "Edit");
      await expect(page).toHaveURL(/view=edit/);
      await expect(page.getByText("Project component preview")).toHaveCount(0);
      await expect(page.locator('[data-sidebar-content="ai-assistant"]')).toHaveCount(0);
      const inspector = page.locator('[data-sidebar-content="inspector"]');
      await expect(inspector).toBeVisible();

      const editFrame = page.frameLocator(
        'iframe[title="Editable component preview"]',
      );
      const topbar = editFrame.getByTestId("component-topbar");
      await expect(topbar).toBeVisible();
      await expect(topbar.getByText("Operations")).toBeVisible();

      const statusBar = page.locator(".editor-statusbar");
      const title = topbar.locator("h1.bo-title");
      await title.click({ force: true });
      await expect(title).toHaveAttribute("data-isonim-selected", "true");
      await expect(statusBar.getByText("h1", { exact: true })).toBeVisible();
      const headerCrumb = page.getByRole("button", {
        name: "Select breadcrumb header[data-testid=component-topbar]", exact: true,
      });
      await expect(headerCrumb).toBeVisible();
      await headerCrumb.click();
      await expect(topbar).toHaveAttribute("data-isonim-selected", "true");

      await selectTopbarElement(page, topbar);
      await expect(statusBar.getByText("header", { exact: true })).toBeVisible();
      for (const slug of ["layout", "fill", "stroke", "typography", "effects"]) {
        await expect(page.locator(`[data-inspector-section-header="${slug}"]`)).toBeVisible();
      }
      for (const row of ["w", "h", "pad-top"]) {
        await expect(page.locator(`[data-property-row="${row}"]`)).toBeVisible();
      }
      const source = page.locator('[data-inspector-section-header="source"]');
      if ((await source.getAttribute("aria-expanded")) !== "true") await source.click();
      await expect(page.locator('[data-inspector-section-body="source"]'))
        .toContainText("apps/back-office/src/backoffice_ui/components.nim:51");

      const colorInput = page.getByRole("textbox", { name: "Edit fill hex" }).first();
      await expect(colorInput).toBeVisible();
      // Cascade origin / scope of the fill (spec "Cascade indicator").
      await expect(page.getByLabel("Choose fill source scope", { exact: true })).toBeVisible();
      await expect(page.getByLabel("Edit raw CSS for Fill section")).toBeVisible();
      // The former Space section's padding rows live in Layout.
      await expect(page.getByLabel("Edit raw CSS for Layout section")).toBeVisible();
      // Advanced colour controls: the fill swatch opens the shared picker.
      await page.locator('[data-fill-row-swatch="0"]').click();
      const picker = page.getByLabel("Edit color", { exact: true }).filter({ visible: true });
      await expect(picker.getByLabel("Color saturation and brightness")).toBeVisible();
      await expect(picker.getByLabel("Hue", { exact: true })).toBeVisible();
      await page.keyboard.press("Escape");
      await expect(
        page.getByRole("button", { name: "Bind fill to variable" }).first(),
      ).toBeVisible();
      // "Element tree selected header": the Layers row of the selection.
      await expect(page.getByRole("button", {
        name: "header[data-testid=component-topbar]", exact: true,
      })).toHaveAttribute("data-selected", "true");
      const history = () => page.evaluate(() =>
        (window as any).__isonimEditorVm.inspector.undoStack.value.length);
      const startHistory = await history();
      const originalColor = await topbar.evaluate(
        (node) => getComputedStyle(node).color,
      );
      const originalBackground = await topbar.evaluate(
        (node) => getComputedStyle(node).backgroundColor,
      );
      await colorInput.fill("");
      await colorInput.fill("#F8FAFC");
      await colorInput.press("Enter");
      await expect
        .poll(() =>
          topbar.evaluate((node) => getComputedStyle(node).backgroundColor),
        )
        .toBe("rgb(248, 250, 252)");
      await expect.poll(history).toBe(startHistory + 1);
      await expectNoPendingSourceEdits(page);
      // Copy the fill value (spec "Universal Patterns": right-click property
      // -> Copy; the fill entry has no More slot) and paste it into the
      // Stroke Color row through its More (⫶) menu. The right-click is on
      // the entry's swatch: the entry's centre is its hex field, where "right-
      // click keeps the browser's own cut, copy and paste menu; the property
      // menu opens outside editable fields" (same spec section).
      await page.locator('[data-fill-row-swatch="0"]').click({ button: "right" });
      await page.getByRole("menuitem", { name: "Copy property" }).click();
      { const stroke = page.locator('[data-inspector-section-header="stroke"]'); if ((await stroke.getAttribute("aria-expanded")) !== "true") await stroke.click(); } // Stroke is collapsed by default (spec "Section catalogue").
      await page.getByRole("button", { name: "More actions for Color" }).click();
      await page.getByRole("menuitem", { name: "Paste property" }).click();
      await expect
        .poll(() =>
          topbar.evaluate((node) => getComputedStyle(node).borderTopColor),
        )
        .toBe("rgb(248, 250, 252)");
      const undoAll = () => undoInspectorHistoryTo(page, startHistory);
      await undoAll();
      await expect
        .poll(() => topbar.evaluate((node) => getComputedStyle(node).color))
        .toBe(originalColor);
      await expect
        .poll(() =>
          topbar.evaluate((node) => getComputedStyle(node).backgroundColor),
        )
        .toBe(originalBackground);
      await expectNoPendingSourceEdits(page);

      await selectTopbarElement(page, topbar);
      const padTop = propertyRowInput(page, "pad-top");
      const originalPadding = await topbar.evaluate(
        (node) => getComputedStyle(node).paddingTop,
      );
      await padTop.focus();
      await page.keyboard.press("ArrowUp");
      await expect
        .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
        .toBe("1px");
      await padTop.press("Enter");
      await undoAll();
      await expect
        .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
        .toBe(originalPadding);
      // "Scrub padding-top value": click-drag on the row's label (spec
      // "Numeric Inputs", "Property row pattern — Label scrubber"). The
      // `label-scrubber` slot is zero-sized; the visible label inside the
      // value pill is the scrub handle.
      await selectTopbarElement(page, topbar);
      const scrub = page.locator('[data-property-row="pad-top"] [data-property-row-field-label="true"]');
      await expect(scrub).toBeVisible();
      const scrubBox = await scrub.boundingBox();
      if (!scrubBox) throw new Error("padding-top scrub label is not visible");
      await page.mouse.move(scrubBox.x + scrubBox.width / 2, scrubBox.y + scrubBox.height / 2);
      await page.mouse.down();
      await page.mouse.move(scrubBox.x + scrubBox.width / 2 + 12,
        scrubBox.y + scrubBox.height / 2, { steps: 4 });
      await page.mouse.up();
      await expect
        .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
        .not.toBe(originalPadding);
      await expect.poll(history).toBe(startHistory + 1);
      await undoAll();
      await expect
        .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
        .toBe(originalPadding);
      await selectTopbarElement(page, topbar);
      await padTop.click();
      await padTop.fill("20");
      await padTop.press("Enter");
      await expect
        .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
        .toBe("20px");
      await expect.poll(history).toBe(startHistory + 1);
      await undoAll();
      await expect
        .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
        .toBe(originalPadding);
      await page.locator('[data-layout-source-scope-property="display"]')
        .getByRole("button", { name: "Apply local instance scope for display", exact: true }).click();
      await page.getByRole("button", { name: "Set layout to none", exact: true }).click();
      await expect
        .poll(() => topbar.evaluate((node) => getComputedStyle(node).display))
        .toBe("block");
      await expect.poll(history).toBe(startHistory + 1);
      await expectNoPendingSourceEdits(page);
      await undoAll();
    } finally {
      await restoreDevWorkspace(page, workspaceBefore);
    }
  });

  // Reconciled 2026-10-14. The per-property "style class cascade token
  // manager" panel was replaced by the property row pattern (editor spec
  // "Property row pattern", "Inspector UI for Shared Properties"): a compact
  // scope strip with the less common scopes in its overflow, a bind-to-
  // variable chip, and the Source section for scope/ownership diagnostics.
  // "Search reusable styles" maps to the variable picker's search field and
  // "Detach reusable class" to the spec's Detach on the shared path ("Edit
  // Routing"). Dropped presence checks with no current spec clause: "Create
  // reusable class" and "Promote local override" (see TRIAGE). Scope choice
  // no longer applies a value; it routes the next edit. Retained: a
  // local-instance padding edit with its preview, a shared-class edit with
  // its preview, its reversal to the local value, and Detach. Save/Revert
  // became automatic saving and Undo.
  //
  // Re-authored 2026-10-22 with the Topbar's honest shared owner offered
  // (metacraft-web `.bo-topbar`, isonim-pm issue 2026-09-26-the-consumer-
  // editor-spec-tests-the-inspector-that-was-demolished): each scope's write
  // is checked where it lands -- the local edit as the element's own
  // components.nim marker, the shared edit in tokens.nim's top-level
  // `.bo-topbar` rule, and Detach as a new local marker carrying the shared
  // value while the rule keeps it.
  test("e2e_style_manager_scope_choices_update_real_preview", async ({
    page,
  }) => {
    await page.goto("/");
    const workspaceBefore = snapshotDevWorkspace();
    const tokensBefore = readFileSync(devBridgeTokenFile, "utf8");
    const componentsBefore = readFileSync(devBridgeSourceFile, "utf8");
    const ruleBefore = topLevelTopbarRule(tokensBefore);
    const appendMarker = (text: string, value: string) => text.replace(/\s+$/, "") +
      "\n# isonim-editor dom.component-topbar.padding-top padding-top=" + value + "\n";
    const ruleWith = (value: string) => tokensBefore.replace(ruleBefore,
      ruleBefore.replace(/\n\}$/, "\n  padding-top: " + value + ";\n}"));
    try {

      const { topbar } = await openTopbarInEditMode(page);
      await selectTopbarElement(page, topbar);

      const row = page.locator('[data-property-row="pad-top"]');
      const padTop = propertyRowInput(page, "pad-top");
      const scopes = row.getByRole("group", { name: /^Choose source scope for / });
      await expect(scopes).toBeVisible();
      for (const scope of ["local instance", "shared class", "story fixture",
          "component schema", "component token", "semantic token",
          "global primitive token"]) {
        await expect(row.locator(
          `[aria-label="Apply ${scope} scope for padding-top"]`).first()).toBeAttached();
      }
      const bind = row.getByRole("button", { name: /^Bind .* to variable$/ });
      await expect(bind).toBeVisible();
      // "Search reusable styles" -> the variable picker's search field (spec
      // "Variable picker — Search field at the top").
      await bind.click();
      await expect(page.getByRole("textbox", { name: "Filter variables" })).toBeVisible();
      await page.keyboard.press("Escape");
      const source = page.locator('[data-inspector-section-header="source"]');
      if ((await source.getAttribute("aria-expanded")) !== "true") await source.click();
      await expect(page.locator('[data-inspector-section-body="source"]'))
        .toContainText("Scope");
      await expect(page.locator('[data-inspector-section-body="source"]'))
        .toContainText("Ownership", { ignoreCase: true });

      const history = () => page.evaluate(() =>
        (window as any).__isonimEditorVm.inspector.undoStack.value.length);
      const startHistory = await history();
      await row.getByRole("button", {
        name: "Apply local instance scope for padding-top", exact: true,
      }).first().click();
      await padTop.click();
      await padTop.fill("20");
      await padTop.press("Enter");
      await expect
        .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
        .toBe("20px");
      // Choosing a scope re-commits the row's current value into it, so the
      // count is relative rather than exactly one edit.
      await expect.poll(history).toBeGreaterThan(startHistory);
      await expectNoPendingSourceEdits(page);
      const afterLocal = appendMarker(componentsBefore, "20px");
      expect(readFileSync(devBridgeSourceFile, "utf8")).toBe(afterLocal);
      expect(readFileSync(devBridgeTokenFile, "utf8")).toBe(tokensBefore);
      const localHistory = await history();

      const sharedScope = row.locator(
        '[aria-label="Apply shared class scope for padding-top"]').first();
      await expect(sharedScope).toHaveAttribute("aria-disabled", "false");
      if (!(await sharedScope.isVisible())) {
        await row.locator('[aria-label^="More Choose source scope for "]').first().click();
      }
      await sharedScope.click();
      await padTop.click();
      await padTop.fill("24");
      await padTop.press("Enter");
      await expect
        .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
        .toBe("24px");
      await expect.poll(history).toBeGreaterThan(localHistory);
      const sharedHistory = await history();
      await expectNoPendingSourceEdits(page);
      // The shared write lands in the rule that styles the Topbar, not as a
      // marker of the element.
      expect(readFileSync(devBridgeTokenFile, "utf8")).toBe(ruleWith("24px"));
      expect(readFileSync(devBridgeSourceFile, "utf8")).toBe(afterLocal);
      await pressHistoryShortcut(page);
      await expect
        .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
        .toBe("20px");
      await expect.poll(history).toBe(sharedHistory - 1);
      await expectNoPendingSourceEdits(page);
      // Choosing the shared scope re-committed 20px there before 24px was
      // typed; undo puts that back.
      expect(readFileSync(devBridgeTokenFile, "utf8")).toBe(ruleWith("20px"));
      expect(readFileSync(devBridgeSourceFile, "utf8")).toBe(afterLocal);
      // Detach (spec "Inspector UI for Shared Properties" [Detach],
      // "Edit Routing — Detach from token"): back on the shared value, detach
      // gives only this element an inline override.
      await pressHistoryShortcut(page, true);
      await expect
        .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
        .toBe("24px");
      const detach = row.getByRole("button", { name: /^Detach/ }).first();
      await expect(detach).toBeVisible();
      await detach.click();
      await expect(row.locator(
        '[aria-label="Apply local instance scope for padding-top"]').first())
        .toHaveAttribute("aria-pressed", "true");
      await expect
        .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
        .toBe("24px");
      await expect.poll(history).toBeGreaterThan(sharedHistory);
      await expectNoPendingSourceEdits(page);
      // Only this element changed: its own marker now carries the value; the
      // shared rule keeps it for every other use.
      expect(readFileSync(devBridgeSourceFile, "utf8"))
        .toBe(appendMarker(afterLocal, "24px"));
      expect(readFileSync(devBridgeTokenFile, "utf8")).toBe(ruleWith("24px"));
      await undoInspectorHistoryTo(page, startHistory);
      await expectNoPendingSourceEdits(page);
      expect(readFileSync(devBridgeSourceFile, "utf8")).toBe(componentsBefore);
      expect(readFileSync(devBridgeTokenFile, "utf8")).toBe(tokensBefore);
    } finally {
      await restoreDevWorkspace(page, workspaceBefore);
    }
  });

  // Reconciled 2026-10-14: edit entry via the mode cluster, topbar
  // selection via its Layers row, the tabbed `padding` textbox became the
  // Layout `pad-top` row with its per-row scope picker, the commit preview
  // became the row/section impact disclosure, and Save became automatic
  // saving (editor spec "Saving", "Property row pattern", "Source-scope
  // clarity"). Retained: a SHARED-scope edit that discloses other affected
  // uses, the real source write, reload verification in View mode, revert
  // and reverted reload.
  //
  // Re-authored 2026-10-22 to follow the owning file. The rule that styles
  // the Topbar, and that metacraft-web declares as its shared class, is the
  // top-level `.bo-topbar` rule of metacraft-design's tokens.nim; the case
  // used to poll components.nim for a `padding-top=28px` marker, which is
  // the LOCAL instance's writer (isonim-pm issue 2026-09-26-the-consumer-
  // editor-spec-tests-the-inspector-that-was-demolished, "File assertion").
  // The shared write must land in that rule and only there: the rule gains
  // exactly one `padding-top: 28px;` declaration, every other dev-workspace
  // copy (components.nim included) is byte-identical, the reloaded Topbar
  // renders it, and the revert restores every copy byte for byte and the
  // Topbar's own padding.
  test("e2e_metacraft_shared_scope_save_reload_verify_and_revert", async ({
    page,
  }) => {
    await page.goto("/?writeBridge=1");
    await expectWritableBridge(page);
    const workspaceBefore = snapshotDevWorkspace();
    const tokensBefore = readFileSync(devBridgeTokenFile, "utf8");
    const componentsBefore = readFileSync(devBridgeSourceFile, "utf8");
    const ruleBefore = topLevelTopbarRule(tokensBefore);
    expect(ruleBefore).toContain(".bo-topbar {");
    expect(ruleBefore).not.toContain("padding");

    // Everything after the snapshot is inside the try: choosing a scope
    // already commits there, so a failure before the typed edit must still
    // restore every copy.
    let afterText = tokensBefore;
    let originalPadding = "";
    try {
      const { topbar } = await openTopbarInEditMode(page);
      await selectTopbarElement(page, topbar);
      originalPadding = await topbar.evaluate(
        (node) => getComputedStyle(node).paddingTop);
      expect(originalPadding).not.toBe("28px");

      const row = page.locator('[data-property-row="pad-top"]');
      const padTop = propertyRowInput(page, "pad-top");
      await expect(padTop).toBeVisible();
      // A captured, unauthored value is the element's: the local instance is
      // the default scope until the shared one is chosen.
      await expect(row.locator(
        '[aria-label="Apply local instance scope for padding-top"]').first())
        .toHaveAttribute("aria-pressed", "true");
      // The per-row scope picker shows the first choices inline and the rest
      // behind its "More" disclosure.
      const sharedScope = row.locator(
        '[aria-label="Apply shared class scope for padding-top"]').first();
      await expect(sharedScope).toHaveAttribute("aria-disabled", "false");
      await expect(sharedScope).toHaveAttribute("data-source-scope-schema",
        "dom.component-topbar");
      if (!(await sharedScope.isVisible())) {
        await row.locator('[aria-label^="More Choose source scope for "]').first().click();
      }
      await sharedScope.click();
      await expect(sharedScope).toHaveAttribute("aria-pressed", "true");
      await expect(page.getByText(
        "Changes the shared source definition; other mapped uses may change.",
      ).first()).toBeVisible();

      // The rule the shared write must produce: the original rule with one
      // `padding-top: 28px;` declaration added before its closing brace.
      const ruleAfter = ruleBefore.replace(/\n\}$/, "\n  padding-top: 28px;\n}");
      await padTop.click();
      await padTop.fill("28");
      await padTop.press("Enter");
      await expect
        .poll(() => topLevelTopbarRule(readFileSync(devBridgeTokenFile, "utf8")))
        .toBe(ruleAfter);
      await expectNoPendingSourceEdits(page);
      afterText = readFileSync(devBridgeTokenFile, "utf8");
      expect(afterText).toBe(tokensBefore.replace(ruleBefore, ruleAfter));
      // Nothing else was written: no local marker, no other copy changed.
      expect(readFileSync(devBridgeSourceFile, "utf8")).toBe(componentsBefore);
      const written = snapshotDevWorkspace();
      for (let i = 0; i < devWorkspaceFiles.length; i += 1) {
        if (devWorkspaceFiles[i][1] !== devBridgeTokenFile) {
          expect(written[i]).toBe(workspaceBefore[i]);
        }
      }

      await page.reload();
      await page.getByRole("button", { name: "Open Components section" }).click();
      await page
        .getByRole("button", {
          name: "Select story Operational components / Topbar",
        })
        .click();
      await switchMode(page, "View");
      const reloadedTopbar = page
        .frameLocator(
          'iframe[title="Component preview Operational components / Topbar"]',
        )
        .getByTestId("component-topbar");
      await expect
        .poll(() =>
          reloadedTopbar.evaluate((node) => getComputedStyle(node).paddingTop),
        )
        .toBe("28px");
      await expect
        .poll(() => readFileSync(devBridgeTokenFile, "utf8"))
        .toBe(afterText);
    } finally {
      await restoreDevWorkspace(page, workspaceBefore);
    }
    expect(readFileSync(devBridgeTokenFile, "utf8")).toBe(tokensBefore);
    expect(readFileSync(devBridgeSourceFile, "utf8")).toBe(componentsBefore);

    await page.reload();
    await page.getByRole("button", { name: "Open Components section" }).click();
    await page
      .getByRole("button", {
        name: "Select story Operational components / Topbar",
      })
      .click();
    await switchMode(page, "View");
    const revertedTopbar = page
      .frameLocator(
        'iframe[title="Component preview Operational components / Topbar"]',
      )
      .getByTestId("component-topbar");
    await expect
      .poll(() =>
        revertedTopbar.evaluate((node) => getComputedStyle(node).paddingTop),
      )
      .toBe(originalPadding);
  });

  // Reconciled 2026-10-14: edit entry via the mode cluster, topbar
  // selection via its Layers row, padding via the Layout `pad-top` row, and
  // automatic saving instead of the Save button and "clean" badge (editor
  // spec "Saving"). The section search field the old case focused is not
  // rendered by the section inspector (recorded separately as a product
  // gap), so the focused inspector control is the edited row's own input.
  // Retained: real source write, post-write preview rebuild, selection and
  // inspector focus surviving the write and the remount caused by browser
  // history traversal.
  test("preserves_history_selection_and_inspector_focus_after_write_bridge_rebuild", async ({
    page,
  }) => {
    await page.goto("/?writeBridge=1");
    await expectWritableBridge(page);
    const beforeText = readFileSync(devBridgeSourceFile, "utf8");

    const { topbar } = await openTopbarInEditMode(page);
    await expect(page).toHaveURL(/view=edit/);
    const editFrameElement = page.locator(
      'iframe[title="Editable component preview"]',
    );
    await expect.poll(() => iframeReloadGeneration(editFrameElement)).toBe(0);
    await selectTopbarElement(page, topbar);

    try {
      const padTop = propertyRowInput(page, "pad-top");
      await expect(padTop).toBeEditable();
      await padTop.click();
      await padTop.fill("20");
      await padTop.press("Enter");
      await expect
        .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
        .toBe("20px");
      await padTop.focus();
      await expect(padTop).toBeFocused();

      await expect
        .poll(() => readFileSync(devBridgeSourceFile, "utf8"))
        .not.toBe(beforeText);
      await expectNoPendingSourceEdits(page);
      // A style write whose preview edit is already on screen does not
      // reload the preview (reloading would rebuild from the pre-edit
      // compiled bundle; editor spec "Live preview update"). The written
      // value stays on screen; the remount below (history traversal) is the
      // rebuild that selection and focus must survive.
      expect(await iframeReloadGeneration(editFrameElement)).toBe(0);
      await expect
        .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
        .toBe("20px");
      const afterText = readFileSync(devBridgeSourceFile, "utf8");
      expect(afterText).toContain("padding-top=20px");
      await expect(topbar).toHaveAttribute("data-isonim-selected", "true");
      await expect(padTop).toBeFocused();

      await page.getByRole("button", { name: "Open Pages section" }).click();
      await expect(page).toHaveURL(/view=page/);
      await expect(
        page
          .frameLocator('[aria-label="Preview device frame"] iframe')
          .getByText("Operations dashboard")
          .first(),
      ).toBeVisible();

      await page.goBack();
      await expect(page).toHaveURL(/view=edit/);
      await expect(topbar).toHaveAttribute("data-isonim-selected", "true");
      await expect(padTop).toBeFocused();
      await page.goForward();
      await expect(page).toHaveURL(/view=page/);
      await page.goBack();
      await expect(page).toHaveURL(/view=edit/);
      await expect(topbar).toHaveAttribute("data-isonim-selected", "true");
      await expect(padTop).toBeFocused();
    } finally {
      await restoreDevBridgeFile(page, "apps/back-office/src/backoffice_ui/components.nim",
        devBridgeSourceFile, beforeText);
    }
    await expect
      .poll(() => readFileSync(devBridgeSourceFile, "utf8"))
      .toBe(beforeText);
  });

  // Reconciled 2026-10-14 (UX-M3 current contracts). Retired: status-bar
  // "write writable"/"dirty" badges, the "N component plan(s) staged" wait
  // and a manual Save/Revert before the write. Saving is automatic (editor
  // spec "Saving"), so the reversal is Undo. Every substantive oracle is
  // retained: schema-bound options and matrix, live patch WITHOUT a preview
  // reload, one real source write of exactly one plan, the post-write
  // rebuild, exact byte restoration with preview restoration, and a
  // reverted-file reload.
  test("e2e_component_variant_matrix_state_controls_write_real_schema_files", async ({
    page,
  }) => {
    const applies: any[] = [];
    page.on("request", request => {
      if (request.url().endsWith("/__isonim-dev-bridge/transaction")) {
        const body = request.postDataJSON();
        if (body.mode === "apply") applies.push(body);
      }
    });
    await page.goto("/?writeBridge=1");
    await expectWritableBridge(page);
    await expect
      .poll(() => readFileSync(devBridgeComponentSchemaFile, "utf8"))
      .toContain("tone=neutral");
    const beforeComponentSchema = readFileSync(
      devBridgeComponentSchemaFile,
      "utf8",
    );

    await page.getByRole("button", { name: "Open Components section" }).click();
    await page
      .getByRole("button", {
        name: "Select story Operational components / Status badge tones",
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
    ).toHaveCount(2);
    await expect(
      propertyPanel.getByRole("group", {
        name: "Choose component property tone",
      }),
    ).toHaveAttribute("data-component-property-options", "4");
    await expect(
      propertyPanel.getByRole("button", {
        name: "Apply component property tone option neutral",
      }),
    ).toHaveAttribute("aria-pressed", "true");
    await expect(
      propertyPanel.getByRole("group", {
        name: "Choose component property tone",
      }),
    ).toHaveAttribute("title", /Status badge tone API/);
    await expect(
      page
        .frameLocator(
          'iframe[title="Component preview Operational components / Status badge tones"]',
        )
        .getByTestId("component-status-badges"),
    ).toBeVisible();
    const previewFrame = page.locator(
      'iframe[title="Component preview Operational components / Status badge tones"]',
    );
    const schemaBadge = page
      .frameLocator(
        'iframe[title="Component preview Operational components / Status badge tones"]',
      )
      .getByTestId("component-schema-status-badge");
    await expect.poll(() => iframeReloadGeneration(previewFrame)).toBe(0);
    await expect(schemaBadge).toHaveClass(/bo-status-neutral/);
    const neutralBackground = await computedBackground(schemaBadge);
    // A component-property edit is recorded in the component-property
    // history (`variants.undoStack`), not the inspector's; the editor's undo
    // walks both. Counting both keeps the oracle "exactly one history entry
    // per commit" (corrected 2026-10-14: this probe read only the inspector
    // stack, which a component-property commit never touches).
    const historyLength = () => page.evaluate(() => {
      const vm = (window as any).__isonimEditorVm;
      return vm.inspector.undoStack.value.length +
        vm.variants.undoStack.value.length;
    });
    const beforeHistory = await historyLength();

    const success = propertyPanel.getByRole("button", {
      name: "Apply component property tone option success",
    });
    await success.click();
    await expect(success).toHaveAttribute("aria-pressed", "true");
    // The live preview is patched in place: no reload of the preview frame.
    await expect(schemaBadge).toHaveClass(/bo-status-success/);
    expect(await iframeReloadGeneration(previewFrame)).toBe(0);
    await expect
      .poll(() => computedBackground(schemaBadge))
      .not.toBe(neutralBackground);
    const successBackground = await computedBackground(schemaBadge);

    // The staged plan is written automatically: one transaction, one plan.
    await expect
      .poll(() => readFileSync(devBridgeComponentSchemaFile, "utf8"))
      .toContain("tone=success");
    await expectNoPendingSourceEdits(page);
    expect(applies).toHaveLength(1);
    expect(applies[0].files).toHaveLength(1);
    expect(applies[0].files[0].file).toBe(componentSchemaBridgeFile);
    expect(await historyLength()).toBe(beforeHistory + 1);
    await expect.poll(() => iframeReloadGeneration(previewFrame)).toBe(1);
    await expect(schemaBadge).toHaveClass(/bo-status-success/);
    await expect
      .poll(() => computedBackground(schemaBadge))
      .toBe(successBackground);
    const afterComponentSchema = readFileSync(
      devBridgeComponentSchemaFile,
      "utf8",
    );
    expect(afterComponentSchema).not.toBe(beforeComponentSchema);

    try {
      // Undo restores the exact source bytes, the option and the preview.
      await success.focus();
      await page.keyboard.press("ControlOrMeta+Z");
      await expect
        .poll(() => readFileSync(devBridgeComponentSchemaFile, "utf8"))
        .toBe(beforeComponentSchema);
      await expectNoPendingSourceEdits(page);
      await expect(
        propertyPanel.getByRole("button", {
          name: "Apply component property tone option neutral",
        }),
      ).toHaveAttribute("aria-pressed", "true");
      await expect(schemaBadge).toHaveClass(/bo-status-neutral/);
      await expect
        .poll(() => computedBackground(schemaBadge))
        .toBe(neutralBackground);
      // Redo writes the same plan back.
      await success.focus();
      await page.keyboard.press("ControlOrMeta+Shift+Z");
      await expect
        .poll(() => readFileSync(devBridgeComponentSchemaFile, "utf8"))
        .toBe(afterComponentSchema);
      await expect(schemaBadge).toHaveClass(/bo-status-success/);
    } finally {
      await restoreDevBridgeFile(page, componentSchemaBridgeFile,
        devBridgeComponentSchemaFile, beforeComponentSchema);
    }
    await expect
      .poll(() => readFileSync(devBridgeComponentSchemaFile, "utf8"))
      .toBe(beforeComponentSchema);
    await page.reload();
    await expect(
      page.getByLabel("Component property schema and variant matrix").first(),
    ).toBeVisible();
    await expect(
      page.getByRole("button", {
        name: "Apply component property tone option neutral",
      }),
    ).toHaveAttribute("aria-pressed", "true");
    await expect(
      page
        .frameLocator(
          'iframe[title="Component preview Operational components / Status badge tones"]',
        )
        .getByTestId("component-schema-status-badge"),
    ).toHaveClass(/bo-status-neutral/);
    const revertedSchemaBadge = page
      .frameLocator(
        'iframe[title="Component preview Operational components / Status badge tones"]',
      )
      .getByTestId("component-schema-status-badge");
    await expect
      .poll(() => computedBackground(revertedSchemaBadge))
      .toBe(neutralBackground);
  });
  // Reconciled 2026-10-14 (UX-M3 current contracts). Retired: status-bar
  // "write writable"/"dirty" badges, the "N component plan(s) staged" wait
  // and the manual Save gesture (editor spec "Saving": automatic, no control).
  // Retained: live text patch WITHOUT a preview reload, one real source write
  // of exactly one plan, the post-write rebuild keeping the new text, and the
  // reverted-file reload. Undo restoring the exact bytes is added as the
  // spec's reversal path.
  test("e2e_component_text_property_updates_panel_header_live_preview", async ({
    page,
  }) => {
    const applies: any[] = [];
    page.on("request", request => {
      if (request.url().endsWith("/__isonim-dev-bridge/transaction")) {
        const body = request.postDataJSON();
        if (body.mode === "apply") applies.push(body);
      }
    });
    await page.goto("/?writeBridge=1");
    await expectWritableBridge(page);
    await expect
      .poll(() => readFileSync(devBridgeComponentSchemaFile, "utf8"))
      .toContain("panelHeader.label=Customers");
    const beforeComponentSchema = readFileSync(
      devBridgeComponentSchemaFile,
      "utf8",
    );

    await page.getByRole("button", { name: "Open Components section" }).click();
    await page
      .getByRole("button", {
        name: "Select story Operational components / Panel header",
      })
      .click();

    const propertyPanel = page
      .getByLabel("Component property schema and variant matrix")
      .first();
    await expect(propertyPanel).toBeVisible();
    const previewFrame = page.locator(
      'iframe[title="Component preview Operational components / Panel header"]',
    );
    const panelHeaderTitle = page
      .frameLocator(
        'iframe[title="Component preview Operational components / Panel header"]',
      )
      .getByTestId("component-panel-header")
      .locator("h2");
    await expect.poll(() => iframeReloadGeneration(previewFrame)).toBe(0);
    await expect(panelHeaderTitle).toHaveText("Customers");

    const labelInput = propertyPanel
      .getByRole("textbox", { name: "Edit component property label" })
      .first();
    await expect(labelInput).toBeVisible();
    await labelInput.fill("Accounts");
    // Live preview while typing: patched in place, no frame reload.
    await expect(panelHeaderTitle).toHaveText("Accounts");
    expect(await iframeReloadGeneration(previewFrame)).toBe(0);
    // Typing previews; Enter commits (the text field commits on change, as
    // every text field does). The retired Save click used to supply this
    // commit implicitly by taking focus out of the field (corrected
    // 2026-10-14).
    await labelInput.press("Enter");

    try {
      // The staged plan is written automatically: one transaction, one plan.
      await expect
        .poll(() => readFileSync(devBridgeComponentSchemaFile, "utf8"))
        .toContain("panelHeader.label=Accounts");
      await expectNoPendingSourceEdits(page);
      expect(applies).toHaveLength(1);
      expect(applies[0].files).toHaveLength(1);
      expect(applies[0].files[0].file).toBe(componentSchemaBridgeFile);
      await expect.poll(() => iframeReloadGeneration(previewFrame)).toBe(1);
      await expect(panelHeaderTitle).toHaveText("Accounts");

      // Undo restores the exact source bytes and the rendered text.
      await propertyPanel.getByRole("button", {
        name: "Cycle component property label",
      }).first().focus();
      await page.keyboard.press("ControlOrMeta+Z");
      await expect
        .poll(() => readFileSync(devBridgeComponentSchemaFile, "utf8"))
        .toBe(beforeComponentSchema);
      await expect(panelHeaderTitle).toHaveText("Customers");
    } finally {
      await restoreDevBridgeFile(page, componentSchemaBridgeFile,
        devBridgeComponentSchemaFile, beforeComponentSchema);
    }
    await expect
      .poll(() => readFileSync(devBridgeComponentSchemaFile, "utf8"))
      .toBe(beforeComponentSchema);
    await page.reload();
    await expect(
      page.getByLabel("Component property schema and variant matrix").first(),
    ).toBeVisible();
    await expect(
      page
        .frameLocator(
          'iframe[title="Component preview Operational components / Panel header"]',
        )
        .getByTestId("component-panel-header")
        .locator("h2"),
    ).toHaveText("Customers");
  });
  // Reconciled 2026-10-14: edit-mode entry and the mode switch use the
  // chrome-bar mode cluster; the right sidebar in Comment mode is the AI
  // assistant and the Inspector is mounted only in Edit (editor spec
  // "Mode-driven right sidebar"). Annotation substance is unchanged.
  test("comment mode stores structured review annotations for AI prompt selection", async ({
    page,
  }) => {
    await page.goto("/");

    await openTopbarInEditMode(page);

    await switchMode(page, "Comment");
    await expect(modeChip(page, "Edit")).toHaveAttribute("aria-pressed", "false");
    await expect(page.locator('[data-sidebar-content="ai-assistant"]')).toBeVisible();
    await expect(page.locator('[data-sidebar-content="inspector"]')).toHaveCount(0);
    // The card summary is "<id> - <state> - <inclusion>" (chat_panel.nim,
    // 04930a8); it carries the same three fields as the former
    // "<id>=<state>:<inclusion>" text.

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

    await expect(
      editFrame.getByRole("button", { name: "Design review comment marker" }),
    ).toBeVisible();
    await expect(page.getByText("Design Review Comments")).toBeVisible();
    await expect(
      page.getByText("Make the title hierarchy feel calmer."),
    ).toBeVisible();
    await expect(
      page.getByText("review-annotation-1 - open - included", { exact: true }),
    ).toBeVisible();
    await page
      .getByRole("button", {
        name: "Exclude review comment review-annotation-1",
      })
      .click();
    await expect(
      page.getByText("review-annotation-1 - open - excluded", { exact: true }),
    ).toBeVisible();
    await page
      .getByRole("button", {
        name: "Include review comment review-annotation-1",
      })
      .click();
    await expect(
      page.getByText("review-annotation-1 - open - included", { exact: true }),
    ).toBeVisible();
  });

  // Reconciled 2026-10-14: the "Widen right panel" buttons and the
  // "Switch to … mode" buttons are retired. The right sidebar is resized by
  // dragging its left-edge `data-resize-handle="right-panel"` (editor spec
  // "Resizable sidebars"); modes come from the chrome-bar mode cluster. The
  // substantive oracle -- one shared width that does not jump when the
  // sidebar swaps between the AI assistant and the Inspector -- is unchanged.
  test("e2e_right_panel_width_does_not_jump_between_ai_comment_edit", async ({
    page,
  }) => {
    await page.goto("/");

    const visibleRightPanel = () => page.locator("[data-sidebar-content]:visible");
    const width = async () => {
      await expect(visibleRightPanel()).toHaveCount(1);
      const box = await visibleRightPanel().boundingBox();
      if (!box) throw new Error("right panel is not visible");
      return Math.round(box.width);
    };
    const widenBy = async (dx: number) => {
      const handle = visibleRightPanel().locator('[data-resize-handle="right-panel"]');
      const box = await handle.boundingBox();
      if (!box) throw new Error("right panel resize handle is not visible");
      const x = box.x + box.width / 2;
      const y = box.y + box.height / 2;
      await page.mouse.move(x, y);
      await page.mouse.down();
      await page.mouse.move(x - dx, y, { steps: 6 });
      await page.mouse.up();
    };

    await expect(page.locator('[data-sidebar-content="ai-assistant"]')).toBeVisible();
    const initial = await width();
    await widenBy(80);
    await expect.poll(width).toBeGreaterThan(initial);
    const widened = await width();

    await switchMode(page, "Edit");
    await expect(page.locator('[data-sidebar-content="inspector"]')).toBeVisible();
    expect(await width()).toBe(widened);

    await widenBy(40);
    await expect.poll(width).toBeGreaterThan(widened);
    const editWidth = await width();

    await switchMode(page, "Comment");
    await expect(page.locator('[data-sidebar-content="ai-assistant"]')).toBeVisible();
    expect(await width()).toBe(editWidth);

    await switchMode(page, "Edit");
    await expect(page.locator('[data-sidebar-content="inspector"]')).toBeVisible();
    expect(await width()).toBe(editWidth);
  });

  // Reconciled 2026-10-14 to the section-based inspector (editor spec
  // "Property Inspector Panel — Section-Based Design"): tabs became
  // collapsible section headers (`data-inspector-section-header`), the
  // former Space tab's padding rows live in Layout, and "Source / Cascade"
  // is the Source section. Retained: the inspector search field filtering
  // sections (spec: "A search field at the top of the inspector"), pointer
  // and keyboard section operation, absence of the retired bulk
  // collapse/expand buttons, the box-model and raw-CSS disclosures (spec
  // "Specialized Editors" / "Universal Patterns"), and no horizontal overflow.
  test("e2e_inspector_sections_are_keyboard_and_pointer_operable", async ({
    page,
  }) => {
    await page.goto("/");

    const { title } = await openTopbarInEditMode(page);
    await title.click({ force: true });
    await expect(title).toHaveAttribute("data-isonim-selected", "true");
    const inspector = page.locator('[data-sidebar-content="inspector"]');
    const header = (slug: string) =>
      page.locator(`[data-inspector-section-header="${slug}"]`);

    const sectionSearch = inspector.getByRole("textbox", {
      name: "Search inspector sections",
    });
    await expect(sectionSearch).toBeVisible();
    await sectionSearch.fill("fill");
    await expect(header("fill")).toBeVisible();
    await expect(header("layout")).toBeHidden();

    // Pointer operation: collapse and re-open Fill by its header.
    await expect(header("fill")).toHaveAttribute("aria-expanded", "true");
    await header("fill").click();
    await expect(header("fill")).toHaveAttribute("aria-expanded", "false");
    await header("fill").click();
    await expect(header("fill")).toHaveAttribute("aria-expanded", "true");
    await expect(
      page.getByRole("textbox", { name: "Edit fill hex" }).first(),
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Collapse all inspector sections" }),
    ).toHaveCount(0);
    await expect(
      page.getByRole("button", { name: "Expand relevant inspector sections" }),
    ).toHaveCount(0);

    // Keyboard operation: Enter and Space toggle a focused section header.
    await sectionSearch.fill("source");
    await expect(header("source")).toBeVisible();
    await header("source").focus();
    await page.keyboard.press("Enter");
    await expect(header("source")).toHaveAttribute("aria-expanded", "true");
    await page.keyboard.press(" ");
    await expect(header("source")).toHaveAttribute("aria-expanded", "false");
    await page.keyboard.press("Enter");
    await expect(header("source")).toHaveAttribute("aria-expanded", "true");

    await sectionSearch.fill("padding");
    await expect(header("layout")).toBeVisible();
    await expect(propertyRowInput(page, "pad-top")).toBeVisible();
    await expect(page.getByLabel("Show box model controls")).toBeVisible();
    // Raw CSS is per section ("Universal Patterns": "Raw CSS toggle — switch
    // to raw CSS text editing for any section"), so every CSS section has a
    // toggle and the tab-era name "Show raw CSS controls" cannot name one of
    // them; the Layout section's is "Show raw CSS for Layout section".
    await expect(page.getByLabel("Show raw CSS for Layout section")).toBeVisible();

    const noOverflow = () => inspector.evaluate(
      (node) => node.scrollWidth <= node.clientWidth + 1);
    expect(await noOverflow()).toBe(true);
    await page.setViewportSize({ width: 900, height: 800 });
    await expect(inspector).toBeVisible();
    expect(await noOverflow()).toBe(true);
  });

  // isonim-pm issue 2026-10-14-the-section-inspector-has-no-search-field.
  // Editor spec "Section catalogue": "A search field at the top of the
  // inspector (⌘F focus) filters sections by name and properties by label —
  // sections without matches collapse; sections with matches open and
  // highlight the matched rows." The mounted section inspector rendered no
  // field at all; `inspector.sectionSearch` only served the retired tabbed
  // body. Property labels match the row name and its CSS property.
  test("metacraft_inspector_search_filters_sections_by_name_and_property_label", async ({
    page,
  }) => {
    await page.goto("/");
    const { topbar } = await openTopbarInEditMode(page);
    await selectTopbarElement(page, topbar);
    const inspector = page.locator('[data-sidebar-content="inspector"]');
    const header = (slug: string) =>
      page.locator(`[data-inspector-section-header="${slug}"]`);
    const search = inspector.getByRole("textbox", { name: "Search inspector sections" });
    await expect(search).toBeVisible();

    // ⌘F / Ctrl+F from a non-editable control focuses the field.
    const editChip = modeChip(page, "Edit");
    await editChip.focus();
    await page.keyboard.press("ControlOrMeta+F");
    await expect(search).toBeFocused();

    // A property label (here the CSS property of Stroke's Width row) shows
    // and opens its section, collapsed by default, and highlights the row.
    await expect(header("stroke")).toHaveAttribute("aria-expanded", "false");
    await expect(header("layout")).toHaveAttribute("aria-expanded", "true");
    await search.fill("border-width");
    await expect(header("stroke")).toBeVisible();
    await expect(header("stroke")).toHaveAttribute("aria-expanded", "true");
    const strokeWidth = page.locator('[data-property-row-css-property="border-width"]');
    await expect(strokeWidth).toBeVisible();
    await expect(strokeWidth).toHaveAttribute("data-inspector-search-match", "true");
    await expect(page.locator('[data-property-row-css-property="border-color"]'))
      .toHaveAttribute("data-inspector-search-match", "false");
    for (const slug of ["position", "layout", "appearance", "fill", "typography", "source"]) {
      await expect(header(slug)).toBeHidden();
    }
    // The user can still collapse a section the search opened.
    await header("stroke").click();
    await expect(header("stroke")).toHaveAttribute("aria-expanded", "false");

    // A row label (Layout's "Pad top") matches too.
    await search.fill("pad top");
    await expect(header("layout")).toBeVisible();
    await expect(page.locator('[data-property-row="pad-top"]'))
      .toHaveAttribute("data-inspector-search-match", "true");
    await expect(page.locator('[data-property-row="pad-left"]'))
      .toHaveAttribute("data-inspector-search-match", "false");
    await expect(header("stroke")).toBeHidden();

    // A section matched by its name only is shown and keeps its own state.
    await search.fill("export");
    await expect(header("export")).toBeVisible();
    await expect(header("export")).toHaveAttribute("aria-expanded", "false");
    await expect(header("layout")).toBeHidden();

    // Nothing matches: no section is shown.
    await search.fill("no-such-property-anywhere");
    await expect(page.locator("[data-inspector-section-header]:visible")).toHaveCount(0);

    // Clearing the query shows every section again with the open/closed
    // state from before the search, and no row stays highlighted.
    await search.fill("");
    for (const slug of ["position", "layout", "appearance", "fill", "stroke", "typography", "source"]) {
      await expect(header(slug)).toBeVisible();
    }
    await expect(header("stroke")).toHaveAttribute("aria-expanded", "false");
    await expect(header("layout")).toHaveAttribute("aria-expanded", "true");
    await expect(page.locator('[data-inspector-search-match="true"]')).toHaveCount(0);

    // Escape in the field clears an active query.
    await search.fill("border-width");
    await expect(header("layout")).toBeHidden();
    await search.press("Escape");
    await expect(search).toHaveValue("");
    await expect(header("layout")).toBeVisible();
    await expect(header("stroke")).toHaveAttribute("aria-expanded", "false");
  });

  // isonim-pm issue 2026-10-14-property-copy-paste-is-unreachable-row-more-
  // menu-is-inert-and-right-click-offers-no-copy. Editor spec "Universal
  // Patterns": "Copy/Paste properties — right-click property → Copy, then
  // paste onto another element"; "Reset to default — right-click → Reset";
  // "Property row pattern": "More (⫶): overflow for Copy property, Paste
  // property, Reset, and Right-click -> Detach Variable". The row More button
  // was inert and right-click opened nothing. A paste is committed by the
  // target control's own commit path (one undoable, written edit); a value
  // the target cannot take is refused with the row's message. Reset is listed
  // and, once the fill's declaration has been written, enabled (it is
  // exercised by metacraft_property_reset_removes_the_declaration_and_undo_
  // restores_it).
  test("metacraft_property_copy_paste_reachable_from_row_more_and_right_click", async ({
    page,
  }) => {
    await page.goto("/");
    const workspaceBefore = snapshotDevWorkspace();
    try {
      await expectWritableBridge(page);
      const { topbar } = await openTopbarInEditMode(page);
      await selectTopbarElement(page, topbar);
      const history = () => page.evaluate(() =>
        (window as any).__isonimEditorVm.inspector.undoStack.value.length);
      const startHistory = await history();
      const originalBorder = await topbar.evaluate(
        (node) => getComputedStyle(node).borderTopColor);
      const originalBackground = await topbar.evaluate(
        (node) => getComputedStyle(node).backgroundColor);

      const fillHex = page.getByRole("textbox", { name: "Edit fill hex" }).first();
      await fillHex.fill("#F8FAFC");
      await fillHex.press("Enter");
      await expect.poll(() => topbar.evaluate(
        (node) => getComputedStyle(node).backgroundColor)).toBe("rgb(248, 250, 252)");
      await expect.poll(history).toBe(startHistory + 1);
      await expectNoPendingSourceEdits(page);

      // Right-click on the fill entry (its swatch: inside the entry's hex
      // field the browser's own text menu stays): Copy property.
      await page.locator('[data-fill-row-swatch="0"]').click({ button: "right" });
      const fillMenu = page.getByRole("menu", { name: "Actions for Fill" });
      await expect(fillMenu).toBeVisible();
      const reset = fillMenu.getByRole("menuitem", { name: "Reset" });
      await expect(reset).toBeVisible();
      await expect(reset).toHaveAttribute("aria-disabled", "false");
      await fillMenu.getByRole("menuitem", { name: "Copy property" }).click();
      await expect(fillMenu).toBeHidden();

      // Stroke Color's More (⫶): Paste property. Stroke is collapsed by default.
      const stroke = page.locator('[data-inspector-section-header="stroke"]');
      if ((await stroke.getAttribute("aria-expanded")) !== "true") await stroke.click();
      const more = page.getByRole("button", { name: "More actions for Color" });
      await more.click();
      const colorMenu = page.getByRole("menu", { name: "Actions for Color" });
      await expect(colorMenu).toBeVisible();
      await colorMenu.getByRole("menuitem", { name: "Paste property" }).click();
      await expect(colorMenu).toBeHidden();
      await expect.poll(() => topbar.evaluate(
        (node) => getComputedStyle(node).borderTopColor)).toBe("rgb(248, 250, 252)");
      await expect.poll(history).toBe(startHistory + 2);
      await expectNoPendingSourceEdits(page);

      // Keyboard: Enter on More opens the menu, Escape closes it and returns
      // focus to the button.
      await more.focus();
      await page.keyboard.press("Enter");
      await expect(colorMenu).toBeVisible();
      await page.keyboard.press("Escape");
      await expect(colorMenu).toBeHidden();
      await expect(more).toBeFocused();

      // Right-click on a property row opens the same menu; a value the
      // property cannot take is refused by the row and changes nothing.
      const widthRow = page.locator('[data-property-row-css-property="border-width"]');
      await widthRow.click({ button: "right" });
      const widthMenu = page.getByRole("menu", { name: "Actions for Width" });
      await expect(widthMenu).toBeVisible();
      await widthMenu.getByRole("menuitem", { name: "Paste property" }).click();
      await expect(widthRow).toContainText("Cannot paste #F8FAFC into Width.");
      expect(await history()).toBe(startHistory + 2);

      await undoInspectorHistoryTo(page, startHistory);
      await expect.poll(() => topbar.evaluate(
        (node) => getComputedStyle(node).borderTopColor)).toBe(originalBorder);
      await expect.poll(() => topbar.evaluate(
        (node) => getComputedStyle(node).backgroundColor)).toBe(originalBackground);
      await expectNoPendingSourceEdits(page);
    } finally {
      await restoreDevWorkspace(page, workspaceBefore);
    }
  });

  // isonim-pm issue 2026-10-14-property-copy-paste-is-unreachable-row-more-
  // menu-is-inert-and-right-click-offers-no-copy (Reset). Editor spec
  // "Universal Patterns": "Reset to default -- right-click -> Reset; reverts
  // to the token/class/inherited value"; "Saving": a refusal the editor can
  // know at the act is made at the act. Reset commits an empty value through
  // the row's own commit; the consumer writer removes the one declaration
  // line the editor wrote for the property, and undo puts back exactly that
  // line. Where nothing the editor wrote owns the property, Reset is
  // disabled with the writer's reason.
  test("metacraft_property_reset_removes_the_declaration_and_undo_restores_it", async ({
    page,
  }) => {
    test.setTimeout(90_000);
    await page.goto("/");
    const workspaceBefore = snapshotDevWorkspace();
    try {
      await expectWritableBridge(page);
      const { topbar } = await openTopbarInEditMode(page);
      await selectTopbarElement(page, topbar);
      const history = () => page.evaluate(() =>
        (window as any).__isonimEditorVm.inspector.undoStack.value.length);
      const startHistory = await history();
      const original = readFileSync(devBridgeSourceFile, "utf8");
      const paddingTop = () => topbar.evaluate(
        (node) => getComputedStyle(node).paddingTop);
      const originalPadding = await paddingTop();
      const row = page.locator('[data-property-row="pad-top"]');
      const label = row.locator('[data-property-row-field-label="true"]');
      const menu = row.locator('[data-property-actions-menu="true"]');
      const reset = menu.getByRole("menuitem", { name: "Reset" });

      // Nothing the editor wrote owns padding-top: disabled, with the reason.
      await label.click({ button: "right" });
      await expect(menu).toBeVisible();
      await expect(reset).toHaveAttribute("aria-disabled", "true");
      await expect(reset).toHaveAttribute("title",
        /no editor declaration of padding-top/);
      // A disabled item is not clickable for Playwright; dispatch the click
      // a pointer would deliver.
      await reset.dispatchEvent("click");
      await expect(menu.locator('[data-property-actions-message="true"]'))
        .toContainText("no editor declaration of padding-top");
      expect(await history()).toBe(startHistory);
      await page.keyboard.press("Escape");
      await expect(menu).toBeHidden();

      const input = propertyRowInput(page, "pad-top");
      await input.click();
      await input.fill("12");
      await input.press("Enter");
      await expect.poll(paddingTop).toBe("12px");
      await expectNoPendingSourceEdits(page);
      await expect.poll(history).toBe(startHistory + 1);
      const edited = readFileSync(devBridgeSourceFile, "utf8");
      expect(edited).toContain(
        "# isonim-editor dom.component-topbar.padding-top padding-top=12px");

      // Reset: one written, undoable edit that removes exactly that line.
      await label.click({ button: "right" });
      await expect(menu).toBeVisible();
      await expect(reset).toHaveAttribute("aria-disabled", "false");
      await reset.click();
      await expect(menu).toBeHidden();
      await expect.poll(paddingTop).toBe(originalPadding);
      await expectNoPendingSourceEdits(page);
      await expect.poll(history).toBe(startHistory + 2);
      expect(readFileSync(devBridgeSourceFile, "utf8")).toBe(original);

      // Undo restores the exact removed line.
      await pressHistoryShortcut(page);
      await expect.poll(() => readFileSync(devBridgeSourceFile, "utf8"))
        .toBe(edited);
      await expect.poll(paddingTop).toBe("12px");
      await expectNoPendingSourceEdits(page);

      await undoInspectorHistoryTo(page, startHistory);
      await expectNoPendingSourceEdits(page);
      expect(readFileSync(devBridgeSourceFile, "utf8")).toBe(original);
      await expect.poll(paddingTop).toBe(originalPadding);

      // The Fill entry's Delete (−) removes the fill's declaration the same
      // way, with the same enablement as its Reset.
      const background = () => topbar.evaluate(
        (node) => getComputedStyle(node).backgroundColor);
      const originalBackground = await background();
      const fillHex = page.getByRole("textbox", { name: "Edit fill hex" }).first();
      await fillHex.fill("#F8FAFC");
      await fillHex.press("Enter");
      await expect.poll(background).toBe("rgb(248, 250, 252)");
      await expectNoPendingSourceEdits(page);
      await expect.poll(history).toBe(startHistory + 1);
      const filled = readFileSync(devBridgeSourceFile, "utf8");
      expect(filled).toContain(
        "# isonim-editor dom.component-topbar.background-color background-color=#f8fafc");
      const deleteFill = page.locator('[data-fill-row-delete="0"]');
      await expect(deleteFill).toHaveAttribute("aria-disabled", "false");
      await deleteFill.click();
      await expect.poll(background).toBe(originalBackground);
      await expectNoPendingSourceEdits(page);
      await expect.poll(history).toBe(startHistory + 2);
      expect(readFileSync(devBridgeSourceFile, "utf8")).toBe(original);
      await pressHistoryShortcut(page);
      await expect.poll(() => readFileSync(devBridgeSourceFile, "utf8"))
        .toBe(filled);
      await expect.poll(background).toBe("rgb(248, 250, 252)");
      await expectNoPendingSourceEdits(page);
      await undoInspectorHistoryTo(page, startHistory);
      await expectNoPendingSourceEdits(page);
      expect(readFileSync(devBridgeSourceFile, "utf8")).toBe(original);
    } finally {
      await restoreDevWorkspace(page, workspaceBefore);
    }
  });

  // Inspector-controls review notes (UX-M3 inspector controls, ACCEPT with
  // notes N1, N2). Editor spec "Section catalogue": the search field takes
  // ⌘F focus -- but not a keystroke another handler already handled; and a
  // right-click inside a row's text field keeps the browser's own Cut / Copy
  // / Paste menu (the property menu opens outside editable fields).
  test("metacraft_find_shortcut_and_field_context_menu_defer_to_their_owners", async ({
    page,
  }) => {
    await page.goto("/");
    const { topbar } = await openTopbarInEditMode(page);
    await selectTopbarElement(page, topbar);
    const search = page.locator('[data-sidebar-content="inspector"]')
      .getByRole("textbox", { name: "Search inspector sections" });
    await expect(search).toBeVisible();
    const chip = modeChip(page, "Edit");
    await chip.evaluate((node) => {
      (window as any).__claimFind = (event: KeyboardEvent) => {
        if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "f") {
          event.preventDefault();
        }
      };
      node.addEventListener("keydown", (window as any).__claimFind);
    });
    await chip.focus();
    await page.keyboard.press("ControlOrMeta+F");
    await expect(chip).toBeFocused();
    await expect(search).not.toBeFocused();
    await chip.evaluate((node) =>
      node.removeEventListener("keydown", (window as any).__claimFind));
    await chip.focus();
    await page.keyboard.press("ControlOrMeta+F");
    await expect(search).toBeFocused();

    await page.evaluate(() => {
      (window as any).__contextMenus = [];
      window.addEventListener("contextmenu", (event) =>
        (window as any).__contextMenus.push(event.defaultPrevented));
    });
    const row = page.locator('[data-property-row="pad-top"]');
    const menu = row.locator('[data-property-actions-menu="true"]');
    await propertyRowInput(page, "pad-top").click({ button: "right" });
    await expect.poll(() => page.evaluate(() =>
      (window as any).__contextMenus)).toEqual([false]);
    await expect(menu).toBeHidden();
    await row.locator('[data-property-row-field-label="true"]')
      .click({ button: "right" });
    await expect(menu).toBeVisible();
    expect(await page.evaluate(() => (window as any).__contextMenus))
      .toEqual([false, true]);
  });

  // isonim-pm issue 2026-10-14-fill-colour-picker-rgb-and-swatches-do-not-
  // commit. Editor spec "Color Picker": "Hex / RGB / HSL input — text fields
  // for precise values"; "Planned interaction parity": every editable
  // control uses the same validation/write-back/preview/undo path. Enter in
  // an RGB channel committed nothing (Enter in the hex field did), and the
  // picker had no HSL entry. The picker edits one cancelable draft: Tab
  // leaves a typed channel as a draft; Enter in an RGB channel or the HSL
  // field commits it and keeps the picker open for the next field; a preset
  // swatch sets the draft and Apply commits it.
  test("metacraft_fill_picker_rgb_and_hsl_fields_commit_on_enter", async ({
    page,
  }) => {
    await page.goto("/");
    const workspaceBefore = snapshotDevWorkspace();
    try {
      await expectWritableBridge(page);
      const { topbar } = await openTopbarInEditMode(page);
      await selectTopbarElement(page, topbar);
      const history = () => page.evaluate(() =>
        (window as any).__isonimEditorVm.inspector.undoStack.value.length);
      const background = () => topbar.evaluate(
        (node) => getComputedStyle(node).backgroundColor);
      const startHistory = await history();
      const originalBackground = await background();

      await page.locator('[data-fill-row-swatch="0"]').click();
      const picker = page.getByLabel("Edit color", { exact: true }).filter({ visible: true });
      await expect(picker).toBeVisible();
      const hex = picker.getByLabel("Hex color", { exact: true });

      // Tab leaves the typed channel a draft.
      const red = picker.getByLabel("Red", { exact: true });
      await red.fill("12");
      await red.press("Tab");
      await expect(hex).toHaveValue(/^#0C/);
      expect(await history()).toBe(startHistory);
      expect(await background()).toBe(originalBackground);

      // Enter commits each channel and the picker stays open.
      let committed = startHistory;
      for (const [channel, value] of [["Red", "59"], ["Green", "130"], ["Blue", "246"]]) {
        const field = picker.getByLabel(channel, { exact: true });
        await field.fill(value);
        await field.press("Enter");
        committed += 1;
        await expect.poll(history).toBe(committed);
        await expect(picker).toBeVisible();
      }
      await expect.poll(background).toBe("rgb(59, 130, 246)");
      const hsl = picker.getByLabel("HSL color", { exact: true });
      await expect(hsl).toHaveValue("hsl(217 91% 60%)");

      // HSL entry: Enter commits.
      await hsl.fill("hsl(0 100% 50%)");
      await hsl.press("Enter");
      await expect.poll(background).toBe("rgb(255, 0, 0)");
      await expect.poll(history).toBe(committed + 1);
      await expect(picker).toBeVisible();
      await expect(hex).toHaveValue("#FF0000");
      // A malformed HSL value is refused with a reason and commits nothing.
      await hsl.fill("hsl(0 100%)");
      await hsl.press("Enter");
      await expect(picker.locator('[data-color-popover-error="true"]'))
        .toContainText("HSL");
      expect(await history()).toBe(committed + 1);
      expect(await background()).toBe("rgb(255, 0, 0)");

      // A preset swatch sets the draft; Apply commits it and closes.
      await picker.getByRole("button", { name: "Use #22C55E" }).click();
      await expect(hex).toHaveValue("#22C55E");
      expect(await history()).toBe(committed + 1);
      await picker.getByRole("button", { name: "Apply" }).click();
      await expect.poll(background).toBe("rgb(34, 197, 94)");
      await expect.poll(history).toBe(committed + 2);
      await expect(page.locator('[data-color-popover-open="true"]')).toHaveCount(0);
      await expectNoPendingSourceEdits(page);

      await undoInspectorHistoryTo(page, startHistory);
      await expect.poll(background).toBe(originalBackground);
      await expectNoPendingSourceEdits(page);
    } finally {
      await restoreDevWorkspace(page, workspaceBefore);
    }
  });

  test("e2e_canvas_selection_matches_layer_tree_and_breadcrumbs", async ({ page }) => {
    await page.goto("/");
    const layers = page.locator('[data-scene-graph="true"]');
    const layerSearch = layers.getByRole("textbox", { name: "Search layers", exact: true });
    const stories = page.locator('[data-sidebar-story-tree="true"]');
    const layerRows = page.locator('[data-scene-graph-rows="true"]');
    await expect(layerSearch).toHaveAttribute("placeholder", "Search layers");
    await expect(page.locator('[data-scene-graph-row]').first()).toBeVisible();
    // Actual long consumer DOM, with separately bounded sibling scroll areas.
    const geometry = await layers.evaluate(node => {
      const story = document.querySelector('[data-sidebar-story-tree="true"]')!;
      const sidebar = node.parentElement!;
      const rows = node.querySelector('[data-scene-graph-rows="true"]')!;
      return {
        siblings: node.parentElement === story.parentElement,
        outerOverflow: getComputedStyle(sidebar).overflowY,
        rowsOverflow: getComputedStyle(rows).overflowY,
        storiesOverflow: getComputedStyle(story).overflowY,
        outerScrollHeight: sidebar.scrollHeight, outerHeight: sidebar.clientHeight,
        layerHeight: rows.clientHeight, storyHeight: story.clientHeight,
        layerScrollHeight: rows.scrollHeight,
      };
    });
    expect(geometry.siblings).toBe(true);
    expect(geometry.outerOverflow).toBe("hidden");
    expect(geometry.rowsOverflow).toBe("auto");
    expect(geometry.storiesOverflow).toBe("auto");
    expect(geometry.outerScrollHeight).toBeLessThanOrEqual(geometry.outerHeight + 1);
    expect(geometry.layerHeight).toBeGreaterThan(80);
    expect(geometry.storyHeight).toBeGreaterThan(80);
    expect(geometry.layerScrollHeight).toBeGreaterThan(geometry.layerHeight);
    const storyScrollBefore = await stories.evaluate(node => node.scrollTop);
    await layerRows.focus();
    await page.keyboard.press("PageDown");
    await expect.poll(() => layerRows.evaluate(node => node.scrollTop)).toBeGreaterThan(0);
    expect(await stories.evaluate(node => node.scrollTop)).toBe(storyScrollBefore);
    await expect(layerSearch).toBeVisible();
    await expect(page.getByRole("textbox", { name: "Search stories" })).toBeVisible();

    await page.getByRole("button", { name: "Open Components section", exact: true }).click();
    await page.getByRole("button", {
      name: "Select story Operational components / Topbar", exact: true,
    }).click();
    await modeButton(page, "View").click();
    await modeButton(page, "Edit").click();
    const editFrame = page.frameLocator('iframe[title="Editable component preview"]');
    const topbar = editFrame.getByTestId("component-topbar");
    const title = topbar.locator("h1.bo-title");
    await title.click();
    await expect(title).toHaveAttribute("data-isonim-selected", "true");
    const titleId = await title.getAttribute("data-isonim-element-id");
    const headerId = await topbar.getAttribute("data-isonim-element-id");
    if (!titleId || !headerId) throw new Error("Selected title/ancestor require stable element ids");
    const headerStamp = await topbar.getAttribute("data-isonim-src");
    const titleStamp = await title.getAttribute("data-isonim-src");
    if (!headerStamp || !titleStamp) throw new Error("Consumer editor build requires genuine compiler source stamps");
    const sourceLocation = (stamp: string) => {
      const match = stamp.match(/^(.*):(\d+):\d+$/);
      if (!match) throw new Error(`Malformed compiler stamp: ${stamp}`);
      return `${match[1]}:${match[2]}`;
    };
    const headerLayerRow = page.locator(`[data-scene-graph-row="${headerId}"]`);
    const titleLayerRow = page.locator(`[data-scene-graph-row="${titleId}"]`);
    await expect(headerLayerRow).toContainText(/components\.nim:\d+/);
    await expect(titleLayerRow).toContainText(/components\.nim:\d+/);
    await expect(headerLayerRow.locator('[data-scene-graph-source]')).toHaveAttribute("title", sourceLocation(headerStamp));
    await expect(titleLayerRow.locator('[data-scene-graph-source]')).toHaveAttribute("title", sourceLocation(titleStamp));
    await expect(titleLayerRow).toBeVisible();
    await expect(titleLayerRow).toHaveAttribute("data-selected", "true");
    const titleCrumb = page.locator(`[data-breadcrumb-id="${titleId}"]`);
    const headerCrumb = page.locator(`[data-breadcrumb-id="${headerId}"]`);
    await expect(titleCrumb).toBeVisible();
    await expect(titleCrumb).toHaveAttribute("data-breadcrumb-state", "selected");
    const headerToggle = headerLayerRow.locator('[data-scene-graph-twisty]');
    await headerToggle.click();
    await expect(titleLayerRow).toHaveCount(0);
    await headerToggle.click();
    await expect(titleLayerRow).toBeVisible();
    // Repeated physical clicks retain the existing ancestor-cycle outcome.
    await title.click();
    await title.click();
    await expect(topbar).toHaveAttribute("data-isonim-selected", "true");
    await expect(topbar).toHaveAttribute("data-isonim-element-id", headerId);
    await expect(headerLayerRow).toHaveAttribute("data-selected", "true");

    await headerToggle.click();
    await expect(headerLayerRow).toHaveAttribute("aria-expanded", "false");
    await expect(titleLayerRow).toHaveCount(0);
    const savedExpansion = await page.evaluate(() =>
      [...(window as any).__isonimEditorVm.inspector.expandedLayerIds.value]);
    await page.getByRole("textbox", { name: "Search stories" }).fill("Topbar");
    await layerSearch.fill("  H1.BO-TITLE  ");
    await expect(headerLayerRow).toBeVisible();
    await expect(titleLayerRow).toBeVisible();
    await expect(layers.getByRole("button", { name: /^p\.bo-subtitle/ })).toHaveCount(0);
    await expect(headerLayerRow).toHaveAttribute("data-selected", "true");
    await expect(topbar).toHaveAttribute("data-isonim-selected", "true");
    expect(await page.evaluate(() =>
      [...(window as any).__isonimEditorVm.inspector.expandedLayerIds.value])).toEqual(savedExpansion);
    await expect(page.getByRole("textbox", { name: "Search stories" })).toHaveValue("Topbar");
    await titleLayerRow.click();
    await expect(title).toHaveAttribute("data-isonim-selected", "true");
    await expect(title).toHaveAttribute("data-isonim-element-id", titleId);
    await expect(titleLayerRow).toHaveAttribute("data-selected", "true");
    await layerSearch.fill("no-consumer-layer-matches-this");
    await expect(layers.getByText("No matching layers", { exact: true })).toBeVisible();
    await expect(title).toHaveAttribute("data-isonim-selected", "true");
    expect(await page.evaluate(() =>
      [...(window as any).__isonimEditorVm.inspector.expandedLayerIds.value])).toEqual(savedExpansion);
    await layerSearch.fill("");
    await expect(headerLayerRow).toHaveAttribute("aria-expanded", "false");
    await expect(titleLayerRow).toHaveCount(0);
    await headerToggle.click();
    await expect(titleLayerRow).toBeVisible();
    await page.getByRole("textbox", { name: "Search stories" }).fill("");
    await layerSearch.fill("  COMPONENTS.NIM  ");
    await expect(headerLayerRow).toBeVisible();
    await expect(titleLayerRow).toBeVisible();
    await layerSearch.fill("");

    await headerCrumb.click();
    await expect(topbar).toHaveAttribute("data-isonim-selected", "true");
    await expect(topbar).toHaveAttribute("data-isonim-element-id", headerId);
    await expect(headerLayerRow).toHaveAttribute("data-selected", "true");
    await expect(titleCrumb).toHaveAttribute("data-breadcrumb-state", "trail");
    await titleCrumb.click();
    await expect(title).toHaveAttribute("data-isonim-selected", "true");
    await expect(titleLayerRow).toHaveAttribute("data-selected", "true");
    await expect(titleCrumb).toHaveAttribute("data-breadcrumb-state", "selected");
    await headerCrumb.click();
    await headerLayerRow.click();
    await expect(titleCrumb).toHaveCount(0);
    await expect(headerCrumb).toHaveAttribute("data-breadcrumb-state", "selected");
    await titleLayerRow.click();
    await expect(titleCrumb).toHaveAttribute("data-breadcrumb-state", "selected");
    await headerCrumb.click();
    await expect(titleCrumb).toHaveAttribute("data-breadcrumb-state", "trail");
    await headerLayerRow.focus();
    await page.keyboard.press("Enter");
    await expect(titleCrumb).toHaveCount(0);
    await expect(headerCrumb).toHaveAttribute("data-breadcrumb-state", "selected");
    // Layers and its query remain available in all four actual mode choices.
    for (const choice of ["View", "Comment", "Spec", "Edit"] as const) {
      await modeButton(page, choice).click();
      await expect(modeButton(page, choice)).toHaveAttribute("aria-pressed", "true");
      await expect(layerSearch).toBeVisible();
      await layerSearch.fill("component-topbar");
      await expect(headerLayerRow).toBeVisible();
      await expect(headerLayerRow).toHaveAttribute("data-selected", "true");
      await layerSearch.fill("");
    }
    await expect(topbar).toHaveAttribute("data-isonim-element-id", headerId);
    await expect(topbar).toHaveAttribute("data-isonim-selected", "true");
    expect(await layerRows.evaluate(node => node.scrollWidth <= node.clientWidth + 1)).toBe(true);
  });
  // Reconciled 2026-10-14: mode changes use the chrome-bar mode cluster;
  // the tabbed inspector became sections (Fill's first entry edits `color`
  // on a text element; Layout's mode chips set `display`); manual Save/Revert
  // became automatic saving with Undo (editor spec "Saving", "Universal
  // Patterns"). The oracle -- the physical selection survives mode, window,
  // edit, save and undo cycles -- is unchanged, and each edit's preview
  // effect and history entry are now checked as well.
  test("e2e_selection_survives_mode_viewport_and_save_cycles", async ({
    page,
  }) => {
    await page.goto("/");
    const workspaceBefore = snapshotDevWorkspace();
    try {

      const { topbar, title } = await openTopbarInEditMode(page);
      await title.click({ force: true });
      await expect(title).toHaveAttribute("data-isonim-selected", "true");

      await switchMode(page, "Comment");
      await expect(title).toHaveAttribute("data-isonim-selected", "true");
      await switchMode(page, "Edit");
      await expect(title).toHaveAttribute("data-isonim-selected", "true");

      await page.setViewportSize({ width: 900, height: 900 });
      await expect(title).toHaveAttribute("data-isonim-selected", "true");
      await page.setViewportSize({ width: 430, height: 900 });
      await expect(title).toHaveAttribute("data-isonim-selected", "true");
      await page.setViewportSize({ width: 1280, height: 900 });
      await expect(title).toHaveAttribute("data-isonim-selected", "true");

      const history = () => page.evaluate(() =>
        (window as any).__isonimEditorVm.inspector.undoStack.value.length);
      const startHistory = await history();
      const originalColor = await title.evaluate(node => getComputedStyle(node).color);
      const colorInput = page.getByRole("textbox", { name: "Edit fill hex" }).first();
      await colorInput.fill("#F8FAFC");
      await colorInput.press("Enter");
      await expect
        .poll(() => title.evaluate(node => getComputedStyle(node).color))
        .toBe("rgb(248, 250, 252)");
      await expect.poll(history).toBe(startHistory + 1);
      await expectNoPendingSourceEdits(page);
      await expect(title).toHaveAttribute("data-isonim-selected", "true");

      await pressHistoryShortcut(page);
      await expect
        .poll(() => title.evaluate(node => getComputedStyle(node).color))
        .toBe(originalColor);
      await expect.poll(history).toBe(startHistory);
      await expectNoPendingSourceEdits(page);
      await expect(title).toHaveAttribute("data-isonim-selected", "true");

      // The title's `display` owner defaults to its shared class, which this
      // host refuses with an explanation; the owned local instance scope is
      // the writable choice (same flow as the accepted case 1).
      await page.locator('[data-layout-source-scope-property="display"]')
        .getByRole("button", { name: "Apply local instance scope for display", exact: true }).click();
      await page.getByRole("button", { name: "Set layout to horizontal", exact: true }).click();
      await expect
        .poll(() => title.evaluate(node => getComputedStyle(node).display))
        .toBe("flex");
      await expect.poll(history).toBe(startHistory + 1);
      await expectNoPendingSourceEdits(page);
      await expect(title).toHaveAttribute("data-isonim-selected", "true");
      void topbar;
    } finally {
      await restoreDevWorkspace(page, workspaceBefore);
    }
  });

  // Reconciled 2026-10-14: edit entry via the mode cluster, topbar
  // selection via its Layers row, the Layout tab became the Layout section,
  // the "Preview Mobile viewport" button became the chrome-bar viewport
  // cluster's Phone preset, and staged/Revert became automatic saving and
  // Undo (editor spec "Preview-pane chrome layout", "Saving"). Retained: the
  // canvas measurement/gap/snap/resize overlays, the Layout section's
  // flex-wrap, grid-template, constraint and responsive-override controls
  // (spec "Full CSS Property Inspector" Layout row and layout semantics), a
  // gap edit with its preview effect, drag-to-resize, and per-viewport
  // override isolation.
  test("e2e_canvas_layout_handles_measurement_and_responsive_overrides", async ({
    page,
  }) => {
    await page.goto("/");
    const workspaceBefore = snapshotDevWorkspace();
    try {

      const { editFrame, topbar } = await openTopbarInEditMode(page);
      await selectTopbarElement(page, topbar);
      await expect(
        editFrame.getByLabel("Canvas spacing measurement"),
      ).toBeVisible();
      await expect(editFrame.getByLabel("Canvas gap overlay")).toBeVisible();
      await expect(editFrame.getByLabel("Canvas snap lines")).toBeVisible();
      await expect(editFrame.getByLabel("Resize selected element")).toBeVisible();

      const layout = page.locator('[data-inspector-section-header="layout"]');
      await expect(layout).toHaveAttribute("aria-expanded", "true");
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

      const history = () => page.evaluate(() =>
        (window as any).__isonimEditorVm.inspector.undoStack.value.length);
      const startHistory = await history();
      const gap = propertyRowInput(page, "gap");
      await gap.click();
      await gap.fill("24");
      await gap.press("Enter");
      await expect
        .poll(() => topbar.evaluate((node) => getComputedStyle(node).gap))
        .toBe("24px");
      await expect.poll(history).toBe(startHistory + 1);
      await expectNoPendingSourceEdits(page);

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
      await expect.poll(history).toBeGreaterThan(startHistory + 1);
      await expectNoPendingSourceEdits(page);

      await undoInspectorHistoryTo(page, startHistory);

      await page.goto("/");
      const phone = viewportButton(page, "Phone");
      await phone.click();
      await expect(phone).toHaveAttribute("aria-pressed", "true");
      const mobile = await openTopbarInEditMode(page);
      await selectTopbarElement(page, mobile.topbar);
      await expect(page.getByText("mobile").first()).toBeVisible();
      await page
        .getByRole("button", { name: "Set responsive override for Mobile mode" })
        .click();
      await expect
        .poll(() => mobile.topbar.evaluate((node) => getComputedStyle(node).gap))
        .toBe("28px");

      const mobileGap = await mobile.topbar.evaluate(
        (node) => getComputedStyle(node).gap,
      );
      await page
        .getByRole("button", { name: "Set responsive override for Tablet mode" })
        .click();
      await expect
        .poll(() => mobile.topbar.evaluate((node) => getComputedStyle(node).gap))
        .toBe(mobileGap);
    } finally {
      await restoreDevWorkspace(page, workspaceBefore);
    }
  });

  // Reconciled 2026-10-14: edit entry via the mode cluster and topbar
  // selection via its Layers row (Shift-click now stays on the stamped
  // title); "source plan(s) staged"/Revert became automatic saving and Undo
  // (editor spec "Edit Mode", "Saving"). Retained: drag-to-resize,
  // spacing-handle drag, drag-to-reorder and double-click inline text, each
  // with its preview effect, the edits being committed and saved, and their
  // reversal.
  test("e2e_canvas_resize_spacing_reorder_and_inline_text", async ({
    page,
  }) => {
    await page.goto("/");
    const workspaceBefore = snapshotDevWorkspace();
    try {

      const { editFrame, topbar, title } = await openTopbarInEditMode(page);
      await selectTopbarElement(page, topbar);
      const history = () => page.evaluate(() =>
        (window as any).__isonimEditorVm.inspector.undoStack.value.length);
      const startHistory = await history();

      const beforeWidth = await topbar.evaluate((node) =>
        Math.round(node.getBoundingClientRect().width),
      );
      const resizeHandle = editFrame.getByLabel("Resize selected element");
      const resizeBox = await resizeHandle.boundingBox();
      if (!resizeBox) throw new Error("resize handle is not visible");
      await page.mouse.move(
        resizeBox.x + resizeBox.width / 2,
        resizeBox.y + resizeBox.height / 2,
      );
      await page.mouse.down();
      await page.mouse.move(
        resizeBox.x + resizeBox.width / 2 + 42,
        resizeBox.y + resizeBox.height / 2,
      );
      await page.mouse.up();
      await expect
        .poll(() =>
          topbar.evaluate((node) =>
            Math.round(node.getBoundingClientRect().width),
          ),
        )
        .toBeGreaterThan(beforeWidth);

      const spacingHandle = editFrame.getByLabel("Adjust selected spacing");
      const spacingBox = await spacingHandle.boundingBox();
      if (!spacingBox) throw new Error("spacing handle is not visible");
      await page.mouse.move(
        spacingBox.x + spacingBox.width / 2,
        spacingBox.y + spacingBox.height / 2,
      );
      await page.mouse.down();
      await page.mouse.move(
        spacingBox.x + spacingBox.width / 2,
        spacingBox.y + spacingBox.height / 2 + 18,
      );
      await page.mouse.up();
      await expect
        .poll(() => topbar.evaluate((node) => getComputedStyle(node).gap))
        .not.toBe("normal");

      await title.click({ force: true });
      await expect(title).toHaveAttribute("data-isonim-selected", "true");
      const titleBox = await title.boundingBox();
      if (!titleBox) throw new Error("title is not visible");
      await page.mouse.move(titleBox.x + 8, titleBox.y + titleBox.height / 2);
      await page.mouse.down();
      await page.mouse.move(titleBox.x + 8, titleBox.y + titleBox.height + 24);
      await page.mouse.up();
      await expect
        .poll(() => title.evaluate((node) => getComputedStyle(node).order))
        .not.toBe("0");

      await title.dblclick({ force: true });
      await page.keyboard.type("Operations Center");
      await page.keyboard.press("Enter");
      await expect(title).toContainText("Operations Center");
      await expect.poll(history).toBeGreaterThan(startHistory);
      await expectNoPendingSourceEdits(page);

      await undoInspectorHistoryTo(page, startHistory);
      await expectNoPendingSourceEdits(page);
    } finally {
      await restoreDevWorkspace(page, workspaceBefore);
    }
  });

  // Reconciled 2026-10-14: edit entry and the return to Edit use the
  // chrome-bar mode cluster; "Unsaved source edit"/Revert became automatic
  // saving and Undo (editor spec "Saving", "Universal Patterns"). Retained:
  // every context-menu command keeps the selection, Reset commits a source
  // edit, Ask AI pre-fills the agent prompt, and the edits are reversible.
  test("e2e_canvas_context_menu_commands_are_selection_safe", async ({
    page,
  }) => {
    await page.goto("/");
    const workspaceBefore = snapshotDevWorkspace();
    try {

      const { editFrame } = await openTopbarInEditMode(page);
      const title = editFrame.locator("h1.bo-title").first();
      await title.click({ force: true });
      await expect(title).toHaveAttribute("data-isonim-selected", "true");
      const history = () => page.evaluate(() =>
        (window as any).__isonimEditorVm.inspector.undoStack.value.length);
      const startHistory = await history();

      const choose = async (name: string) => {
        await title.click({ button: "right", force: true });
        await expect(
          editFrame.getByRole("menu", { name: "Canvas selection context menu" }),
        ).toBeVisible();
        await editFrame.getByRole("menuitem", { name }).click();
        await expect(title).toHaveAttribute("data-isonim-selected", "true");
      };

      await choose("Copy styles");
      await choose("Paste styles");
      await choose("Reset");
      await expect.poll(history).toBeGreaterThan(startHistory);
      await expectNoPendingSourceEdits(page);
      await choose("Detach style");
      await choose("Promote style");
      await choose("Create variant");
      await choose("Wrap selection");
      await choose("Duplicate");
      await choose("Delete");
      await choose("Open source");
      await choose("Ask AI about selection");

      await expect(
        page.getByRole("textbox", { name: "Agent prompt" }),
      ).toHaveValue(/Ask AI about selection:/);
      await switchMode(page, "Edit");
      await expect(title).toHaveAttribute("data-isonim-selected", "true");

      // Undo every committed edit from a non-editable focus target.
      await undoInspectorHistoryTo(page, startHistory);
      await expectNoPendingSourceEdits(page);
      await expect(title).toHaveAttribute("data-isonim-selected", "true");
    } finally {
      await restoreDevWorkspace(page, workspaceBefore);
    }
  });

  // Reconciled 2026-10-14 to the section inspector (editor spec "Numeric
  // Inputs", "Color Picker", "Specialized Editors", "Property row pattern",
  // "Saving"). Mapping: Space tab -> Layout `pad-top` row (ArrowUp +1, unit
  // chip cycles px -> em per the spec's px/em/rem order, math entry); Fill
  // tab "advanced color" -> the fill swatch's colour picker with RGB/HSL
  // entry and variable binding; Stroke radius -> Appearance corner radius
  // (all four corners) and its Per-corner linked/independent toggle;
  // Type tab -> Typography font-weight choice and its text-style binding;
  // Revert/Save -> Undo and automatic saving. Retained as specified:
  // gradient editor, Bezier transition editor and shadow editor (spec
  // "Specialized Editors"). Dropped presence checks with no current spec
  // clause: colour contrast preview, typography "details", fluid text mode
  // and truncation. "Choose variable mode for color" is qualified, not a
  // control here: modes belong to the variable editor's "Apply across all
  // modes" (see TRIAGE).
  test("e2e_figma_grade_numeric_color_shadow_typography_controls", async ({
    page,
  }) => {
    await page.goto("/");
    const workspaceBefore = snapshotDevWorkspace();
    try {

      const { topbar } = await openTopbarInEditMode(page);
      const title = topbar.locator("h1.bo-title");
      await selectTopbarElement(page, topbar);
      const history = () => page.evaluate(() =>
        (window as any).__isonimEditorVm.inspector.undoStack.value.length);
      const startHistory = await history();

      const padRow = page.locator('[data-property-row="pad-top"]');
      const paddingInput = propertyRowInput(page, "pad-top");
      await paddingInput.focus();
      await expect(paddingInput).toBeFocused();
      const originalPadding = await topbar.evaluate(
        (node) => getComputedStyle(node).paddingTop,
      );
      await paddingInput.press("ArrowUp");
      await expect
        .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
        .toBe("1px");
      const unit = padRow.getByRole("button", { name: "Cycle Pad top unit" });
      await unit.click();
      await expect(unit).toHaveText("em");
      await paddingInput.click();
      await paddingInput.fill("6*4px");
      await paddingInput.press("Enter");
      await expect
        .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
        .toBe("24px");
      await expect.poll(history).toBeGreaterThan(startHistory);
      await expectNoPendingSourceEdits(page);
      await undoInspectorHistoryTo(page, startHistory);
      await expect
        .poll(() => topbar.evaluate((node) => getComputedStyle(node).paddingTop))
        .toBe(originalPadding);
      await expectNoPendingSourceEdits(page);

      await selectTopbarElement(page, topbar);
      await page.locator('[data-fill-row-swatch="0"]').click();
      const picker = page.getByLabel("Edit color", { exact: true }).filter({ visible: true });
      await expect(picker).toBeVisible();
      for (const channel of ["Red", "Green", "Blue"]) {
        await expect(picker.getByLabel(channel, { exact: true })).toBeVisible();
      }
      await expect(picker.getByLabel(/HSL/).first()).toBeVisible();
      await expect(page.getByRole("button", { name: "Bind fill to variable" }).first())
        .toBeVisible();
      for (const [channel, value] of [["Red", "59"], ["Green", "130"], ["Blue", "246"]]) {
        const field = picker.getByLabel(channel, { exact: true });
        await field.fill(value);
        await field.press("Enter");
      }
      await expect
        .poll(() => topbar.evaluate((node) => getComputedStyle(node).backgroundColor))
        .toBe("rgb(59, 130, 246)");
      await page.keyboard.press("Escape");
      await expectNoPendingSourceEdits(page);

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

      // This host cannot write the component-token scope, so that chip is
      // disabled with its reason and is not the default (see
      // metacraft_unwritable_corner_radius_scope_is_refused_when_chosen_not_at_save).
      // The owned local instance scope is the writable route.
      const radiusRow = page.locator('[data-property-row="corner-radius"]');
      const localRadius = radiusRow.locator(
        '[aria-label="Apply local instance scope for border-radius"]').first();
      if (!(await localRadius.isVisible())) {
        await radiusRow.locator('[aria-label^="More Choose source scope for "]').first().click();
      }
      await localRadius.click();
      const radius = propertyRowInput(page, "corner-radius");
      await radius.click();
      await radius.fill("12");
      await radius.press("Enter");
      const corners = () => topbar.evaluate((node) => {
        const style = getComputedStyle(node);
        return [style.borderTopLeftRadius, style.borderTopRightRadius,
          style.borderBottomRightRadius, style.borderBottomLeftRadius];
      });
      await expect.poll(corners).toEqual(["12px", "12px", "12px", "12px"]);
      await expectNoPendingSourceEdits(page);
      // Linked/independent corners (spec "Specialized Editors — Border
      // radius", Appearance "individual-corner radii toggle"): the
      // Per-corner toggle reveals the four corner rows.
      const perCorner = page.getByRole("checkbox", { name: "Toggle Per-corner" });
      await perCorner.click();
      await expect(perCorner).toBeChecked();
      for (const corner of ["tl", "tr", "br", "bl"]) {
        await expect(page.locator(`[data-property-row="${corner}"]`)).toBeVisible();
        await expect(propertyRowInput(page, corner)).toHaveValue("12");
      }

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
      await expect(title).toHaveAttribute("data-isonim-selected", "true");
      const weight = page.locator('[data-property-row="font-weight"]');
      await expect(weight.getByRole("button", { name: "Bind Font weight to variable" }))
        .toBeVisible();
      await weight.locator("[data-choice-group-trigger]").click();
      await page.locator("[data-choice-group-option]").filter({ hasText: /^Bold$/ })
        .first().click();
      await expect
        .poll(() => title.evaluate((node) => getComputedStyle(node).fontWeight))
        .toBe("700");

      await expectNoPendingSourceEdits(page);
      await undoInspectorHistoryTo(page, startHistory);
      await expectNoPendingSourceEdits(page);
    } finally {
      await restoreDevWorkspace(page, workspaceBefore);
    }
  });

  // isonim-pm issue 2026-10-14-consumer-corner-radius-edit-is-previewed-then-
  // refused-only-at-save. The topbar's Corner radius row defaulted to the
  // component-token scope (owner metacraft.backoffice.components.panel.radius
  // in tokens.nim), which no entry of this host's writer owns: typing 12 +
  // Enter previewed 12px, added a history entry and was then refused by the
  // automatic write ("Not saved -- No project schema or source map entry can
  // safely represent this edit."), leaving the preview at 12px and the
  // per-corner rows at 0. Editor spec "Saving" (an edit no rule owns is
  // refused at the commit) and "Planned interaction parity" (a refused source
  // edit restores the control and preview and explains the refusal). The
  // refusal now happens where the user chooses: the chip is disabled and
  // carries the reason, the default is a scope the host can write, and an
  // edit at that default is written, with the per-corner rows following it.
  //
  // Re-measured 2026-10-22: `panel.radius` is the Panel's token (its node
  // names Panel, KpiTile and ActionCard), and it reached the Topbar only
  // through IsoNim's former first-node-of-the-property fallback. Scope
  // choices now come from the element's own ownership (identity key,
  // source-ownership edge, or its owner component's chain; isonim-pm issue
  // 2026-09-26-the-consumer-editor-spec-tests-the-inspector-that-was-
  // demolished, "Fallback owner"), so the Topbar has no component-token
  // owner: the chip is still shown, disabled, with that reason and no owner
  // schema key, and everything else below is unchanged. The refusal of an
  // owned scope no schema entry can represent ("can safely represent this
  // edit") is pinned by IsoNim's tests/test_editor_act_time_refusals.nim.
  test("metacraft_unwritable_corner_radius_scope_is_refused_when_chosen_not_at_save", async ({
    page,
  }) => {
    await page.goto("/");
    const workspaceBefore = snapshotDevWorkspace();
    try {
      await expectWritableBridge(page);
      const { topbar } = await openTopbarInEditMode(page);
      await selectTopbarElement(page, topbar);
      const history = () => page.evaluate(() =>
        (window as any).__isonimEditorVm.inspector.undoStack.value.length);
      const pending = () => page.evaluate(() =>
        (window as any).__isonimEditorVm.inspector.pendingSourceEdits.value.length);
      const startHistory = await history();
      const corners = () => topbar.evaluate((node) => {
        const style = getComputedStyle(node);
        return [style.borderTopLeftRadius, style.borderTopRightRadius,
          style.borderBottomRightRadius, style.borderBottomLeftRadius];
      });
      const before = await corners();

      const radiusRow = page.locator('[data-property-row="corner-radius"]');
      await radiusRow.scrollIntoViewIfNeeded();
      const tokenChip = radiusRow.locator(
        '[aria-label="Apply component token scope for border-radius"]').first();
      if (!(await tokenChip.isVisible())) {
        await radiusRow.locator('[aria-label^="More Choose source scope for "]').first().click();
      }
      await expect(tokenChip).toBeVisible();
      await expect(tokenChip).toHaveAttribute("aria-disabled", "true");
      await expect(tokenChip).toHaveAttribute("data-source-scope-editable", "false");
      await expect(tokenChip).toHaveAttribute("title",
        "No project schema owner is currently mapped for this scope.");
      await expect(tokenChip).toHaveAttribute("data-source-scope-schema", "");
      // Choosing it changes nothing: not the scope, the history or the journal.
      await tokenChip.click({ force: true });
      await expect(tokenChip).toHaveAttribute("aria-pressed", "false");
      expect(await history()).toBe(startHistory);
      expect(await pending()).toBe(0);
      await page.keyboard.press("Escape");

      // The scope the row will commit at is one this host can write.
      const pressed = radiusRow.locator(
        '[data-source-scope-kind][aria-pressed="true"]').first();
      await expect(pressed).toHaveAttribute("data-source-scope-editable", "true");
      await expect(pressed).not.toHaveAttribute("data-source-scope-kind", "sskComponentToken");

      const radius = propertyRowInput(page, "corner-radius");
      await radius.click();
      await radius.fill("12");
      await radius.press("Enter");
      await expect.poll(corners).toEqual(["12px", "12px", "12px", "12px"]);
      await expect.poll(history).toBe(startHistory + 1);
      await expectNoPendingSourceEdits(page);
      await expect(radius).toHaveValue("12");
      const perCorner = page.getByRole("checkbox", { name: "Toggle Per-corner" });
      await perCorner.click();
      await expect(perCorner).toBeChecked();
      for (const corner of ["tl", "tr", "br", "bl"]) {
        await expect(propertyRowInput(page, corner)).toHaveValue("12");
      }
      await perCorner.click();

      await undoInspectorHistoryTo(page, startHistory);
      await expect.poll(corners).toEqual(before);
      await expectNoPendingSourceEdits(page);
    } finally {
      await restoreDevWorkspace(page, workspaceBefore);
    }
  });

  // Reconciled 2026-10-14: the Type tab and its per-property "advanced"
  // details are retired; Typography is a section whose rows follow the
  // property row pattern (`data-property-row`; editor spec "Property row
  // pattern", "No overflow into hidden controls"). The geometric oracle is
  // unchanged: at desktop, tablet and phone window widths every visible row
  // is wider than 180px, stays inside the window and its children do not
  // overlap, and the font-size row stays inside the inspector; a hidden
  // inspector leaves no horizontal page scroll and no visible rows.
  test("e2e_property_controls_no_layout_overlap", async ({ page }) => {
    await page.goto("/");

    const { title } = await openTopbarInEditMode(page);
    await title.click({ force: true });
    await expect(title).toHaveAttribute("data-isonim-selected", "true");

    for (const viewport of [
      { width: 1280, height: 900 },
      { width: 900, height: 900 },
      { width: 430, height: 900 },
    ]) {
      await page.setViewportSize(viewport);
      const inspector = page.locator('[data-sidebar-content="inspector"]');
      const inspectorVisible = await inspector.isVisible();
      test.info().annotations.push({ type: "viewport",
        description: `${viewport.width}: inspector ${inspectorVisible ? "visible" : "hidden"}` });
      if (!inspectorVisible) {
        await expect
          .poll(() =>
            page.evaluate(
              () => document.documentElement.scrollWidth <= window.innerWidth,
            ),
          )
          .toBe(true);
        await expect(page.locator("[data-property-row]:visible")).toHaveCount(0);
        continue;
      }
      const typography = page.locator('[data-inspector-section-header="typography"]');
      if ((await typography.getAttribute("aria-expanded")) !== "true") {
        await typography.click();
      }
      await expect(typography).toHaveAttribute("aria-expanded", "true");
      const fontSizeRow = page.locator('[data-property-row="font-size"]');
      await fontSizeRow.scrollIntoViewIfNeeded();
      await expect(fontSizeRow).toBeVisible();

      const rows = await inspector
        .locator("[data-property-row]")
        .evaluateAll((nodes) =>
          nodes.filter((node) => (node as HTMLElement).offsetParent !== null)
            .map((node) => {
            const rect = node.getBoundingClientRect();
            // The row's controls are the slots of its line (label, value,
            // bind, more); the scope strip and message stack below it.
            const slots = Array.from(node.querySelectorAll(
              ":scope > [data-property-row-line] > *, :scope > :not([data-property-row-line])"));
            const escapes = slots.filter((child) => {
              const r = child.getBoundingClientRect();
              return r.width > 0 && (r.left < rect.left - 0.5 || r.right > rect.right + 0.5);
            }).length;
            const children = slots.map((child) => {
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
              row: node.getAttribute("data-property-row"),
              left: rect.left,
              right: rect.right,
              top: Math.round(rect.top),
              bottom: rect.bottom,
              width: rect.width,
              overlaps,
              escapes,
            };
          }),
        );
      expect(rows.length).toBeGreaterThan(0);
      for (const row of rows) {
        expect(row.left, row.row ?? "").toBeGreaterThanOrEqual(0);
        expect(row.right, row.row ?? "").toBeLessThanOrEqual(viewport.width + 1);
        expect(row.overlaps, row.row ?? "").toBe(0);
        expect(row.escapes, row.row ?? "").toBe(0);
      }
      // Paired rows (e.g. W | H) share one line by design; the former
      // full-width dense-row floor now applies to each line, and rows on a
      // line must not overlap one another.
      const lines = new Map<number, typeof rows>();
      for (const row of rows) lines.set(row.top, [...(lines.get(row.top) ?? []), row]);
      for (const [top, line] of lines) {
        const span = Math.max(...line.map(r => r.right)) - Math.min(...line.map(r => r.left));
        expect(span, `line at ${top}: ${line.map(r => r.row).join(",")}`).toBeGreaterThan(180);
        const ordered = [...line].sort((x, y) => x.left - y.left);
        for (let i = 1; i < ordered.length; i += 1) {
          expect(ordered[i].left, `${ordered[i - 1].row}|${ordered[i].row}`)
            .toBeGreaterThanOrEqual(ordered[i - 1].right - 0.5);
        }
      }

      const inspectorBox = await inspector.boundingBox();
      const fontSizeBox = await fontSizeRow.boundingBox();
      if (!inspectorBox || !fontSizeBox) {
        throw new Error("Inspector typography row boxes are not visible");
      }
      expect(fontSizeBox.x).toBeGreaterThanOrEqual(inspectorBox.x);
      expect(fontSizeBox.x + fontSizeBox.width).toBeLessThanOrEqual(
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

    await viewportButton(page, "Phone").click();
    await expect(page).toHaveURL(/viewport=phone/);
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
    await expect(page).toHaveURL(/viewport=phone/);
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
      "1440px",
    );

    await page.goBack();
    await expect(page).toHaveURL(/view=flow/);
    await expect(page.locator('[data-figma-canvas="true"]')).toBeVisible();

    await page.goForward();
    await expect(page).toHaveURL(/view=page/);
    await page.goForward();
    await expect(page).toHaveURL(/viewport=phone/);
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

    // Fit (editor spec "Canvas Features": "Fit to view — toolbar button zooms
    // to fit all content"; "Canvas Navigation": "Fit button — Zoom to fit
    // all cards") brings every flow card inside the canvas. Reconciled
    // 2026-10-19: this case used to expect Fit to restore the 100% origin
    // view, which is what the removed toolbar's Fit did; on this consumer's
    // six cards that leaves four of them outside the canvas, so the oracle is
    // now the specified one -- every card visible -- and the pan below is
    // measured from the fitted view.
    await page.getByRole("button", { name: "Fit storyboard" }).click();
    await expect.poll(inlineTransform).toMatch(
      /^translate\(-?[\d.]+px, -?[\d.]+px\) scale\(0\.\d+\)$/,
    );
    const canvasBox = await canvas.boundingBox();
    if (!canvasBox) throw new Error("Flow canvas is not visible");
    const cards = page.locator('[data-flow-card="true"]');
    await expect(cards).toHaveCount(6);
    for (const card of await cards.all()) {
      const cardBox = await card.boundingBox();
      if (!cardBox) throw new Error("Flow card has no box");
      expect(cardBox.x).toBeGreaterThanOrEqual(canvasBox.x);
      expect(cardBox.y).toBeGreaterThanOrEqual(canvasBox.y);
      expect(cardBox.x + cardBox.width).toBeLessThanOrEqual(
        canvasBox.x + canvasBox.width,
      );
      expect(cardBox.y + cardBox.height).toBeLessThanOrEqual(
        canvasBox.y + canvasBox.height,
      );
    }
    const fitted = await inlineTransform();
    const [, fitX, fitY, fitScale] = fitted
      .match(/^translate\((-?[\d.]+)px, (-?[\d.]+)px\) scale\(([\d.]+)\)$/)!
      .map(Number);

    const box = await canvas.boundingBox();
    if (!box) throw new Error("Flow canvas is not visible");
    await page.mouse.move(box.x + 8, box.y + 8);
    await page.mouse.down();
    await page.mouse.move(box.x + 88, box.y + 48);
    await page.mouse.up();
    await expect
      .poll(async () => {
        const [, x, y, scale] = (await inlineTransform())
          .match(/^translate\((-?[\d.]+)px, (-?[\d.]+)px\) scale\(([\d.]+)\)$/)!
          .map(Number);
        return [
          Math.round((x - fitX) * 1000) / 1000,
          Math.round((y - fitY) * 1000) / 1000,
          scale === fitScale,
        ];
      })
      .toEqual([80, 40, true]);
    const panned = await inlineTransform();

    await page.keyboard.down("Control");
    await page.mouse.wheel(0, -240);
    await page.keyboard.up("Control");
    await expect.poll(inlineTransform).not.toBe(panned);
  });

  // Editor spec "Canvas Features" / "Canvas Navigation" / "Interactive Play
  // Mode" (isonim-pm issue 2026-10-14-storyboard-zoom-fit-and-flow-play-
  // controls-are-specified-but-absent): the storyboard's zoom, Fit and flow
  // playback controls in the chrome bar, operable by pointer and keyboard;
  // the current step's annotation on the canvas. Physical input on the
  // compiled consumer; nothing is mocked.
  test("e2e_storyboard_flow_controls_zoom_fit_and_playback", async ({ page }) => {
    await page.goto("/");
    await page
      .getByRole("button", { name: "Open User Journeys section" })
      .click();
    const canvas = page.locator('[data-figma-canvas="true"]');
    await expect(canvas).toBeVisible();
    const content = page.locator('[data-figma-canvas-content="true"]');
    const inlineTransform = () =>
      content.evaluate((node) => (node as HTMLElement).style.transform);
    // The operator's 2026-10-22 decision: the controls live in the chrome bar.
    const controls = page.locator('[data-preview-chrome-bar="true"] [data-flow-controls="true"]');
    await expect(controls).toBeVisible();
    await expect(page.locator('[data-storyboard-controls="true"]')).toHaveCount(0);
    const annotation = page.locator('[data-storyboard-step-annotation="true"]');
    // The read-only step caption stays inside the canvas, clear of the minimap.
    const keepsClear = async () => {
      const [o, c, m] = await page.evaluate(() => {
        const box = (n: Element | null) => n!.getBoundingClientRect().toJSON();
        const canvasNode = document.querySelector('[data-figma-canvas="true"]');
        const minimap = [...canvasNode!.children].find((n) => n.textContent?.trim() === "minimap") ?? null;
        return [box(document.querySelector('[data-storyboard-step-annotation="true"]')), box(canvasNode), box(minimap)];
      });
      return o.left >= c.left && o.right <= m.left && o.bottom <= c.bottom;
    };
    expect(await keepsClear()).toBe(true);
    const level = controls.locator('[data-storyboard-zoom-level="true"]');
    const step = annotation.locator('[data-storyboard-step="true"]');
    const zoomOut = page.getByRole("button", { name: "Zoom storyboard out" });
    const zoomIn = page.getByRole("button", { name: "Zoom storyboard in" });
    await expect(level).toHaveText("100%");

    // Zoom keeps the canvas centre in place: 1/1.2 about (w/2, h/2).
    const size = await canvas.evaluate((node) => [node.clientWidth, node.clientHeight]);
    await zoomOut.click();
    await expect(level).toHaveText("83%");
    const [cx, cy] = [size[0] / 2, size[1] / 2];
    const z = 1 / 1.2;
    await expect
      .poll(async () => {
        const [, x, y, scale] = (await inlineTransform())
          .match(/^translate\((-?[\d.]+)px, (-?[\d.]+)px\) scale\(([\d.]+)\)$/)!
          .map(Number);
        return [Math.abs(x - (cx - cx * z)) < 0.01, Math.abs(y - (cy - cy * z)) < 0.01, Math.abs(scale - z) < 1e-6];
      })
      .toEqual([true, true, true]);

    // Keyboard: the clicked control keeps focus; Tab reaches Zoom in, Enter
    // and Space activate it.
    await expect(zoomOut).toBeFocused();
    await page.keyboard.press("Tab");
    await expect(zoomIn).toBeFocused();
    await page.keyboard.press("Enter");
    await expect(level).toHaveText("100%");
    await page.keyboard.press("Space");
    await expect(level).toHaveText("120%");
    for (let i = 0; i < 12; i += 1) await page.keyboard.press("Enter");
    await expect(level).toHaveText("400%");
    await expect(zoomIn).toHaveAttribute("aria-disabled", "true");

    await page.keyboard.press("Tab");
    await expect(page.getByRole("button", { name: "Fit storyboard" })).toBeFocused();
    await page.keyboard.press("Enter");
    const canvasBox = await canvas.boundingBox();
    if (!canvasBox) throw new Error("Flow canvas is not visible");
    // The storyboard's content: the six cards and the two flow headers.
    const boxes = await page
      .locator('[data-flow-card="true"], [data-flow-header]')
      .evaluateAll((nodes) => nodes.map((node) => node.getBoundingClientRect().toJSON()));
    expect(boxes).toHaveLength(8);
    const left = Math.min(...boxes.map((b) => b.left));
    const right = Math.max(...boxes.map((b) => b.right));
    const top = Math.min(...boxes.map((b) => b.top));
    const bottom = Math.max(...boxes.map((b) => b.bottom));
    // Inside the canvas with the 24 px margin on the binding axis, centred.
    expect(left).toBeGreaterThanOrEqual(canvasBox.x + 23.5);
    expect(right).toBeLessThanOrEqual(canvasBox.x + canvasBox.width - 23.5);
    expect(top).toBeGreaterThanOrEqual(canvasBox.y);
    expect(bottom).toBeLessThanOrEqual(canvasBox.y + canvasBox.height);
    expect(Math.abs(left - canvasBox.x - (canvasBox.x + canvasBox.width - right))).toBeLessThan(1);
    expect(Math.abs(top - canvasBox.y - (canvasBox.y + canvasBox.height - bottom))).toBeLessThan(1);
    await expect(level).not.toHaveText("400%");
    await expect(zoomIn).toHaveAttribute("aria-disabled", "false");

    // Flow playback: Play enters step-through playback at the current step.
    const play = page.getByRole("button", { name: "Play flow", exact: true });
    await expect(play).toHaveAttribute("aria-pressed", "false");
    await expect(step).toHaveText("Step 1 / 6");
    await play.click();
    const pause = page.getByRole("button", { name: "Pause flow", exact: true });
    await expect(pause).toHaveAttribute("aria-pressed", "true");
    await expect(page).toHaveURL(/story=Operations%20dashboard/);
    const next = page.getByRole("button", { name: "Next flow step" });
    await next.focus();
    await page.keyboard.press("Enter");
    await expect(step).toHaveText("Step 2 / 6");
    await expect(page).toHaveURL(/story=Customer%20detail/);
    await expect(
      page.getByRole("button", { name: "Select story Back-office pages / Customer detail" }),
    ).toHaveAttribute("aria-current", "true");
    // Chrome order: Play, Stop, Previous, Next.
    await page.keyboard.press("Shift+Tab");
    await page.keyboard.press("Shift+Tab");
    await page.keyboard.press("Shift+Tab");
    await expect(pause).toBeFocused();
    await page.keyboard.press("Space");
    await expect(play).toHaveAttribute("aria-pressed", "false");
    await expect(step).toHaveText("Step 2 / 6");
    await page.getByRole("button", { name: "Previous flow step" }).click();
    await page.getByRole("button", { name: "Previous flow step" }).click();
    await expect(step).toHaveText("Step 6 / 6");
    await expect(page).toHaveURL(/story=Partner%20settlement%20readiness/);

    // Each flow header (with its Play button) stays above its first card.
    const headerGaps = await page.evaluate(() =>
      [...document.querySelectorAll("[data-flow-header]")].map((header) => {
        const name = header.getAttribute("data-flow-header");
        const top = header.getBoundingClientRect().top;
        const below = [...document.querySelectorAll('[data-flow-card="true"]')]
          .map((card) => card.getBoundingClientRect())
          .filter((box) => box.top >= top)
          .sort((a, b) => a.top - b.top)[0];
        return [name, Math.round((below.top - header.getBoundingClientRect().bottom) * 100) / 100];
      }));
    expect(headerGaps).toHaveLength(2);
    for (const [, gap] of headerGaps) expect(gap as number).toBeGreaterThanOrEqual(0);

    // The current step is annotated with its action.
    await expect(annotation.locator('[data-storyboard-step-action="true"]')).toHaveText(
      "Settlement batch export",
    );

    expect(await keepsClear()).toBe(true);
    // Each flow has its own Play: it starts at that flow's first step.
    await page.getByRole("button", { name: "Play flow Partner operations" }).click();
    await expect(step).toHaveText("Step 4 / 6");
    await expect(pause).toHaveAttribute("aria-pressed", "true");
    await expect(annotation.locator('[data-storyboard-step-action="true"]')).toHaveText(
      "Partner invitation",
    );
    // Double-clicking a flow enters playback at its first step.
    await pause.click();
    await page.getByRole("button", { name: "Next flow step" }).click();
    await expect(step).toHaveText("Step 5 / 6");
    await page
      .locator('[data-flow-header="Customer and license flows"]')
      .getByText("Customer and license flows", { exact: true })
      .dblclick();
    await expect(step).toHaveText("Step 1 / 6");
    await expect(pause).toHaveAttribute("aria-pressed", "true");
    await page.getByRole("button", { name: "Next flow step" }).click();
    await expect(step).toHaveText("Step 2 / 6");
    await page.getByRole("button", { name: "Stop flow" }).click();
    await expect(play).toHaveAttribute("aria-pressed", "false");
    await expect(step).toHaveText("Step 1 / 6");
    await expect(page).toHaveURL(/story=Operations%20dashboard/);
    await expect(canvas).toBeVisible();
  });

  // Editor spec "Preview-pane chrome layout": every chrome-bar control stays
  // visible in its single 44 px row while the storyboard's flow controls are
  // shown, at the desktop (1440) and laptop (1280) window widths with the
  // default sidebars; on another view the row is unchanged.
  test("e2e_storyboard_chrome_bar_shows_every_control_at_1280_and_1440", async ({
    page,
  }) => {
    for (const width of [1440, 1280]) {
      await page.setViewportSize({ width, height: 900 });
      await page.goto("/");
      await page.getByRole("button", { name: "Open User Journeys section" }).click();
      await expect(page.locator('[data-figma-canvas="true"]')).toBeVisible();
      const chrome = page.locator('[data-preview-chrome-bar="true"]');
      await expect(chrome.locator('[data-flow-controls="true"]')).toBeVisible();
      const layout = await chrome.evaluate((bar) => {
        const box = bar.getBoundingClientRect();
        const controls = [...bar.querySelectorAll("button, [role=button]")].filter(
          (node) => (node as HTMLElement).offsetParent !== null,
        );
        return {
          height: Math.round(box.height),
          scroll: bar.scrollWidth - bar.clientWidth,
          count: controls.length,
          outside: controls
            .filter((node) => {
              const r = node.getBoundingClientRect();
              return r.left < box.left - 0.5 || r.right > box.right + 0.5 ||
                r.top < box.top - 0.5 || r.bottom > box.bottom + 0.5;
            })
            .map((node) => node.getAttribute("aria-label") || node.textContent?.trim()),
        };
      });
      expect(layout.height).toBe(44);
      expect(layout.outside).toEqual([]);
      expect(layout.scroll).toBeLessThanOrEqual(0);
      for (const name of ["Toggle left sidebar", "Toggle right sidebar", "Switch to edit mode",
        "Play flow", "Fit storyboard", "Zoom storyboard in"]) {
        await expect(page.getByRole("button", { name, exact: true })).toBeInViewport({ ratio: 1 });
      }
    }
  });

  // Editor spec "Resizable sidebars" (isonim-pm issue 2026-10-14-dragging-
  // the-right-sidebar-resize-handle-does-not-resize-it): both handles are
  // dragged across the project preview iframe on the root page -- the case
  // that lost every pointer event to the iframe -- and operated from the
  // keyboard; widths are clamped and persist across a reload.
  test("e2e_sidebar_resize_handles_drag_over_preview_keyboard_and_persist", async ({
    page,
  }) => {
    await page.goto("/");
    await expect(page.locator('[data-sidebar-content="ai-assistant"]')).toBeVisible();
    const right = page.locator('[data-sidebar-content]:visible [data-resize-handle="right-panel"]');
    const left = page.locator('[data-resize-handle="left-sidebar"]');
    const rightWidth = () =>
      page.locator("[data-sidebar-content]:visible").getAttribute("data-right-panel-width");
    const leftWidth = () =>
      page.locator("[data-left-sidebar-width]").getAttribute("data-left-sidebar-width");
    await expect.poll(rightWidth).toBe("320");
    await expect.poll(leftWidth).toBe("260");
    await expect(page.frameLocator('iframe[title="Project preview"]').locator("body")).toBeVisible();

    const drag = async (handle, dx: number) => {
      const box = await handle.boundingBox();
      if (!box) throw new Error("resize handle is not visible");
      const x = box.x + box.width / 2;
      const y = box.y + box.height / 2;
      await page.mouse.move(x, y);
      await page.mouse.down();
      await page.mouse.move(x + dx, y, { steps: 8 });
      await page.mouse.up();
      return { x, y };
    };
    const underPath = (x: number, y: number) =>
      page.evaluate(([px, py]) => {
        const node = document.elementFromPoint(px, py);
        return node?.tagName === "IFRAME" ? node.getAttribute("title") : node?.tagName;
      }, [x, y]);

    // The pointer travels over the project preview iframe.
    const rightStart = await right.boundingBox();
    if (!rightStart) throw new Error("right handle is not visible");
    expect(await underPath(rightStart.x - 40, rightStart.y + rightStart.height / 2)).toBe("Project preview");
    const stored = () =>
      page.evaluate(() => JSON.parse(localStorage.getItem("isonim-editor-sidebar-widths") ?? "null"));
    // Touch and pen drags are not handed to the browser's panning.
    expect(await right.evaluate((node) => getComputedStyle(node).touchAction)).toBe("none");
    expect(await left.evaluate((node) => getComputedStyle(node).touchAction)).toBe("none");
    // The drag resizes live but writes storage once, on release.
    {
      const box = await right.boundingBox();
      if (!box) throw new Error("resize handle is not visible");
      const x = box.x + box.width / 2;
      const y = box.y + box.height / 2;
      await page.mouse.move(x, y);
      await page.mouse.down();
      await page.mouse.move(x - 80, y, { steps: 8 });
      await expect.poll(rightWidth).toBe("400");
      expect(await stored()).toBeNull();
      await page.mouse.up();
    }
    expect(await stored()).toEqual({ left: 260, right: 400 });
    expect(await page.evaluate(() => document.body.style.cursor)).toBe("");
    await expect(right).toHaveAttribute("aria-valuenow", "400");
    // Clamped at 420 however far the drag goes.
    await drag(right, -200);
    await expect.poll(rightWidth).toBe("420");

    const leftStart = await left.boundingBox();
    if (!leftStart) throw new Error("left handle is not visible");
    expect(await underPath(leftStart.x + 40, leftStart.y + leftStart.height / 2)).toBe("Project preview");
    await drag(left, 60);
    await expect.poll(leftWidth).toBe("320");
    expect(await stored()).toEqual({ left: 320, right: 420 });
    await drag(left, -400);
    await expect.poll(leftWidth).toBe("180");

    // A mode switch mid-drag swaps the right sidebar out (the AI panel or
    // the Inspector is detached, not disposed). The drag must end there --
    // the handle loses its pointer capture -- even when the button is then
    // released over the preview iframe, whose document would receive that
    // release: the cursor is restored, the width the drag reached is
    // persisted, and the panel no longer follows a pointer with no button.
    const dragAcrossModeSwitch = async (modeIndex: number, nextPanel: string) => {
      await right.focus();
      await page.keyboard.press("Home");
      await expect.poll(rightWidth).toBe("240");
      const box = await right.boundingBox();
      if (!box) throw new Error("resize handle is not visible");
      const x = box.x + box.width / 2;
      const y = box.y + box.height / 2;
      await page.mouse.move(x, y);
      await page.mouse.down();
      // Past the 420 clamp: the pointer ends up over the preview iframe.
      await page.mouse.move(x - 220, y, { steps: 8 });
      await expect.poll(rightWidth).toBe("420");
      expect(await underPath(x - 220, y)).toBe("Project preview");
      expect(await stored()).toEqual({ left: 180, right: 240 });
      expect(await page.evaluate(() => document.body.style.cursor)).toBe("col-resize");
      await page.evaluate((m) => (window as any).__isonimEditor.setEditMode(m), modeIndex);
      await expect(page.locator(`[data-sidebar-content="${nextPanel}"]`)).toBeVisible();
      await page.mouse.move(x - 230, y, { steps: 2 });
      await page.mouse.up();
      expect(await page.evaluate(() => document.body.style.cursor)).toBe("");
      expect(await page.evaluate(() => document.body.style.userSelect)).toBe("");
      expect(await stored()).toEqual({ left: 180, right: 420 });
      // Hovering back with no button held does not resize.
      await page.mouse.move(x + 100, y, { steps: 4 });
      await expect.poll(rightWidth).toBe("420");
    };
    await dragAcrossModeSwitch(3, "inspector"); // AI assistant -> Edit
    await dragAcrossModeSwitch(1, "ai-assistant"); // Inspector -> View

    // A move with no button held ends a drag whose release never arrived
    // (it went to another document): the drag stops and is persisted.
    {
      const box = await left.boundingBox();
      if (!box) throw new Error("left handle is not visible");
      const x = box.x + box.width / 2;
      const y = box.y + box.height / 2;
      await page.mouse.move(x, y);
      await page.mouse.down();
      await page.mouse.move(x + 20, y, { steps: 2 });
      await expect.poll(leftWidth).toBe("200");
      await page.evaluate(([px, py]) => {
        document.dispatchEvent(new PointerEvent("pointermove", {
          pointerId: 1, pointerType: "mouse", isPrimary: true, buttons: 0,
          clientX: px + 60, clientY: py, bubbles: true,
        }));
      }, [x, y]);
      expect(await page.evaluate(() => document.body.style.cursor)).toBe("");
      expect(await stored()).toEqual({ left: 200, right: 420 });
      await page.mouse.move(x + 60, y, { steps: 2 });
      await expect.poll(leftWidth).toBe("200");
      await page.mouse.up();
      await left.focus();
      await page.keyboard.press("Home");
      await expect.poll(leftWidth).toBe("180");
    }

    // Touch (and pen) drags resize too: the handles listen to pointer
    // events and set touch-action: none. A real CDP touch gesture.
    {
      const box = await left.boundingBox();
      if (!box) throw new Error("left handle is not visible");
      const x = Math.round(box.x + box.width / 2);
      const y = Math.round(box.y + box.height / 2);
      const cdp = await page.context().newCDPSession(page);
      const touch = (type: string, tx: number) =>
        cdp.send("Input.dispatchTouchEvent", {
          type,
          touchPoints: type === "touchEnd" ? [] : [{ x: tx, y }],
        });
      await touch("touchStart", x);
      for (let i = 1; i <= 5; i += 1) await touch("touchMove", x + 8 * i);
      await expect.poll(leftWidth).toBe("220");
      expect(await stored()).toEqual({ left: 180, right: 420 });
      await touch("touchEnd", x + 40);
      await expect.poll(stored).toEqual({ left: 220, right: 420 });
      expect(await page.evaluate(() => document.body.style.cursor)).toBe("");
      await cdp.detach();
    }

    // Keyboard: focusable vertical separators carrying the width.
    await expect(right).toHaveAttribute("role", "separator");
    await expect(right).toHaveAttribute("aria-orientation", "vertical");
    await expect(right).toHaveAttribute("aria-valuemin", "240");
    await expect(right).toHaveAttribute("aria-valuemax", "420");
    await right.focus();
    await page.keyboard.press("End");
    await expect.poll(rightWidth).toBe("420");
    await page.keyboard.press("ArrowRight");
    await expect.poll(rightWidth).toBe("404");
    await page.keyboard.press("Home");
    await expect.poll(rightWidth).toBe("240");
    await page.keyboard.press("ArrowLeft");
    await page.keyboard.press("ArrowLeft");
    await expect.poll(rightWidth).toBe("272");
    await expect(right).toHaveAttribute("aria-valuenow", "272");
    await left.focus();
    await page.keyboard.press("End");
    await expect.poll(leftWidth).toBe("420");
    await page.keyboard.press("ArrowLeft");
    await expect.poll(leftWidth).toBe("404");
    const leftBox = await page.locator("[data-left-sidebar-width]").boundingBox();
    expect(Math.round(leftBox!.width)).toBeGreaterThanOrEqual(404);

    // Persisted: a reload restores both widths.
    await page.reload();
    await expect(page.locator('[data-sidebar-content="ai-assistant"]')).toBeVisible();
    await expect.poll(rightWidth).toBe("272");
    await expect.poll(leftWidth).toBe("404");
    expect(await stored()).toEqual({ left: 404, right: 272 });
  });
});

// Current consumer regression: genuine compiled frontend, owned filesystem
// bridge and physical inspector interactions. The consumer's declarative
// compile callbacks are not a post-write compiler-execution oracle. All cases
// target the current UI; the historical cases were reconciled on 2026-10-14
// (each carries a "Reconciled" note mapping its retired controls), except the
// storyboard zoom case, whose zoom/fit controls the specification still
// requires. No case uses mocks: the compiled bundle, the dev write bridge over
// generated source copies and real Chromium are exercised directly.
// Additional cascade/foreign/malformed markers are owned source fixtures applied
// through the real CAS bridge, not simulated inspector or compiler results.
// A temporary sibling DOM reference uses independent browser font-unit CSS;
// it measures expected em/ex pixels without changing editor models.
test("metacraft_topbar_padding_edges_survive_actual_save_and_reload", async ({ page }) => {
  // Three full reloads and six real bridge writes: 17-20 s on an idle host,
  // 26 s and a 30 s timeout under a loaded full run (UX-M3 act-time refusals
  // review). The default 30 s budget measured the host, not the editor; the
  // sibling-padding case below already carries its own budget.
  test.setTimeout(90_000);
  const errors: string[] = [];
  page.on("pageerror", error => errors.push(error.message));
  const writes: any[] = [];
  page.on("request", request => {
    if (request.url().endsWith("/__isonim-dev-bridge/transaction")) {
      writes.push(request.postDataJSON());
    }
  });
  await page.goto("/?writeBridge=1");
  const original = readFileSync(devBridgeSourceFile, "utf8");
  let saved = original;
  const selectTopbar = async () => {
    await page.getByRole("button", {
      name: "Select story Operational components / Topbar", exact: true,
    }).click();
    await page.locator('[data-toolbar-cluster="mode"] [data-choice-group-label="View"]').click();
    await page.locator('[data-toolbar-cluster="mode"] [data-choice-group-label="Edit"]').click();
    const topbar = page.frameLocator('iframe[title="Editable component preview"]')
      .getByTestId("component-topbar");
    await expect(topbar).toBeVisible();
    await expect.poll(() => topbar.evaluate(node => node.ownerDocument.readyState)).toBe("complete");
    // A restored same-ID selection is already selected in the VM. Choose the
    // real child first so the physical header selection reaches the new frame.
    await page.getByRole("button", { name: /h1\.bo-title.*Operations dashboard/ }).click();
    await page.getByRole("button", {
      name: "header[data-testid=component-topbar]", exact: true,
    }).click();
    await expect(topbar).toHaveAttribute("data-isonim-selected", "true");
    return topbar;
  };
  const history = async () => page.evaluate(() => {
    const inspector = (window as any).__isonimEditorVm.inspector;
    if (!Array.isArray(inspector.undoStack.value) || !Array.isArray(inspector.redoStack.value)) {
      throw new Error("Missing actual inspector history");
    }
    return { undo: inspector.undoStack.value.length, redo: inspector.redoStack.value.length };
  });
  const paddings = async (topbar) => topbar.evaluate(node => {
    const style = getComputedStyle(node);
    return [style.paddingTop, style.paddingRight, style.paddingBottom, style.paddingLeft];
  });
  try {
    let topbar = await selectTopbar();
    await expect.poll(() => paddings(topbar)).toEqual(["0px", "0px", "0px", "0px"]);
    const beforeHistory = await history();
    let commits = 0;
    for (const [edge, value] of [["top", "17"], ["right", "19"], ["bottom", "23"], ["left", "29"]]) {
      const input = page.locator(`[data-property-row="pad-${edge}"] input[data-property-row-input]`);
      await expect(input).toBeEditable();
      await input.click();
      await input.fill(value);
      await input.press("Enter");
      await expect.poll(() => readFileSync(devBridgeSourceFile, "utf8"))
        .toContain(`# isonim-editor dom.component-topbar.padding-${edge} padding-${edge}=${value}px`);
      commits++;
      await expect.poll(history).toEqual({ undo: beforeHistory.undo + commits, redo: 0 });
    }
    saved = readFileSync(devBridgeSourceFile, "utf8");
    expect(saved).not.toBe(original);
    expect(writes.filter(write => write.mode === "apply")).toHaveLength(4);
    await expect.poll(() => paddings(topbar)).toEqual(["17px", "19px", "23px", "29px"]);
    await page.reload();
    topbar = await selectTopbar();
    await expect.poll(() => paddings(topbar)).toEqual(["17px", "19px", "23px", "29px"]);
    expect(readFileSync(devBridgeSourceFile, "utf8")).toBe(saved);
    // Untouched focus/Tab must not append another marker or source operation.
    const input = page.locator('[data-property-row="pad-top"] input[data-property-row-input]');
    await expect(input).toHaveValue("17");
    const untouchedHistory = await history();
    await input.click();
    await input.press("Tab");
    expect(await history()).toEqual(untouchedHistory);
    expect(readFileSync(devBridgeSourceFile, "utf8")).toBe(saved);
    expect(writes.filter(write => write.mode === "apply")).toHaveLength(4);
    expect(errors).toEqual([]);
    const cascade = saved +
      "# isonim-editor dom.component-panel-header.padding padding=90px\n" +
      "# isonim-editor dom.component-topbar.padding padding=3px 4px\n" +
      "# isonim-editor dom.component-topbar.padding-left padding-left=31px\n" +
      "# isonim-editor dom.component-topbar.padding-top padding-top=NaNpx\n" +
      "# isonim-editor dom.component-topbar.padding padding=9px; color:red\n";
    const applied = await page.evaluate(async ({ beforeText, afterText }) => {
      const response = await fetch("/__isonim-dev-bridge/transaction", {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ mode: "apply", files: [{
          file: "apps/back-office/src/backoffice_ui/components.nim", beforeText, afterText,
        }] }),
      });
      return response.json();
    }, { beforeText: saved, afterText: cascade });
    expect(applied.ok).toBe(true);
    expect(readFileSync(devBridgeSourceFile, "utf8")).toBe(cascade);
    await page.reload();
    topbar = await selectTopbar();
    await expect.poll(() => paddings(topbar)).toEqual(["3px", "4px", "3px", "31px"]);
    expect(readFileSync(devBridgeSourceFile, "utf8")).toBe(cascade);
    expect(errors).toEqual([]);
    // Exercise the actual compiled pure reader, including exponent/unit
    // boundaries, against fixed literal CSS expectations (no parser mirror).
    for (const unit of ["px", "em", "rem", "%", "vw", "vh", "vmin", "vmax", "ch", "ex"]) {
      for (const magnitude of ["1.25", "1e2", "1.25e-2", "0"]) {
        const value = magnitude + unit;
        const declarations = await page.evaluate(value =>
          (window as any).__metacraftTopbarPaddingDeclarations(
            "# isonim-editor dom.component-topbar.padding-top padding-top=" + value), value);
        expect(declarations).toBe("padding-top:" + value + " !important;");
      }
    }
    for (const value of ["1epx", "1e+em", "1e-ex", "1e2remjunk", "1.25.3em", "1e309em"]) {
      expect(await page.evaluate(value =>
        (window as any).__metacraftTopbarPaddingDeclarations(
          "# isonim-editor dom.component-topbar.padding-top padding-top=" + value), value)).toBe("");
    }
    const fontUnits = cascade + "# isonim-editor dom.component-topbar.padding padding=1.25em 1.25ex\n";
    const unitApplied = await page.evaluate(async ({ beforeText, afterText }) => {
      const response = await fetch("/__isonim-dev-bridge/transaction", {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ mode: "apply", files: [{
          file: "apps/back-office/src/backoffice_ui/components.nim", beforeText, afterText,
        }] }),
      });
      return response.json();
    }, { beforeText: cascade, afterText: fontUnits });
    expect(unitApplied.ok).toBe(true);
    await page.reload();
    topbar = await selectTopbar();
    const unitStyles = await topbar.evaluate(node => {
      const style = getComputedStyle(node);
      const reference = node.ownerDocument.createElement("div");
      reference.style.font = style.font;
      reference.style.padding = "1.25em 1.25ex";
      node.parentElement!.appendChild(reference);
      try {
        const expected = getComputedStyle(reference);
        return {
          actual: [style.paddingTop, style.paddingRight, style.paddingBottom, style.paddingLeft],
          expected: [expected.paddingTop, expected.paddingRight, expected.paddingBottom, expected.paddingLeft],
          rule: node.ownerDocument.getElementById("metacraft-editor-topbar-padding")!.textContent,
        };
      } finally { reference.remove(); }
    });
    expect(unitStyles.actual).toEqual(unitStyles.expected);
    expect(unitStyles.actual[0]).not.toBe("0px");
    expect(unitStyles.actual[1]).not.toBe("0px");
    expect(unitStyles.rule).toContain("padding:1.25em 1.25ex !important;");
    expect(readFileSync(devBridgeSourceFile, "utf8")).toBe(fontUnits);
    expect(errors).toEqual([]);
  } finally {
    // Through the bridge while the page is alive, else written directly: a
    // timeout closes the page, and a revert that needed it left the markers
    // in the dev workspace for the next case to start from.
    await restoreDevBridgeFile(page,
      "apps/back-office/src/backoffice_ui/components.nim",
      devBridgeSourceFile, original);
    expect(readFileSync(devBridgeSourceFile, "utf8")).toBe(original);
  }
  await page.reload();
  const restoredTopbar = await selectTopbar();
  await expect.poll(() => paddings(restoredTopbar)).toEqual(["0px", "0px", "0px", "0px"]);
  expect(errors).toEqual([]);
});

// Sibling-undo data-loss regression: isonim-specs issue
// 2026-10-13-undo-of-an-appended-edit-expects-the-bare-value and metacraft-web
// issue 2026-10-13-patch-file-replaces-every-occurrence-of-the-expected-value.
// No mocks: the genuine compiled consumer bundle, the real dev write bridge
// over the generated dist/editor-dev-workspace source copy, and real Chromium.
// Edits are typed into the Layout pad rows; history is driven by Ctrl/Cmd+Z,
// Ctrl/Cmd+Shift+Z and by pointer clicks on the command palette's Undo/Redo
// options. The VM is only read (history counts). Expected file contents are
// literal marker lines, not values recomputed by an editor model.
test("metacraft_topbar_sibling_padding_undo_restores_only_its_own_marker", async ({ page }) => {
  // Twelve auto-saved writes (each after the editor's 900 ms debounce),
  // three reloads and a refusal hold; the shared 30 s default is too small
  // for the sequence, so this case declares its own explicit budget.
  test.setTimeout(150_000);
  const errors: string[] = [];
  page.on("pageerror", error => errors.push(error.message));
  const writes: any[] = [];
  page.on("request", request => {
    if (request.url().endsWith("/__isonim-dev-bridge/transaction")) {
      writes.push(request.postDataJSON());
    }
  });
  const sourceFile = "apps/back-office/src/backoffice_ui/components.nim";
  const read = () => readFileSync(devBridgeSourceFile, "utf8");
  const marker = (edge: string, value: string) =>
    `# isonim-editor dom.component-topbar.padding-${edge} padding-${edge}=${value}\n`;
  // The writer appends after the trimmed file and one newline.
  const append = (text: string, line: string) => text.replace(/\s+$/, "") + "\n" + line;
  await page.goto("/?writeBridge=1");
  const original = read();
  const afterTop = append(original, marker("top", "6px"));
  const afterBoth = append(afterTop, marker("left", "6px"));
  const applies = () => writes.filter(write => write.mode === "apply").length;
  const selectTopbar = async () => {
    await page.getByRole("button", {
      name: "Select story Operational components / Topbar", exact: true,
    }).click();
    await page.locator('[data-toolbar-cluster="mode"] [data-choice-group-label="View"]').click();
    await page.locator('[data-toolbar-cluster="mode"] [data-choice-group-label="Edit"]').click();
    const topbar = page.frameLocator('iframe[title="Editable component preview"]')
      .getByTestId("component-topbar");
    await expect(topbar).toBeVisible();
    await expect.poll(() => topbar.evaluate(node => node.ownerDocument.readyState)).toBe("complete");
    await page.getByRole("button", { name: /h1\.bo-title.*Operations dashboard/ }).click();
    await page.getByRole("button", {
      name: "header[data-testid=component-topbar]", exact: true,
    }).click();
    await expect(topbar).toHaveAttribute("data-isonim-selected", "true");
    return topbar;
  };
  const history = async () => page.evaluate(() => {
    const inspector = (window as any).__isonimEditorVm.inspector;
    if (!Array.isArray(inspector.undoStack.value) || !Array.isArray(inspector.redoStack.value)) {
      throw new Error("Missing actual inspector history");
    }
    return { undo: inspector.undoStack.value.length, redo: inspector.redoStack.value.length };
  });
  const paddings = async (topbar) => topbar.evaluate(node => {
    const style = getComputedStyle(node);
    return [style.paddingTop, style.paddingRight, style.paddingBottom, style.paddingLeft];
  });
  const commit = async (edge: string, value: string) => {
    const input = page.locator(`[data-property-row="pad-${edge}"] input[data-property-row-input]`);
    await expect(input).toBeEditable();
    await input.click();
    await input.fill(value);
    await input.press("Enter");
  };
  // Keyboard history needs a non-editable focus target; the shortcut is
  // deliberately ignored while a text field owns the keys.
  // The selected Layers row is a real, non-editable control.
  const layersRow = () => page.getByRole("button", {
    name: "header[data-testid=component-topbar]", exact: true,
  });
  const keyboardHistory = async (redo: boolean) => {
    const target = layersRow();
    await target.focus();
    await expect(target).toBeFocused();
    await page.keyboard.press(redo ? "ControlOrMeta+Shift+Z" : "ControlOrMeta+Z");
  };
  const pointerHistory = async (redo: boolean) => {
    const target = layersRow();
    await target.focus();
    await page.keyboard.press("ControlOrMeta+K");
    const option = page.locator(
      `[data-editor-command-option="true"][data-command-kind="${redo ? "eckRedo" : "eckUndo"}"]`);
    await expect(option).toBeVisible();
    await option.click();
    await expect(page.locator('[data-editor-command-palette="true"]'))
      .toHaveAttribute("aria-hidden", "true");
  };
  const settled = async (text: string, hist, pads, topbar) => {
    await expect.poll(read).toBe(text);
    await expect.poll(history).toEqual(hist);
    await expect.poll(() => paddings(topbar)).toEqual(pads);
    // The auto-save debounce has nothing left to write.
    await expect.poll(() => page.evaluate(() =>
      (window as any).__isonimEditorVm.inspector.pendingSourceEdits.value.length)).toBe(0);
    expect(read()).toBe(text);
  };
  try {
    let topbar = await selectTopbar();
    await expect.poll(() => paddings(topbar)).toEqual(["0px", "0px", "0px", "0px"]);
    const h0 = await history();
    const at = (undo: number, redo: number) => ({ undo: h0.undo + undo, redo: h0.redo + redo });
    const zero = ["0px", "0px", "0px", "0px"];
    const top = ["6px", "0px", "0px", "0px"];
    const both = ["6px", "0px", "0px", "6px"];

    // Two sibling edits whose values have the same text.
    await commit("top", "6");
    await settled(afterTop, at(1, 0), top, topbar);
    await commit("left", "6");
    await settled(afterBoth, at(2, 0), both, topbar);
    expect(read().split("padding-top=6px").length - 1).toBe(1);

    // Undo once (pointer): only padding-left's own marker line goes.
    await pointerHistory(false);
    await settled(afterTop, at(1, 1), top, topbar);
    // Redo (pointer): the line comes back, byte-identical to the edit.
    await pointerHistory(true);
    await settled(afterBoth, at(2, 0), both, topbar);
    // Undo twice (keyboard): one edit at a time, back to the original bytes.
    await keyboardHistory(false);
    await settled(afterTop, at(1, 1), top, topbar);
    await keyboardHistory(false);
    await settled(original, at(0, 2), zero, topbar);
    await keyboardHistory(true);
    await settled(afterTop, at(1, 1), top, topbar);
    await keyboardHistory(true);
    await settled(afterBoth, at(2, 0), both, topbar);

    // Unsafe restoration: someone else rewrites padding-left's written line.
    // Undo must refuse, say why, and change nothing.
    const external = afterBoth.replace(marker("left", "6px"), marker("left", "7px"));
    const rewrite = async (beforeText: string, afterText: string) => page.evaluate(
      async ({ file, beforeText, afterText }) => {
        const response = await fetch("/__isonim-dev-bridge/transaction", {
          method: "POST", headers: { "content-type": "application/json" },
          body: JSON.stringify({ mode: "apply", files: [{ file, beforeText, afterText }] }),
        });
        return response.json();
      }, { file: sourceFile, beforeText, afterText });
    expect((await rewrite(afterBoth, external)).ok).toBe(true);
    const appliesBeforeRefusal = applies();
    await keyboardHistory(false);
    const refusal = page.locator('[data-save-error="true"]');
    await expect(refusal).toBeVisible();
    await expect(refusal).toContainText("Undo refused");
    expect(await history()).toEqual(at(2, 0));
    await expect.poll(() => paddings(topbar)).toEqual(both);
    await page.waitForTimeout(1500);
    expect(read()).toBe(external);
    expect(applies()).toBe(appliesBeforeRefusal);
    expect((await rewrite(external, afterBoth)).ok).toBe(true);

    // Undo once more, then reload: the un-undone padding-top edit survives.
    await keyboardHistory(false);
    await settled(afterTop, at(1, 1), top, topbar);
    await expect(refusal).toBeHidden();
    await page.reload();
    topbar = await selectTopbar();
    await expect.poll(() => paddings(topbar)).toEqual(top);
    expect(read()).toBe(afterTop);

    // Single-edit regression on the reloaded editor (fresh history): one
    // appended edit, keyboard undo restores the exact bytes, redo re-appends.
    const r0 = await history();
    const afterBottom = append(afterTop, marker("bottom", "6px"));
    const topBottom = ["6px", "0px", "6px", "0px"];
    await commit("bottom", "6");
    await settled(afterBottom, { undo: r0.undo + 1, redo: r0.redo }, topBottom, topbar);
    await keyboardHistory(false);
    await settled(afterTop, { undo: r0.undo, redo: r0.redo + 1 }, top, topbar);
    await keyboardHistory(true);
    await settled(afterBottom, { undo: r0.undo + 1, redo: r0.redo }, topBottom, topbar);
    expect(errors).toEqual([]);
  } finally {
    const afterText = read();
    if (afterText !== original) {
      try {
        await revertDevBridgeFiles(page, [{ file: sourceFile, beforeText: original, afterText }]);
      } catch (error) {
        // The page is gone (e.g. a timeout): restore the generated copy
        // directly so a failure here cannot leak into later cases.
        writeFileSync(devBridgeSourceFile, original);
        throw error;
      }
    }
    expect(read()).toBe(original);
  }
  await page.reload();
  const restoredTopbar = await selectTopbar();
  await expect.poll(() => paddings(restoredTopbar)).toEqual(["0px", "0px", "0px", "0px"]);
  expect(errors).toEqual([]);
});
