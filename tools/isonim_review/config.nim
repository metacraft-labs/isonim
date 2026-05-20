## REV-M4 — ``isonim-review`` configuration loader.
##
## Resolution order (highest priority first):
##
##   1. Environment: ``$ISONIM_REVIEW_DB`` (full libpq URL),
##      ``$ISONIM_REVIEW_PORT`` (HTTP listen port).
##   2. ``~/.isonim/config.toml`` if present.
##   3. Built-in defaults.
##
## TOML schema (mirrors the milestone description):
##
##   [db]
##   host = "127.0.0.1"
##   port = 5533
##   database = "isonim_design_review"
##   app_user = "design_review_app"
##   migrator_user = "design_review_migrator"
##
##   [server]
##   bind = "127.0.0.1"
##   port = 8113
##
##   [store]
##   path = "~/.isonim/review-store"
##
##   [workspace]
##   root = "~/metacraft"
##
## We deliberately hand-roll a minimal TOML reader (only the keys above,
## only string and integer scalars, only ``[section]`` blocks).  This is
## the same dependency-discipline decision REV-M1 took for its YAML
## subset: the project's nimble shell is fragile under
## ``aarch64-darwin`` and adding ``parsetoml`` would tighten the toolchain
## without buying enough flexibility — the schema is closed and tiny.

import std/[os, parseutils, strutils]

import nim_agents

