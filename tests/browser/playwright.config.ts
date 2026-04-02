import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./specs",
  timeout: 30000,
  use: {
    baseURL: "http://localhost:8080",
    headless: true,
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
  ],
});
