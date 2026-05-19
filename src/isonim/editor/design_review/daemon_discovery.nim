## REV-M8 — daemon-base-URL discovery for the editor.
##
## The editor's JS bundle needs to know where the ``isonim-review serve``
## daemon is listening before it can call ``/api/design-review/*``.  Three
## inputs feed the discovery in priority order:
##
##   1. ``$ISONIM_REVIEW_API`` env var.  Only meaningful for native CLI
##      tests; the editor JS bundle has no ``getEnv``, but the same
##      module is consumed by native unit tests so we keep the env path.
##   2. A ``<meta name="isonim-review-api" content="...">`` tag the
##      hosting page can inject.  This is the production-deploy hook —
##      pre-bake the URL at build time when the daemon binds somewhere
##      other than the default ``127.0.0.1:8113``.
##   3. ``window.location.origin`` rewritten to ``http://127.0.0.1:8113``
##      (the REV-M4 default port).  Fits the local-dev case where the
##      editor and the daemon both run on the same workstation.
##
## ``discoverDaemonBaseUrl`` returns ``("", false)`` when none of these
## inputs yields a non-empty URL — callers (the history-button mount,
## the per-preview ``briefHasHistory`` poll) treat the empty return as
## "no daemon reachable; gracefully disable the gallery affordance".
##
## The probe-and-confirm phase (a HEAD / GET to ``/health``) is the
## ``daemon_discovery.probeDaemon`` call: it returns ``false`` on any
## non-200 / unreachable response.  Native tests use this verbatim; the
## JS path stubs it to ``true`` (the browser fetch from the history-
## button poll is what actually exercises the daemon).

import std/[options, strutils]

when not defined(js):
  import std/[os, httpclient]

const
  DefaultBaseUrl* = "http://127.0.0.1:8113"
  EnvVar* = "ISONIM_REVIEW_API"

type
  DaemonDiscovery* = object
    baseUrl*: string
    source*: string  ## "env", "meta", "default", or "" (none)

# ---------------------------------------------------------------------------
# JS-side helpers.  ``readMetaTag`` lifts the ``<meta name="..."
# content="...">`` from the hosting page; ``readWindowOrigin`` falls
# back to ``window.location.origin``.  Both are no-ops on native.
# ---------------------------------------------------------------------------

proc readMetaTag*(name: string): string =
  ## Returns the ``content`` attribute of a ``<meta name>`` tag, or "" if
  ## the tag does not exist.  Native-side returns "" always.
  when defined(js):
    var found: cstring = ""
    let n: cstring = name
    {.emit: ["""
      try {
        var m = document.querySelector('meta[name=\"' + """, n, """ + '\"]');
        if (m && m.content) """, found, """ = m.content;
      } catch (e) { """, found, """ = ""; }
    """].}
    result = $found
  else:
    result = ""

proc readWindowOrigin*(): string =
  when defined(js):
    var origin: cstring = ""
    {.emit: ["""
      try {
        if (typeof window !== 'undefined' && window.location && window.location.origin)
          """, origin, """ = window.location.origin;
      } catch (e) { """, origin, """ = ""; }
    """].}
    result = $origin
  else:
    result = ""

proc readEnvVar*(name: string): string =
  when defined(js):
    return ""
  else:
    return getEnv(name)

# ---------------------------------------------------------------------------
# Top-level discovery.  Order: env → meta → window-origin-with-port →
# default.  Empty-string sentinel for "no daemon".
# ---------------------------------------------------------------------------

proc normalize(url: string): string =
  result = url.strip()
  if result.endsWith("/"):
    result = result[0 ..< result.len - 1]

proc discoverDaemonBaseUrl*(): DaemonDiscovery =
  ## Returns the discovered base URL + the source it came from.  Callers
  ## inspect ``baseUrl == ""`` to detect the "no daemon" condition.

  # 1. Env var.  Native tests set this to override the default; the JS
  # path always sees "" (no ``getEnv``).
  let env = readEnvVar(EnvVar)
  if env.len > 0:
    return DaemonDiscovery(baseUrl: normalize(env), source: "env")

  # 2. Meta-tag injection.  The hosting page can pre-bake the URL into
  # the bundle at build time.
  let meta = readMetaTag("isonim-review-api")
  if meta.len > 0:
    return DaemonDiscovery(baseUrl: normalize(meta), source: "meta")

  # 3. Window-origin-with-default-port fallback (JS only).  This is the
  # local-dev case: editor on :8090, daemon on :8113.
  when defined(js):
    let origin = readWindowOrigin()
    if origin.len > 0:
      # Rewrite the port to the daemon's default.
      var host = ""
      var scheme = "http"
      # Split scheme:// and host:port
      let schemeEnd = origin.find("://")
      if schemeEnd > 0:
        scheme = origin[0 ..< schemeEnd]
        host = origin[schemeEnd + 3 .. ^1]
      else:
        host = origin
      let portIdx = host.find(':')
      if portIdx >= 0:
        host = host[0 ..< portIdx]
      let rebuilt = scheme & "://" & host & ":8113"
      return DaemonDiscovery(baseUrl: rebuilt, source: "window-origin")

  # 4. Native default.
  return DaemonDiscovery(baseUrl: DefaultBaseUrl, source: "default")

# ---------------------------------------------------------------------------
# Probe — confirm the daemon is reachable by hitting ``/health``.  On
# JS this is always ``true`` (the actual probe happens via the editor's
# history-button poll which surfaces "no daemon" as
## ``briefHasHistory == false``).  On native it does a real GET with
# a short timeout so unit tests can run against a daemon that may not
# be running.
# ---------------------------------------------------------------------------

proc probeDaemon*(baseUrl: string; timeoutMs: int = 1500): bool =
  if baseUrl.len == 0: return false
  when defined(js):
    return true
  else:
    try:
      let client = newHttpClient(timeout = timeoutMs)
      defer: client.close()
      let resp = client.request(baseUrl & "/health")
      let codeStr = resp.status.split(' ')[0]
      let code = try: parseInt(codeStr) except ValueError: 0
      return code in 200..299 or code == 503  # 503 = DB unhealthy but daemon is up
    except CatchableError:
      return false

proc effectiveBaseUrl*(): Option[string] =
  ## Convenience: returns ``some(url)`` if the discovered URL probes
  ## green; ``none`` otherwise.  Editor mount code uses this to decide
  ## whether to wire the 🕘 button.
  let disc = discoverDaemonBaseUrl()
  if disc.baseUrl.len == 0:
    return none[string]()
  when defined(js):
    # Defer the probe to the actual history-button fetch.
    return some(disc.baseUrl)
  else:
    if probeDaemon(disc.baseUrl):
      return some(disc.baseUrl)
    return none[string]()
