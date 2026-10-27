/** Real compiled env() in Chromium; local HTTP serves bytes and real referring
 * documents, not metadata. Partial hosts separately test unavailable platform
 * members and their failures. Owner comparison imports the installed library;
 * no reference framework, copied helper or fake codec is used. */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { createServer } from "node:http";
import vm from "node:vm";
import { chromium } from "./browser/node_modules/playwright/index.mjs";
const source = readFileSync(process.env.ISONIM_ENV_BUNDLE, "utf8");
const artifact = process.env.CT_ARTIFACT;
const ownerMode = process.env.ISONIM_ENV_OWNER === "1";
let owner;
if (ownerMode) {
  assert(artifact, "CT_ARTIFACT must name installed owner package");
  const require = createRequire(
    artifact + "/packages/boundary-shim/package.json",
  );
  const esbuild = require("esbuild");
  owner = (
    await esbuild.build({
      stdin: {
        contents:
          "import {readEnvironment} from '@codetracer/boundary-shim/dist/browser/install.js';import {captureOriginals} from '@codetracer/boundary-shim/dist/browser/originals.js';globalThis.xrOwnerEnv=()=>readEnvironment(window,captureOriginals(window));",
        resolveDir: artifact,
      },
      bundle: true,
      platform: "browser",
      format: "iife",
      write: false,
    })
  ).outputFiles[0].text;
}
function partial(window) {
  const context = vm.createContext({
    window,
    console,
    URL: globalThis.URL,
    crypto: globalThis.crypto,
    performance: globalThis.performance,
    setTimeout,
    clearTimeout,
    queueMicrotask,
  });
  vm.runInContext(source, context, { timeout: 2000 });
  return JSON.parse(context.isonimBootEnv);
}
// These are deliberately partial hosts; no-preference here is not claimed as
// an emulated Chromium media preference.
for (const [mode, expected] of [
  ["dark", 2],
  ["light", 1],
  ["none", 0],
]) {
  const calls = [];
  const snapshot = partial({
    matchMedia(q) {
      calls.push(q);
      return { matches: q === `(prefers-color-scheme: ${mode})` };
    },
  });
  assert.equal(snapshot.prefersDark, mode === "dark");
  console.log("legacy-environment-values: PASS");
  assert.equal(
    snapshot.colorScheme,
    expected,
    "three-way environment color must distinguish light and no preference",
  );
  assert.equal(calls.filter((q) => q.includes("dark")).length, 1);
  assert.equal(
    calls.filter((q) => q.includes("light")).length,
    mode === "dark" ? 0 : 1,
  );
  assert.equal(calls.filter((q) => q.includes("reduce")).length, 1);
}
for (const window of [
  {},
  { document: {} },
  { URL, document: { referrer: "" } },
  { URL, document: { referrer: "bad URL" } },
  { URL, document: { referrer: 123 } },
  { document: { referrer: "https://source.test/private?q=secret" } },
  {
    URL,
    document: {
      get referrer() {
        throw Error("new referrer failure");
      },
    },
  },
  {
    URL: function () {
      throw Error("new URL failure");
    },
    document: { referrer: "https://source.test/private" },
  },
]) {
  assert.equal(
    partial(window).referrerOrigin,
    "",
    "unavailable referrer must be empty",
  );
}
let gets = 0,
  constructs = 0,
  urlGets = 0;
