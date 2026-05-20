## CMP-M5 — chat-session priming tests.
##
## The daemon's ``POST /api/agent/sessions`` handler primes every
## freshly-opened chat ACP session with the AI Assistant system prompt
## + a project-context block.  These tests boot the real
## ``isonim-review`` daemon with the fake ACP agent and inspect the
## ``$FAKE_ACP_CONTENT_LOG`` to assert the primer prompt body shape.
##
## The fixture's content log is the cleanest hook: every
## ``session/prompt`` the daemon ships to the ACP agent is appended as
## a JSON-summary line; primer prompts carry ``"source": "primer"`` so
## the tests can dedupe primer-vs-user prompts without inspecting wire
## bytes.

import std/[json, os, strutils, times, unittest]

import helpers/agent_routes_fixture
import helpers/campaign_routes_fixture
  # for the regression test that confirms campaign sessions don't
  # receive the AI Assistant primer.

# --------------------------------------------------------------------------- #
#  Fixture builders — write a per-test project root with an AI Assistant     #
#  prompt + optional briefs/, AGENTS.md, and config TOML pointing the       #
#  daemon at the right paths.                                                #
# --------------------------------------------------------------------------- #

type
  PrimerFixture = object
    projectRoot: string
    assistantPath: string
    configPath: string

const ProbeAssistantSentinel = "You are the IsoNim AI Assistant"
  ## Anchor phrase from ``prompts/ai-assistant.md`` § A.  The primer
  ## must include this verbatim so tests can assert the prompt body
  ## actually landed in the outbound ``session/prompt``.

proc uniqueDir(prefix: string): string =
  getTempDir() / (prefix & "_" & $((int(epochTime() * 1000)) mod 1_000_000))

proc writeAssistantPrompt(path: string; body: string = "") =
  createDir(path.parentDir)
  let final =
    if body.len > 0: body
    else: "# IsoNim Editor AI Assistant — System Prompt\n\n" &
          "## A. You are the IsoNim AI Assistant\n\n" &
          "You are the test-fixture assistant.  Keep replies short.\n"
  writeFile(path, final)

proc writeBrief(root: string; relPath: string; briefId, title: string) =
  let p = root / "briefs" / relPath
  createDir(p.parentDir)
  let body = "---\n" &
    "briefId: " & briefId & "\n" &
    "schemaVersion: 1\n" &
    "kind: render\n" &
    "title: " & title & "\n" &
    "coversPreviews:\n" &
    "  - storyRef: { group: \"Probe\", name: \"Index\", kind: page, index: 0 }\n" &
    "    backends: [web]\n" &
    "captureViewports:\n" &
    "  - { width: 1080, height: 720, label: \"tablet\" }\n" &
    "reviewerSchemaVersion: 1\n" &
    "scoringDimensions:\n" &
    "  - { id: overall, label: \"Overall\", weight: 1.0, scale: { min: 1, max: 10 } }\n" &
    "relatedBriefs: []\n" &
    "---\n\n# " & title & "\n"
  writeFile(p, body)

proc setupFixture(briefs: bool = false; agentsMd: string = "";
                  primerEnabled: bool = true;
                  assistantPromptOverride: string = "";
                  bogusAssistantPath: bool = false): PrimerFixture =
  result.projectRoot = uniqueDir("cmp_m5_proj")
  createDir(result.projectRoot)
  result.assistantPath = result.projectRoot / "isonim" / "prompts" /
                         "ai-assistant.md"
  if assistantPromptOverride.len > 0:
    writeAssistantPrompt(result.assistantPath, assistantPromptOverride)
  else:
    writeAssistantPrompt(result.assistantPath)
  if briefs:
    writeBrief(result.projectRoot, "render/probe.md",
               "render.probe", "Probe Brief")
  if agentsMd.len > 0:
    writeFile(result.projectRoot / "AGENTS.md", agentsMd)
  result.configPath = result.projectRoot / "isonim-review-config.toml"
  let assistantPathLine =
    if bogusAssistantPath:
      "assistant_prompt_path = \"" & result.projectRoot / "nonexistent" /
        "ai-assistant.md" & "\"\n"
    else:
      "assistant_prompt_path = \"" & result.assistantPath & "\"\n"
  let primerEnabledLine =
    "primer_enabled = " & (if primerEnabled: "true" else: "false") & "\n"
  writeFile(result.configPath,
    "[workspace]\nroot = \"" & result.projectRoot & "\"\n\n" &
    "[agent]\n" & assistantPathLine & primerEnabledLine)