type
  DbConfig* = object
    host*: string
    port*: int
    database*: string
    appUser*: string
    migratorUser*: string
    ## Optional full URL override.  When non-empty wins over the
    ## host/port/database trio: used by ``$ISONIM_REVIEW_DB`` and by
    ## tests that need a non-default user in the connection string.
    url*: string

  ServerConfig* = object
    bindAddr*: string
    port*: int

  StoreConfig* = object
    path*: string

  WorkspaceConfig* = object
    root*: string

  BackendConfig* = object
    binaryDir*: string
      ## Optional directory holding ``isonim-examples-<backend>``
      ## launcher binaries.  Empty means "fall back to env +
      ## ``~/.isonim/backends/`` + ``<workspace>/isonim-examples/build/
      ## backends/``" — see
      ## ``isonim/editor/design_review/backend_launcher.resolveBackendBinary``.

  CodexAgentConfig* = object
    ## Follow-up 2 — per-backend Codex knobs.  Today only ``model``
    ## (which is the ChatGPT-subscription–scoped model name like
    ## ``"gpt-5.5"``).  The daemon turns this into ``codex-acp -c
    ## model=<name>`` automatically.
    model*: string

  ClaudeAgentConfig* = object
    ## Follow-up 2 — per-backend Claude knobs.  ``model`` is currently
    ## informational: ``claude-agent-acp`` reads its model preference
    ## from ``~/.claude/settings.json`` and from the in-session
    ## ``session/set_model`` ACP call, not from a CLI flag.  The daemon
    ## therefore records the configured model but cannot pass it as
    ## a binary argv; ``claudeExtraArgs`` returns ``@[]`` until the
    ## upstream binary grows a ``--model`` flag.
    model*: string

  AgentConfig* = object
    ## Phase B — the daemon's ACP backend configuration.
    ##
    ##   * ``backend`` selects between the supported ACP servers
    ##     (``"claude"``, ``"codex"``, ``"custom"``); the resolved
    ##     :type:`AcpAgentKind` value is exposed via
    ##     :proc:`agentBackendKind`.  Default: ``"claude"`` (no
    ##     behaviour change for existing users).
    ##   * ``command`` overrides the agent binary on PATH (defaults
    ##     to ``claude-agent-acp`` / ``claude-code-acp`` for the
    ##     ``"claude"`` backend, ``codex-acp`` for ``"codex"``).  For
    ##     ``backend = "custom"`` it is *mandatory* and points at the
    ##     stdio-ACP binary to spawn.
    ##   * ``args`` is the custom backend's argv tail; ignored for
    ##     ``"claude"`` and ``"codex"``.
    ##   * ``model`` and ``maxTokens`` are advisory hints the daemon
    ##     passes through to the agent on session creation.
    ##   * ``defaultDaemonUrl`` is the URL the CLI's ``chat`` subcommand
    ##     uses when no ``--daemon`` flag is supplied.
    ##   * ``codex`` / ``claude`` carry the per-backend model selectors
    ##     introduced by follow-up 2.  See :proc:`codexExtraArgs` and
    ##     :proc:`claudeExtraArgs` for how they reach the spawned ACP
    ##     binary's argv.
    backend*: string
    command*: string
    args*: seq[string]
    extraArgs*: seq[string]
    model*: string
    maxTokens*: int
    defaultDaemonUrl*: string
    codex*: CodexAgentConfig
    claude*: ClaudeAgentConfig
    httpTimeoutMs*: int
      ## Follow-up — HTTP read timeout (ms) the CLI's
      ## :proc:`daemonBackend` applies when POSTing the reviewer prompt
      ## to the daemon's ``/api/agent/prompts`` SSE endpoint.  The
      ## request legitimately blocks for the *whole* agent turn — 60 s
      ## to 5+ minutes for image-heavy review prompts — so the
      ## historical hard-coded 60_000 ms here was the second of two
      ## stacked timeouts that killed real-codex reviews mid-stream.
      ## Default :const:`DefaultAgentHttpTimeoutMs` (30 min) matches the
      ## nim-acp transport's wall-clock cap so the CLI and the daemon's
      ## ACP layer fail at the same overall budget.  Operator overrides:
      ##   * TOML: ``[agent].http_timeout_ms = <int>``
      ##   * Env:  ``ISONIM_AGENT_HTTP_TIMEOUT_MS=<int>``
      ##   * CLI:  ``run-review --agent-http-timeout-ms=<int>``
    campaignIdleTimeoutMs*: int
      ## CMP-M2.1 — per-frame idle silence budget on the stdio-ACP
      ## transport for campaign sessions.  Default 900_000 ms (15 min):
      ## the campaign orchestrator legitimately stays silent across
      ## long sub-agent dispatches before emitting its next
      ## ``session/update`` frame, and the default 5-minute idle cap
      ## used by chat / one-shot sessions ended round 2 of the CMP-M2
      ## experiment with ``stopReason: error`` after the orchestrator
      ## paused for ~5 minutes mid-tool-call.  Operator overrides:
      ##   * TOML: ``[agent].campaign_idle_timeout_ms = <int>``
      ##   * Env:  ``ISONIM_CAMPAIGN_IDLE_TIMEOUT_MS=<int>``
    campaignAutoTickDelayMs*: int
      ## CMP-M2.1 — delay (ms) between a ``round_complete`` whose
      ## ORCHESTRATOR_STATUS marker carries ``reason=tick_ready`` and
      ## the daemon's auto-scheduled follow-up tick.  Default 2_000 ms:
      ## small enough that the campaign drives forward briskly,
      ## large enough that tests / operators can still observe the
      ## ``round_complete`` row before the next ``round_started``
      ## lands.  Operator overrides:
      ##   * TOML: ``[agent].campaign_auto_tick_delay_ms = <int>``
      ##   * Env:  ``ISONIM_CAMPAIGN_AUTOTICK_DELAY_MS=<int>``
    campaignAutoTickDisabled*: bool
      ## CMP-M2.1 — test hook.  When true, the daemon parses the
      ## ORCHESTRATOR_STATUS marker and records the parsed fields on
      ## the ``round_complete`` event but does NOT schedule the
      ## follow-up tick.  Used by ``test_round_counter_increments``
      ## which drives explicit ``campaign tick`` calls and would
      ## otherwise race the auto-tick.  Operator overrides:
      ##   * Env:  ``ISONIM_CAMPAIGN_AUTOTICK_DISABLED=1``
    assistantPromptPath*: string
      ## CMP-M5 — absolute path to the AI Assistant system prompt
      ## file that the daemon prepends to every chat session via the
      ## "primer" round-trip on ``POST /api/agent/sessions``.  When
      ## empty (the default) the daemon resolves it to
      ## ``<workspace>/isonim/prompts/ai-assistant.md``.  When the
      ## resolved file doesn't exist the daemon logs a warning and
      ## falls back to a tiny built-in placeholder — chat sessions
      ## stay functional even on broken installs.  Operator overrides:
      ##   * TOML: ``[agent].assistant_prompt_path = "<abs path>"``
      ##   * Env:  ``ISONIM_ASSISTANT_PROMPT_PATH=<abs path>``
    primerEnabled*: bool
      ## CMP-M5 — when true (default) every chat ACP session created
      ## via ``POST /api/agent/sessions`` is primed with the AI
      ## Assistant system prompt + project context before the
      ## sessionId is returned to the caller.  Set to false to skip
      ## the primer round-trip — useful for CLI-only callers and
      ## tests that want to drive a raw agent.  Operator overrides:
      ##   * TOML: ``[agent].primer_enabled = true|false``
      ##   * Env:  ``ISONIM_ASSISTANT_PRIMER_ENABLED=0|1``

  ReviewConfig* = object
    db*: DbConfig
    server*: ServerConfig
    store*: StoreConfig
    workspace*: WorkspaceConfig
    backend*: BackendConfig
    agent*: AgentConfig
    ## Path the loader actually read TOML from (empty if defaults only).
    configPath*: string

