import { existsSync } from "node:fs";
import { defineConfig } from "@playwright/test";

const chromiumExecutable =
  process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ??
  (existsSync("/run/current-system/sw/bin/chromium")
    ? "/run/current-system/sw/bin/chromium"
    : undefined);

export default defineConfig({
  testDir: "./specs",
  timeout: 30000,
  use: {
    baseURL: "http://localhost:8080",
    headless: true,
    browserName: "chromium",
    launchOptions: chromiumExecutable
      ? { executablePath: chromiumExecutable }
      : undefined,
  },
  webServer: [
    {
      command: "npx serve ../../demos/isonim-replica/dist -l 8080 -s",
      port: 8080,
      reuseExistingServer: true,
    },
    {
      command: "npx serve ./dist -l 8081 -s",
      port: 8081,
      reuseExistingServer: true,
    },
    {
      command: "npx serve ../../build/editor -l 8090 -s",
      port: 8090,
      reuseExistingServer: true,
    },
    {
      command:
        "bash -lc 'rm -rf dist/editor-dev-workspace && mkdir -p dist/editor-dev-workspace/apps/back-office/src/backoffice_ui && cp apps/back-office/src/backoffice_ui/components.nim dist/editor-dev-workspace/apps/back-office/src/backoffice_ui/components.nim && METACRAFT_EDITOR_SOURCE_ROOT=\"$PWD/dist/editor-dev-workspace\" node tools/serve_editor_dev_bridge.mjs dist/back-office-editor 8092'",
      cwd: "../../../metacraft-web",
      port: 8092,
      reuseExistingServer: false,
    },
  ],
  projects: [
    {
      name: "demo-app",
      testMatch: "demo-app.spec.ts",
      use: {
        baseURL: "http://localhost:8080",
      },
    },
    {
      name: "ssr-hydration",
      testMatch: "ssr-hydration.spec.ts",
      use: {
        baseURL: "http://localhost:8081",
      },
    },
    {
      name: "editor-example",
      testMatch: "editor-example.spec.ts",
      use: {
        baseURL: "http://localhost:8090",
      },
    },
    {
      name: "metacraft-web-editor",
      testMatch: "metacraft-web-editor.spec.ts",
      use: {
        baseURL: "http://localhost:8092",
      },
    },
  ],
});
