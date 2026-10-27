// The explicitly scripted transport is the existing deterministic backend API.
// Real generated Nim runs in real Chromium; requestJson constructs its own nil
// GET body. No fetch, Promise, DOM or RPC implementation is substituted.
import { chromium } from "./browser/node_modules/playwright/index.mjs";
import { readFile, writeFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import assert from "node:assert/strict";
const bundle = await readFile(
  process.env.SCRIPTED_RPC_BODY_FIXTURE ?? "build/scripted_rpc_body_fixture.js",
  "utf8",
);
const browser = await chromium.launch({
  executablePath:
    process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ??
    execFileSync("which", ["chromium"], { encoding: "utf8" }).trim(),
});
const results = [],
  failures = [];
try {
  for (const method of ["publicGet", "directEmpty", "directBody"])
    for (const rejects of [false, true]) {
      const page = await browser.newPage();
      const errors = [];
      page.on("pageerror", (error) => errors.push(String(error)));
      await page.goto("about:blank");
      await page.addScriptTag({ content: bundle });
      const observed = await page.evaluate(
        async ({ method, rejects }) => {
          scriptedRpcBody.setup(rejects);
          const order = ["entry"];
          const pending = scriptedRpcBody[method]();
          queueMicrotask(() => order.push("existing-microtask"));
          let outcome;
          try {
            const value = await pending;
            outcome = { state: "fulfilled", value };
          } catch (error) {
            outcome = {
              state: "rejected",
              error: Array.isArray(error?.message)
                ? String.fromCharCode(...error.message)
                : String(error?.message ?? error),
            };
          }
          order.push("continuation");
          return { outcome, order, backend: scriptedRpcBody.observe() };
        },
        { method, rejects },
      );
      try {
        assert.deepEqual(errors, [], "no uncaught browser errors");
        assert.equal(
          observed.backend.calls,
          1,
          "scripted RPC reaches the selected transport exactly once",
        );
        assert.equal(
          observed.backend.body,
          method === "directBody" ? "payload" : "",
          "nil and empty RPC body project to the same empty HttpRequest body",
        );
        assert.equal(
          observed.backend.httpMethod,
          method === "directBody" ? "POST" : "GET",
        );
        assert.equal(
          observed.backend.url,
          method === "publicGet"
            ? "/scripted-get"
            : method === "directEmpty"
              ? "/scripted-empty"
              : "/scripted-body",
        );
        assert.equal(
          observed.backend.dispatch,
          1,
          "ready or rejected scripted RPC settles once",
        );
        assert.deepEqual(observed.order, [
          "entry",
          "existing-microtask",
          "continuation",
        ]);
        assert.equal(
          observed.outcome.state,
          rejects ? "rejected" : "fulfilled",
        );
        if (rejects)
          assert(observed.outcome.error.includes("planned scripted rejection"));
        else if (method === "publicGet")
          assert.deepEqual(JSON.parse(observed.outcome.value), { ok: true });
        else {
          assert.equal(observed.outcome.value.status, 200);
          assert.equal(observed.outcome.value.text, '{"ok":true}');
        }
      } catch (error) {
        failures.push({ method, rejects, error: String(error) });
      }
      results.push({ method, rejects, observed, errors });
      await page.close();
    }
  if (process.env.SCRIPTED_RPC_BODY_RECEIPT)
    await writeFile(
      process.env.SCRIPTED_RPC_BODY_RECEIPT,
      JSON.stringify(
        { browser: browser.version(), results, failures },
        null,
        2,
      ),
    );
  assert.deepEqual(
    failures,
    [],
    "all six scripted RPC body controls must pass",
  );
  console.log("scripted RPC body controls PASS6");
} finally {
  await browser.close();
}