const
  DefaultDbHost* = "127.0.0.1"
  DefaultDbPort* = 5533
  DefaultDbName* = "isonim_design_review"
  DefaultAppUser* = "design_review_app"
  DefaultMigratorUser* = "design_review_migrator"
  DefaultServerBind* = "127.0.0.1"
  DefaultServerPort* = 8113
  DefaultStorePath* = "~/.isonim/review-store"
  DefaultWorkspaceRoot* = "~/metacraft"
  DefaultCodexModel* = "gpt-5.5"
    ## Follow-up 2 — the codex-acp default the user's ChatGPT
    ## subscription is expected to have access to.  The upstream
    ## ``codex-acp`` binary defaults to ``gpt-5.2-codex`` which most
    ## subscriptions don't carry, so we ship a saner default and let
    ## the operator override via TOML, env, or CLI flag.
  DefaultClaudeModel* = ""
    ## Follow-up 2 — claude-agent-acp doesn't accept a CLI ``--model``
    ## flag (model preference lives in ``~/.claude/settings.json`` and
    ## in the in-session ``session/set_model`` call), so we leave the
    ## default empty and let the binary pick its own.
  DefaultCampaignIdleTimeoutMs* = 900_000
    ## CMP-M2.1 — 15-minute idle cap for campaign ACP sessions.  See
    ## :type:`AgentConfig.campaignIdleTimeoutMs` for the rationale.
  DefaultCampaignAutoTickDelayMs* = 2_000
    ## CMP-M2.1 — 2-second pause between ``round_complete`` and the
    ## auto-scheduled follow-up tick.  See
    ## :type:`AgentConfig.campaignAutoTickDelayMs`.
  DefaultAssistantPromptRelPath* = "isonim/prompts/ai-assistant.md"
    ## CMP-M5 — relative path under the workspace root that resolves
    ## to the AI Assistant system prompt when
    ## ``[agent].assistant_prompt_path`` is empty.  Mirrors how
    ## ``OrchestratorPromptRelPath`` works for the campaign side.
  DefaultPrimerEnabled* = true
    ## CMP-M5 — the daemon primes new chat sessions by default; set
    ## ``[agent].primer_enabled = false`` (or ``ISONIM_ASSISTANT_PRIMER_ENABLED=0``)
    ## to opt back into the raw-agent behaviour.
  DefaultAgentHttpTimeoutMs* = 1_800_000
    ## Follow-up — 30 minute HTTP timeout for the CLI ➝ daemon
    ## ``/api/agent/prompts`` SSE POST.  Matches the nim-acp transport's
    ## :const:`DefaultNativeStdioHardDeadlineMs` so the two layers cap
    ## at the same wall-clock budget.  The previous hard-coded 60_000
    ## ms in ``agent_dispatch.nim`` aborted real-codex image reviews
    ## around 124 s wall-clock (60 s read timeout × two POSTs);
    ## image-heavy review prompts legitimately need minutes of agent
    ## first-byte latency.

proc defaultConfigPath*(): string =
  ## ``~/.isonim/config.toml`` — the on-disk location every CLI command
  ## reads from when ``--config`` isn't given.
  getHomeDir() / ".isonim" / "config.toml"

proc expandTilde*(path: string): string =
  ## Expand a leading ``~`` to ``$HOME``.  Used uniformly across config
  ## keys so the user never has to spell out ``/Users/...`` in TOML.
  if path.len == 0:
    return path
  if path == "~":
    return getHomeDir()
  if path.startsWith("~/"):
    return getHomeDir() / path[2 .. ^1]
  path

proc defaults*(): ReviewConfig =
  ## Built-in defaults — what the CLI uses when no TOML file exists and
  ## no environment variables override anything.
  result = ReviewConfig(
    db: DbConfig(
      host: DefaultDbHost,
      port: DefaultDbPort,
      database: DefaultDbName,
      appUser: DefaultAppUser,
      migratorUser: DefaultMigratorUser,
      url: "",
    ),
    server: ServerConfig(
      bindAddr: DefaultServerBind,
      port: DefaultServerPort,
    ),
    store: StoreConfig(
      path: expandTilde(DefaultStorePath),
    ),
    workspace: WorkspaceConfig(
      root: expandTilde(DefaultWorkspaceRoot),
    ),
    backend: BackendConfig(
      binaryDir: "",
    ),
    agent: AgentConfig(
      backend: "claude",
      command: "",
      args: @[],
      extraArgs: @[],
      model: "",
      maxTokens: 0,
      defaultDaemonUrl: "",
      codex: CodexAgentConfig(model: DefaultCodexModel),
      claude: ClaudeAgentConfig(model: DefaultClaudeModel),
      httpTimeoutMs: DefaultAgentHttpTimeoutMs,
      campaignIdleTimeoutMs: DefaultCampaignIdleTimeoutMs,
      campaignAutoTickDelayMs: DefaultCampaignAutoTickDelayMs,
      campaignAutoTickDisabled: false,
      assistantPromptPath: "",
      primerEnabled: DefaultPrimerEnabled,
    ),
    configPath: "",
  )

