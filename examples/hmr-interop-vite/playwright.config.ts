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
  timeout: 90_000,
  use: {
    baseURL: "http://localhost:5179",
    headless: true,
    browserName: "chromium",
    launchOptions: chromiumExecutable
      ? { executablePath: chromiumExecutable }
      : undefined,
  },
  webServer: {
    // Vite dev server compiles .nim on demand via the plugin and
    // serves the WebSocket HMR channel that the test relies on.
    command: "npx vite",
    port: 5179,
    reuseExistingServer: !process.env.CI,
    cwd: __dirname,
    stdout: "pipe",
    stderr: "pipe",
  },
});
