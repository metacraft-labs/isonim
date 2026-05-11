import { defineConfig } from "@playwright/test";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const chromiumExecutable =
  process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ??
  (existsSync("/run/current-system/sw/bin/chromium")
    ? "/run/current-system/sw/bin/chromium"
    : undefined);

export default defineConfig({
  testDir: "./specs",
  timeout: 60_000,
  use: {
    baseURL: "http://localhost:5180",
    headless: true,
    browserName: "chromium",
    launchOptions: chromiumExecutable
      ? { executablePath: chromiumExecutable }
      : undefined,
  },
  webServer: {
    // One Node process serves the static demo files, the
    // LiveReload-protocol WebSocket (port 35729), and a
    // control-HTTP endpoint (port 35730). Bundling these into
    // one server avoids depending on python3 or a third-party
    // static server.
    command: "node livereload-server.mjs",
    // Playwright probes the static port; once it's up the WS +
    // control endpoints are too (same process).
    port: 5180,
    reuseExistingServer: false,
    cwd: __dirname,
    stdout: "pipe",
    stderr: "pipe",
  },
});