# ---------------------------------------------------------------------------
# Minimal TOML reader.
#
# Supports exactly:
#   * ``# comment`` and blank lines
#   * ``[section]`` and ``[section.sub]`` (we only look at the first
#     component below)
#   * ``key = "string"`` and ``key = 1234`` and ``key = true``
#
# That's enough for the closed schema above.  Anything fancier
# (multi-line strings, arrays, inline tables) is rejected loudly so a
# user who needs it knows to ask for the proper parser.
# ---------------------------------------------------------------------------

type
  TomlValueKind = enum tvkString, tvkInt, tvkBool, tvkStringArray
  TomlValue = object
    case kind: TomlValueKind
    of tvkString: s: string
    of tvkInt: i: int
    of tvkBool: b: bool
    of tvkStringArray: arr: seq[string]

  TomlParseError* = object of CatchableError

proc parseStringLiteral(s: string; lineNo: int): string =
  ## Parse a ``"..."`` literal.  Backslash escapes restricted to ``\\``,
  ## ``\"``, ``\n``, ``\t`` — same subset TOML basic strings require.
  if s.len < 2 or s[0] != '"' or s[^1] != '"':
    raise newException(TomlParseError,
      "line " & $lineNo & ": expected double-quoted string, got: " & s)
  result = newStringOfCap(s.len - 2)
  var i = 1
  while i < s.len - 1:
    let ch = s[i]
    if ch == '\\':
      inc i
      if i >= s.len - 1:
        raise newException(TomlParseError,
          "line " & $lineNo & ": trailing backslash in string")
      case s[i]
      of '\\': result.add '\\'
      of '"': result.add '"'
      of 'n': result.add '\n'
      of 't': result.add '\t'
      else:
        raise newException(TomlParseError,
          "line " & $lineNo & ": unsupported escape \\" & s[i])
      inc i
    else:
      result.add ch
      inc i

proc parseStringArray(raw: string; lineNo: int): seq[string] =
  ## Parse ``[ "a", "b" ]`` — only string elements supported. Trailing
  ## commas allowed. Whitespace between commas/items ignored.
  if raw.len < 2 or raw[0] != '[' or raw[^1] != ']':
    raise newException(TomlParseError,
      "line " & $lineNo & ": expected ``[ ... ]`` array, got: " & raw)
  let inner = raw[1 .. ^2].strip()
  if inner.len == 0:
    return @[]
  var i = 0
  while i < inner.len:
    # Skip whitespace and commas between items.
    while i < inner.len and inner[i] in {' ', '\t', ','}:
      inc i
    if i >= inner.len:
      break
    if inner[i] != '"':
      raise newException(TomlParseError,
        "line " & $lineNo & ": array elements must be quoted strings")
    # Find the matching closing quote, honouring backslash escapes.
    var j = i + 1
    while j < inner.len:
      if inner[j] == '\\' and j + 1 < inner.len:
        inc j, 2
        continue
      if inner[j] == '"':
        break
      inc j
    if j >= inner.len:
      raise newException(TomlParseError,
        "line " & $lineNo & ": unterminated string in array")
    result.add parseStringLiteral(inner[i .. j], lineNo)
    i = j + 1

proc parseTomlValue(raw: string; lineNo: int): TomlValue =
  ## Parse the right-hand side of a ``key = value`` line.  ``raw`` is
  ## already stripped of surrounding whitespace and trailing comment.
  if raw.len == 0:
    raise newException(TomlParseError,
      "line " & $lineNo & ": empty value")
  if raw[0] == '"':
    return TomlValue(kind: tvkString, s: parseStringLiteral(raw, lineNo))
  if raw[0] == '[':
    return TomlValue(kind: tvkStringArray,
                     arr: parseStringArray(raw, lineNo))
  if raw == "true":
    return TomlValue(kind: tvkBool, b: true)
  if raw == "false":
    return TomlValue(kind: tvkBool, b: false)
  # Integer.  We don't support negative or hex/octal — overkill here.
  var i: int
  let consumed = parseInt(raw, i, 0)
  if consumed != raw.len:
    raise newException(TomlParseError,
      "line " & $lineNo & ": unsupported value (only string, int, bool, string array): " & raw)
  TomlValue(kind: tvkInt, i: i)

