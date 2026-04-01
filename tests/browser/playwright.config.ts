import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./specs",
  timeout: 30000,
  use: {
    baseURL: "http://localhost:8080",
    headless: true,
  },
  webServer: {
    command: "npx serve ../../demos/isonim-replica/dist -l 8080 -s",
    port: 8080,
    reuseExistingServer: true,
  },
});
