// CHRM-M6 Phase D — Shared design-review test harness.
//
// Extracted verbatim from
// ``tests/e2e_design_review_history_button_in_real_editor.mjs`` so the
// gallery Playwright tests landing in CHRM-M6 don't each duplicate
// ~150 lines of daemon/Postgres/editor boot.
//
// Every spawn/temp-dir helper returns a teardown callback and ALSO
// registers a ``process.on('exit', ...)`` hook so a crashing test
// can't leak a Postgres cluster or an http.server. The convenience
// ``bootFullHarness`` composes them all and exposes a single
// ``teardownAll`` plus a curried ``seedCaptures``.
//
// IMPORTANT: helpers in this module preserve the exact behavior of
// the original test file. The signatures are designed so each helper
// is independently usable by tests that only need a subset (e.g. a
// pure DB test that doesn't need the editor server).

import { execSync, spawn } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  copyFileSync,
  writeFileSync,
  readFileSync,
  existsSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";

const __dirname = dirname(fileURLToPath(import.meta.url));
// tests/browser/lib/design_review_harness.mjs → projectRoot = isonim/
const projectRoot = join(__dirname, "..", "..", "..");
const DEFAULT_CLI_PATH = join(projectRoot, "build", "bin", "isonim-review");
const DEFAULT_EDITOR_BUILD = join(projectRoot, "build", "editor");
const DEFAULT_MIG_DIR = join(projectRoot, "db", "migrations");

// Track every teardown so we can flush on process.exit even if a test
// crashes before its own ``test.after`` runs.
const _exitTeardowns = new Set();
let _exitHookInstalled = false;

function _ensureExitHook() {
  if (_exitHookInstalled) return;
  _exitHookInstalled = true;
  process.on("exit", () => {
    for (const fn of _exitTeardowns) {
      try {
        fn();
      } catch {}
    }
  });
}

function _registerTeardown(fn) {
  _ensureExitHook();
  _exitTeardowns.add(fn);
  return () => {
    try {
      fn();
    } catch {}
    _exitTeardowns.delete(fn);
  };
}

function _exec(cmd, opts = {}) {
  return execSync(cmd, { stdio: "pipe", ...opts }).toString();
}

/**
 * Pick a free TCP port starting at ``base``. Returns the first port in
 * ``[base, base+200)`` that doesn't answer an HTTP ping. NOT a hard
 * guarantee — racey by design, sufficient for test harnesses.
 *
 * @param {number} base starting port to probe
 * @returns {number} a probably-free port
 */
export function pickPort(base) {
  for (let i = 0; i < 200; i++) {
    const c = base + ((Date.now() + i) % 200);
    try {
      execSync(`curl -s -o /dev/null --max-time 0.5 http://127.0.0.1:${c}/`, {
        stdio: "pipe",
      });
    } catch {
      return c;
    }
  }
  throw new Error("no free port");
}

/**
 * Boot a throwaway Postgres cluster in a temp directory.
 *
 * Creates two roles (``design_review_migrator``,
 * ``design_review_app``) and an ``isonim_design_review`` database
 * owned by the migrator, matching what the daemon expects.
 *
 * @param {object} [opts]
 * @param {number} [opts.basePort=5840] starting port for port probing
 * @param {string} [opts.tmpPrefix="isonim-revm8e-pg-"] mkdtemp prefix
 * @returns {Promise<{pgPort: number, pgDataDir: string, pgUrl: string, teardown: () => void}>}
 *   ``pgUrl`` is a convenience string ``host=127.0.0.1 port=<pgPort>``-style
 *   composite (i.e. the host + port, not a libpq URI) — most callers
 *   actually want the host/port separately for ``ISONIM_REVIEW_PG*``
 *   env vars, so ``pgPort`` is the primary return value.
 *   ``teardown`` stops the cluster + rm -rf's the data dir.
 */
