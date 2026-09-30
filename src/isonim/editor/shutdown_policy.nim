## One shutdown budget shared with tools/editor_server.py. Native creation or
## delivery followed by stop consumes at most two HTTP request deadlines;
## concurrent closes prevent session count from multiplying that allowance.
import std/[json, os]
const policyText = staticRead(currentSourcePath().parentDir.parentDir.parentDir.parentDir / "tools" / "editor_shutdown.json")
const AgentHttpTimeoutMs* = parseJson(policyText)["http_request_seconds"].getInt * 1000
const EnumerationTimeoutMs* = parseJson(policyText)["enumeration_seconds"].getInt * 1000
const HarborTeardownTimeoutMs* = parseJson(policyText)["harbor_teardown_seconds"].getInt * 1000