proc stripTrailingComment(s: string): string =
  ## Drop ``# ...`` from the end of a line — but only if the ``#`` is
  ## not inside a ``"..."`` string literal.
  var inStr = false
  var escaped = false
  for i, ch in s:
    if escaped:
      escaped = false
      continue
    if ch == '\\' and inStr:
      escaped = true
      continue
    if ch == '"':
      inStr = not inStr
      continue
    if ch == '#' and not inStr:
      return s[0 ..< i]
  s

proc applyToml(cfg: var ReviewConfig; content: string) =
  ## Parse the TOML ``content`` and apply each known key onto ``cfg``.
  ## Unknown sections and keys are reported as warnings on stderr so
  ## typos are visible without bombing the entire CLI.
  var section = ""
  var lineNo = 0
  for rawLine in content.splitLines():
    inc lineNo
    let stripped = stripTrailingComment(rawLine).strip()
    if stripped.len == 0:
      continue
    if stripped[0] == '[' and stripped[^1] == ']':
      section = stripped[1 .. ^2].strip()
      continue
    let eq = stripped.find('=')
    if eq < 0:
      raise newException(TomlParseError,
        "line " & $lineNo & ": expected ``key = value`` got: " & stripped)
    let key = stripped[0 ..< eq].strip()
    let valRaw = stripped[eq + 1 .. ^1].strip()
    let v = parseTomlValue(valRaw, lineNo)
    case section
    of "db":
      case key
      of "host":
        if v.kind == tvkString: cfg.db.host = v.s
      of "port":
        if v.kind == tvkInt: cfg.db.port = v.i
      of "database":
        if v.kind == tvkString: cfg.db.database = v.s
      of "app_user":
        if v.kind == tvkString: cfg.db.appUser = v.s
      of "migrator_user":
        if v.kind == tvkString: cfg.db.migratorUser = v.s
      of "url":
        if v.kind == tvkString: cfg.db.url = v.s
      else:
        stderr.writeLine("isonim-review config: unknown key [db]." & key)
    of "server":
      case key
      of "bind":
        if v.kind == tvkString: cfg.server.bindAddr = v.s
      of "port":
        if v.kind == tvkInt: cfg.server.port = v.i
      else:
        stderr.writeLine("isonim-review config: unknown key [server]." & key)
    of "store":
      case key
      of "path":
        if v.kind == tvkString: cfg.store.path = expandTilde(v.s)
      else:
        stderr.writeLine("isonim-review config: unknown key [store]." & key)
    of "workspace":
      case key
      of "root":
        if v.kind == tvkString: cfg.workspace.root = expandTilde(v.s)
      else:
        stderr.writeLine("isonim-review config: unknown key [workspace]." & key)
    of "backend":
      case key
      of "binary_dir":
        if v.kind == tvkString: cfg.backend.binaryDir = expandTilde(v.s)
      else:
        stderr.writeLine("isonim-review config: unknown key [backend]." & key)
    of "agent":
      case key
      of "backend":
        if v.kind == tvkString: cfg.agent.backend = v.s
      of "command":
        if v.kind == tvkString: cfg.agent.command = v.s
      of "args":
        if v.kind == tvkStringArray: cfg.agent.args = v.arr
      of "model":
        if v.kind == tvkString: cfg.agent.model = v.s
      of "max_tokens":
        if v.kind == tvkInt: cfg.agent.maxTokens = v.i
      of "default_daemon_url":
        if v.kind == tvkString: cfg.agent.defaultDaemonUrl = v.s
      of "http_timeout_ms":
        if v.kind == tvkInt: cfg.agent.httpTimeoutMs = v.i
      of "campaign_idle_timeout_ms":
        if v.kind == tvkInt: cfg.agent.campaignIdleTimeoutMs = v.i
      of "campaign_auto_tick_delay_ms":
        if v.kind == tvkInt: cfg.agent.campaignAutoTickDelayMs = v.i
      of "assistant_prompt_path":
        if v.kind == tvkString: cfg.agent.assistantPromptPath = expandTilde(v.s)
      of "primer_enabled":
        if v.kind == tvkBool: cfg.agent.primerEnabled = v.b
      else:
        stderr.writeLine("isonim-review config: unknown key [agent]." & key)
    of "agent.codex":
      case key
      of "model":
        if v.kind == tvkString: cfg.agent.codex.model = v.s
      else:
        stderr.writeLine("isonim-review config: unknown key [agent.codex]." & key)
    of "agent.claude":
      case key
      of "model":
        if v.kind == tvkString: cfg.agent.claude.model = v.s
      else:
        stderr.writeLine("isonim-review config: unknown key [agent.claude]." & key)
    else:
      stderr.writeLine("isonim-review config: unknown section [" &
        section & "]")