export async function bootPg(opts = {}) {
  const { basePort = 5840, tmpPrefix = "isonim-revm8e-pg-" } = opts;
  const pgDataDir = mkdtempSync(join(tmpdir(), tmpPrefix));
  const pgPort = pickPort(basePort);
  _exec(`initdb --locale=C.UTF-8 --encoding=UTF8 --auth=trust -D ${pgDataDir}`);
  writeFileSync(
    join(pgDataDir, "postgresql.conf"),
    `\nlisten_addresses = '127.0.0.1'\nport = ${pgPort}\nunix_socket_directories = '${pgDataDir}'\n`,
    { flag: "a" },
  );
  _exec(
    `pg_ctl -D ${pgDataDir} -l ${join(pgDataDir, "log")} -w start </dev/null >/dev/null 2>&1`,
  );
  for (let i = 0; i < 60; i++) {
    try {
      execSync(`pg_isready -h 127.0.0.1 -p ${pgPort} -q`, { stdio: "pipe" });
      break;
    } catch {
      execSync("sleep 0.2");
    }
  }
  _exec(
    `psql -h 127.0.0.1 -p ${pgPort} -d postgres -v ON_ERROR_STOP=1 -c "CREATE ROLE design_review_migrator LOGIN"`,
  );
  _exec(
    `psql -h 127.0.0.1 -p ${pgPort} -d postgres -v ON_ERROR_STOP=1 -c "CREATE ROLE design_review_app LOGIN"`,
  );
  _exec(
    `createdb -h 127.0.0.1 -p ${pgPort} -O design_review_migrator isonim_design_review`,
  );
  const teardown = _registerTeardown(() => {
    try {
      _exec(`pg_ctl -D ${pgDataDir} stop -m fast`);
    } catch {}
    try {
      rmSync(pgDataDir, { recursive: true, force: true });
    } catch {}
  });
  // ``pgUrl`` here is the host:port for convenience — callers that need
  // the env-var triplet should read pgPort directly.
  const pgUrl = `127.0.0.1:${pgPort}`;
  return { pgPort, pgDataDir, pgUrl, teardown };
}

/**
 * Apply the design-review SQL migrations via ``isonim-review init``.
 *
 * Inherits ``ISONIM_REVIEW_PGHOST`` / ``ISONIM_REVIEW_PGPORT`` from
 * ``pgUrl`` (the ``host:port`` string returned by ``bootPg``). Pure
 * side effect — no teardown (migrations live in the DB and die when
 * the Postgres cluster shuts down).
 *
 * @param {string} pgUrl ``host:port`` composite from ``bootPg``
 * @param {object} [opts]
 * @param {string} [opts.cliPath]  override the ``isonim-review`` binary
 * @param {string} [opts.migDir]   override the migrations directory
 */
export async function applyMig(pgUrl, opts = {}) {
  const { cliPath = DEFAULT_CLI_PATH, migDir = DEFAULT_MIG_DIR } = opts;
  const [host, port] = pgUrl.split(":");
  _exec(`${cliPath} init --migrations ${migDir}`, {
    env: {
      ...process.env,
      ISONIM_REVIEW_PGHOST: host,
      ISONIM_REVIEW_PGPORT: String(port),
    },
  });
}

/**
 * Start the ``isonim-review serve`` daemon against a booted Postgres.
 *
 * @param {object} args
 * @param {string} args.pgUrl    ``host:port`` from ``bootPg``
 * @param {string} [args.storeDir] override store dir (default: fresh tmpdir)
 * @param {string} [args.cliPath] override the ``isonim-review`` binary
 * @param {string} [args.migDir]  override the migrations directory
 * @param {number} [args.basePort=18635] starting port for port probing
 * @returns {Promise<{httpPort: number, storeDir: string, daemonProc: import("node:child_process").ChildProcess, configPath: string, teardown: () => void}>}
 *   ``teardown`` SIGTERMs the daemon and rm -rf's the store dir
 *   (which it allocated unless the caller passed one in).
 */
export async function startDaemon(args) {
  const {
    pgUrl,
    storeDir: providedStoreDir,
    cliPath = DEFAULT_CLI_PATH,
    migDir = DEFAULT_MIG_DIR,
    basePort = 18635,
  } = args;
  const [host, port] = pgUrl.split(":");
  const httpPort = pickPort(basePort);
  const ownsStoreDir = !providedStoreDir;
  const storeDir =
    providedStoreDir || mkdtempSync(join(tmpdir(), "isonim-revm8e-store-"));
  const configPath = join(
    tmpdir(),
    `isonim-revm8e-config-${Date.now()}-${httpPort}.toml`,
  );
  writeFileSync(configPath, `[store]\npath = "${storeDir}"\n`);
  const daemonProc = spawn(
    cliPath,
    ["serve", "--migrations", migDir, "--config", configPath],
    {
      env: {
        ...process.env,
        ISONIM_REVIEW_PGHOST: host,
        ISONIM_REVIEW_PGPORT: String(port),
        ISONIM_REVIEW_PORT: String(httpPort),
      },
      stdio: "ignore",
    },
  );
  let ready = false;
  for (let i = 0; i < 80; i++) {
    try {
      execSync(
        `curl -s --max-time 1 -w '|%{http_code}' http://127.0.0.1:${httpPort}/health`,
        { stdio: "pipe" },
      );
      ready = true;
      break;
    } catch {
      execSync("sleep 0.15");
    }
  }
  if (!ready) {
    try {
      daemonProc.kill("SIGTERM");
    } catch {}
    throw new Error("daemon failed");
  }
  const teardown = _registerTeardown(() => {
    try {
      daemonProc.kill("SIGTERM");
    } catch {}
    if (ownsStoreDir) {
      try {
        rmSync(storeDir, { recursive: true, force: true });
      } catch {}
    }
    try {
      rmSync(configPath, { force: true });
    } catch {}
  });
  return { httpPort, storeDir, daemonProc, configPath, teardown };
}

