## Phase C — daemon URL discovery for the editor's AI sidebar.
##
## Thin wrapper over the REV-M8 ``daemon_discovery`` module that
## documents the resolution order required by the AI sidebar wiring:
##
##   1. ``<meta name="isonim-review-api" content="http://...">`` —
##      the hosting page can pre-bake the URL at build time when the
##      daemon binds somewhere other than the default port.
##   2. ``window.location.origin`` with the port replaced by ``8113``
##      — the local-dev case: editor at ``:8090``, daemon at ``:8113``.
##   3. ``http://127.0.0.1:8113`` — the REV-M4 default.
##
## The ``ISONIM_REVIEW_API`` env var is honoured on native by the
## underlying ``daemon_discovery`` module (used by native CLI tests);
## the JS bundle has no ``getEnv`` so step 1 is the equivalent override.

import ./daemon_discovery

const
  AgentSessionsPath* = "/api/agent/sessions"
  AgentPromptsPath* = "/api/agent/prompts"
  AgentCancelPath* = "/api/agent/cancel"

proc resolveDaemonUrl*(): string =
  ## Returns the daemon base URL (no trailing slash) following the
  ## resolution order above.  Never returns an empty string — falls
  ## through to ``DefaultBaseUrl`` when no override is present.
  let disc = discoverDaemonBaseUrl()
  if disc.baseUrl.len > 0:
    return disc.baseUrl
  return DefaultBaseUrl
