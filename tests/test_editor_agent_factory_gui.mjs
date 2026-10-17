// This is an additive mount-composition fixture, not a daemon/provider proof.
// The actual server is private and intentionally refuses every API request.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const bundlePath = process.env.ISONIM_AGENT_FACTORY_CONTROL_BUNDLE;
const playwrightPath = process.env.ISONIM_AGENT_FACTORY_PLAYWRIGHT;
const chromiumExecutable = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
assert(
  bundlePath && playwrightPath && chromiumExecutable,
  "explicit owning inputs required",
);
const { chromium } = await import(pathToFileURL(playwrightPath));
const bundle = readFileSync(bundlePath);
function installMountListenerLedger() {
  const active = [];
  for (const target of [window, document]) {
    const add = target.addEventListener;
    const remove = target.removeEventListener;
    target.addEventListener = function (type, callback, options) {
      const result = Reflect.apply(add, this, [type, callback, options]);
      const capture =
        typeof options === "boolean" ? options : !!options?.capture;
      // Once listeners retire in the browser itself and are not counted here.
      if (
        !options?.once &&
        !active.some(
          (x) =>
            x.target === this &&
            x.type === type &&
            x.callback === callback &&
            x.capture === capture,
        )
      ) {
        active.push({ target: this, type, callback, capture });
      }
      return result;
    };
    target.removeEventListener = function (type, callback, options) {
      const result = Reflect.apply(remove, this, [type, callback, options]);
      const capture =
        typeof options === "boolean" ? options : !!options?.capture;
      const index = active.findIndex(
        (x) =>
          x.target === this &&
          x.type === type &&
          x.callback === callback &&
          x.capture === capture,
      );
      if (index >= 0) active.splice(index, 1);
      return result;
    };
  }
  window.__mountListenerLedger = () =>
    active.map((x) => ({
      target: x.target === window ? "window" : "document",
      type: x.type,
      capture: x.capture,
    }));
}
const sockets = new Set();
const requests = [];
const server = createServer((request, response) => {
  requests.push(request.url);
  if (request.url === "/fixture.js") {
    response.writeHead(200, { "Content-Type": "application/javascript" });
    response.end(bundle);
  } else if (request.url?.startsWith("/api/")) {
    response.writeHead(503, { "Content-Type": "application/json" });
    response.end('{"error":"declared unavailable test peer"}');
  } else {
    const address = server.address();
    response.writeHead(200, { "Content-Type": "text/html" });
    response.end(
      `<!doctype html><html><head><meta name="isonim-review-api" content="http://127.0.0.1:${address.port}"></head><body></body></html>`,
    );
  }
});
server.on("connection", (socket) => {
  sockets.add(socket);
  socket.once("close", () => sockets.delete(socket));
});
await new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(0, "127.0.0.1", resolve);
});
let browser;
const cases = [];
try {
  browser = await chromium.launch({
    executablePath: chromiumExecutable,
    headless: true,
  });
  for (const mode of [
    "default",
    "adapter-only",
    "client",
    "throws",
    "throws-new",
    "throws-new-cleanup",
    "cleanup-failure",
    "unregister-throws",
    "throws-new-defect-cleanup",
  ]) {
    const page = await browser.newPage();
    const cleanupWarnings = [];
    page.on("console", (event) => {
      if (event.type() === "warning") cleanupWarnings.push(event.text());
    });
    try {
      await page.goto(
        `http://127.0.0.1:${server.address().port}/?mode=${mode}`,
      );
      // Initialize both real Playwright contexts before observing PRODUCT
      // listeners. Main-world waitForFunction constructs InjectedScript too;
      // a body locator alone only guarantees its selector context.
      await page.waitForFunction(() => document.body !== null);
      assert.equal(await page.locator("body").count(), 1);
      await page.evaluate(() => {
        window.__factoryLedgerDocument = document;
      });
      await page.evaluate(installMountListenerLedger);
      await page.evaluate(() => {
        window.__factoryLedgerSentinel = () => {};
        window.addEventListener(
          "factory-ledger-sensitivity",
          window.__factoryLedgerSentinel,
        );
      });
      const deliberateLeak = await page.evaluate(() =>
        window.__mountListenerLedger(),
      );
      assert.throws(
        () =>
          assert.deepEqual(
            deliberateLeak,
            [],
            "failed mount removed actual window/document listeners",
          ),
        { code: "ERR_ASSERTION" },
        "an actual retained DOM listener must fail the same empty-ledger oracle",
      );
      await page.evaluate(() =>
        window.removeEventListener(
          "factory-ledger-sensitivity",
          window.__factoryLedgerSentinel,
        ),
      );
      assert.deepEqual(
        await page.evaluate(() => window.__mountListenerLedger()),
        [],
        "exact sentinel removal restores the empty ledger",
      );
      // Same document, real served bundle, unchanged API peer and factory.
      await page.addScriptTag({
        url: `http://127.0.0.1:${server.address().port}/fixture.js`,
      });
      assert.equal(
        await page.evaluate(() => window.__factoryLedgerDocument === document),
        true,
        "no navigation replaced the observed document",
      );
      await page.waitForFunction(() => !!window.__agentFactoryProbe);
      const snapshot = () =>
        page.evaluate(() => JSON.parse(window.__agentFactoryProbe.snapshot()));
      const invoke = (name) =>
        page.evaluate((name) => window.__agentFactoryProbe[name](), name);
      let state = await snapshot();
      if (mode === "throws") {
        assert.equal(state.caught, "declared factory failure");
        assert.equal(
          state.caughtSameError,
          true,
          "preserve original factory exception object",
        );
        assert.equal(
          state.activeFactoryBindings,
          0,
          "owned root actually disposed",
        );
        assert.equal(
          await page.locator('[data-shell-row="true"]').count(),
          0,
          "exact failed shell removed",
        );
        assert.deepEqual(
          await page.evaluate(() => window.__mountListenerLedger()),
          [],
          "failed mount removed actual window/document listeners",
        );
        await invoke("invokeRestoredConfigurator");
        state = await snapshot();
        assert.equal(state.priorConfigureCalls, 1);
        assert.equal(state.factoryCalls, 1, "failed factory not retried");
      } else {
        assert.equal(state.caught, "");
        assert.equal(state.clientPresent, ["default", "client"].includes(mode));
        assert.equal(state.clientBound, ["default", "client"].includes(mode));
        if (mode === "default" || mode === "client") {
          assert.equal(await invoke("closedClientNegative"), true);
          assert.equal(
            (await snapshot()).legacyCalls,
            0,
            "old fake not preserved as production adapter",
          );
        }
        const before = await snapshot();
        await invoke("newChat");
        state = await snapshot();
        if (
          mode === "throws-new" ||
          mode === "throws-new-cleanup" ||
          mode === "throws-new-defect-cleanup"
        ) {
          assert.equal(state.caught, "declared factory failure");
          assert.equal(
            state.caughtSameError,
            true,
            "preserve original factory exception object",
          );
          assert.equal(
            state.activeFactoryBindings,
            before.activeFactoryBindings,
            "failed new chat disposed only its own factory resources",
          );
          assert.equal(
            state.chats,
            before.chats,
            "failed new chat was not appended",
          );
          assert.equal(
            state.activeLaterResources,
            before.activeLaterResources,
            "later resources drained after throwing cleanup",
          );
          assert.equal(
            state.activeTrackedRegistrations,
            before.activeTrackedRegistrations,
            "failed configure did not register retained entry",
          );
          if (
            mode === "throws-new-cleanup" ||
            mode === "throws-new-defect-cleanup"
          )
            assert.equal(
              state.cleanupFailures,
              1,
              "actual secondary cleanup exception occurred",
            );
        } else {
          assert.equal(state.chats, before.chats + 1);
          assert.equal(
            state.factoryCalls,
            mode === "default" ? 0 : before.factoryCalls + 1,
          );
          assert.equal(state.uniqueChats, true);
          assert.equal(state.clientBound, ["default", "client"].includes(mode));
          await invoke("reload");
          assert.equal(
            (await snapshot()).factoryCalls,
            state.factoryCalls,
            "HMR does not reconfigure existing chats",
          );
          await invoke("newChat");
          const afterReload = await snapshot();
          assert.equal(
            afterReload.factoryCalls,
            mode === "default" ? 0 : state.factoryCalls + 1,
          );
          assert.equal(
            afterReload.clientBound,
            ["default", "client"].includes(mode),
          );
          if (mode === "adapter-only") {
            assert.equal(
              await page.evaluate(() =>
                window.__agentFactoryProbe.prompt("owned fixture response"),
              ),
              true,
            );
            assert.equal((await snapshot()).localCalls, 1);
          }
          if (mode !== "default") {
            assert.equal(
              afterReload.activeFactoryBindings,
              before.activeFactoryBindings + 2,
              "new scopes survive HMR",
            );
            assert.equal(await invoke("selectInitial"), true);
            const initialBefore = await snapshot();
            assert.equal(await invoke("deniedClose"), true);
            const initialDenied = await snapshot();
            assert.equal(
              initialDenied.chats,
              initialBefore.chats,
              "denied initial close retains session",
            );
            assert.equal(
              initialDenied.activeFactoryBindings,
              initialBefore.activeFactoryBindings,
              "denied initial close retains scope",
            );
            assert.equal(await invoke("successfulClose"), true);
            const initialClosed = await snapshot();
            assert.equal(initialClosed.chats, initialBefore.chats - 1);
            assert.equal(
              initialClosed.activeFactoryBindings,
              initialBefore.activeFactoryBindings - 1,
              "successful initial close disposes its exact scope",
            );
            assert.equal(
              initialClosed.factoryCalls,
              initialBefore.factoryCalls,
              "initial close does not configure another factory",
            );
            await invoke("reload");
            assert.equal(
              (await snapshot()).factoryCalls,
              initialBefore.factoryCalls,
              "initial close followed by HMR does not reconfigure",
            );
            const beforeDenied = await snapshot();
            assert.equal(
              await invoke("deniedClose"),
              true,
              "close request dispatched",
            );
            const denied = await snapshot();
            assert.equal(
              denied.chats,
              beforeDenied.chats,
              "denied close retains session",
            );
            assert.equal(
              denied.activeFactoryBindings,
              beforeDenied.activeFactoryBindings,
              "denied close retains factory scope",
            );
            assert.equal(await invoke("successfulClose"), true);
            const closed = await snapshot();
            assert.equal(closed.chats, beforeDenied.chats - 1);
            assert.equal(
              closed.activeFactoryBindings,
              beforeDenied.activeFactoryBindings - 1,
              "successful close disposes exact scope",
            );
            if (mode === "unregister-throws") {
              assert.equal(
                closed.unregisterFailures,
                1,
                "actual unregister exception occurred",
              );
              assert.equal(
                closed.cleanupFailures,
                1,
                "root cleanup still ran and genuinely threw afterward",
              );
              assert.equal(
                closed.activeLaterResources,
                0,
                "root later resource drained despite unregister error",
              );
              assert.ok(
                cleanupWarnings.some((message) =>
                  message.includes(
                    "chat configuration cleanup failed: declared unregister failure",
                  ),
                ),
                "first secondary error retained after both steps",
              );
            }
            const beforeChurn = await snapshot();
            for (let index = 0; index < 32; index++) {
              await invoke("newChat");
              const created = await snapshot();
              assert.equal(
                created.activeTrackedRegistrations,
                beforeChurn.activeTrackedRegistrations + 1,
                "actual new registration observed",
              );
              assert.equal(await invoke("successfulClose"), true);
              const removed = await snapshot();
              assert.equal(removed.chats, beforeChurn.chats);
              assert.equal(
                removed.activeTrackedRegistrations,
                beforeChurn.activeTrackedRegistrations,
                "closed entry actually unregistered",
              );
              assert.equal(
                removed.activeFactoryBindings,
                beforeChurn.activeFactoryBindings,
              );
            }
            await invoke("disposeMountedRoot");
            assert.equal(
              (await snapshot()).activeFactoryBindings,
              0,
              "mount disposal cleans initial and surviving new scopes",
            );
            assert.equal(
              (await snapshot()).activeLaterResources,
              0,
              "all later resources drained despite prior cleanup error",
            );
            assert.equal(
              (await snapshot()).activeTrackedRegistrations,
              0,
              "final mount disposal unregisters all surviving entries",
            );
            if (mode === "cleanup-failure")
              assert.equal(
                (await snapshot()).cleanupFailures,
                1,
                "other sessions cleaned after one actual cleanup failure",
              );
            await invoke("disposeMountedRoot");
            assert.equal(
              (await snapshot()).activeFactoryBindings,
              0,
              "repeated disposal does not rerun cleanup",
            );
          }
        }
      }
      cases.push({ mode, state: await snapshot() });
    } finally {
      await page.close();
    }
  }
  console.log(
    JSON.stringify({
      cases,
      requests,
      qualification:
        "mount composition only; API peer intentionally unavailable",
    }),
  );
} finally {
  try {
    if (browser) await browser.close();
  } finally {
    const closed = new Promise((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    );
    for (const socket of sockets) socket.destroy(); // Only this private server's own retained sockets.
    await closed;
  }
}