type
  AgentConfigError* = object of CatchableError
    ## Raised when the ``[agent]`` section is internally inconsistent
    ## (unknown backend, ``backend = "custom"`` without ``command``,
    ## etc.).

proc agentBackendKind*(cfg: ReviewConfig): AcpAgentKind =
  ## Resolve ``[agent].backend`` to the typed :type:`AcpAgentKind`.
  ## An unknown / typo'd value raises :type:`AgentConfigError` so the
  ## operator sees the misconfiguration at load time rather than
  ## later when the daemon tries to spawn the wrong binary.
  case cfg.agent.backend.toLowerAscii()
  of "", "claude", "claude-code", "claude-code-acp", "claude-agent-acp":
    aakClaude
  of "codex", "codex-acp":
    aakCodex
  of "custom":
    aakCustom
  else:
    raise newException(AgentConfigError,
      "isonim-review config: unknown [agent].backend = \"" &
      cfg.agent.backend & "\" (expected one of: claude, codex, custom)")

proc validateAgentConfig*(cfg: ReviewConfig) =
  ## Cross-check the ``[agent]`` keys for consistency. Called from
  ## :proc:`loadConfig` so the failure surfaces at config load.
  let kind = agentBackendKind(cfg)
  if kind == aakCustom and cfg.agent.command.len == 0:
    raise newException(AgentConfigError,
      "isonim-review config: [agent].backend = \"custom\" requires " &
      "[agent].command to point at the stdio-ACP binary to spawn")

proc parsePortFromUrl(url: string): int =
  ## Pull the ``:PORT`` segment out of a libpq URL.  Returns 0 if not
  ## present — callers fall back to the existing port.
  ##
  ## Accepts ``postgres://[user[:pw]@]host:port/db`` and the variant
  ## without scheme prefix.
  var s = url
  let schemeIdx = s.find("://")
  if schemeIdx >= 0:
    s = s[schemeIdx + 3 .. ^1]
  let at = s.rfind('@')
  if at >= 0:
    s = s[at + 1 .. ^1]
  let slash = s.find('/')
  if slash >= 0:
    s = s[0 ..< slash]
  let colon = s.rfind(':')
  if colon < 0:
    return 0
  var port: int
  if parseInt(s[colon + 1 .. ^1], port, 0) > 0:
    return port
  0

