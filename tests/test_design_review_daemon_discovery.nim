## REV-M8 — daemon discovery tests.
##
## Tests the four-tier discovery (env → meta → window-origin → default)
## plus the probe behaviour against an unreachable URL.  The JS-only
## ``readMetaTag`` / ``readWindowOrigin`` paths are exercised by the
## real-editor e2e (they require a browser DOM); native unit tests
## cover the env-var and probe paths.

import std/[unittest, os, options]

import isonim/editor/design_review/daemon_discovery

suite "REV-M8 daemon discovery":

  test "test_daemon_discovery_honours_env_var":
    putEnv("ISONIM_REVIEW_API", "http://192.0.2.99:9999")
    let d = discoverDaemonBaseUrl()
    check d.baseUrl == "http://192.0.2.99:9999"
    check d.source == "env"
    delEnv("ISONIM_REVIEW_API")

  test "test_daemon_discovery_strips_trailing_slash":
    putEnv("ISONIM_REVIEW_API", "http://192.0.2.99:9999/")
    let d = discoverDaemonBaseUrl()
    check d.baseUrl == "http://192.0.2.99:9999"
    delEnv("ISONIM_REVIEW_API")

  test "test_daemon_discovery_native_default":
    # Make sure the env var is unset and observe the default fallback.
    delEnv("ISONIM_REVIEW_API")
    let d = discoverDaemonBaseUrl()
    check d.baseUrl == DefaultBaseUrl
    check d.source == "default"

  test "test_probe_daemon_returns_false_for_unreachable_host":
    # 192.0.2.x is the IETF TEST-NET-1 prefix — guaranteed unreachable.
    let reachable = probeDaemon("http://192.0.2.99:9999", timeoutMs = 500)
    check reachable == false

  test "test_probe_daemon_returns_false_for_empty_url":
    check probeDaemon("", timeoutMs = 200) == false

  test "test_effective_base_url_returns_none_when_probe_fails":
    putEnv("ISONIM_REVIEW_API", "http://192.0.2.99:9999")
    let eff = effectiveBaseUrl()
    check eff.isNone
    delEnv("ISONIM_REVIEW_API")
