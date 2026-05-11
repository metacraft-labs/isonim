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
  timeout: 120_000,
  use: {
    baseURL: "http://localhost:5181",
    headless: true,
    browserName: "chromium",
    launchOptions: chromiumExecutable
      ? { executablePath: chromiumExecutable }
      : undefined,
  },
  webServer: {
    command: "npx webpack serve --mode development --config webpack.config.cjs",
    port: 5181,
    reuseExistingServer: !process.env.CI,
    cwd: __dirname,
    stdout: "pipe",
    stderr: "pipe",
    timeout: 60_000,
  },
});