proc teardownFixture(fx: PrimerFixture) =
  try: removeDir(fx.projectRoot) except OSError: discard

proc createSessionWithProjectRoot(f: AgentRoutesFixture;
                                  projectRoot: string):
    tuple[code: int; sessionId: string] =
  let body = $(%* {"projectRoot": projectRoot})
  let (code, raw) = f.agentPost("/api/agent/sessions", body)
  if code != 200:
    return (code: code, sessionId: "")
  return (code: code, sessionId: parseJson(raw){"sessionId"}.getStr(""))

proc waitForPrimerEntry(f: AgentRoutesFixture; needle: string;
                       timeoutSec: float = 4.0): bool =
  let deadline = epochTime() + timeoutSec
  while epochTime() < deadline:
    let txt = latestPrimerPromptText(f)
    if txt.len > 0 and needle in txt:
      return true
    sleep(80)
  false

# --------------------------------------------------------------------------- #
#  1. The primer carries the AI Assistant system prompt.                      #
# --------------------------------------------------------------------------- #

test "test_chat_session_receives_assistant_prompt_at_creation":
  let fx = setupFixture()
  defer: teardownFixture(fx)
  let f = startAgentDaemon(configPath = fx.configPath)
  defer: f.shutdown()
  let (code, sessionId) = createSessionWithProjectRoot(f, fx.projectRoot)
  check code == 200
  check sessionId.len > 0
  check waitForPrimerEntry(f, ProbeAssistantSentinel)
  let primer = latestPrimerPromptText(f)
  check ProbeAssistantSentinel in primer
  check "SYSTEM CONTEXT — IsoNim AI Assistant prompt" in primer
  check "PROJECT CONTEXT" in primer
  check "Project root: " & fx.projectRoot in primer

# --------------------------------------------------------------------------- #
#  2. Brief index summary lands in the primer.                                #
# --------------------------------------------------------------------------- #

test "test_chat_session_primer_includes_brief_index":
  let fx = setupFixture(briefs = true)
  defer: teardownFixture(fx)
  let f = startAgentDaemon(configPath = fx.configPath)
  defer: f.shutdown()
  let (code, sessionId) = createSessionWithProjectRoot(f, fx.projectRoot)
  check code == 200
  check sessionId.len > 0
  check waitForPrimerEntry(f, "render.probe")
  let primer = latestPrimerPromptText(f)
  check "render.probe" in primer
  check "Probe Brief" in primer
  check "Brief index" in primer

# --------------------------------------------------------------------------- #
#  3. Active campaigns surface in the primer.                                 #
# --------------------------------------------------------------------------- #

test "test_chat_session_primer_includes_active_campaigns":
  ## This test uses the full campaign fixture (real Postgres) so we can
  ## seed an ``active`` campaign row, then open a chat session and
  ## confirm the campaignId reaches the primer prompt body.
  let f = startCampaignDaemon()
  defer: f.shutdown()
  # The campaign fixture's promptDir doubles as the daemon's
  # workspace root; primer config knobs land via the TOML the fixture
  # wrote.  We start a campaign through ``/api/campaign/start`` so the
  # active-campaign row exists before we open the chat session.
  let docPath = f.promptDir / "campaigns" / "cmp-m5-chat.md"
  createDir(docPath.parentDir)
  let docBody = "---\ncampaignId: cmp-m5-chat\n---\n# Probe campaign\n"
  writeFile(docPath, docBody)
  let startBody = $(%* {
    "docPath": docPath,
    "docSha": "fakesha",
    "briefRefs": ["render.probe"],
    "body": docBody,
    "manifestHash": "local",
    "startedBy": "test",
  })
  let (sCode, sBody) = f.campaignPost("/api/campaign/start", startBody)
  # Even if the SSE stream's status is non-200 due to ACP idiosyncrasies,
  # the campaign row should still land (``start_campaign`` writes before
  # the first agent prompt).  Tolerate non-200 codes so the test focuses
  # on the primer assertion.
  discard sCode
  discard sBody
  check countCampaigns(f) >= 1
  let campaignsAfterStart = fetchCampaignByDoc(f, docPath)
  check campaignsAfterStart.len >= 1
  let campaignId = campaignsAfterStart[0][0]
  # Now open a chat session via /api/agent/sessions.  The campaign
  # fixture's daemon mounts both agent + campaign routes.
  let (cCode, cBody) = f.campaignPost("/api/agent/sessions",
    $(%* {"projectRoot": f.promptDir}))
  check cCode == 200
  let sessionId = parseJson(cBody){"sessionId"}.getStr("")
  check sessionId.len > 0
  # Poll the content log for the primer entry.
  let deadline = epochTime() + 4.0
  var sawCampaign = false
  while epochTime() < deadline:
    for e in readContentLogEntries(f):
      if e == nil: continue
      if e{"source"}.getStr("") != "primer": continue
      let body = e{"promptText"}.getStr("")
      if campaignId in body and "Active campaigns" in body:
        sawCampaign = true
        break
    if sawCampaign: break
    sleep(80)
  check sawCampaign

