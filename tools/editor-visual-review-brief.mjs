#!/usr/bin/env node

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

const defaultInput = "build/editor/visual-review/changed-surfaces.json";
const defaultOutput = "build/editor/visual-review/brief.md";

function parseArgs(argv) {
  const args = {
    input: defaultInput,
    output: defaultOutput,
  };
  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--input" && argv[i + 1]) args.input = argv[++i];
    else if (arg === "--output" && argv[i + 1]) args.output = argv[++i];
    else if (arg === "--help") {
      console.log(
        "Usage: node tools/editor-visual-review-brief.mjs --input changes.json --output brief.md",
      );
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return args;
}

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function listItems(items, render) {
  if (!items || items.length === 0) return "- None reported\n";
  return items.map(render).join("\n") + "\n";
}

export function renderVisualReviewBrief(report) {
  const generatedAt = report.generatedAt || new Date(0).toISOString();
  const milestone = report.milestone || "M43";
  const title = report.title || "IsoNim Editor Visual Review";
  const changedScreenshots = report.changedScreenshots || [];
  const densityChecks = report.failedDensityChecks || [];
  const affected = report.affectedMilestones || [];
  const commands = report.commands || [];

  return `# ${title}

Milestone: ${milestone}
Generated: ${generatedAt}

## Changed Screenshots
${listItems(changedScreenshots, (item) => {
  const diff = item.diffPixels === undefined ? "n/a" : `${item.diffPixels} px`;
  const ratio =
    item.diffRatio === undefined
      ? "n/a"
      : `${Math.round(Number(item.diffRatio) * 10000) / 100}%`;
  return `- ${item.surface} (${item.viewport})\n  screenshot: ${item.path}\n  diff: ${diff}, ${ratio}\n  feature: ${item.feature || "unspecified"}`;
})}
## Failed Density And UX Checks
${listItems(densityChecks, (item) => {
  return `- ${item.surface}: ${item.check}\n  expected: ${item.expected}\n  actual: ${item.actual}`;
})}
## Affected Milestones
${listItems(affected, (item) => `- ${item}`)}
## Reproduction Commands
${listItems(commands, (item) => `- \`${item}\``)}
`;
}

function main() {
  const args = parseArgs(process.argv);
  const input = resolve(args.input);
  const output = resolve(args.output);
  const report = readJson(input);
  const brief = renderVisualReviewBrief(report);
  mkdirSync(dirname(output), { recursive: true });
  writeFileSync(output, brief);
  console.log(output);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
