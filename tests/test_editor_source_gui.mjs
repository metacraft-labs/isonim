/**
 * Real mounted consumer/native CLI/RPC/WorkspaceEditAdapter/files/Nim compiler.
 * No mocked renderer, dispatcher, source storage, compiler or HTTP endpoints.
 * A scripted external ACP agent substitutes provider protocol behavior and model
 * output at the provider boundary. Production transport/client, actual provider
 * process, persistent session, scoped CLI and control registry remain real.
 * This isolates deterministic lifecycle checks from an external model/service.
 * The small checked-in consumer is copied into a disposable source project.
 * A scheduling barrier wraps the actual producer for one build to prove the UI
 * and API stay responsive while compilation is pending; it changes scheduling
 * only and still invokes the same real compiler/SSR producer after release.
 * A network barrier holds a real preview script during navigation; an additional
 * complete stale iframe proves that completion alone cannot qualify as capture.
 */
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import {
  mkdtempSync,
  cpSync,
  readFileSync,
  writeFileSync,
  existsSync,
  rmSync,
  openSync,
  closeSync,
  statSync,
  chmodSync,
} from "node:fs";
import path from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { chromium } from "../node_modules/playwright/index.mjs";
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const artifacts = mkdtempSync(path.join(tmpdir(), "isonim-source-gui-"));
const project = path.join(artifacts, "project");
cpSync(path.join(repo, "examples/source_project"), project, {
  recursive: true,
  filter: (source) => !source.includes("catalog-producer"),
});
// Actual compiler output carries authored comments, quoted head attributes and
// executable raw script/style text. These bytes must survive identity stamping.
const authored = path.join(project, "stories.nim");
// Large authored CSS is compiled/persisted/rendered in full; operation summaries
// must have a size independent of these real producer bytes.
const largeCss = "/* concise-operation-" + "x".repeat(256 * 1024) + " */";
const authoredWrapper = `proc card(title: string): string =
  "\\xEF\\xBB\\xBF<?xml version=\\"1.0\\"?><!doctype html><!-- valid documentation: <head> and <header> -->" & cardDocument(title).replace("<body>", """<body><!-- <i class='flex'> --><script>window.phantomMarkup=\"<i class='flex'>\";</script><style>body::after{content: \"<i class='text-sm'>\";display:none}</style><title><i class='flex'></title><textarea hidden><i class='text-sm'></textarea><noscript><i class='flex'></noscript><template><i class='text-sm'></i></template><div data-class-relevance title='1 > 0' =class='flex' CLASS='p&#45;4&Tab;w&#x2d;12' class='flex'></div><div data-class-entity-oracle class='&OverBar; &UnderBar; &race;'></div>""").replace("<head>", """<HeAd data-authored-double="1 > 0" data-authored-single='2 > 1'><script>window.authoredPreviewLiteral="<head>";window.authoredPreviewCounter=(window.authoredPreviewCounter||0)+1;</script><style>body::before{content:"<head>";display:none}</style><style data-large-source>${largeCss}</style>""")

`;
writeFileSync(
  authored,
  readFileSync(authored, "utf8")
    .replace("import std/json", "import std/[json, strutils]")
    .replace("proc card(title:", "proc cardDocument(title:")
    .replace("var stories =", authoredWrapper + "var stories ="),
);
rmSync(path.join(project, ".isonim/catalog.json"), { force: true });
const initialCatalog = spawnSync(
  "python3",
  [path.join(repo, "tools/build_source_catalog.py"), project],
  {
    encoding: "utf8",
    timeout: 70000,
    env: { ...process.env, ISONIM_SOURCE_FRAMEWORK: repo },
  },
);
assert.equal(
  initialCatalog.status,
  0,
  initialCatalog.stdout + " " + initialCatalog.stderr,
);
// Compile the actual headless producer against the same framework/style inputs.
// Its extraction output is compared with real compiled/mounted DOM, never a
// synthetic successful capture or a reconstructed renderer.
const classOracle = path.join(artifacts, "actual-preview-class-oracle");
const oracleBuild = spawnSync(
  "nim",
  [
    "c",
    "--path:src",
    "--path:../nim-everywhere/src",
    "--path:../nim-acp/src",
    "--path:../nim-agent-harbor/src",
    "--path:../nim-agents/src",
    "--path:../isonim-render-serve/src",
    "--out:" + classOracle,
    "tests/helpers/editor_context_snapshot.nim",
  ],
  { cwd: repo, encoding: "utf8", timeout: 70000 },
);
assert.equal(
  oracleBuild.status,
  0,
  oracleBuild.stdout + " " + oracleBuild.stderr,
);