# --------------------------------------------------------------------------- #
#  4. AGENTS.md lands in the primer when present.                             #
# --------------------------------------------------------------------------- #

test "test_chat_session_primer_includes_agents_md_when_present":
  const Marker = "CMP-M5-AGENTS-MARKER-7f3a"
  let fx = setupFixture(agentsMd = "# Project agent rules\n\n" & Marker & "\n")
  defer: teardownFixture(fx)
  let f = startAgentDaemon(configPath = fx.configPath)
  defer: f.shutdown()
  let (code, sessionId) = createSessionWithProjectRoot(f, fx.projectRoot)
  check code == 200
  check sessionId.len > 0
  check waitForPrimerEntry(f, Marker)
  let primer = latestPrimerPromptText(f)
  check Marker in primer
  check "AGENTS.md" in primer

# --------------------------------------------------------------------------- #
#  5. Large AGENTS.md gets head+tail truncated.                               #
# --------------------------------------------------------------------------- #

test "test_chat_session_primer_truncates_long_agents_md":
  const HeadMarker = "HEAD-CMP-M5-MARKER-START"
  const TailMarker = "TAIL-CMP-M5-MARKER-END"
  # ~10 KB of body: head marker + filler + tail marker.  The middle
  # filler is ~10 KB so the total exceeds the 4 KB primer cap and the
  # truncation kicks in.
  let filler = repeat("ABCDEFGH", 1_400)  # ~11 KB
  let agentsMd = HeadMarker & "\n" & filler & "\n" & TailMarker & "\n"
  let fx = setupFixture(agentsMd = agentsMd)
  defer: teardownFixture(fx)
  let f = startAgentDaemon(configPath = fx.configPath)
  defer: f.shutdown()
  let (code, sessionId) = createSessionWithProjectRoot(f, fx.projectRoot)
  check code == 200
  check sessionId.len > 0
  check waitForPrimerEntry(f, HeadMarker)
  let primer = latestPrimerPromptText(f)
  check HeadMarker in primer
  check TailMarker in primer
  check "…truncated…" in primer
  # The full filler must NOT be in the primer in full — the truncation
  # rule keeps 2 KB head + 2 KB tail, so the middle bytes drop out.
  let fillerInPrimer = primer.count("ABCDEFGH")
  let fillerInSource = agentsMd.count("ABCDEFGH")
  check fillerInPrimer < fillerInSource

# --------------------------------------------------------------------------- #
#  6. primer_enabled = false disables the primer.                             #
# --------------------------------------------------------------------------- #

test "test_chat_session_primer_disabled_via_config":
  let fx = setupFixture(primerEnabled = false)
  defer: teardownFixture(fx)
  let f = startAgentDaemon(configPath = fx.configPath)
  defer: f.shutdown()
  let (code, sessionId) = createSessionWithProjectRoot(f, fx.projectRoot)
  check code == 200
  check sessionId.len > 0
  # Give the daemon a beat in case it did issue a primer (it shouldn't).
  sleep(300)
  let primers = primerEntries(f)
  check primers.len == 0
  # And the fake-ACP must not have received any prompt yet — the
  # caller hasn't sent a user prompt, and the primer was disabled.
  check countPrompts(f, sessionId) == 0

