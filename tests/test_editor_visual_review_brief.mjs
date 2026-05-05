import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import test from "node:test";
import assert from "node:assert/strict";

test("editor_visual_review_brief_lists_changed_surfaces", () => {
  const dir = mkdtempSync(join(tmpdir(), "isonim-editor-visual-"));
  const input = join(dir, "changed-surfaces.json");
  const output = join(dir, "brief.md");

  writeFileSync(
    input,
    JSON.stringify(
      {
        title: "IsoNim Editor M43 Visual Review",
        milestone: "M43",
        generatedAt: "2026-05-05T00:00:00.000Z",
        changedScreenshots: [
          {
            surface: "edit inspector, token manager, style manager, layers",
            viewport: "1440x900",
            path: "test-results/m43-edit-inspector-token-style-layers.png",
            diffPixels: 412,
            diffRatio: 0.0021,
            feature: "css_editors style_class_cascade_token_manager",
          },
          {
            surface: "vector editor canvas handles",
            viewport: "1280x800",
            path: "test-results/m43-vector-editor.png",
            diffPixels: 96,
            diffRatio: 0.0004,
            feature: "svg_editors",
          },
        ],
        failedDensityChecks: [
          {
            surface: "narrow right panel",
            check: "essential controls remain reachable",
            expected: "no clipped Save/Revert or token controls",
            actual:
              "Save button stayed visible; token row clipped in candidate",
          },
        ],
        affectedMilestones: ["M43", "M45"],
        commands: [
          "direnv exec /home/zahary/metacraft/isonim just test-editor-visual-gates",
        ],
      },
      null,
      2,
    ),
  );

  execFileSync("node", [
    "tools/editor-visual-review-brief.mjs",
    "--input",
    input,
    "--output",
    output,
  ]);

  const brief = readFileSync(output, "utf8");
  assert.match(brief, /IsoNim Editor M43 Visual Review/);
  assert.match(brief, /edit inspector, token manager, style manager, layers/);
  assert.match(brief, /vector editor canvas handles/);
  assert.match(brief, /narrow right panel/);
  assert.match(brief, /M45/);
  assert.match(brief, /just test-editor-visual-gates/);
});