const snapshot = partial({
  get URL() {
    urlGets++;
    return class extends URL {
      constructor(...args) {
        constructs++;
        super(...args);
      }
    };
  },
  document: {
    get referrer() {
      gets++;
      return "https://source.test/private?secret=hidden#private";
    },
  },
});
assert.equal(
  snapshot.referrerOrigin,
  "https://source.test",
  "environment referrer must retain origin only",
);
assert.equal(gets, 1);
assert.equal(constructs, 1);
assert.equal(urlGets, 1);
assert.equal(
  partial({
    matchMedia(q) {
      if (q.includes("light")) throw Error("new light failure");
      return { matches: false };
    },
  }).colorScheme,
  0,
);
assert.throws(
  () =>
    partial({
      matchMedia() {
        throw Error("legacy dark failure");
      },
    }),
  /legacy dark failure/,
);
assert.throws(
  () =>
    partial({
      matchMedia(q) {
        if (q.includes("reduce")) throw Error("legacy reduced failure");
        return { matches: false };
      },
    }),
  /legacy reduced failure/,
);
console.log("environment-partial-hosts: PASS");
let destination;
const server = createServer((req, res) => {
  if (req.url === "/suite.js") {
    res.setHeader("Content-Type", "text/javascript");
    res.end(source);
  } else if (req.url.startsWith("/private")) {
    res.setHeader("Referrer-Policy", "unsafe-url");
    res.end(`<a id="next" href="${destination}">continue</a>`);
  } else {
    res.end(
      '<!doctype html><meta name="traceparent" content="00-11111111111111111111111111111111-2222222222222222-00"><script src="/suite.js"></script>',
    );
  }
});
await new Promise((r) => server.listen(0, "0.0.0.0", r));
let browser;
try {
  browser = await chromium.launch({
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE,
  });
  for (const colorScheme of ["light", "dark"])
    for (const cross of [false, true]) {
      const context = await browser.newContext({ colorScheme });
      await context.addInitScript(() => {
        const counts = { dark: 0, light: 0, reduced: 0, referrer: 0, url: 0 };
        globalThis.xrMetadataCounts = counts;
        const original = window.matchMedia.bind(window);
        window.matchMedia = (q) => {
          if (q.includes("dark")) counts.dark++;
          if (q.includes("light")) counts.light++;
          if (q.includes("reduce")) counts.reduced++;
          return original(q);
        };
        const descriptor = Object.getOwnPropertyDescriptor(
          Document.prototype,
          "referrer",
        );
        Object.defineProperty(document, "referrer", {
          get() {
            counts.referrer++;
            return descriptor.get.call(this);
          },
        });
        const NativeURL = window.URL;
        window.URL = class extends NativeURL {
          constructor(...args) {
            counts.url++;
            super(...args);
          }
        };
      });
      const page = await context.newPage();
      const errors = [];
      page.on("pageerror", (e) => errors.push(String(e)));
      const port = server.address().port;
      destination = `http://${cross ? "localhost" : "127.0.0.1"}:${port}/target`;
      await page.goto(
        `http://127.0.0.1:${port}/private?secret=referring-secret#private-fragment`,
      );
      await Promise.all([page.waitForURL(destination), page.click("#next")]);
      if (ownerMode) await page.addScriptTag({ content: owner });
      const result = await page.evaluate((ownerMode) => {
        const before = structuredClone(xrMetadataCounts),
          boot = JSON.parse(isonimBootEnv);
        const legacy = JSON.parse(isonimReadEnv());
        isonimMutateEnv();
        const after = JSON.parse(isonimReadEnv());
        const cached = structuredClone(xrMetadataCounts);
        const expected = ownerMode ? xrOwnerEnv() : null;
        const preFresh = structuredClone(xrMetadataCounts);
        isonimResetEnv();
        const fresh = JSON.parse(isonimReadEnv());
        const postFresh = structuredClone(xrMetadataCounts);
        return {
          before,
          boot,
          legacy,
          after,
          cached,
          expected,
          preFresh,
          fresh,
          postFresh,
          referrer: document.referrer,
          hasCt: Object.keys(globalThis).some((k) => k.startsWith("__ct")),
          actualDark: matchMedia("(prefers-color-scheme: dark)").matches,
          actualLight: matchMedia("(prefers-color-scheme: light)").matches,
        };
      }, ownerMode);
      assert.deepEqual(errors, []);
      assert.deepEqual(result.legacy, result.boot);
      assert.equal(result.after.timeZone, result.boot.timeZone);
      for (const [key, value] of Object.entries(result.boot))
        if (!["colorScheme", "referrerOrigin"].includes(key))
          assert.deepEqual(result.after[key], value, `legacy ${key}`);
      assert.deepEqual(result.cached, result.before);
      console.log("legacy-environment-values: PASS");
      const expected = ownerMode
        ? result.expected
        : {
            color_scheme: colorScheme === "dark" ? 2 : 1,
            referrer_origin: `http://127.0.0.1:${port}`,
          };
      assert.equal(result.actualDark, colorScheme === "dark");
      assert.equal(result.actualLight, colorScheme === "light");
      for (const actual of [result.boot, result.after, result.fresh]) {
        assert.equal(
          actual.colorScheme,
          expected.color_scheme,
          "three-way environment color must distinguish light and no preference",
        );
        assert.equal(
          actual.referrerOrigin,
          expected.referrer_origin,
          "environment referrer must retain origin only",
        );
        assert(
          !JSON.stringify(actual).includes("referring-secret"),
          "environment must never retain full referring URL",
        );
      }
      assert.equal(
        result.referrer,
        `http://127.0.0.1:${port}/private?secret=referring-secret`,
      );
      assert.equal(result.before.dark, 1);
      assert.equal(result.before.light, colorScheme === "dark" ? 0 : 1);
      assert.equal(result.before.reduced, 1);
      assert.equal(result.before.referrer, 1);
      assert.equal(result.before.url, 1);
      for (const key of ["dark", "reduced", "referrer", "url"])
        assert.equal(result.postFresh[key] - result.preFresh[key], 1);
      assert.equal(
        result.postFresh.light - result.preFresh.light,
        colorScheme === "dark" ? 0 : 1,
      );
      assert.equal(result.hasCt, false);
      await context.close();
    }
  console.log(
    `environment-metadata-cache-${ownerMode ? "owner" : "platform"}: PASS browser=${browser.version()} artifact=${artifact}`,
  );
} finally {
  await browser?.close();
  await new Promise((r) => server.close(r));
}