proc loadConfig*(explicitPath: string = ""): ReviewConfig =
  ## Build the resolved ``ReviewConfig``:
  ##
  ##   defaults ← TOML(``explicitPath`` or ``~/.isonim/config.toml``)
  ##            ← env overrides
  ##
  ## TOML is optional — missing file means defaults stand.  Parsing
  ## errors raise ``TomlParseError``.
  result = defaults()
  let path =
    if explicitPath.len > 0: explicitPath
    else: defaultConfigPath()
  if fileExists(path):
    let content =
      try: readFile(path)
      except IOError as e:
        raise newException(TomlParseError,
          "isonim-review: cannot read " & path & ": " & e.msg)
    applyToml(result, content)
    result.configPath = path

  # Env overrides — last, so they win over both defaults and TOML.
  let envUrl = getEnv("ISONIM_REVIEW_DB")
  if envUrl.len > 0:
    result.db.url = envUrl
    # Surface the port for any consumer that just compares against
    # ``cfg.db.port``.  Keeps the loader's contract simple: callers who
    # care about the wire URL use ``connectionString``, callers that
    # match against a port number use ``cfg.db.port``.
    let p = parsePortFromUrl(envUrl)
    if p > 0:
      result.db.port = p

  let envPort = getEnv("ISONIM_REVIEW_PORT")
  if envPort.len > 0:
    var p: int
    if parseInt(envPort, p, 0) > 0:
      result.server.port = p

  let envPgPort = getEnv("ISONIM_REVIEW_PGPORT")
  if envPgPort.len > 0 and envUrl.len == 0:
    # Convenience: respect the same env var the dev shell sets so
    # ``ISONIM_REVIEW_PGPORT=5599 isonim-review db-health`` works
    # without writing a full URL.
    var p: int
    if parseInt(envPgPort, p, 0) > 0:
      result.db.port = p

  let envPgHost = getEnv("ISONIM_REVIEW_PGHOST")
  if envPgHost.len > 0 and envUrl.len == 0:
    result.db.host = envPgHost

  # ``ISONIM_AGENT_BACKEND`` is the env-level CLI override used by
  # automation that doesn't want to write a TOML file (notably the
  # smoke targets in this repo's Justfile).  Setting it to a known
  # value here keeps ``agentBackendKind(cfg)`` and the CLI flag in
  # sync.
  let envBackend = getEnv("ISONIM_AGENT_BACKEND")
  if envBackend.len > 0:
    result.agent.backend = envBackend

  # Follow-up 2 — per-backend model env overrides.  These win over
  # TOML but lose to ``--codex-model=`` / ``--claude-model=`` on the
  # CLI (the dispatcher applies the flag last).
  let envCodexModel = getEnv("ISONIM_CODEX_MODEL")
  if envCodexModel.len > 0:
    result.agent.codex.model = envCodexModel
  let envClaudeModel = getEnv("ISONIM_CLAUDE_MODEL")
  if envClaudeModel.len > 0:
    result.agent.claude.model = envClaudeModel

  # Follow-up — HTTP timeout env override.  Wins over TOML; loses to
  # ``run-review --agent-http-timeout-ms=`` (the dispatcher applies the
  # flag last).
  let envHttpTimeout = getEnv("ISONIM_AGENT_HTTP_TIMEOUT_MS")
  if envHttpTimeout.len > 0:
    var n: int
    if parseInt(envHttpTimeout, n, 0) > 0 and n > 0:
      result.agent.httpTimeoutMs = n
    else:
      stderr.writeLine("isonim-review config: ignored ISONIM_AGENT_HTTP_TIMEOUT_MS=\"" &
        envHttpTimeout & "\" (expected positive integer ms)")

  # CMP-M2.1 — campaign-session idle timeout env override.  Wins over
  # TOML.  Empty / non-numeric values are ignored with a stderr note
  # so the operator notices the misconfiguration.
  let envCampaignIdle = getEnv("ISONIM_CAMPAIGN_IDLE_TIMEOUT_MS")
  if envCampaignIdle.len > 0:
    var n: int
    if parseInt(envCampaignIdle, n, 0) > 0 and n > 0:
      result.agent.campaignIdleTimeoutMs = n
    else:
      stderr.writeLine("isonim-review config: ignored ISONIM_CAMPAIGN_IDLE_TIMEOUT_MS=\"" &
        envCampaignIdle & "\" (expected positive integer ms)")

  # CMP-M2.1 — campaign auto-tick delay env override.  Wins over TOML.
  let envCampaignAutoTick = getEnv("ISONIM_CAMPAIGN_AUTOTICK_DELAY_MS")
  if envCampaignAutoTick.len > 0:
    var n: int
    if parseInt(envCampaignAutoTick, n, 0) > 0 and n >= 0:
      result.agent.campaignAutoTickDelayMs = n
    else:
      stderr.writeLine("isonim-review config: ignored ISONIM_CAMPAIGN_AUTOTICK_DELAY_MS=\"" &
        envCampaignAutoTick & "\" (expected non-negative integer ms)")

  # CMP-M2.1 — test hook to disable auto-tick scheduling.
  let envAutoTickDisabled = getEnv("ISONIM_CAMPAIGN_AUTOTICK_DISABLED")
  if envAutoTickDisabled.len > 0 and envAutoTickDisabled != "0":
    result.agent.campaignAutoTickDisabled = true

  # CMP-M5 — AI Assistant primer config env overrides.  Wins over TOML.
  let envAssistantPath = getEnv("ISONIM_ASSISTANT_PROMPT_PATH")
  if envAssistantPath.len > 0:
    result.agent.assistantPromptPath = expandTilde(envAssistantPath)
  let envPrimerEnabled = getEnv("ISONIM_ASSISTANT_PRIMER_ENABLED")
  if envPrimerEnabled.len > 0:
    result.agent.primerEnabled = envPrimerEnabled != "0" and
                                  envPrimerEnabled.toLowerAscii() != "false"

  # Validate the [agent] section at load time so the operator sees a
  # clear error instead of an opaque spawn failure later.
  validateAgentConfig(result)

proc codexExtraArgs*(cfg: ReviewConfig): seq[string] =
  ## Follow-up 2 — translate ``[agent.codex].model`` into the ``-c
  ## model=<value>`` flag pair the ``codex-acp`` binary accepts on its
  ## CLI.  Returns ``@[]`` when no model is set so callers can blindly
  ## concatenate the result without dragging in a default the user
  ## explicitly cleared.
  if cfg.agent.codex.model.len == 0:
    return @[]
  @["-c", "model=" & cfg.agent.codex.model]

