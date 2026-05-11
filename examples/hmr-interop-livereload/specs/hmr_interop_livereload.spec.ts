// IsoNim × LiveReload HMR interop integration test.
//
// Drives `hmr_livereload.nim` against a minimal LiveReload-protocol
// WebSocket server (the `livereload-server.mjs` companion). The
// transport opens the WebSocket, exchanges a `hello`, then waits
// for `reload` messages. We assert both branches of the transport:
//
//   - CSS path: matching `<link>` tag's href gets a cache-bust
//     query (the swap-then-replace path from hmr_css_watch).
//   - JS path: the configured bundle URL is re-fetched via
//     applyBundleByScriptTag, and the new bundle's top-level
//     globals appear in `globalThis`.
//
// The fake server's `/trigger` HTTP endpoint exists so the spec can
// control timing without owning a WebSocket itself. Real
// LiveReload servers fire `reload` from a file watcher; here we
// drive it directly, which is the right shape for a unit test of
// the *transport* (a separate integration test would cover the
// file-watching leg).

import { test, expect } from "@playwright/test";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { execSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const EXAMPLE_ROOT = resolve(__dirname, "..");
const MAIN_NIM = join(EXAMPLE_ROOT, "main.nim");
const MAIN_JS = join(EXAMPLE_ROOT, "main.js");
const STYLES_CSS = join(EXAMPLE_ROOT, "styles.css");

async function triggerLiveReload(path: string): Promise<void> {
  const res = await fetch("http://localhost:35730/trigger", {
    method: "POST",
    body: JSON.stringify({ path }),
    headers: { "content-type": "application/json" },
  });
  if (!res.ok) {
    throw new Error(
      `livereload /trigger failed: ${res.status} ${await res.text()}`,
    );
  }
}

function captureSource(path: string): string {
  try {
    execSync(`git checkout HEAD -- ${JSON.stringify(path)}`, {
      stdio: "ignore",
    });
  } catch {
    // Untracked or no git — proceed with on-disk content.
  }
  return readFileSync(path, "utf8");
}

function rebuildMainJs() {
  execSync(
    [
      "nim",
      "js",
      "-d:isonimHmr",
      "--path:../../src",
      "--path:../../../nim-everywhere/src",
      "--hints:off",
      "-o:main.js",
      "main.nim",
    ].join(" "),
    { cwd: EXAMPLE_ROOT, stdio: ["ignore", "ignore", "pipe"] },
  );
}

test.describe("IsoNim × LiveReload HMR interop", () => {
  test.skip(!existsSync(MAIN_JS), "main.js missing — build it first");

  test("CSS reload signal swaps the matching <link> href to a cache-busted URL", async ({
    page,
  }) => {
    const originalCss = captureSource(STYLES_CSS);
    try {
      await page.goto("/");
      // Give the transport a beat to open its WS + exchange hello.
      await page.waitForTimeout(500);

      const initialHref = await page.evaluate(() => {
        const node = document.querySelector(
          'link[rel="stylesheet"][href*="styles.css"]',
        ) as HTMLLinkElement | null;
        return node ? node.href : null;
      });
      expect(initialHref).not.toBeNull();
      expect(initialHref!.includes("styles.css")).toBe(true);
      // Initial href has no cache-bust (we just loaded the page).
      expect(/[?&]v=\d+/.test(initialHref!)).toBe(false);

      // Modify the CSS file. The transport will swap the link
      // when the server tells it to — the server is what watches
      // files in a real LiveReload setup, but here the test
      // drives the signal directly.
      writeFileSync(
        STYLES_CSS,
        originalCss + "\n.ct-livereload-marker { color: rgb(99, 88, 77); }\n",
      );
      await triggerLiveReload("/styles.css");

      // Wait for the swap. swapLinkHref's clone-then-replace
      // pattern is async (it waits for the clone's `load` event)
      // so we poll.
      await page.waitForFunction(
        (before) => {
          const node = document.querySelector(
            'link[rel="stylesheet"][href*="styles.css"]',
          ) as HTMLLinkElement | null;
          return !!(node && node.href !== before);
        },
        initialHref!,
        { timeout: 5000 },
      );

      const newHref = await page.evaluate(() => {
        const node = document.querySelector(
          'link[rel="stylesheet"][href*="styles.css"]',
        ) as HTMLLinkElement | null;
        return node ? node.href : null;
      });
      expect(newHref).toContain("styles.css");
      expect(/[?&]v=\d+/.test(newHref!)).toBe(true);
    } finally {
      writeFileSync(STYLES_CSS, originalCss);
    }
  });

  test("non-CSS reload signal triggers a bundle reload through applyBundleByScriptTag", async ({
    page,
  }) => {
    const originalNim = captureSource(MAIN_NIM);
    try {
      await page.goto("/");
      await page.waitForTimeout(500);

      const initialBuild = await page.evaluate(
        () =>
          (globalThis as { __ct_livereload_build?: string })
            .__ct_livereload_build,
      );
      expect(initialBuild).toBe("v1-initial");

      // Rebuild main.js with a different build marker. The .nim
      // source is the only thing we touch; the test driver reruns
      // `nim js` to produce a fresh main.js. In a real LiveReload
      // setup the watcher would have already done this; here the
      // test owns both ends.
      const edited = originalNim.replace('"v1-initial"', '"v2-after-reload"');
      if (edited === originalNim) {
        throw new Error(
          "could not find build-version literal in main.nim — fixture drifted.",
        );
      }
      writeFileSync(MAIN_NIM, edited);
      rebuildMainJs();

      // Now tell the LiveReload server to send a reload signal
      // for something that isn't CSS. The transport routes
      // through applyBundleByScriptTag, which appends a fresh
      // <script src="main.js?v=…"> tag. The browser fetches the
      // new file (the one we just rebuilt) and runs its
      // top-level code — including our new globalThis marker.
      await triggerLiveReload("/main.js");

      await expect
        .poll(
          () =>
            page.evaluate(
              () =>
                (globalThis as { __ct_livereload_build?: string })
                  .__ct_livereload_build,
            ),
          { timeout: 10_000 },
        )
        .toBe("v2-after-reload");
    } finally {
      writeFileSync(MAIN_NIM, originalNim);
      rebuildMainJs();
    }
  });
});
