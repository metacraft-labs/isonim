## EAC-M6 — real daemon ACP role-instruction and project-context tests.
##
## Tests exercise actual HTTP, native stdio JSON-RPC and project files, plus
## real Postgres for campaign isolation/context. A deterministic ACP provider
## records the exact session/new metadata and actual user turn; it replaces only
## model inference to make role separation, truncation and failures repeatable.
## It does not prove a real Claude model honors metadata; the separately registered
## authoring workflow supplies that proof. No hidden user primer is permitted.

import std/[sequtils,sha1,json, options, os, strutils, times, unittest]
from std/unicode import runeLen
import isonim/editor/design_review/context_budget

import db_connector/db_postgres

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

proc roleText(f: AgentRoutesFixture): string =
  for entry in readContentLogEntries(f):
    if entry{"source"}.getStr == "role_instructions":
      result.add entry{"metadata", "systemPrompt", "append"}.getStr

proc userText(f: AgentRoutesFixture): string =
  for entry in readContentLogEntries(f):
    if entry{"source"}.getStr == "fake_acp":
      result.add entry{"promptText"}.getStr

proc submitUser(f: AgentRoutesFixture; sid: string; text = "Inspect this project") =
  let (code, body) = f.agentPost("/api/agent/prompts", $(%* {
    "sessionId": sid, "messages": [{"role": "user", "content": [
      {"type": "text", "text": text}]}]}), timeoutMs = 15_000)
  check code == 200
  check "event: admitted" in body
  check "end_turn" in body

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
  check ProbeAssistantSentinel in roleText(f)
  check countPrompts(f, sessionId) == 0
  check ProbeAssistantSentinel in roleText(f)
  submitUser(f, sessionId)
  let primer = userText(f)
  check ProbeAssistantSentinel notin primer
  check "SYSTEM CONTEXT — IsoNim AI Assistant prompt" notin primer
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
  submitUser(f, sessionId)
  check "render.probe" in userText(f)
  let primer = userText(f)
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
  ##
  ## CMP-M6: ``/api/campaign/start`` now runs the orchestrator as a
  ## single ACP turn and the post-turn fallback transitions the
  ## campaign out of ``active`` (to ``failed`` when the fixture doc
  ## doesn't set a terminal status) before this request returns.  To
  ## keep the primer assertion deterministic against the new model
  ## we seed the row directly via the ``start_campaign`` SECURITY-
  ## DEFINER routine — bypassing the ACP turn entirely so the
  ## campaign stays ``active`` for the duration of the test.
  let f = startCampaignDaemon()
  defer: f.shutdown()
  let docPath = f.promptDir / "campaigns" / "cmp-m5-chat.md"
  createDir(docPath.parentDir)
  let docBody = "---\ncampaignId: cmp-m5-chat\n---\n# Probe campaign\n"
  writeFile(docPath, docBody)
  # Seed directly via the SQL routine to leave the campaign ``active``.
  let db = connectMigrator(f)
  defer: db.close()
  let stmt = "SELECT design_review.start_campaign(" &
    "'" & docPath.replace("'", "''") & "', " &
    "'fakesha', " &
    "ARRAY['render.probe']::text[], " &
    "NULL, 3, 'local', 'claude', NULL, 'test')::text"
  let campaignId = db.getValue(sql(stmt))
  check campaignId.len > 0
  check countCampaigns(f) >= 1
  # Now open a chat session via /api/agent/sessions.  The campaign
  # fixture's daemon mounts both agent + campaign routes.
  let (cCode, cBody) = f.campaignPost("/api/agent/sessions",
    $(%* {"projectRoot": f.promptDir}))
  check cCode == 200
  let sessionId = parseJson(cBody){"sessionId"}.getStr("")
  check sessionId.len > 0
  let (pCode, _) = f.campaignPost("/api/agent/prompts", $(%* {
    "sessionId": sessionId, "messages": [{"role": "user", "content": [
      {"type": "text", "text": "Inspect active campaigns"}]}]}))
  check pCode == 200
  # Observe project context in the actual user turn, not role metadata.
  let deadline = epochTime() + 4.0
  var sawCampaign = false
  while epochTime() < deadline:
    for e in readContentLogEntries(f):
      if e == nil: continue
      if e{"source"}.getStr("") != "fake_acp": continue
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
  submitUser(f, sessionId)
  check Marker in userText(f)
  let primer = userText(f)
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
  submitUser(f, sessionId)
  check HeadMarker in userText(f)
  let primer = userText(f)
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
  check roleText(f).len == 0
  # And the fake-ACP must not have received any prompt yet — the
  # caller hasn't sent a user prompt, and the primer was disabled.
  check countPrompts(f, sessionId) == 0
  let first = "  Human turn with instructions disabled 保持😀  "
  let followup = "  Follow up with instructions still disabled 保持😀  "
  submitUser(f, sessionId, first)
  check countPrompts(f, sessionId) == 1
  submitUser(f, sessionId, followup)
  check countPrompts(f, sessionId) == 2
  check roleText(f).len == 0
  check ProbeAssistantSentinel notin userText(f)
  var roleRecords = 0
  var prompts: seq[string]
  for entry in readContentLogEntries(f):
    if entry{"source"}.getStr == "role_instructions":
      inc roleRecords
      check entry{"sessionId"}.getStr == sessionId
      check entry{"metadata"} != nil and entry["metadata"].kind == JNull
    elif entry{"source"}.getStr == "fake_acp":
      check entry{"sessionId"}.getStr == sessionId
      check entry{"textBlocks"}.getInt == 2
      prompts.add entry{"promptText"}.getStr
  check roleRecords == 1
  check prompts.len == 2
  if prompts.len == 2:
    check prompts[0].startsWith(first & "PROJECT CONTEXT:")
    check prompts[1].startsWith(followup & "PROJECT CONTEXT:")