/**
 * Copy ``build/editor`` into a fresh temp dir and inject the
 * ``<meta name="isonim-review-api">`` tag pointing at the spawned
 * daemon, so the editor's daemon-discovery loop picks our daemon
 * instead of the conventional default URL.
 *
 * Throws if ``build/editor`` is missing (run ``just editor-build``
 * first).
 *
 * @param {object} args
 * @param {number} args.daemonHttpPort the daemon port returned by ``startDaemon``
 * @param {string} [args.editorBuild]  override the editor build dir
 * @returns {Promise<{servingDir: string, teardown: () => void}>}
 *   ``teardown`` rm -rf's the temp serving dir.
 */
export async function prepareEditorServingDir(args) {
  const { daemonHttpPort, editorBuild = DEFAULT_EDITOR_BUILD } = args;
  if (
    !existsSync(join(editorBuild, "editor.js")) ||
    !existsSync(join(editorBuild, "index.html"))
  ) {
    throw new Error("build/editor missing — run ``just editor-build`` first");
  }
  const servingDir = mkdtempSync(join(tmpdir(), "isonim-revm8e-editor-"));
  copyFileSync(join(editorBuild, "editor.js"), join(servingDir, "editor.js"));
  const optionalFiles = [
    "fabric.min.js",
    "paper-core.min.js",
    "svgo.browser.js",
  ];
  for (const f of optionalFiles) {
    const src = join(editorBuild, f);
    if (existsSync(src)) copyFileSync(src, join(servingDir, f));
  }
  let html = readFileSync(join(editorBuild, "index.html"), "utf8");
  const meta = `<meta name="isonim-review-api" content="http://127.0.0.1:${daemonHttpPort}">`;
  if (html.includes("<head>")) {
    html = html.replace("<head>", "<head>\n" + meta);
  } else {
    html = meta + "\n" + html;
  }
  writeFileSync(join(servingDir, "index.html"), html);
  const teardown = _registerTeardown(() => {
    try {
      rmSync(servingDir, { recursive: true, force: true });
    } catch {}
  });
  return { servingDir, teardown };
}

/**
 * Start a ``python3 -m http.server`` to serve the prepared editor
 * directory. Detached so SIGTERM of the spawned process group cleans
 * up reliably even if node exits ungracefully.
 *
 * Sleeps 1s to give the server time to bind before the first request
 * (matches the original test).
 *
 * @param {object} args
 * @param {string} args.servingDir prepared dir from ``prepareEditorServingDir``
 * @param {number} args.port       port to bind
 * @returns {Promise<{pageServer: import("node:child_process").ChildProcess, editorUrl: string, teardown: () => void}>}
 *   ``teardown`` SIGTERMs the entire process group so the python server dies.
 */
export async function startEditorServer(args) {
  const { servingDir, port } = args;
  const pageServer = spawn(
    "python3",
    ["-m", "http.server", String(port), "--bind", "127.0.0.1"],
    { cwd: servingDir, stdio: "ignore", detached: true },
  );
  execSync("sleep 1");
  const teardown = _registerTeardown(() => {
    try {
      process.kill(-pageServer.pid);
    } catch {}
  });
  const editorUrl = `http://127.0.0.1:${port}/`;
  return { pageServer, editorUrl, teardown };
}

const TINY_PNG = Buffer.from(
  "89504e470d0a1a0a0000000d49484452000000010000000108020000009077" +
    "53de0000000c4944415478" +
    "9c63000100000500010d2db40000000049454e44ae426082",
  "hex",
);

function _putPngInStore(storeDir, buf) {
  const sha = createHash("sha256").update(buf).digest("hex");
  const dir = join(storeDir, sha.slice(0, 2));
  mkdirSync(dir, { recursive: true });
  const path = join(dir, sha + ".png");
  writeFileSync(path, buf);
  return { sha, path };
}

/**
 * Seed a brief + one or more captures into the design-review DB and
 * store. Used to make ``brief-has-history`` resolve to true before the
 * browser polls.
 *
 * The default ``captures`` argument seeds a single tiny-PNG capture
 * with reasonable mobile-ish defaults — matching what the original
 * test did via the ``briefId``-only call. Each entry may override
 * ``storyId``, ``platform``, ``deviceClass``, ``width``, ``height``,
 * ``png`` (Buffer), and ``runArgs`` (``{ snapshotHash, recordedBy }``).
 *
 * @param {object} args
 * @param {string} args.pgUrl    ``host:port`` from ``bootPg``
 * @param {string} args.storeDir store directory from ``startDaemon``
 * @param {string} args.briefId  brief id (e.g. ``"render/task-app"``)
 * @param {Array<object>} [args.captures] capture descriptors (see above)
 * @returns {Promise<{runId: string, captureRefs: Array<{sha: string, path: string}>}>}
 */