# --------------------------------------------------------------------------- #
#  7. Missing assistant prompt path falls back to placeholder; session works. #
# --------------------------------------------------------------------------- #

test "test_chat_session_falls_back_when_prompt_file_missing":
  let fx = setupFixture(bogusAssistantPath = true)
  defer: teardownFixture(fx)
  let f = startAgentDaemon(configPath = fx.configPath)
  defer: f.shutdown()
  let (code, sessionId) = createSessionWithProjectRoot(f, fx.projectRoot)
  check code == 200
  check sessionId.len > 0
  # The primer must still fire — just with the built-in fallback body.
  check waitForPrimerEntry(f, "You are a coding assistant")
  let primer = latestPrimerPromptText(f)
  check "PROJECT CONTEXT" in primer
  # Subsequent user prompts must still work.
  let promptBody = $(%* {
    "sessionId": sessionId,
    "messages": [{
      "role": "user",
      "content": [{"type": "text", "text": "hello"}],
    }],
  })
  let (pCode, _) = f.agentPost("/api/agent/prompts", promptBody,
                                timeoutMs = 15_000)
  check pCode == 200

# --------------------------------------------------------------------------- #
#  8. The primer is exactly one turn — subsequent user prompts increment.    #
# --------------------------------------------------------------------------- #

test "test_chat_session_primer_is_one_turn":
  let fx = setupFixture()
  defer: teardownFixture(fx)
  let f = startAgentDaemon(configPath = fx.configPath)
  defer: f.shutdown()
  let (code, sessionId) = createSessionWithProjectRoot(f, fx.projectRoot)
  check code == 200
  check sessionId.len > 0
  check waitForPrimerEntry(f, ProbeAssistantSentinel)
  # The fake-ACP recorded the primer prompt as one ``session/prompt``.
  check countPrompts(f, sessionId) == 1
  # Now POST a normal user prompt; the fake-ACP entry count must
  # increment by exactly 1.
  let promptBody = $(%* {
    "sessionId": sessionId,
    "messages": [{
      "role": "user",
      "content": [{"type": "text", "text": "user message 1"}],
    }],
  })
  let (pCode, _) = f.agentPost("/api/agent/prompts", promptBody,
                                timeoutMs = 15_000)
  check pCode == 200
  # Allow a brief flush window.
  let deadline = epochTime() + 2.0
  var saw2 = false
  while epochTime() < deadline:
    if countPrompts(f, sessionId) >= 2:
      saw2 = true
      break
    sleep(60)
  check saw2

# --------------------------------------------------------------------------- #
#  9. Campaign sessions do NOT receive the AI Assistant primer.               #
# --------------------------------------------------------------------------- #

test "test_campaign_session_does_not_receive_assistant_primer":
  ## Regression — campaign sessions go through ``campaign_routes.nim``
  ## which loads its own orchestrator prompt; the chat-priming code
  ## must not double-prime them with the AI Assistant body.
  let f = startCampaignDaemon()
  defer: f.shutdown()
  let docPath = f.promptDir / "campaigns" / "cmp-m5-regression.md"
  createDir(docPath.parentDir)
  let docBody = "---\ncampaignId: cmp-m5-regression\n---\n# Probe\n"
  writeFile(docPath, docBody)
  let startBody = $(%* {
    "docPath": docPath,
    "docSha": "regsha",
    "briefRefs": ["render.probe"],
    "body": docBody,
    "manifestHash": "local",
    "startedBy": "test",
  })
  discard f.campaignPost("/api/campaign/start", startBody)
  # The campaign fixture's prompt fixture is the orchestrator one, not
  # the AI Assistant one — so the AI Assistant sentinel must NOT show
  # up anywhere in the content log under ``source = primer`` (in fact
  # no ``source = primer`` entries should exist for the campaign's
  # session — campaign sessions don't go through ``/api/agent/sessions``).
  sleep(400)
  for e in readContentLogEntries(f):
    if e == nil: continue
    let body = e{"promptText"}.getStr("")
    # The orchestrator prompt has its own "SYSTEM CONTEXT —
    # orchestrator system prompt" header; ensure we don't see the
    # AI Assistant header there.
    check "SYSTEM CONTEXT — IsoNim AI Assistant prompt" notin body