# --------------------------------------------------------------------------- #
#  7. Missing assistant prompt path falls back to placeholder; session works. #
# --------------------------------------------------------------------------- #

test "test_chat_session_reports_missing_role_instructions":
  let fx = setupFixture(bogusAssistantPath = true)
  defer: teardownFixture(fx)
  let f = startAgentDaemon(configPath = fx.configPath)
  defer: f.shutdown()
  let (code, body) = f.agentPost("/api/agent/sessions",
    $(%* {"projectRoot": fx.projectRoot}))
  check code == 503
  check "instruction file is missing" in body
  check roleText(f).len == 0
  check countPrompts(f) == 0

# --------------------------------------------------------------------------- #
#  8. The primer is exactly one turn — subsequent user prompts increment.    #
# --------------------------------------------------------------------------- #

test "test_role_instructions_add_no_hidden_turn_and_persist_across_users":
  let fx = setupFixture()
  defer: teardownFixture(fx)
  let f = startAgentDaemon(configPath = fx.configPath)
  defer: f.shutdown()
  let (code, sessionId) = createSessionWithProjectRoot(f, fx.projectRoot)
  check code == 200
  check sessionId.len > 0
  check ProbeAssistantSentinel in roleText(f)
  # The fake-ACP recorded the primer prompt as one ``session/prompt``.
  check countPrompts(f, sessionId) == 0
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
    if countPrompts(f, sessionId) == 1:
      saw2 = true
      break
    sleep(60)
  check saw2
  submitUser(f, sessionId, "Follow up in this same session")
  check countPrompts(f, sessionId) == 2
  var roles = 0
  for entry in readContentLogEntries(f):
    if entry{"source"}.getStr == "role_instructions": inc roles
  check roles == 1
  check ProbeAssistantSentinel in roleText(f)
  check ProbeAssistantSentinel notin userText(f)

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
    check e{"metadata", "systemPrompt", "append"}.getStr.len == 0


