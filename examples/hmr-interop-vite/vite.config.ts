import { defineConfig } from "vite";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import isonim from "./vite-plugin-isonim";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// Resolve the isonim source root relative to this config file so
// the example works in-repo without per-developer path tweaks.
const isonimRoot = resolve(__dirname, "..", "..", "src");

export default defineConfig({
  root: __dirname,
  // Pin the port so the Playwright spec doesn't have to scrape it.
  server: { port: 5179, strictPort: true },
  plugins: [
    isonim({
      isonimRoot,
      // Sibling repo nim-everywhere is required by some isonim
      // modules. Resolved relative to the metacraft workspace
      // root.
      extraNimPaths: [
        resolve(__dirname, "..", "..", "..", "nim-everywhere", "src"),
      ],
    }),
  ],
});