export async function seedBriefWithHistory(args) {
  const {
    pgUrl,
    storeDir,
    briefId,
    captures = [
      {
        storyId: "p/x:page#0@web",
        platform: "web",
        deviceClass: "mobile",
        width: 320,
        height: 568,
      },
    ],
  } = args;
  const [host, port] = pgUrl.split(":");
  const psqlBase = `psql -h ${host} -p ${port} -d isonim_design_review -A -t -v ON_ERROR_STOP=1`;
  const firstRunArgs = captures[0]?.runArgs || {
    snapshotHash: "h1",
    recordedBy: "tester",
  };
  const runId = execSync(
    `${psqlBase} -c "SELECT design_review.start_run('${briefId}', '${firstRunArgs.snapshotHash}', '${firstRunArgs.recordedBy}')"`,
    { stdio: "pipe" },
  )
    .toString()
    .trim();
  const captureRefs = [];
  for (const c of captures) {
    const png = _putPngInStore(storeDir, c.png || TINY_PNG);
    captureRefs.push(png);
    execSync(
      `${psqlBase} -c "SELECT design_review.record_capture('${runId}'::uuid, '${c.storyId}', '${c.platform}', '${c.deviceClass}', '${png.sha}', '${png.path}', ${c.width}, ${c.height})"`,
      { stdio: "pipe" },
    );
  }
  return { runId, captureRefs };
}

/**
 * Convenience: boot Postgres + apply migrations + start daemon +
 * prepare the editor serving dir + start the http.server in order.
 * Returns everything tests typically need plus an aggregate
 * ``teardownAll`` and a curried ``seedCaptures`` that's already bound
 * to the booted pgUrl + storeDir.
 *
 * @param {object} [opts]
 * @param {number} [opts.editorPort] port for the python http.server (default: dynamic)
 * @param {string} [opts.cliPath]    override the ``isonim-review`` binary
 * @param {string} [opts.migDir]     override migrations dir
 * @param {string} [opts.editorBuild] override ``build/editor``
 * @returns {Promise<{
 *   pgUrl: string,
 *   pgPort: number,
 *   storeDir: string,
 *   daemonHttpPort: number,
 *   editorUrl: string,
 *   teardownAll: () => void,
 *   seedCaptures: (briefId: string, captures?: Array<object>) => Promise<{runId: string, captureRefs: Array<{sha: string, path: string}>}>,
 * }>}
 */
export async function bootFullHarness(opts = {}) {
  const {
    editorPort,
    cliPath = DEFAULT_CLI_PATH,
    migDir = DEFAULT_MIG_DIR,
    editorBuild = DEFAULT_EDITOR_BUILD,
  } = opts;
  if (!existsSync(cliPath)) throw new Error("CLI missing: " + cliPath);
  const pg = await bootPg();
  let daemon, serving, server;
  try {
    await applyMig(pg.pgUrl, { cliPath, migDir });
    daemon = await startDaemon({ pgUrl: pg.pgUrl, cliPath, migDir });
    serving = await prepareEditorServingDir({
      daemonHttpPort: daemon.httpPort,
      editorBuild,
    });
    const port = editorPort || pickPort(18495);
    server = await startEditorServer({
      servingDir: serving.servingDir,
      port,
    });
  } catch (e) {
    // Aggregate cleanup if any step fails mid-boot.
    try {
      server?.teardown();
    } catch {}
    try {
      serving?.teardown();
    } catch {}
    try {
      daemon?.teardown();
    } catch {}
    try {
      pg.teardown();
    } catch {}
    throw e;
  }
  const teardownAll = () => {
    try {
      server.teardown();
    } catch {}
    try {
      serving.teardown();
    } catch {}
    try {
      daemon.teardown();
    } catch {}
    try {
      pg.teardown();
    } catch {}
  };
  const seedCaptures = (briefId, captures) =>
    seedBriefWithHistory({
      pgUrl: pg.pgUrl,
      storeDir: daemon.storeDir,
      briefId,
      captures,
    });
  return {
    pgUrl: pg.pgUrl,
    pgPort: pg.pgPort,
    storeDir: daemon.storeDir,
    daemonHttpPort: daemon.httpPort,
    editorUrl: server.editorUrl,
    teardownAll,
    seedCaptures,
  };
}