const config = path.join(artifacts, "agent.toml");
writeFileSync(
  config,
  '[agent]\nbackend="custom"\ncommand="python3"\nargs=' +
    JSON.stringify([path.join(repo, "tests/helpers/editor_control_peer.py")]) +
    "\nprimer_enabled=false\n",
);
const log = openSync(path.join(artifacts, "server.log"), "w");
const server = spawn(
  "python3",
  [
    path.join(repo, "tools/editor_server.py"),
    "--directory",
    path.join(repo, "build/editor-source"),
    "--project-root",
    project,
    "--port",
    "0",
    "--bind",
    "127.0.0.1",
    "--config",
    config,
    "--daemon-binary",
    path.join(repo, "build/bin/isonim-review"),
  ],
  {
    env: {
      ...process.env,
      ISONIM_SOURCE_FRAMEWORK: repo,
      CONTROL_PROBE_DIR: artifacts,
    },
    stdio: ["ignore", "pipe", log],
  },
);
let browser, origin;
const startup = new Promise((resolve, reject) => {
  let output = "";
  server.stdout.on("data", (chunk) => {
    output += chunk;
    const match = output.match(/Editor listening on (http:\/\/[^\s]+)\//);
    if (match) {
      origin = match[1];
      resolve();
    }
  });
  server.once("exit", (code) =>
    reject(new Error("Launcher exited " + code + "; " + artifacts)),
  );
  setTimeout(
    () => reject(new Error("Launcher timeout; " + artifacts)),
    30000,
  ).unref();
});
function cli(scope, args, expected = 0) {
  const run = spawnSync(
    path.join(repo, "build/bin/isonim"),
    ["editor", ...args],
    {
      encoding: "utf8",
      timeout: 70000,
      env: {
        ...process.env,
        ISONIM_EDITOR_ENDPOINT: origin,
        ISONIM_EDITOR_WORKSPACE: scope.workspace,
        ISONIM_EDITOR_INSTANCE: scope.instance,
        ISONIM_EDITOR_EPOCH: scope.epoch,
        ISONIM_EDITOR_TOKEN: scope.controlToken,
      },
    },
  );
  assert.equal(run.status, expected, run.stdout + " " + run.stderr);
  return JSON.parse(run.stdout);
}
async function cliAsync(scope, args, expected = 0) {
  return new Promise((resolve, reject) => {
    const process = spawn(
      path.join(repo, "build/bin/isonim"),
      ["editor", ...args],
      {
        env: {
          ...globalThis.process.env,
          ISONIM_EDITOR_ENDPOINT: origin,
          ISONIM_EDITOR_WORKSPACE: scope.workspace,
          ISONIM_EDITOR_INSTANCE: scope.instance,
          ISONIM_EDITOR_EPOCH: scope.epoch,
          ISONIM_EDITOR_TOKEN: scope.controlToken,
        },
        stdio: ["ignore", "pipe", "pipe"],
      },
    );
    let stdout = "",
      stderr = "";
    process.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    process.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    const timeout = setTimeout(() => {
      process.kill("SIGKILL");
      reject(
        new Error(
          "Native CLI process exceeded unchanged 70 second harness bound",
        ),
      );
    }, 70000);
    process.once("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    process.once("exit", (code) => {
      clearTimeout(timeout);
      try {
        assert.equal(code, expected, stdout + " " + stderr);
        resolve(JSON.parse(stdout));
      } catch (error) {
        reject(error);
      }
    });
  });
}
function successfulSourceSummary(scope, operation, storyId) {
  const catalog = JSON.parse(
    readFileSync(path.join(project, ".isonim/catalog.json"), "utf8"),
  );
  assert.equal(operation.status, "applied");
  assert.deepEqual(
    operation.result,
    { ok: true, storyId, compiledStoryCount: catalog.stories.length },
    "Public success must report the validated compiled outcome without catalog/manifest HTML",
  );
  assert(
    Buffer.byteLength(JSON.stringify(operation.result)) < 256,
    "Summary size is independent of compiled HTML/CSS",
  );
  assert.equal(operation.request.workspace, scope.workspace);
  assert.equal(operation.request.instance, scope.instance);
  assert.equal(operation.request.epoch, scope.epoch);
  assert(Number.isInteger(operation.revision));
  return catalog;
}
async function stable(scope, ready = () => true) {
  let revision = -1,
    count = 0;
  for (let step = 0; step < 50; step++) {
    const state = cli(scope, ["state"]);
    count = state.revision === revision ? count + 1 : 0;
    revision = state.revision;
    if (count >= 3 && ready(state)) return state;
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error("Revision did not stabilize");
}
async function mounted(page) {
  const [registration] = await Promise.all([
    page.waitForResponse(
      (r) =>
        r.url().endsWith("/api/editor/rpc") &&
        r.request().postDataJSON()?.method === "editor.register",
    ),
    page.goto(origin),
  ]);
  const scope = (await registration.json()).result;
  assert(scope);
  for (let step = 0; step < 100; step++) {
    const state = cli(scope, ["state"]);
    if (state.capabilities.includes("create-story")) return scope;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("Source bridge did not become available");
}
async function request(scope, method, params, token = scope.controlToken) {
  const result = await fetch(origin + "/api/editor/rpc", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-IsoNim-Control": token },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method,
      params: {
        workspace: scope.workspace,
        instance: scope.instance,
        epoch: scope.epoch,
        ...params,
      },
    }),
  });
  return result.json();
}
try {
  await startup;
  const env = { ...process.env };
  delete env.LD_LIBRARY_PATH;
  browser = await chromium.launch({
    headless: true,
    executablePath:
      process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ??
      "/nix/store/1id5xlj91r8d5cj5ks4a5byrxdvr4b50-chromium-143.0.7499.192/bin/chromium",
    env,
  });
  const page = await browser.newPage({
    viewport: { width: 1440, height: 1000 },
  });
  const errors = [];
  page.on("pageerror", (error) => {
    errors.push(error.message);
    console.error("Source GUI browser error: " + error.message);
  });
  const scope = await mounted(page);
  let state = await stable(scope);
  assert(
    state.fixtures.some((f) => f.component === "Card" && f.state === "busy"),
  );
  assert(state.capabilities.includes("capture-preview"));
  assert(!state.capabilities.includes("capture-preview-html"));
  cli(scope, [
    "open-story",
    "Card / default ready",
    "--command-id",
    "open-ready",
    "--wait",
  ]);
  await page
    .frameLocator('iframe[data-component-project-frame="true"]')
    .locator("h1")
    .filter({ hasText: "Ready card" })
    .waitFor();
  const authoredDocument = await page
    .frameLocator('iframe[data-component-project-frame="true"]')
    .locator("body")
    .evaluate((body) => ({
      compatMode: body.ownerDocument.compatMode,
      double: body.ownerDocument.head.getAttribute("data-authored-double"),
      single: body.ownerDocument.head.getAttribute("data-authored-single"),
      literal: body.ownerDocument.defaultView.authoredPreviewLiteral,
      executions: body.ownerDocument.defaultView.authoredPreviewCounter,
      style: body.ownerDocument.querySelector("style")?.textContent,
      text: body.innerText,
      classes: [
        ...new Set(
          [...body.ownerDocument.querySelectorAll("[class]")].flatMap(
            (element) => [...element.classList],
          ),
        ),
      ],
    }));
  assert.equal(authoredDocument.compatMode, "CSS1Compat");
  assert.equal(authoredDocument.double, "1 > 0");
  assert.equal(authoredDocument.single, "2 > 1");
  assert.equal(authoredDocument.literal, "<head>");
  assert.equal(authoredDocument.executions, 1);
  assert.equal(
    authoredDocument.style,
    'body::before{content:"<head>";display:none}',
  );
  assert(authoredDocument.text.includes("Ready card"));
  assert.deepEqual(
    authoredDocument.classes,
    ["p-4", "w-12", "‾", "_", "∽̱"],
    "Actual mounted DOM ignores inactive markup, uses first duplicate class and decodes corrected WHATWG names",
  );
  const rawReady = JSON.parse(
    readFileSync(path.join(project, ".isonim/catalog.json"), "utf8"),
  ).stories.find(
    (story) => story.group === "Card" && story.name === "default ready",
  ).documentHtml;
  assert(rawReady.startsWith('\uFEFF<?xml version="1.0"?><!doctype html>'));
  const extractedClasses = spawnSync(classOracle, ["--preview-classes"], {
    input: rawReady,
    encoding: "utf8",
    timeout: 70000,
  });
  assert.equal(extractedClasses.status, 0, extractedClasses.stderr);
  assert.deepEqual(
    JSON.parse(extractedClasses.stdout),
    authoredDocument.classes,
    "Actual production extractor and real mounted DOM must agree on genuine compiler HTML",
  );
  const compiledStyles = JSON.parse(
    readFileSync(path.join(repo, "build/tailwind-styles.json"), "utf8"),
  );
  const mountedCompiledClasses = authoredDocument.classes.filter((name) =>
    Object.hasOwn(compiledStyles, name),
  );
  assert.deepEqual(mountedCompiledClasses, ["p-4", "w-12"]);

  const unstampedReadyOracle = await page.evaluate(async (html) => {
    const frame = document.createElement("iframe");
    frame.style.cssText =
      "position:fixed;left:-10000px;width:1000px;height:1000px";
    const loaded = new Promise((resolve) => (frame.onload = resolve));
    frame.srcdoc = html;
    document.body.append(frame);
    await loaded;
    const doc = frame.contentDocument;
    const win = frame.contentWindow;
    const result = {
      compatMode: doc.compatMode,
      double: doc.head.getAttribute("data-authored-double"),
      single: doc.head.getAttribute("data-authored-single"),
      literal: win.authoredPreviewLiteral,
      executions: win.authoredPreviewCounter,
      style: doc.querySelector("style")?.textContent,
      text: doc.body.innerText,
      classes: [
        ...new Set(
          [...doc.querySelectorAll("[class]")].flatMap((element) => [
            ...element.classList,
          ]),
        ),
      ],
    };
    frame.remove();
    return result;
  }, rawReady);
  assert.deepEqual(
    authoredDocument,
    unstampedReadyOracle,
    "Leading BOM/PI/doctype/comments and head attributes must preserve actual authored rendering/execution",
  );
  await stable(scope);
  const authoredCapture = cli(scope, [
    "capture-preview",
    "--command-id",
    "capture-authored-ready",
    "--wait",
  ]);
  assert.equal(authoredCapture.result.storyId, "Card / default ready");
  assert(authoredCapture.result.documentHtml.includes("Ready card"));
  const composer = page.locator('[data-editor-control-focus="composer"]');
  await composer.fill("Keep this real conversation across source compilation");
  const contextRequest = page.waitForRequest(
    (request) =>
      request.url().endsWith("/api/agent/prompts") &&
      request.method() === "POST",
  );
  await page
    .getByRole("button", { name: "Send agent prompt", exact: true })
    .click();
  const submittedContext = (await contextRequest).postDataJSON().context;
  assert.deepEqual(
    submittedContext.availableTailwindClasses.slice(0, 2),
    mountedCompiledClasses,
    "Actual production preview context follows mounted DOM classes before unrelated compiled inventory",
  );
  assert(
    submittedContext.availableTailwindClasses.includes("flex") &&
      submittedContext.availableTailwindClasses.includes("text-sm"),
    "Phantoms are genuinely compiled but must not take relevance priority",
  );
  await page.getByText("CONTROL_SCOPE_OK", { exact: false }).first().waitFor();
  await stable(scope);
  const conversation = cli(scope, ["state"]).conversations.find(
    (chat) => chat.active,
  );
  assert(
    conversation.backendSessionId,
    "Actual backend conversation was launched",
  );
  await composer.fill("Preserve my draft across source compilation");
  await stable(scope);
  const created = cli(scope, [
    "create-story",
    "Card",
    "--variant",
    "default",
    "--state",
    "busy",
    "--command-id",
    "create-busy",
    "--wait",
    "--timeout-ms",
    "60000",
  ]);
  assert.equal(created.status, "applied");
  assert.equal(created.result.storyId, "Card / default busy");
  const createdCatalog = successfulSourceSummary(
    scope,
    created,
    "Card / default busy",
  );
  assert(
    createdCatalog.stories.every((story) =>
      story.documentHtml.includes(largeCss),
    ),
  );
  const createdProducerTime = statSync(
    path.join(project, ".isonim/catalog-producer"),
    { bigint: true },
  ).mtimeNs;
  const repeatedCreate = { ...created.request };
  delete repeatedCreate.conversation;
  const duplicateCreate = (
    await request(scope, "editor.command", repeatedCreate)
  ).result;
  assert.deepEqual(duplicateCreate.result, created.result);
  assert.equal(duplicateCreate.operationId, created.operationId);
  assert.equal(
    statSync(path.join(project, ".isonim/catalog-producer"), { bigint: true })
      .mtimeNs,
    createdProducerTime,
  );
  assert(
    readFileSync(path.join(project, "stories.nim"), "utf8").includes(
      'card("Busy card")',
    ),
  );
  assert.equal(
    await composer.inputValue(),
    "Preserve my draft across source compilation",
  );
  assert.equal(
    cli(scope, ["state"]).conversations.find(
      (chat) => chat.id === conversation.id,
    ).backendSessionId,
    conversation.backendSessionId,
  );
  await stable(scope);
  cli(scope, [
    "open-story",
    "Card / default busy",
    "--command-id",
    "open-busy",
    "--wait",
  ]);
  await page
    .frameLocator('iframe[data-component-project-frame="true"]')
    .locator("h1")
    .filter({ hasText: "Busy card" })
    .waitFor();
  await stable(scope);
  const capture = cli(scope, [
    "capture-preview",
    "--command-id",
    "capture-busy",
    "--wait",
  ]);
  assert.equal(capture.status, "applied");
  assert.equal(capture.result.format, "text/html");
  assert.equal(capture.result.storyId, "Card / default busy");
  assert(
    capture.result.documentHtml.includes("Busy card") &&
      !capture.result.documentHtml.includes("Ready card"),
  );
  assert(capture.result.documentHtml.includes(largeCss));
  assert.equal(
    capture.result.documentHtml,
    "<!doctype html>\n" +
      (await page
        .frameLocator('iframe[data-component-project-frame="true"]')
        .locator("html")
        .evaluate((root) => root.ownerDocument.documentElement.outerHTML)),
  );
  await page
    .locator("iframe:visible")
    .first()
    .screenshot({ path: path.join(artifacts, "busy-preview.png") });
  const manifestPath = path.join(project, ".isonim/source-project.json");
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  manifest.fixtures[1].declaration += '\nlet invalidNim: int = "wrong type"';
  writeFileSync(manifestPath, JSON.stringify(manifest));
  const beforeSource = readFileSync(path.join(project, "stories.nim"), "utf8");
  const failed = cli(
    scope,
    [
      "create-story",
      "Card",
      "--variant",
      "default",
      "--state",
      "error",
      "--command-id",
      "invalid-create",
      "--wait",
      "--timeout-ms",
      "60000",
    ],
    4,
  );
  assert.equal(failed.status, "failed");
  assert(failed.diagnostic.includes("type mismatch"));
  assert.equal(
    readFileSync(path.join(project, "stories.nim"), "utf8"),
    beforeSource,
  );
  assert.equal(
    await page
      .frameLocator('iframe[data-component-project-frame="true"]')
      .locator("h1")
      .textContent(),
    "Busy card",
  );
  assert.equal(
    await composer.inputValue(),
    "Preserve my draft across source compilation",
  );
  assert.equal(
    cli(scope, ["state"]).conversations.find(
      (chat) => chat.id === conversation.id,
    ).backendSessionId,
    conversation.backendSessionId,
  );
  // A real producer may compile successfully but omit the requested story.
  // That still must roll back creation and retain a terminal deduplicated failure.
  manifest.fixtures[1].declaration = JSON.parse(
    readFileSync(
      path.join(repo, "examples/source_project/.isonim/source-project.json"),
      "utf8",
    ),
  ).fixtures[1].declaration;
  const omissionTrace = path.join(project, ".isonim/producer-invocations");
  const omissionWrapper = path.join(project, "trace_producer.py");
  writeFileSync(
    omissionWrapper,
    'from pathlib import Path\nimport subprocess,sys\nwith Path(".isonim/producer-invocations").open("a") as trace: trace.write("invoked\\n")\nsys.exit(subprocess.call(["python3","build_catalog.py"]))\n',
  );
  manifest.build = ["python3", "trace_producer.py"];
  writeFileSync(manifestPath, JSON.stringify(manifest));
  const omittedSource = beforeSource.replace(
    'echo $(%* {"stories": stories})',
    'stories = %*[stories[0], stories[1]]\necho $(%* {"stories": stories})',
  );
  writeFileSync(path.join(project, "stories.nim"), omittedSource);
  const beforeOmittedCatalog = readFileSync(
    path.join(project, ".isonim/catalog.json"),
    "utf8",
  );
  await stable(scope);
  const omitted = cli(
    scope,
    [
      "create-story",
      "Card",
      "--variant",
      "default",
      "--state",
      "error",
      "--command-id",
      "omitted-created-story",
      "--wait",
      "--timeout-ms",
      "60000",
    ],
    4,
  );
  assert.equal(omitted.status, "failed");
  assert(
    omitted.diagnostic.includes(
      "Compiled catalog omits requested story: Card / default error",
    ),
  );
  assert.equal(
    readFileSync(path.join(project, "stories.nim"), "utf8"),
    omittedSource,
  );
  assert.equal(
    readFileSync(path.join(project, ".isonim/catalog.json"), "utf8"),
    beforeOmittedCatalog,
  );
  assert.equal(
    await page
      .frameLocator('iframe[data-component-project-frame="true"]')
      .locator("h1")
      .textContent(),
    "Busy card",
  );
  assert.equal(
    readFileSync(omissionTrace, "utf8"),
    "invoked\n",
    "Real producer executes exactly once for the failed omission",
  );
  const omittedProducerTime = statSync(
    path.join(project, ".isonim/catalog-producer"),
    { bigint: true },
  ).mtimeNs;
  const omittedRequest = { ...omitted.request };
  delete omittedRequest.conversation;
  const repeatedOmission = (
    await request(scope, "editor.command", omittedRequest)
  ).result;
  assert.equal(repeatedOmission.status, "failed");
  assert.equal(repeatedOmission.diagnostic, omitted.diagnostic);
  assert.equal(
    readFileSync(omissionTrace, "utf8"),
    "invoked\n",
    "Duplicate terminal failure must not invoke the real producer",
  );
  assert.equal(
    statSync(path.join(project, ".isonim/catalog-producer"), { bigint: true })
      .mtimeNs,
    omittedProducerTime,
    "Duplicate failed creation must not run the real compiler again",
  );
  assert.equal(
    readFileSync(path.join(project, "stories.nim"), "utf8"),
    omittedSource,
  );
  manifest.build = ["python3", "build_catalog.py"];
  writeFileSync(manifestPath, JSON.stringify(manifest));
  const edited = beforeSource.replace("Busy card", "Agent revised card");
  writeFileSync(path.join(project, "stories.nim"), edited);
  await stable(scope);
  // Actual producer succeeds before a real publication directory write failure.
  const publicationWrapper = path.join(project, "publication_failure.py");
  writeFileSync(
    publicationWrapper,
    'from pathlib import Path\nimport os,subprocess,sys\nrun=subprocess.run(["python3","build_catalog.py"],capture_output=True,text=True)\nif run.returncode: sys.stdout.write(run.stdout); sys.exit(run.returncode)\nPath("actually-compiled.json").write_text(run.stdout)\nos.chmod(".isonim",0o555)\nsys.stdout.write(run.stdout)\n',
  );
  manifest.build = ["python3", "publication_failure.py"];
  writeFileSync(manifestPath, JSON.stringify(manifest));
  const beforePublicationCatalog = readFileSync(
    path.join(project, ".isonim/catalog.json"),
    "utf8",
  );
  try {
    const refused = cli(
      scope,
      [
        "build",
        "--command-id",
        "publication-refused",
        "--wait",
        "--timeout-ms",
        "60000",
      ],
      4,
    );
    assert.equal(refused.status, "failed");
    assert(refused.diagnostic.includes("Catalog publication failed"));
    assert(refused.diagnostic.includes("Permission denied"));
    assert(
      readFileSync(
        path.join(project, "actually-compiled.json"),
        "utf8",
      ).includes("Agent revised card"),
    );
    assert.equal(
      readFileSync(path.join(project, ".isonim/catalog.json"), "utf8"),
      beforePublicationCatalog,
    );
    assert.equal(
      readFileSync(path.join(project, "stories.nim"), "utf8"),
      edited,
    );
    assert(!existsSync(path.join(project, ".isonim/source-transaction.json")));
    assert.equal(
      await page
        .frameLocator('iframe[data-component-project-frame="true"]')
        .locator("h1")
        .textContent(),
      "Busy card",
    );
    await stable(scope);
    const previousCapture = cli(scope, [
      "capture-preview",
      "--command-id",
      "capture-publication-failed",
      "--wait",
    ]);
    assert.equal(previousCapture.result.storyId, "Card / default busy");
    assert(
      previousCapture.result.documentHtml.includes("Busy card") &&
        !previousCapture.result.documentHtml.includes("Agent revised card"),
    );
  } finally {
    chmodSync(path.join(project, ".isonim"), 0o755);
  }
  manifest.build = ["python3", "build_catalog.py"];
  writeFileSync(manifestPath, JSON.stringify(manifest));
  await stable(scope);
  const built = cli(scope, [
    "build",
    "--command-id",
    "general-edit-build",
    "--wait",
    "--timeout-ms",
    "60000",
  ]);
  const builtCatalog = successfulSourceSummary(scope, built, "");
  assert(
    builtCatalog.stories.every((story) =>
      story.documentHtml.includes(largeCss),
    ),
  );
  const builtProducerTime = statSync(
    path.join(project, ".isonim/catalog-producer"),
    { bigint: true },
  ).mtimeNs;
  const repeatedBuild = { ...built.request };
  delete repeatedBuild.conversation;
  const duplicateBuild = (await request(scope, "editor.command", repeatedBuild))
    .result;
  assert.deepEqual(duplicateBuild.result, built.result);
  assert.equal(duplicateBuild.operationId, built.operationId);
  assert.equal(
    statSync(path.join(project, ".isonim/catalog-producer"), { bigint: true })
      .mtimeNs,
    builtProducerTime,
  );
  const staleBuild = cli(
    scope,
    [
      "build",
      "--command-id",
      "stale-summary-build",
      "--expected-revision",
      String(built.revision - 1),
      "--wait",
    ],
    6,
  );
  assert.equal(staleBuild.status, "failed");
  assert.equal(staleBuild.error, "revision_conflict");
  assert.equal(
    statSync(path.join(project, ".isonim/catalog-producer"), { bigint: true })
      .mtimeNs,
    builtProducerTime,
  );
  await page
    .frameLocator('iframe[data-component-project-frame="true"]')
    .locator("h1")
    .filter({ hasText: "Agent revised card" })
    .waitFor();
  assert.equal(
    await page
      .frameLocator('iframe[data-component-project-frame="true"]')
      .locator("head")
      .getAttribute("data-authored-double"),
    "1 > 0",
  );
  assert.equal(
    await page
      .frameLocator('iframe[data-component-project-frame="true"]')
      .locator("body")
      .evaluate(
        (body) => body.ownerDocument.defaultView.authoredPreviewLiteral,
      ),
    "<head>",
  );
  await stable(scope);
  const builtCapture = cli(scope, [
    "capture-preview",
    "--command-id",
    "capture-concise-build",
    "--wait",
  ]);
  assert.equal(builtCapture.result.ready, true);
  assert.equal(builtCapture.result.storyId, "Card / default busy");
  assert(builtCapture.result.documentHtml.includes(largeCss));
  assert(builtCapture.result.documentHtml.includes("Agent revised card"));
  assert.equal(
    builtCapture.result.documentHtml,
    "<!doctype html>\n" +
      (await page
        .frameLocator('iframe[data-component-project-frame="true"]')
        .locator("html")
        .evaluate((root) => root.ownerDocument.documentElement.outerHTML)),
  );
  // Scripting-enabled iframe noscript is raw/inactive, including '<head>'.
  // Compile a real headless fragment and capture it before restoring the document.
  const fragmentWrapper = `proc card(title: string): string =
  """<noscript>Authored fallback <head> example</noscript><header><h1>""" & escapeHtml(title) & """</h1></header><script>window.authoredPreviewLiteral="<head>";window.authoredDoubleEscaped="<!--<script></script><head>";window.authoredCommentTerminated="<!--<script>--><header>";window.authoredWordBoundary="<!--<scripture></scripture><head>";window.authoredCompound='<!--<script x="<script>"></script x="<script>"><head>-->';</script>"""

`;
  writeFileSync(authored, edited.replace(authoredWrapper, fragmentWrapper));
  cli(scope, [
    "build",
    "--command-id",
    "headless-noscript-build",
    "--wait",
    "--timeout-ms",
    "60000",
  ]);
  await page
    .frameLocator('iframe[data-component-project-frame="true"]')
    .locator("h1")
    .filter({ hasText: "Agent revised card" })
    .waitFor();
  await page
    .frameLocator('iframe[data-component-project-frame="true"]')
    .locator("noscript")
    .waitFor({ state: "attached" });
  const headlessState = await page
    .frameLocator('iframe[data-component-project-frame="true"]')
    .locator("body")
    .evaluate((body) => ({
      visible: body.innerText,
      noscript: body.ownerDocument.querySelector("noscript")?.textContent,
      literal: body.ownerDocument.defaultView.authoredPreviewLiteral,
      doubleEscaped: body.ownerDocument.defaultView.authoredDoubleEscaped,
      commentTerminated:
        body.ownerDocument.defaultView.authoredCommentTerminated,
      wordBoundary: body.ownerDocument.defaultView.authoredWordBoundary,
      compound: body.ownerDocument.defaultView.authoredCompound,
      compatMode: body.ownerDocument.compatMode,
    }));
  assert(headlessState.noscript.includes("Authored fallback <head> example"));
  assert(!headlessState.visible.includes("Authored fallback"));
  assert.equal(headlessState.literal, "<head>");
  assert.equal(headlessState.doubleEscaped, "<!--<script></script><head>");
  assert.equal(headlessState.commentTerminated, "<!--<script>--><header>");
  assert.equal(headlessState.wordBoundary, "<!--<scripture></scripture><head>");
  assert.equal(
    headlessState.compound,
    '<!--<script x="<script>"></script x="<script>"><head>-->',
  );
  const rawFragment = JSON.parse(
    readFileSync(path.join(project, ".isonim/catalog.json"), "utf8"),
  ).stories.find(
    (story) => story.group === "Card" && story.name === "default busy",
  ).documentHtml;
  const unstampedOracle = await page.evaluate(async (html) => {
    const frame = document.createElement("iframe");
    frame.style.cssText =
      "position:fixed;left:-10000px;width:1000px;height:1000px";
    const loaded = new Promise((resolve) => (frame.onload = resolve));
    frame.srcdoc = html;
    document.body.append(frame);
    await loaded;
    const doc = frame.contentDocument;
    const win = frame.contentWindow;
    const result = {
      visible: doc.body.innerText,
      noscript: doc.querySelector("noscript")?.textContent,
      literal: win.authoredPreviewLiteral,
      doubleEscaped: win.authoredDoubleEscaped,
      commentTerminated: win.authoredCommentTerminated,
      wordBoundary: win.authoredWordBoundary,
      compound: win.authoredCompound,
      compatMode: doc.compatMode,
    };
    frame.remove();
    return result;
  }, rawFragment);
  assert.deepEqual(
    headlessState,
    unstampedOracle,
    "Production stamped document must retain actual unstamped authored execution/render semantics",
  );
  await stable(scope);
  const headlessCapture = cli(scope, [
    "capture-preview",
    "--command-id",
    "headless-noscript-capture",
    "--wait",
  ]);
  assert.equal(headlessCapture.result.storyId, "Card / default busy");
  assert(headlessCapture.result.documentHtml.includes("Agent revised card"));
  writeFileSync(authored, edited);
  cli(scope, [
    "build",
    "--command-id",
    "restore-authored-document",
    "--wait",
    "--timeout-ms",
    "60000",
  ]);
  await page
    .frameLocator('iframe[data-component-project-frame="true"]')
    .locator('head[data-authored-double="1 > 0"]')
    .waitFor({ state: "attached" });
  assert.equal(
    await page
      .frameLocator('iframe[data-component-project-frame="true"]')
      .locator("head")
      .getAttribute("data-authored-double"),
    "1 > 0",
  );
  await stable(scope);
  // Hydrate both real editors before holding a transaction that metadata reads await.
  const waitingPage = await browser.newPage({
    viewport: { width: 1440, height: 1000 },
  });
  const waitingScope = await mounted(waitingPage);
  await stable(waitingScope);
  // Deterministically hold the real producer while unrelated HTTP/UI remain live.
  const barrier = path.join(artifacts, "release-build");
  const started = path.join(artifacts, "build-started");
  const wrapper = path.join(artifacts, "producer_barrier.py");
  writeFileSync(
    wrapper,
    "from pathlib import Path\nimport subprocess,time,sys\nPath(" +
      JSON.stringify(started) +
      ').open("a").write("started\\n")\nwhile not Path(' +
      JSON.stringify(barrier) +
      ').exists(): time.sleep(.02)\nsys.exit(subprocess.call(["python3","build_catalog.py"]))\n',
  );
  manifest.build = ["python3", wrapper];
  writeFileSync(manifestPath, JSON.stringify(manifest));
  const pending = cli(scope, ["build", "--command-id", "pending-build"]);
  for (let step = 0; step < 100 && !existsSync(started); step++)
    await new Promise((resolve) => setTimeout(resolve, 50));
  assert(existsSync(started), "Real producer reached scheduling barrier");
  const running = cli(
    scope,
    ["wait", pending.operationId, "--timeout-ms", "300"],
    5,
  );
  assert.equal(running.operation.status, "running");
  assert.equal(running.operation.sourcePhase, "admitted");
  const waitingResponse = waitingPage.waitForResponse((response) =>
    response.url().endsWith("/api/editor/source/operation"),
  );
  waitingResponse.catch(() => {}); // Preserve the primary assertion if cleanup closes this page.
  const waitingBuild = cli(waitingScope, [
    "build",
    "--command-id",
    "revoked-waiting-build",
  ]);
  let waitingOperation;
  for (let step = 0; step < 100; step++) {
    waitingOperation = (
      await request(waitingScope, "editor.wait", {
        operationId: waitingBuild.operationId,
      })
    ).result;
    if (
      waitingOperation.sourcePhase === "waiting" &&
      waitingOperation.status === "running"
    )
      break;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  assert.equal(
    waitingOperation.sourcePhase,
    "waiting",
    "Second real source request reached the transaction lock admission boundary",
  );
  assert.equal(waitingOperation.status, "running");
  assert.equal(
    (
      await request(
        waitingScope,
        "editor.disconnect",
        {},
        waitingScope.browserToken,
      )
    ).result.disconnected,
    true,
  );
  const startedAt = performance.now();
  const http = await fetch(origin + "/index.html");
  assert.equal(http.status, 200);
  assert(
    performance.now() - startedAt < 800,
    "Static HTTP stays responsive during compiler job",
  );
  await composer.fill("I can keep writing while compiler runs");
  assert.equal(
    await composer.inputValue(),
    "I can keep writing while compiler runs",
  );
  const originalRequest = { ...pending.request };
  delete originalRequest.conversation;
  const duplicate = await request(scope, "editor.command", originalRequest);
  assert.equal(duplicate.result.operationId, pending.operationId);
  assert.equal(duplicate.result.status, "running");
  writeFileSync(barrier, "release");
  cli(scope, ["wait", pending.operationId, "--timeout-ms", "60000"]);
  const revokedSource = await (await waitingResponse).json();
  assert.equal(revokedSource.ok, false);
  assert(revokedSource.diagnostic.includes("disconnected"));
  assert.equal(
    readFileSync(started, "utf8"),
    "started\n",
    "Revoked waiting operation must never launch a second real producer",
  );
  assert(
    JSON.parse(
      readFileSync(path.join(project, ".isonim/catalog.json"), "utf8"),
    ).stories.some((story) =>
      story.documentHtml.includes("Agent revised card"),
    ),
    "Admitted producer publishes its actual rendered catalog",
  );
  await waitingPage.close();
  // Hold an actual subresource while the new srcdoc is loading. A complete
  // stale document remains mounted alongside it, so capture must check identity.
  let releaseCapture, captureRequested;
  const captureBarrier = new Promise((resolve) => {
    releaseCapture = resolve;
  });
  const captureSeen = new Promise((resolve) => {
    captureRequested = resolve;
  });
  await page.route("**/capture-delay.js", async (route) => {
    captureRequested();
    await captureBarrier;
    await route.fulfill({
      contentType: "application/javascript",
      body: "void 0;",
    });
  });
  const delayedSource = readFileSync(
    path.join(project, "stories.nim"),
    "utf8",
  ).replace(
    "title: text title",
    'title: text title\n        script(src = "/capture-delay.js"): text ""',
  );
  writeFileSync(path.join(project, "stories.nim"), delayedSource);
  const beforeDelayedPreview = await stable(scope);
  await cliAsync(scope, [
    "build",
    "--command-id",
    "delayed-render-build",
    "--wait",
    "--timeout-ms",
    "60000",
  ]);
  await Promise.race([
    captureSeen,
    new Promise((_, reject) =>
      setTimeout(
        () =>
          reject(
            new Error("Preview script did not reach its real network barrier"),
          ),
        10000,
      ),
    ),
  ]);
  await page.evaluate((html) => {
    const stale = document.createElement("iframe");
    stale.setAttribute("data-page-project-frame", "true");
    stale.id = "stale-capture-control";
    stale.style.cssText = "position:fixed;bottom:0;width:20px;height:20px;";
    stale.srcdoc = html;
    document.querySelector(".isonim-editor")?.appendChild(stale) ||
      document.body.appendChild(stale);
  }, capture.result.documentHtml);
  await page.waitForFunction((before) => {
    const stale = document.querySelector(
      "#stale-capture-control",
    )?.contentDocument;
    const frame = document.querySelector(
      'iframe[data-component-project-frame="true"]',
    );
    const current = frame?.contentDocument;
    const story = current?.querySelector('meta[name="isonim-rendered-story"]');
    const generation = current?.querySelector(
      'meta[name="isonim-rendered-generation"]',
    );
    return (
      stale?.readyState === "complete" &&
      current?.readyState === "loading" &&
      !current.querySelector("main") &&
      story?.content === before.storyId &&
      Number(generation?.content) > before.previewGeneration
    );
  }, beforeDelayedPreview);
  // The real reader retains old layers until its two empty polls publish [].
  // Await that observable publication within the existing revision budget;
  // the current document cannot acquire body layers while its head script is held.
  await stable(
    scope,
    (state) =>
      state.previewGeneration > beforeDelayedPreview.previewGeneration &&
      state.buildStage === "wesClean" &&
      Array.isArray(state.elements) &&
      state.elements.length === 0,
  );
  const notReady = await cliAsync(
    scope,
    ["capture-preview", "--command-id", "capture-delayed-negative", "--wait"],
    4,
  );
  assert.equal(notReady.error, "preview_not_ready");
  assert.equal(notReady.result.ready, false);
  releaseCapture();
  await page.unrouteAll({ behavior: "wait" });
  await page
    .locator("#stale-capture-control")
    .evaluate((frame) => frame.remove());
  await page
    .frameLocator('iframe[data-component-project-frame="true"]')
    .locator("h1")
    .filter({ hasText: "Agent revised card" })
    .waitFor();
  assert.equal(
    await page
      .frameLocator('iframe[data-component-project-frame="true"]')
      .locator("head")
      .getAttribute("data-authored-double"),
    "1 > 0",
  );
  assert.equal(
    await page
      .frameLocator('iframe[data-component-project-frame="true"]')
      .locator("body")
      .evaluate(
        (body) => body.ownerDocument.defaultView.authoredPreviewLiteral,
      ),
    "<head>",
  );
  await page.waitForFunction(
    () =>
      document.querySelector("iframe[data-component-project-frame]")
        ?.contentDocument?.readyState === "complete",
  );
  await stable(scope);
  const readyCapture = await cliAsync(scope, [
    "capture-preview",
    "--command-id",
    "capture-delayed-positive",
    "--wait",
  ]);
  assert.equal(readyCapture.result.ready, true);
  assert.equal(
    readyCapture.result.previewGeneration,
    cli(scope, ["state"]).previewGeneration,
  );
  assert(readyCapture.result.documentHtml.includes("Agent revised card"));
  const reloadedScope = await mounted(page);
  await stable(reloadedScope);
  assert(
    cli(reloadedScope, ["stories"]).some(
      (story) => story.id === "Card / default busy",
    ),
  );
  cli(reloadedScope, [
    "open-story",
    "Card / default busy",
    "--command-id",
    "reload-open",
    "--wait",
  ]);
  await page
    .frameLocator('iframe[data-component-project-frame="true"]')
    .locator("h1")
    .filter({ hasText: "Agent revised card" })
    .waitFor();
  assert.equal(
    await page
      .frameLocator('iframe[data-component-project-frame="true"]')
      .locator("head")
      .getAttribute("data-authored-double"),
    "1 > 0",
  );
  assert.equal(
    await page
      .frameLocator('iframe[data-component-project-frame="true"]')
      .locator("body")
      .evaluate(
        (body) => body.ownerDocument.defaultView.authoredPreviewLiteral,
      ),
    "<head>",
  );
  assert.deepEqual(errors, []);
} finally {
  if (browser) await browser.close();
  server.kill("SIGTERM");
  await new Promise((resolve, reject) => {
    if (server.exitCode !== null) return resolve();
    server.once("exit", resolve);
    setTimeout(
      () => reject(new Error("Source launcher cleanup timeout")),
      75000,
    ).unref();
  });
  closeSync(log);
  assert.equal(
    server.exitCode,
    143,
    "Launcher must report its intentional SIGTERM; abnormal native exit must fail earlier; " +
      artifacts,
  );
  assert(
    !readFileSync(path.join(artifacts, "server.log"), "utf8").includes(
      "SIGSEGV",
    ),
    "Native teardown must not crash",
  );
}

writeFileSync(
  path.join(artifacts, "results.json"),
  JSON.stringify(
    {
      cases: 20,
      passed: true,
      htmlClassOracle: true,
      renderedCapture: "busy-preview.png",
      nativeCleanup: true,
    },
    null,
    2,
  ),
);
console.log("Source GUI acceptance passed; artifacts " + artifacts);