proc claudeExtraArgs*(cfg: ReviewConfig): seq[string] =
  ## Follow-up 2 — ``claude-agent-acp`` does NOT accept a CLI
  ## ``--model`` flag (verified against the v0.21.0 package shipped in
  ## this dev shell — it reads model preference from
  ## ``~/.claude/settings.json`` and from the in-session
  ## ``session/set_model`` ACP call).  We therefore return ``@[]``
  ## even when ``[agent.claude].model`` is set — the model is recorded
  ## in the config (and surfaced in the daemon log line) but cannot
  ## be passed on the binary's argv until upstream grows a flag.
  ##
  ## When the upstream binary adds CLI support, return e.g.
  ## ``@["--model", cfg.agent.claude.model]`` here.
  @[]

proc resolveAssistantPromptPath*(cfg: ReviewConfig): string =
  ## CMP-M5 — resolve the absolute path the daemon should read the
  ## AI Assistant system prompt from.  Honours an explicit
  ## ``[agent].assistant_prompt_path`` first, then falls back to
  ## ``<workspace>/`` & ``DefaultAssistantPromptRelPath`` so an
  ## operator with a populated ``[workspace].root`` gets the prompt
  ## for free without extra TOML.
  if cfg.agent.assistantPromptPath.len > 0:
    return cfg.agent.assistantPromptPath
  if cfg.workspace.root.len > 0:
    return cfg.workspace.root / DefaultAssistantPromptRelPath
  ""

proc daemonBaseUrl*(cfg: ReviewConfig): string =
  ## URL the CLI's ``chat`` subcommand defaults to.  Honors an explicit
  ## ``[agent].default_daemon_url`` from TOML; otherwise derives the URL
  ## from ``[server]``.  Used by ``cmd_chat`` and by ``daemonBackend``.
  if cfg.agent.defaultDaemonUrl.len > 0:
    return cfg.agent.defaultDaemonUrl
  "http://" & cfg.server.bindAddr & ":" & $cfg.server.port

proc spliceUserIntoUrl(url, user: string): string =
  ## Replace (or insert) the ``user[:pw]@`` segment of a libpq URL.  The
  ## host/port/database segments of ``url`` are preserved verbatim so
  ## tests that configure a TOML ``[db].url`` against an ephemeral
  ## ``PgFixture`` survive ``ISONIM_REVIEW_PGPORT`` poisoning from the
  ## surrounding dev shell.
  let schemeEnd = url.find("://")
  if schemeEnd < 0:
    # Not a wire URL — fall through to a manually-built URL by the
    # caller.  Returning ``""`` signals "URL splice not applicable".
    return ""
  let scheme = url[0 ..< schemeEnd + 3]
  var rest = url[schemeEnd + 3 .. ^1]
  let at = rest.rfind('@')
  if at >= 0:
    rest = rest[at + 1 .. ^1]
  if user.len > 0:
    return scheme & user & "@" & rest
  scheme & rest

proc connectionString*(cfg: ReviewConfig; role: string = ""): string =
  ## Builds the libpq URL to feed ``open()`` with.  ``role`` selects
  ## which Postgres user to authenticate as:
  ##
  ##   * ``""`` — use whatever the URL or env carries (OS user under
  ##     trust auth on the dev cluster).
  ##   * ``"app"`` — log in as ``cfg.db.appUser``.
  ##   * ``"migrator"`` — log in as ``cfg.db.migratorUser``.
  ##
  ## If ``cfg.db.url`` is set we honour it verbatim *unless* a role was
  ## requested, in which case we splice the user in but keep the
  ## explicit host/port/database from the URL.  This matters when the
  ## surrounding dev shell exports ``ISONIM_REVIEW_PGPORT`` (env
  ## overrides bump ``cfg.db.port`` for convenience) but the operator
  ## or a test wrote an explicit TOML ``[db].url`` pointing at a
  ## different cluster: the URL host/port must win.
  if cfg.db.url.len > 0 and role.len == 0:
    return cfg.db.url
  let user =
    case role
    of "app": cfg.db.appUser
    of "migrator": cfg.db.migratorUser
    else: ""
  if cfg.db.url.len > 0:
    let spliced = spliceUserIntoUrl(cfg.db.url, user)
    if spliced.len > 0:
      return spliced
  let userPart =
    if user.len > 0: user & "@" else: ""
  "postgres://" & userPart & cfg.db.host & ":" & $cfg.db.port &
    "/" & cfg.db.database
