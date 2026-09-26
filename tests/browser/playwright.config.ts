import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { defineConfig } from "@playwright/test";

// Relative paths in a Playwright config resolve against the *invocation* cwd,
// not against this file, so every path below is anchored here instead.
// (Playwright transpiles this TS config to CJS, so `__dirname` is defined;
// `import.meta.url` is not available and would flip the module to ESM.)
const here: string = __dirname;
const repoRoot = resolve(here, "../..");
const workspaceRoot = resolve(repoRoot, "..");

const chromiumExecutable =
  process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ??
  (existsSync("/run/current-system/sw/bin/chromium")
    ? "/run/current-system/sw/bin/chromium"
    : undefined);

// Shift every port in one go. Port 8080 in particular is a magnet for
// unrelated long-running dev servers, and with `reuseExistingServer` Playwright
// cannot tell a foreign server from its own — it reuses it and the specs fail
// with `net::ERR_EMPTY_RESPONSE`, which names nothing useful. Set
// `ISONIM_BROWSER_PORT_OFFSET=100` (or run two checkouts on different offsets)
// rather than hunting for whatever owns the port.
const portOffset = Number(process.env.ISONIM_BROWSER_PORT_OFFSET ?? 0);

// A pre-existing server is NOT reused by default: reuse is exactly how a
// foreign process on the port turns into an opaque test failure. Opt back in
// with ISONIM_BROWSER_REUSE_SERVER=1 when iterating locally.
const reuseExistingServer = process.env.ISONIM_BROWSER_REUSE_SERVER === "1";

// --- which projects is this invocation actually running? --------------------
//
// Playwright has no per-project `webServer`: it starts EVERY entry in the
// array before the first test, whatever `--project` was asked for. That is
// what made this suite unrunnable. The `metacraft-web-editor` entry carried
// `cwd: "../../../metacraft-web"`, a sibling repo that is not part of this
// checkout and is not declared in `.github/sibling-repos`. Node reports a
// spawn into a non-existent cwd as an ENOENT on the *shell*, so the whole run
// died before a single test with:
//
//     Error: Failed to launch: Error: spawn /bin/sh ENOENT
//
// — a message that names `/bin/sh`, which exists, and never names the
// directory that does not. Reproduced in isolation with
// `spawn('/bin/sh', ['-c','echo'], { cwd: '/does/not/exist' })`.
//
// So the server list is now built from the projects this invocation selected.
const selectedProjects = (() => {
  const out = new Set<string>();
  const argv = process.argv;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--project" && argv[i + 1]) out.add(argv[i + 1]);
    else if (a.startsWith("--project=")) out.add(a.slice("--project=".length));
  }
  return out;
})();
const isSelected = (name: string) =>
  selectedProjects.size === 0 || selectedProjects.has(name);

// `serve` is not a dependency of this package, of the repo root, or of the
// flake dev shell, so the old `npx serve …` commands reached out to the npm
// registry on every run. `tools/static_server.mjs` is the same contract
// (static root + SPA fallback) with no install and no network.
const staticServer = (root: string, port: number) =>
  `node ${JSON.stringify(resolve(here, "tools/static_server.mjs"))} ${JSON.stringify(root)} ${port}`;

type ServerSpec = {
  project: string;
  /** Spec file this project runs. */
  testMatch: string;
  /** Base port before `ISONIM_BROWSER_PORT_OFFSET`. */
  basePort: number;
  command: (port: number) => string;
  cwd?: string;
  env?: (port: number) => Record<string, string>;
  /** Build output this server publishes; missing → hard error naming `needs`. */
  requires: string;
  /** The exact command that produces `requires`. */
  needs: string;
};

