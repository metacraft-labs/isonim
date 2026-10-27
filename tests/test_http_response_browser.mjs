// Local HTTP deliberately controls head/body/failure timing; Chromium and all
// Nim/default fetch/Promise APIs are real. No transport or stream substitutions.
import { chromium } from "./browser/node_modules/playwright/index.mjs";
import { readFile, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { execFileSync } from "node:child_process";
import assert from "node:assert/strict";
const app = await readFile(
  process.env.HTTP_RESPONSE_FIXTURE ?? "build/http_response_fixture.js",
  "utf8",
);
const requests = [];
const slots = new Map();
const server = createServer((req, res) => {
  const u = new URL(req.url, "http://localhost");
  const id = u.searchParams.get("id");
  if (u.pathname === "/") {
    res.end("<!doctype html><body>request proof");
    return;
  }
  if (u.pathname === "/probe.js") {
    res.setHeader("Content-Type", "text/javascript");
    res.end(app);
    return;
  }
  if (u.pathname === "/head" || u.pathname === "/body") {
    requests.push({
      path: u.pathname,
      id,
      csrf: req.headers["x-csrf-token"] ?? null,
    });
    slots.set(id, res);
    if (u.pathname === "/body") {
      res.writeHead(207, "XR Result", {
        "Content-Type": "text/plain",
        "X-XR-Proof": "actual",
      });
      res.flushHeaders();
      res.write("first-");
    }
    return;
  }
  if (u.pathname === "/disconnect") {
    requests.push({ path: u.pathname, id });
    req.socket.destroy();
    return;
  }
  if (u.pathname === "/redirect") {
    requests.push({ path: u.pathname, id });
    res.writeHead(302, { Location: "/complete?id=" + id });
    res.end();
    return;
  }
  if (u.pathname === "/complete") {
    requests.push({ path: u.pathname, id });
    res.writeHead(207, "XR Result", {
      "Content-Type": "text/plain",
      "X-XR-Proof": "actual",
    });
    res.end("complete");
    return;
  }
  res.writeHead(404);
  res.end();
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = "http://127.0.0.1:" + server.address().port;
const browser = await chromium.launch({
  executablePath: execFileSync("which", ["chromium"], {
    encoding: "utf8",
  }).trim(),
});
const results = [],
  errors = [];
async function page() {
  const p = await browser.newPage();
  p.on("pageerror", (error) => errors.push(String(error)));
  await p.goto(base);
  await p.addScriptTag({ url: base + "/probe.js" });
  await p.evaluate(() => xrRequest.reset());
  return p;
}
async function waitSlot(id) {
  for (let i = 0; i < 200; i++) {
    if (slots.has(id)) return slots.get(id);
    await new Promise((r) => setTimeout(r, 5));
  }
  throw Error("missing request " + id);
}
try {
  for (const kind of ["ordinary", "rpc"])
    for (const phase of ["head", "body"]) {
      const p = await page();
      const id = kind + "-" + phase;
      await p.evaluate(
        ({ kind, phase, id }) => {
          globalThis.outcome = { state: "pending" };
          globalThis.controller = new AbortController();
          xrRequest[kind]("/" + phase + "?id=" + id, controller.signal).then(
            (v) => (outcome = { state: "fulfilled", value: v }),
            (e) => (outcome = { state: "rejected", error: String(e) }),
          );
        },
        { kind, phase, id },
      );
      const r = await waitSlot(id);
      await p.evaluate(
        () =>
          new Promise((resolve) => {
            const c = new MessageChannel();
            c.port1.onmessage = () => {
              c.port1.close();
              c.port2.close();
              resolve();
            };
            c.port2.postMessage(0);
          }),
      );
      const pending = await p.evaluate(() => ({
        outcome,
        dispatch: xrRequest.count(),
      }));
      assert.deepEqual(pending, { outcome: { state: "pending" }, dispatch: 0 });
      if (phase === "head") {
        r.writeHead(207, "XR Result", {
          "Content-Type": "text/plain",
          "X-XR-Proof": "actual",
        });
        r.flushHeaders();
      }
      r.end(phase === "body" ? "last" : "complete");
      await p.waitForFunction(() => outcome.state !== "pending");
      const done = await p.evaluate(() => outcome);
      assert.equal(done.state, "fulfilled");
      assert.equal(done.value.status, 207);
      assert.equal(
        done.value.body,
        phase === "body" ? "first-last" : "complete",
      );
      assert.equal(done.value.dispatch, 1);
      if (kind === "ordinary")
        assert.equal(done.value.header, "actual", "buffered headers preserved");
      assert.equal(
        requests.filter((request) => request.id === id).length,
        1,
        "one actual facade request",
      );
      assert.equal(
        requests.find((request) => request.id === id).csrf,
        kind === "rpc" ? "csrf" : null,
        "original request headers",
      );
      results.push({ kind, phase, pending, done });
      await p.close();
    }
  for (const phase of ["head", "body"]) {
    const p = await page();
    const id = "abort-" + phase;
    const arrived =
      phase === "body"
        ? p.waitForResponse((r) => r.url().endsWith("/body?id=" + id))
        : null;
    await p.evaluate(
      ({ phase, id }) => {
        globalThis.outcome = { state: "pending" };
        const c = new AbortController();
        globalThis.abort = () => c.abort();
        xrRequest.rpc("/" + phase + "?id=" + id, c.signal).then(
          (v) => (outcome = { state: "fulfilled", value: v }),
          (e) => (outcome = { state: "rejected", error: String(e) }),
        );
      },
      { phase, id },
    );
    await waitSlot(id);
    if (arrived) await arrived;
    await p.evaluate(() => abort());
    await p.waitForFunction(() => outcome.state !== "pending");
    const done = await p.evaluate(() => outcome);
    assert.equal(done.state, "fulfilled");
    assert.equal(
      done.value.status,
      -1,
      "RPC abort remains a fulfilled -1 outcome",
    );
    assert.equal(done.value.dispatch, 1);
    results.push({ kind: "rpc", phase: "abort-" + phase, done });
    await p.close();
    slots.get(id).destroy();
  }
  for (const kind of ["ordinary", "rpc"]) {
    const p = await page();
    const id = "body-failure-" + kind;
    const arrived = p.waitForResponse((r) =>
      r.url().endsWith("/body?id=" + id),
    );
    await p.evaluate(
      ({ kind, id }) => {
        globalThis.outcome = { state: "pending" };
        xrRequest[kind]("/body?id=" + id, null).then(
          (value) => (outcome = { state: "fulfilled", value }),
          (error) => (outcome = { state: "rejected", error: String(error) }),
        );
      },
      { kind, id },
    );
    const r = await waitSlot(id);
    await arrived;
    r.destroy();
    await p.waitForFunction(() => outcome.state !== "pending");
    const done = await p.evaluate(() => outcome);
    assert.equal(done.state, "fulfilled");
    assert.equal(
      done.value.status,
      kind === "ordinary" ? 599 : 0,
      "body failure keeps legacy fulfilled status",
    );
    assert.equal(done.value.dispatch, 1);
    results.push({ kind, phase: "body-failure", done });
    await p.close();
  }
  for (const kind of ["ordinary", "rpc"]) {
    const p = await page();
    const done = await p.evaluate(async (kind) => {
      try {
        return {
          state: "fulfilled",
          value: await xrRequest[kind]("/disconnect?id=" + kind, null),
        };
      } catch (e) {
        return { state: "rejected", error: String(e) };
      }
    }, kind);
    assert.equal(done.state, "fulfilled");
    assert.equal(done.value.status, kind === "ordinary" ? 599 : 0);
    assert.equal(done.value.dispatch, 1);
    results.push({ kind, phase: "disconnect", done });
    await p.close();
  }
  for (const method of ["scripted", "scriptedRpc"])
    for (const rejects of [false, true]) {
      const p = await page();
      const done = await p.evaluate(
        async ({ method, rejects }) => {
          const order = ["entry"];
          const f = xrRequest[method](rejects);
          queueMicrotask(() => order.push("existing-microtask"));
          let outcome;
          try {
            outcome = { state: "fulfilled", value: await f };
          } catch (e) {
            outcome = { state: "rejected", error: String(e) };
          }
          order.push("continuation");
          return { outcome, order, dispatch: xrRequest.count() };
        },
        { method, rejects },
      );
      assert.equal(done.dispatch, 1);
      assert.equal(done.outcome.state, rejects ? "rejected" : "fulfilled");
      assert.deepEqual(done.order, [
        "entry",
        "existing-microtask",
        "continuation",
      ]);
      results.push({ kind: method, rejects, done });
      await p.close();
    }
  // Plain browser control proves actual head metadata/chunk demand exists before
  // the facade's whole-body settlement; never calls clone or an extra request.
  const p = await page();
  const id = "plain-body";
  await p.evaluate(() => {
    globalThis.plain = { state: "pending" };
    xrRequest.raw("/body?id=plain-body", {}).then(async (r) => {
      globalThis.reader = r.body.getReader();
      plain = {
        state: "head",
        status: r.status,
        statusText: r.statusText,
        url: r.url,
        redirected: r.redirected,
        type: r.type,
        headers: [...r.headers],
      };
      globalThis.first = await reader.read();
      plain.first = new TextDecoder().decode(first.value);
    });
  });
  const r = await waitSlot(id);
  await p.waitForFunction(() => plain.first === "first-");
  const head = await p.evaluate(() => plain);
  assert.equal(head.statusText, "XR Result");
  assert.equal(head.type, "basic");
  assert.equal(head.state, "head");
  r.end("last");
  const tail = await p.evaluate(async () => ({
    next: new TextDecoder().decode((await reader.read()).value),
    end: (await reader.read()).done,
  }));
  assert.deepEqual(tail, { next: "last", end: true });
  results.push({ kind: "plain", phase: "body-stream", head, tail });
  await p.close();
  const p2 = await page();
  const redirect = await p2.evaluate(async () => {
    const r = await xrRequest.raw("/redirect?id=redirect", {});
    return {
      status: r.status,
      statusText: r.statusText,
      url: r.url,
      redirected: r.redirected,
      type: r.type,
      body: await r.text(),
    };
  });
  assert.equal(redirect.redirected, true);
  assert(redirect.url.endsWith("/complete?id=redirect"));
  results.push({ kind: "raw", phase: "redirect", redirect });
  await p2.close();
  assert.deepEqual(errors, [], "no browser page errors");
  if (process.env.HTTP_RESPONSE_RECEIPT)
    await writeFile(
      process.env.HTTP_RESPONSE_RECEIPT,
      JSON.stringify(
        { browser: browser.version(), results, requests, errors },
        null,
        2,
      ),
    );
  console.log("PASS real browser request controls", results.length);
} finally {
  await browser.close();
  for (const r of slots.values()) r.destroy();
  server.closeAllConnections();
  await new Promise((r) => server.close(r));
}