suite "Actual remaining-quota optional context policy":
  test "large hierarchy compaction preserves exact pre-optimization bytes and Unicode cap":
    # This semantic/wire baseline was recorded from the original compactor in
    # owning Nim debug (7.832 CPU seconds, 7,445 repeated size calculations).
    # The HTTP test independently retains its original ten-second deadline.
    var rows = newJArray()
    rows.add(%* {"id":"root","parentId":"","depth":0})
    for i in 0 ..< 600:
      rows.add(%* {"id":"unrelated." & $i,"parentId":"root","depth":1})
    rows.add(%* {"id":"late-parent","parentId":"root","depth":1})
    rows.add(%* {"id":"late-selected","parentId":"late-parent","depth":2,"schemaKey":"actual.label"})
    let original = %* {"renderedComponentTree":rows,
      "selectedElement":{"id":"late-selected","ancestorIds":["root","late-parent"]},
      "pendingSourceEdits":[{"schemaKey":"actual.label","newValue":"  exact 保持😀  "}],
      "contextAvailability":[]}
    let snapshot = $original
    let compacted = compactEditorContext(original,1783)
    check compacted.isSome
    var expected = parseJson(snapshot)
    var expectedRows = newJArray()
    for i in 0 .. 27: expectedRows.add rows[i]
    expectedRows.add rows[601]
    expectedRows.add rows[602]
    expected["renderedComponentTree"] = expectedRows
    expected["contextAvailability"] = %* ["renderedComponentTree: 30/603 records; quota truncated"]
    check compacted.get == expected
    check $compacted.get == $expected
    check $secureHash($compacted.get) == "8742FF712B919B70F8BFAFA1934CEA36E24D8F43"
    check runeLen($compacted.get) <= 1783
    check compacted.get["pendingSourceEdits"] == original["pendingSourceEdits"]
    check $original == snapshot
  test "quota retry preserves current small hierarchy and selected late descendant ancestor closure":
    var context = %* {"renderedComponentTree":[],"selectedElement":{"id":"late-selected","ancestorIds":["root","late-parent"]},
      "pendingSourceEdits":[{"schemaKey":"actual.label","newValue":"exact"}],"contextAvailability":[]}
    context["renderedComponentTree"].add(%* {"id":"root","parentId":"","depth":0})
    for i in 0 ..< 600:
      context["renderedComponentTree"].add(%* {"id":"other." & $i,"parentId":"root","depth":1})
    context["renderedComponentTree"].add(%* {"id":"late-parent","parentId":"root","depth":1})
    context["renderedComponentTree"].add(%* {"id":"late-selected","parentId":"late-parent","depth":2,"schemaKey":"actual.label"})
    let compacted = compactEditorContext(context,1600)
    check compacted.isSome
    check compacted.get["renderedComponentTree"].elems.anyIt(it{"id"}.getStr()=="late-parent")
    check compacted.get["renderedComponentTree"].elems.anyIt(it{"id"}.getStr()=="late-selected" and it{"parentId"}.getStr()=="late-parent" and it{"depth"}.getInt()==2)
    check compacted.get["pendingSourceEdits"] == context["pendingSourceEdits"]
    let small = %* {"renderedComponentTree":[{"id":"root","parentId":"","depth":0},
      {"id":"branch","parentId":"root","depth":1},{"id":"leaf","parentId":"branch","depth":2}],"contextAvailability":[]}
    check compactEditorContext(small,1200).get == small
    check compactEditorContext(small,50).isNone
  test "Unicode optional records compact without altering protected edits or field availability":
    var context = %* {"selectedStory":{"group":"Hero", "name":"пример😀"},
      "accumulatedEdits":["exact😀保持"], "pendingSourceEdits":[{"value":"  exact 😀  "}],
      "designSystemConstraints":["keep all"], "currentFileDiffs":["exact diff"],
      "contextAvailability":["sourceMap: unavailable", "diagnostics: truncated to 100 records (editor context budget)"],
      "diagnostics":[], "renderedComponentTree":[], "availableTailwindClasses":["text-primary"]}
    for i in 0 ..< 100:
      context["diagnostics"].add(%* {"message":"Unicode😀保持" & $i,"file":"src/catalog.nim","line":i})
      context["renderedComponentTree"].add(%* {"id": $i,"parentId":"root","depth":1})
    let original = $context
    let bounded = compactEditorContext(context, 1500)
    check bounded.isSome
    check runeLen($bounded.get) <= 1500
    check $context == original
    for key in ["selectedStory", "accumulatedEdits", "pendingSourceEdits", "designSystemConstraints", "currentFileDiffs"]:
      check bounded.get[key] == context[key]
    check bounded.get.len == context.len
    check bounded.get["diagnostics"].len >= 1
    check bounded.get["renderedComponentTree"].len >= 1
    check ($bounded.get["contextAvailability"]).contains("quota truncated")
    check ($bounded.get["contextAvailability"]).contains("sourceMap: unavailable")
  test "protected or minimum meaningful snapshot exhaustion never loses data":
    let context = %* {"accumulatedEdits":["保持😀".repeat(3000)],
      "diagnostics":[{"message":"actual diagnostic", "file":"catalog.nim"}],"contextAvailability":[]}
    let original = $context
    check compactEditorContext(context, 1000).isNone
    check $context == original
    check compactEditorContext(%* {"diagnostics":[{"message":"actual complete record"}]}, 5).isNone

  test "sparse and malformed public context shapes cannot crash compaction":
    check compactEditorContext(newJNull(), 1000).isNone
    check compactEditorContext(newJArray(), 1000).isNone
    check compactEditorContext(newJObject(), 1000).isSome
    check compactEditorContext(newJObject(), -1).isNone
    check compactEditorContext(newJObject(), 0).isNone
    for invalid in [newJNull(), %"wrong type", %42, %* {"unexpected":"object"}]:
      check compactEditorContext(%* {"contextAvailability":invalid}, 1000).isNone
      check compactEditorContext(%* {"diagnostics":invalid}, 1000).isNone
    check compactEditorContext(%* {"contextAvailability":[newJNull()]}, 1000).isNone
    let nested = %* {"diagnostics":[newJNull(), "opaque record", {"message":newJNull()}],
      "accumulatedEdits":["保持😀 exact"], "contextAvailability":[]}
    let bounded = compactEditorContext(nested, 1000)
    check bounded.isSome
    check bounded.get["diagnostics"] == nested["diagnostics"]
    check bounded.get["accumulatedEdits"] == nested["accumulatedEdits"]

  test "source identity references only successful admitted representations including bounded subsets":
    let first = %* {"diagnostics":[{"message":"first"},{"message":"second"}],
      "accumulatedEdits":["exact edit"],"contextAvailability":[]}
    let sources = contextSourceIdentities(first)
    let bounded = %* {"diagnostics":[{"message":"first"}],
      "accumulatedEdits":["exact edit"],"contextAvailability":["diagnostics: quota truncated"]}
    let wire = referenceContext(first,bounded,sources)
    # Tiny records may be cheaper to repeat, so use a substantial unchanged field.
    var current = parseJson($first)
    current["diagnostics"][0]["message"] = %"actual current diagnostic 保持😀".repeat(30)
    let fullSources = contextSourceIdentities(current)
    var admitted = parseJson($current)
    admitted["diagnostics"] = %* [{"message":"actual bounded subset"}]
    let reference = referenceContext(current,admitted,fullSources)
    check reference["fromContext"].getStr() == $secureHash($admitted)
    check reference["boundedInherited"] == %*["diagnostics"]
    check deliveredContext(reference,admitted)["diagnostics"] == admitted["diagnostics"]
    check reference["current"]["accumulatedEdits"] == current["accumulatedEdits"]
    check deliveredContext(referenceContext(current,admitted,newJObject()),admitted) == current
    current["diagnostics"][0]["message"] = %"Changed actual diagnostic"
    check deliveredContext(referenceContext(current,admitted,fullSources),admitted) == current
    var forged = parseJson($reference)
    forged["fromContext"] = %"not an actual admitted representation"
    expect ValueError: discard deliveredContext(forged,admitted)
    expect ValueError: discard deliveredContext(reference,nil)
    forged = parseJson($reference)
    forged["current"].delete("accumulatedEdits")
    expect ValueError: discard deliveredContext(forged,admitted)

  test "reserved envelope keys remain exact submitted data and forged bases fail safely":
    let raw = %* {"fromContext":"user-authored identity", "current":{"diagnostics":["user data"]},
      "boundedInherited":["user data"]}
    check deliveredContext(raw,newJObject(),raw) == raw
    let next = referenceContext(raw,raw,contextSourceIdentities(raw))
    check deliveredContext(next,raw,raw) == raw
    let prior = %* {"diagnostics":["actual admitted diagnostic"], "contextAvailability":[],
      "accumulatedEdits":["exact protected edit"]}
    for malformed in [%* {"fromContext":"forged", "current":{}},
        %* {"fromContext": $secureHash($prior), "current":newJNull()},
        %* {"fromContext": $secureHash($prior), "current":{}, "unexpected":true}]:
      expect ValueError: discard deliveredContext(malformed,prior)

  test "versioned protected tuples retain exact target and edit values and reject malformed encodings":
    let context = %* {"accumulatedEdits":[{"oldValue":"  保持😀 exact  ","newValue":"new"}],
      "pendingSourceEdits":[{"unknownRecordField":"exact"}], "designSystemConstraints":["exact 保持😀"],
      "currentFileDiffs":[{"before":"old", "after":"  exact  "}],
      "selectedStory":{"group":"Hero", "name":"example", "kind":0, "index":2},
      "selectedElement":{"id":"actual", "sourceKey":"source", "domPath":"main > button",
        "schemaKey":"schema", "tag":"button", "sourceFile":"src/real.nim", "sourceLine":42,
        "sourceColumn":7, "properties":[{"unknownProperty":"exact"}], "children":["child"],
        "ancestors":["main"], "ancestorIds":["root"], "depth":2},
      "diagnostics":[{"message":"meaningful diagnostic 保持😀".repeat(30)}], "contextAvailability":[]}
    let raw = $context
    let wire = referenceContext(context,context,contextSourceIdentities(context))
    check wire.hasKey("protectedV1")
    check deliveredContext(wire,context,context) == context
    check $context == raw
    var malformed = parseJson($wire)
    malformed["protectedV1"].elems[5].elems[6] = %"42"
    expect ValueError: discard deliveredContext(malformed,context)
    malformed = parseJson($wire)
    malformed["protectedV1"].elems[4] = %*["wrong arity"]
    expect ValueError: discard deliveredContext(malformed,context)
    malformed = parseJson($wire)
    malformed["current"]["accumulatedEdits"] = %* {"fromPreviousItems":[{"reuse":0}]}
    expect ValueError: discard deliveredContext(malformed,context)
    var changed = parseJson($context)
    changed["selectedElement"]["unknownIdentityField"] = %"must survive"
    let fallback = referenceContext(changed,context,contextSourceIdentities(context))
    check not fallback.hasKey("protectedV1")
    check deliveredContext(fallback,context,changed) == changed
    changed.delete("diagnostics")
    check referenceContext(changed,context,contextSourceIdentities(context)) == changed
    check deliveredContext(changed,context,changed) == changed

  test "V2 protected tuples preserve current source style bindings and reject malformed or duplicate versions":
    let context = %* {"accumulatedEdits":[{"newValue":" exact 保持😀 "}],
      "pendingSourceEdits":[{"schemaKey":"current.key"}], "designSystemConstraints":["exact scope"],
      "currentFileDiffs":[{"afterText":" exact source "}],
      "selectedStory":{"group":"Hero", "name":"example", "kind":0, "index":2},
      "selectedElement":{"id":"actual", "sourceKey":"source", "domPath":"main > button",
        "schemaKey":"schema", "tag":"button", "sourceFile":"src/real.nim", "sourceLine":42,
        "sourceColumn":7, "properties":[{"value":"exact"}], "children":["child"],
        "ancestors":["main"], "ancestorIds":["root"], "depth":2,
        "styleBindings":"  background: token(保持😀); opacity: 0.75  "},
      "diagnostics":[{"message":"actual diagnostic".repeat(30)}], "contextAvailability":[]}
    let before = $context
    let wire = referenceContext(context,context,contextSourceIdentities(context))
    check wire.hasKey("protectedV2")
    check not wire.hasKey("protectedV1")
    check wire["protectedV2"][5][13] == context["selectedElement"]["styleBindings"]
    check deliveredContext(wire,context,context) == context
    check runeLen($wire) < runeLen($context)
    check $context == before
    var changed = parseJson($context)
    changed["selectedElement"]["styleBindings"] = %"  color: token(new 保持😀)  "
    let next = referenceContext(changed,context,contextSourceIdentities(context))
    check next.hasKey("protectedV2")
    check deliveredContext(next,context,changed) == changed
    for invalid in [newJNull(), %42, newJArray()]:
      var malformed = parseJson($wire)
      malformed["protectedV2"].elems[5].elems[13] = invalid
      expect ValueError: discard deliveredContext(malformed,context)
    var malformed = parseJson($wire)
    malformed["protectedV2"].elems[5].elems.setLen(13)
    expect ValueError: discard deliveredContext(malformed,context)
    malformed = parseJson($wire)
    malformed["protectedV1"] = parseJson($wire["protectedV2"])
    expect ValueError: discard deliveredContext(malformed,context)
    malformed = parseJson($wire)
    malformed["current"]["selectedElement"] = parseJson($context["selectedElement"])
    expect ValueError: discard deliveredContext(malformed,context)
    changed["selectedElement"]["unknownIdentityField"] = %" preserve future scope "
    let fallback = referenceContext(changed,context,contextSourceIdentities(context))
    check not fallback.hasKey("protectedV1")
    check not fallback.hasKey("protectedV2")
    check deliveredContext(fallback,context,changed) == changed
    changed = parseJson($context)
    changed["selectedElement"]["styleBindings"] = %42
    let typedFallback = referenceContext(changed,context,contextSourceIdentities(context))
    check not typedFallback.hasKey("protectedV2")
    check deliveredContext(typedFallback,context,changed) == changed

  test "quota compaction resolves inherited ownership before measuring re-encoded current data":
    var prior = %* {"designSystemSchema":[], "diagnostics":[], "contextAvailability":[],
      "accumulatedEdits":[{"property":"ariaLabel", "newValue":"exact"}],
      "pendingSourceEdits":[{"schemaKey":"current.key"}]}
    for i in 0 ..< 60:
      prior["designSystemSchema"].add(%* {"key":"other." & $i,"property":"other", "value":"actual " & $i})
      prior["diagnostics"].add(%* {"source":"compiler", "category":"generic", "message":"actual " & $i})
    prior["designSystemSchema"].add(%* {"key":"current.key", "property":"ariaLabel", "value":"old"})
    var current = parseJson($prior)
    current["designSystemSchema"].elems[^1]["value"] = %"current meaningful 保持😀"
    current["diagnostics"].add(%* {"source":"review", "category":"accessibility", "message":"actual warning"})
    let before = $current
    let bounded = compactEditorContext(current,850,prior)
    check bounded.isSome
    let wire = referenceContext(bounded.get,prior,nil)
    check runeLen($wire) <= 850
    check deliveredContext(wire,prior) == bounded.get
    check $current == before
    check bounded.get["accumulatedEdits"] == current["accumulatedEdits"]
    check bounded.get["pendingSourceEdits"] == current["pendingSourceEdits"]
    check bounded.get["designSystemSchema"].elems.anyIt(it{"key"}.getStr() == "current.key" and it{"value"}.getStr() == "current meaningful 保持😀")
    check bounded.get["diagnostics"].elems.anyIt(it{"source"}.getStr() == "review")

  test "quota retry retains selected and edited ownership and distinct actionable diagnostic categories":
    var context = %* {"designSystemSchema":[],"selectedSchemaNodes":[],"sourceMap":[],"diagnostics":[],
      "pendingSourceEdits":[{"schemaKey":"current.key","property":"ariaLabel"}],
      "accumulatedEdits":[{"property":"ariaLabel","newValue":"exact current"}],"contextAvailability":[]}
    for i in 0 ..< 100:
      context["designSystemSchema"].add(%* {"key":"unrelated." & $i,"property":"other"})
      context["diagnostics"].add(%* {"source":"compiler","category":"generic","message":"unrelated " & $i})
    context["designSystemSchema"].add(%* {"key":"current.key","property":"ariaLabel"})
    context["diagnostics"].add(%* {"source":"review","category":"accessibility","message":"actual warning"})
    let result=compactEditorContext(context,1600)
    check result.isSome
    check ($result.get["designSystemSchema"]).contains("current.key")
    check ($result.get["diagnostics"]).contains("actual warning")
    check result.get["pendingSourceEdits"]==context["pendingSourceEdits"]