const specs: ServerSpec[] = [
  {
    project: "demo-app",
    testMatch: "demo-app.spec.ts",
    basePort: 8080,
    command: (p) => staticServer(resolve(repoRoot, "demos/isonim-replica/dist"), p),
    requires: resolve(repoRoot, "demos/isonim-replica/dist/main.js"),
    needs: "just demo-build",
  },
  {
    project: "ssr-hydration",
    testMatch: "ssr-hydration.spec.ts",
    basePort: 8081,
    command: (p) => staticServer(resolve(here, "dist"), p),
    requires: resolve(here, "dist/main.js"),
    needs: "just build-ssr-test-all",
  },
  {
    project: "hmr",
    testMatch: "hmr.spec.ts",
    basePort: 8082,
    command: (p) => staticServer(resolve(here, "hmr_fixture"), p),
    requires: resolve(here, "hmr_fixture/main.js"),
    needs: "just build-hmr-fixture",
  },
  {
    project: "hmr-transport",
    testMatch: "hmr_transport.spec.ts",
    basePort: 8083,
    // Repo-local, not /tmp: this worktree is shared between agents, and a
    // stale /tmp binary from another branch is indistinguishable from a
    // fresh one.
    command: () => resolve(repoRoot, "build/isonim_test_server"),
    env: (p) => ({ HMR_TRANSPORT_PORT: String(p) }),
    requires: resolve(repoRoot, "build/isonim_test_server"),
    needs: "just build-hmr-transport-fixture",
  },
  {
    project: "hmr-parametric",
    testMatch: "hmr_parametric.spec.ts",
    basePort: 8084,
    command: (p) => staticServer(resolve(here, "hmr_parametric_fixture"), p),
    requires: resolve(here, "hmr_parametric_fixture/main.js"),
    needs: "just build-hmr-parametric-fixture",
  },
  {
    project: "editor-example",
    testMatch: "editor-example.spec.ts",
    basePort: 8090,
    command: (p) => staticServer(resolve(repoRoot, "build/editor"), p),
    requires: resolve(repoRoot, "build/editor/editor.js"),
    needs: "just editor-build",
  },
  {
    project: "metacraft-web-editor",
    testMatch: "metacraft-web-editor.spec.ts",
    basePort: 8092,
    cwd: resolve(workspaceRoot, "metacraft-web"),
    command: (p) =>
      "bash -lc 'rm -rf dist/editor-dev-workspace && mkdir -p dist/editor-dev-workspace/apps/back-office/src/backoffice_ui dist/editor-dev-workspace/apps/back-office/src/backoffice_editor dist/editor-dev-workspace/packages/metacraft-design/src/metacraft_design && cp apps/back-office/src/backoffice_ui/components.nim dist/editor-dev-workspace/apps/back-office/src/backoffice_ui/components.nim && cp apps/back-office/src/backoffice_editor/component_schema.schema dist/editor-dev-workspace/apps/back-office/src/backoffice_editor/component_schema.schema && cp apps/back-office/src/backoffice_editor/story_fixtures.schema dist/editor-dev-workspace/apps/back-office/src/backoffice_editor/story_fixtures.schema && cp packages/metacraft-design/src/metacraft_design/tokens.nim dist/editor-dev-workspace/packages/metacraft-design/src/metacraft_design/tokens.nim && METACRAFT_EDITOR_SOURCE_ROOT=\"$PWD/dist/editor-dev-workspace\" node tools/serve_editor_dev_bridge.mjs dist/back-office-editor " +
      p +
      "'",
    requires: resolve(
      workspaceRoot,
      "metacraft-web/dist/back-office-editor/editor.js",
    ),
    needs:
      "clone metacraft-labs/metacraft-web next to this repo, then " +
      "`(cd ../metacraft-web && just build-back-office-editor)`",
  },
];

const portOf = (s: ServerSpec) => s.basePort + portOffset;

// Playwright re-loads this config inside every worker process, where argv no
// longer carries `--project`. The `webServer` list is only consulted in the
// main process, so the prerequisite check belongs there too — running it in a
// worker would fail the very tests it is meant to protect.
const inWorker = process.env.TEST_WORKER_INDEX !== undefined;

// `--list` starts no servers, so it has no prerequisites. Keeping it usable
// on a checkout that has not been built is the difference between "what is
// in this suite?" being answerable and not.
const listingOnly = process.argv.includes("--list");

const active = specs.filter((s) => isSelected(s.project));
const missing =
  inWorker || listingOnly
    ? []
    : active.filter((s) => !existsSync(s.requires));
if (missing.length > 0) {
  throw new Error(
    "\n\nPlaywright prerequisites are missing. Build them first — or run\n" +
      "`just test-browser-all`, which builds everything and then runs the suite.\n\n" +
      missing
        .map(
          (s) =>
            `  [${s.project}]  missing: ${s.requires}\n` +
            `                  build it: ${s.needs}\n`,
        )
        .join("\n") +
      "\nSee tests/browser/README.md for the two one-time setup steps.\n",
  );
}

export default defineConfig({
  testDir: "./specs",
  timeout: 30000,
  use: {
    headless: true,
    browserName: "chromium",
    // Explicit, though it matches Playwright's own default. The Layers panel
    // decides membership by VISIBILITY -- `scene_graph_walk.nim`'s
    // `isSelectable` requires `getBoundingClientRect()` to be non-zero -- so a
    // browser with no window size filters out every element and the panel
    // renders zero rows. That failure is SILENT: no error, no warning, just an
    // empty tree that looks like "this story has nothing in it". Measured
    // against the grip pilot: 61 rows at 1600x1000, 0 rows at 0x0. Pinning the
    // viewport here means a future default change cannot reintroduce it.
    viewport: { width: 1280, height: 720 },
    launchOptions: chromiumExecutable
      ? { executablePath: chromiumExecutable }
      : undefined,
  },
  webServer: active.map((s) => ({
    command: s.command(portOf(s)),
    port: portOf(s),
    cwd: s.cwd,
    env: s.env?.(portOf(s)),
    reuseExistingServer,
    stdout: "pipe" as const,
    stderr: "pipe" as const,
  })),
  projects: specs.map((s) => ({
    name: s.project,
    testMatch: s.testMatch,
    use: { baseURL: `http://localhost:${portOf(s)}` },
  })),
});
