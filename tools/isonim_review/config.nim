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

  ReviewConfig* = object
    db*: DbConfig
    server*: ServerConfig
    store*: StoreConfig
    workspace*: WorkspaceConfig
    backend*: BackendConfig
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
  TomlValueKind = enum tvkString, tvkInt, tvkBool
  TomlValue = object
    case kind: TomlValueKind
    of tvkString: s: string
    of tvkInt: i: int
    of tvkBool: b: bool

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

proc parseTomlValue(raw: string; lineNo: int): TomlValue =
  ## Parse the right-hand side of a ``key = value`` line.  ``raw`` is
  ## already stripped of surrounding whitespace and trailing comment.
  if raw.len == 0:
    raise newException(TomlParseError,
      "line " & $lineNo & ": empty value")
  if raw[0] == '"':
    return TomlValue(kind: tvkString, s: parseStringLiteral(raw, lineNo))
  if raw == "true":
    return TomlValue(kind: tvkBool, b: true)
  if raw == "false":
    return TomlValue(kind: tvkBool, b: false)
  # Integer.  We don't support negative or hex/octal — overkill here.
  var i: int
  let consumed = parseInt(raw, i, 0)
  if consumed != raw.len:
    raise newException(TomlParseError,
      "line " & $lineNo & ": unsupported value (only string, int, bool): " & raw)
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
    else:
      stderr.writeLine("isonim-review config: unknown section [" &
        section & "]")

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
  ## requested, in which case we splice the user in.
  if cfg.db.url.len > 0 and role.len == 0:
    return cfg.db.url
  let user =
    case role
    of "app": cfg.db.appUser
    of "migrator": cfg.db.migratorUser
    else: ""
  let userPart =
    if user.len > 0: user & "@" else: ""
  "postgres://" & userPart & cfg.db.host & ":" & $cfg.db.port &
    "/" & cfg.db.database
