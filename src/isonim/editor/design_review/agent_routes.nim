## HTTP bridge from editor conversations to nim-agents.
## Harbor conversations begin as explicit local drafts; their first user message
## creates a standalone persistent REST session. Follow-ups reuse that session.
## Streams run on a worker while the daemon remains available for editor commands.
## POST /api/agent/close ends the session. Cancellation is a separate capability;
## Harbor currently rejects it because REST has no process-preserving cancel route.
## A disconnected response stream is drained without closing the conversation.
## Explicit direct ACP backends retain their existing initialization behavior.

import std/[asyncdispatch, asyncnet, asynchttpserver, atomics, base64, json, locks,
            options, os, osproc, sequtils, streams, strutils, tables, times, sha1]

when defined(posix): import std/posix

from std/unicode import runeLen

import db_connector/db_postgres

import nim_acp
import nim_agents

import ../shutdown_policy
import ./control_routes
import ./log_setup
import ./context_budget
import ./brief_format
import std/oids
import ./brief_index
import ./db as dr_db

logScope:
  topics = "agent"

type
  AgentSessionState* = object
    sessionId*: string
    client*: AgentClient
    session*: AgentSession
    capabilities*: AgentCapabilities
    cwd*: string
    isDraft*: bool
    turnWorking*: bool
    editorInstructions*: bool
    controlScope*: ControlScope
    deliveredContextJson*, deliveredContextSources*, deliveredProjectContext*: string
    contextCacheEpoch*, contextHistoryCount*: int
    controlEnvFile*: string

  AgentRegistry* = ref object
    ## Cache of active ACP sessions, keyed by the session id returned to
    ## the caller of ``POST /api/agent/sessions``.  We don't try to
    ## reconcile against the agent's view — if the agent forgets a
    ## session, the next ``POST /api/agent/prompts`` will get an ACP
    ## error and we surface it to the caller untouched.
    ##
    ## ``backend`` / ``customCmd`` / ``customArgs`` capture the ACP
    ## server selection.  They are populated from the ``[agent]``
    ## TOML section (and the ``--agent-backend`` CLI flag) at daemon
    ## startup.  ``extraArgs`` stays for callers that just need to
    ## pass per-session argv tail to ``claude-agent-acp``.
    prepareBackend*: proc(): Future[void] {.gcsafe.}
    controlRegistry*: EditorControlRegistry
    lock: Lock
    sessions: Table[string, AgentSessionState]
    activePrompts: Table[string, bool]
    activePromptStates: Table[string, ptr AgentSessionState]
    retiredSessions: Table[string, AgentSessionState]
    activeCreations: Atomic[int]
    shuttingDown: bool
    backend*: AcpAgentKind
    harborUrl*, harborToken*, harborAgent*, harborModel*: string
    customCmd*: string
    customArgs*: seq[string]
    extraArgs: seq[string]
    ## AI Assistant role-instruction configuration (legacy primer option names).  ``assistantPromptPath`` is
    ## the absolute path the daemon reads for the system prompt;
    ## ``primerEnabled`` controls provider role instructions on session
    ## creation.  ``workspaceRoot`` is the fallback project root used
    ## when ``POST /api/agent/sessions`` doesn't carry ``projectRoot``.
    ## ``db`` is optional — when nil project context skips the
    ## active-campaigns section.
    assistantPromptPath*: string
    primerEnabled*: bool
    workspaceRoot*: string
    db*: ReviewDb

  AgentBackendUnavailableError* = object of CatchableError

const
  SseContentType* = "text/event-stream; charset=utf-8"
  AgentSessionsRoute* = "/api/agent/sessions"
  AgentPromptsRoute* = "/api/agent/prompts"
  AgentCancelRoute* = "/api/agent/cancel"
  AgentCloseRoute* = "/api/agent/close"

# --------------------------------------------------------------------------- #
#  Registry helpers.                                                          #
# --------------------------------------------------------------------------- #

proc cleanupControlEnvironment(filename: string) =
  if filename.len == 0: return
  let python = findExe("python3")
  if python.len == 0: raise newException(OSError, "Python control cleanup boundary unavailable")
  let helper = currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir /
    "tools" / "editor_agent_env.py"
  let process = startProcess(python, args = @[helper, "--cleanup", filename], options = {})
  defer: process.close()
  process.inputStream.close()
  if process.waitForExit() != 0:
    raise newException(OSError, "Private control environment cleanup failed")

proc newAgentRegistry*(extraArgs: seq[string] = @[];
    backend: AcpAgentKind = aakClaude;
    customCmd: string = "";
    customArgs: seq[string] = @[];
    assistantPromptPath: string = "";
    primerEnabled: bool = true;
    workspaceRoot: string = "";
    db: ReviewDb = nil;
    harborUrl = ""; harborToken = ""; harborAgent = ""; harborModel = ""): AgentRegistry =
  ## Allocate an empty session cache. The defaults match the
  ## pre-Phase-C contract (claude-agent-acp without explicit args)
  ## so existing callers keep working untouched.
  ##
  ## ``primerEnabled`` is the retained configuration name for provider role
  ## instructions; false deliberately disables them. ``assistantPromptPath``
  ## selects the complete instruction file. ``workspaceRoot`` is the fallback
  ## project root and ``db`` provides active campaigns for per-turn project data.
  result = AgentRegistry(
    sessions: initTable[string, AgentSessionState](),
    activePrompts: initTable[string, bool](),
    activePromptStates: initTable[string, ptr AgentSessionState](),
    retiredSessions: initTable[string, AgentSessionState](),
    backend: backend,
    harborUrl: harborUrl, harborToken: harborToken,
    harborAgent: harborAgent, harborModel: harborModel,
    customCmd: customCmd,
    customArgs: customArgs,
    extraArgs: extraArgs,
    assistantPromptPath: assistantPromptPath,
    primerEnabled: primerEnabled,
    workspaceRoot: workspaceRoot,
    db: db)
  initLock(result.lock)
  case backend
  of aakClaude:
    info "agent registry initialised", backend = "claude"
  of aakCodex:
    info "agent registry initialised", backend = "codex"
  of aakCustom:
    info "agent registry initialised", backend = "custom",
      cmd = customCmd

proc attachDb*(reg: AgentRegistry; db: ReviewDb) =
  ## CMP-M5 — late-bind the design-review DB handle onto the agent
  ## registry.  Called by ``mountDesignReviewRoutes`` after it opens
  ## the long-lived ``ReviewDb`` connection.  When set, project context's
  ## "Active campaigns" section is populated from
  ## ``design_review.list_campaigns('active', 50, 0)``; when nil the
  ## project context simply omits the section.
  reg.db = db

proc release*(reg: AgentRegistry; sessionId: string) =
  acquire(reg.lock)
  try:
    if reg.sessions.hasKey(sessionId):
      reg.sessions.del(sessionId)
  finally:
    release(reg.lock)

proc finishSessionRelease(reg: AgentRegistry; state: var AgentSessionState) =
  ## Dispose daemon-owned transport/state only on its owner thread.
  let sessionId = state.sessionId
  shutdown(state.client)
  info "agent client shutdown end", sessionId = sessionId
  if reg.controlRegistry != nil: reg.controlRegistry.revokeConversation(sessionId)
  try:
    cleanupControlEnvironment(state.controlEnvFile)
  except OSError as error:
    warn "closed agent control environment cleanup failed", sessionId = sessionId, reason = error.msg
  # Closing the backend can return before its stream worker finishes. Move
  # the owner without changing reference counts; the post-join handler alone
  # disposes it. Check current membership under the same lock: a worker that
  # already joined while close was pending needs no retired holder.
  acquire(reg.lock)
  try:
    if reg.activePrompts.hasKey(sessionId):
      reg.retiredSessions[sessionId] = move(state)
  finally:
    release(reg.lock)

proc shutdownAndRelease*(reg: AgentRegistry; sessionId: string) =
  ## CMP-M7 — take a session out of the registry AND terminate its
  ## ACP transport (including the spawned stdio child).  Used by the
  ## campaign route after a turn ends and by the chat route when the
  ## SSE client explicitly closes the session.  Without this the
  ## daemon leaks one ACP child per session: ``release`` alone only
  ## drops the registry entry, leaving the child alive in the
  ## background because its closures keep the transport pinned.
  var state: AgentSessionState
  var found = false
  acquire(reg.lock)
  try:
    if reg.sessions.hasKey(sessionId):
      state = move(reg.sessions[sessionId])
      reg.sessions.del(sessionId)
      found = true
  finally:
    release(reg.lock)
  if found:
    info "agent client shutdown begin", sessionId = sessionId
    try:
      if state.client.backend == abkHarbor and not state.isDraft:
        {.cast(gcsafe).}:
          state.client.closeSession(state.session)
      reg.finishSessionRelease(state)
    except CatchableError as e:
      warn "agent client shutdown raised",
        sessionId = sessionId, reason = e.msg
      acquire(reg.lock)
      try:
        if not reg.shuttingDown: reg.sessions[sessionId] = move(state)
        elif reg.activePrompts.hasKey(sessionId):
          reg.retiredSessions[sessionId] = move(state)
      finally:
        release(reg.lock)
      raise
  else:
    info "agent client shutdown skipped (not in registry)",
      sessionId = sessionId

proc shutdownAll*(reg: AgentRegistry) =
  ## Stop admission atomically with the snapshot. Close independent sessions
  ## concurrently: N sessions must not multiply the native 30s HTTP deadline.
  ## Creation may consume 30s followed by its late-session stop's 30s. The
  ## supervisor reserves both operations plus owned Harbor teardown (75s).
  var ids, acpIds: seq[string]
  acquire(reg.lock)
  try:
    reg.shuttingDown = true
    # Classify with scalar metadata only: copying a live state here would
    # touch worker-owned transport reference counts during shutdown.
    for id in reg.sessions.keys:
      if reg.sessions[id].client.backend == abkAcp: acpIds.add(id)
      else: ids.add(id)
  finally:
    release(reg.lock)
  type HarborCloseWork = object
    state: AgentSessionState
    succeeded: bool
  # Move ownership on the daemon thread. Workers borrow stable addresses solely
  # for the blocking REST call; they must never move or destroy this state (Nim's
  # GC heap belongs to its allocating thread). Keep it until stream workers join.
  var work = newSeq[HarborCloseWork](ids.len)
  var captured = 0
  acquire(reg.lock)
  try:
    for id in ids:
      if reg.sessions.hasKey(id):
        work[captured].state = move(reg.sessions[id])
        reg.sessions.del(id)
        inc captured
  finally:
    release(reg.lock)
  work.setLen(captured)              # Finalize stable addresses before spawning.
  proc closeOne(work: ptr HarborCloseWork) {.thread, gcsafe.} =
    {.cast(gcsafe).}:
      try:
        if not work.state.isDraft:
          work.state.client.closeSession(work.state.session)
        work.succeeded = true
      except CatchableError as e:
        warn "agent shutdown failed", sessionId = work.state.sessionId, reason = e.msg
  var closers = newSeq[Thread[ptr HarborCloseWork]](work.len)
  for i in 0 ..< work.len:
    info "agent client shutdown begin", sessionId = work[i].state.sessionId
    createThread(closers[i], closeOne, addr work[i])
  # ACP transport callbacks and captured state belong to the daemon thread.
  # Release them here; independent blocking REST closes remain concurrent above.
  for id in acpIds:
    try: reg.shutdownAndRelease(id)
    except CatchableError as e:
      warn "agent shutdown failed", sessionId = id, reason = e.msg
  for closer in closers.mitems: joinThread(closer)
  for item in work.mitems:
    if item.succeeded:
      try: reg.finishSessionRelease(item.state)
      except CatchableError as e:
        warn "agent shutdown failed", sessionId = item.state.sessionId, reason = e.msg
        let id = item.state.sessionId
        acquire(reg.lock)
        try:
          if reg.activePrompts.hasKey(id):
            reg.retiredSessions[id] = move(item.state)
        finally:
          release(reg.lock)
    else:
      let id = item.state.sessionId
      acquire(reg.lock)
      try:
        if reg.activePrompts.hasKey(id):
          reg.retiredSessions[id] = move(item.state)
      finally:
        release(reg.lock)
  # Do not wait for event streams: their provider has been closed above. Do
  # wait for admitted creation AND its compensating close to actually finish.
  # A shorter independent drain timer would abandon a newly returned ID.
  while reg.activeCreations.load() != 0:
    sleep(10)
  # The daemon calls shutdown here on its event-loop thread. Let admitted HTTP
  # handlers finish their channel drain/final join before disposing the registry.
  # Backend closure above terminates their streams; no new admission is allowed.
  while true:
    acquire(reg.lock)
    let pending = reg.activePrompts.len
    release(reg.lock)
    if pending == 0: break
    poll(10)

proc getState*(reg: AgentRegistry; sessionId: string): Option[AgentSessionState] =
  acquire(reg.lock)
  try:
    if reg.sessions.hasKey(sessionId):
      return some(reg.sessions[sessionId])
    else:
      return none(AgentSessionState)
  finally:
    release(reg.lock)

proc sessionBackend(reg: AgentRegistry; sessionId: string): Option[AgentBackendKind] =
  # Scalar metadata reads must not copy client/session reference graphs while
  # the provider worker is using them.
  acquire(reg.lock)
  try:
    if reg.sessions.hasKey(sessionId): return some(reg.sessions[sessionId].client.backend)
    return none(AgentBackendKind)
  finally:
    release(reg.lock)

type PromptAdmission = enum paUnknown, paBusy, paAccepted
proc admitPromptState(reg: AgentRegistry; sessionId: string):
    tuple[admission: PromptAdmission, state: AgentSessionState] =
  acquire(reg.lock)
  try:
    if not reg.sessions.hasKey(sessionId): return (paUnknown, AgentSessionState())
    if reg.shuttingDown or reg.sessions[sessionId].turnWorking:
      return (paBusy, AgentSessionState())
    # The previous HTTP handler clears this flag only after joining its worker.
    # Take the managed input snapshot while no provider worker can use it.
    reg.sessions[sessionId].turnWorking = true
    reg.activePrompts[sessionId] = true
    result = (paAccepted, reg.sessions[sessionId])
  finally:
    release(reg.lock)

proc storeSession(reg: AgentRegistry; state: AgentSessionState) =
  var rejected = false
  acquire(reg.lock)
  try:
    rejected = reg.shuttingDown
    if not rejected: reg.sessions[state.sessionId] = state
  finally:
    release(reg.lock)
  if rejected:
    var client = state.client
    if not state.isDraft: client.closeSession(state.session)
    shutdown(client)
    raise newException(AgentBackendUnavailableError, "Editor daemon is shutting down")

proc storeExistingSession(reg: AgentRegistry; state: AgentSessionState): bool =
  acquire(reg.lock)
  try:
    if reg.shuttingDown or not reg.sessions.hasKey(state.sessionId): return false
    reg.sessions[state.sessionId] = state
    return true
  finally:
    release(reg.lock)

proc setTurnWorking(reg: AgentRegistry; id: string; working: bool): bool =
  acquire(reg.lock)
  try:
    if not working:
      reg.activePrompts.del(id)
      reg.retiredSessions.del(id)
    if not reg.sessions.hasKey(id): return false
    if working and (reg.shuttingDown or reg.sessions[id].turnWorking): return false
    reg.sessions[id].turnWorking = working
    return true
  finally:
    release(reg.lock)

# --------------------------------------------------------------------------- #
#  Session creation.                                                          #
# --------------------------------------------------------------------------- #

proc controlEnvironmentPath*(id: string): string =
  ## Application data stays visible read-only inside Harbor's supported sandbox.
  ## Host /tmp, runtime IPC and mutable cache overlays are deliberately excluded.
  if id.len == 0 or id.anyIt(it notin {'a'..'z', 'A'..'Z', '0'..'9', '-'}):
    raise newException(IOError, "Invalid control environment identity")
  when defined(macosx):
    let data = getHomeDir() / "Library" / "Application Support"
  else:
    let data = getHomeDir() / ".local" / "share"
  data / "isonim" / "editor-control" / ("isonim-control-" & id) / "environment.json"

proc prepareControlEnvironment(reg: AgentRegistry; scope: ControlScope; id: string): string =
  result = controlEnvironmentPath(id)
  let python = findExe("python3")
  if python.len == 0: raise newException(IOError, "Python control launch boundary unavailable")
  let helper = currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir /
    "tools" / "editor_agent_env.py"
  let process = startProcess(python, args = @[helper, "--prepare", result], options = {})
  defer: process.close()
  process.inputStream.write($(%* {
    "ISONIM_EDITOR_ENDPOINT": reg.controlRegistry.endpoint,
    "ISONIM_EDITOR_WORKSPACE": scope.workspace,
    "ISONIM_EDITOR_INSTANCE": scope.instance,
    "ISONIM_EDITOR_EPOCH": scope.epoch,
    "ISONIM_EDITOR_TOKEN": scope.token,
    "ISONIM_EDITOR_CLI_DIR": currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir / "build" / "bin"}))
  process.inputStream.close()
  if process.waitForExit() != 0:
    raise newException(IOError, "Private control environment preparation failed")

proc controlLaunchPrefix(environment: string): seq[string] =
  let python = findExe("python3")
  if python.len == 0: raise newException(AgentBackendUnavailableError, "Python control launch boundary unavailable")
  @[python, currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir /
    "tools" / "editor_agent_env.py", "--environment", environment, "--"]

proc createAcpSession*(reg: AgentRegistry; cwd = "";
    idleTimeoutMs: int = -1; controlScope = ControlScope();
    editorInstructions = false): AgentSessionState {.gcsafe.} =
  ## Spawn the ACP agent, run ``initialize`` + ``session/new`` and stash
  ## the resulting :type:`AgentClient` in the registry.  The agent
  ## selection comes from ``reg.backend`` (set by the daemon from
  ## ``[agent].backend`` / ``--agent-backend``).  Raises
  ## :type:`AgentBackendUnavailableError` when the chosen factory
  ## fails because the binary isn't on PATH.
  ##
  ## ``idleTimeoutMs`` overrides the default per-frame idle silence
  ## budget on the spawned stdio-ACP transport.  Pass a negative value
  ## to keep ``nim-agents``' built-in default (5 min for chat / one-shot
  ## prompts); campaign sessions pass a larger value (default 15 min)
  ## because the orchestrator legitimately stays silent across long
  ## sub-agent dispatches before emitting its next ``session/update``.
  ##
  ## Marked ``gcsafe`` because the surrounding asynchttpserver dispatch
  ## requires it; the nim-acp transport's indirect-call methods are
  ## benign here — per-session state lives entirely inside the cached
  ## :type:`AgentClient`, which never escapes this thread.
  {.gcsafe.}:
    acquire(reg.lock)
    try:
      if reg.shuttingDown:
        raise newException(AgentBackendUnavailableError, "Editor daemon is shutting down")
    finally:
      release(reg.lock)
    var client: AgentClient
    let root = if cwd.len > 0: cwd
               elif reg.workspaceRoot.len > 0: reg.workspaceRoot
               else: getCurrentDir()
    if reg.harborUrl.len > 0:
      let auth = if reg.harborToken.len > 0: bearerAuth(reg.harborToken)
                 else: HarborAuth(kind: akNone)
      var harbor = newNativeHarborClient(reg.harborUrl, auth)
      harbor.transport = nativeHarborTransport(AgentHttpTimeoutMs)
      client = fromHarbor(harbor)
      # This is a local conversation draft, not a fabricated Harbor session.
      # The first user message creates the real backend session.
      let id = "draft-" & $genOid()
      result = AgentSessionState(sessionId: id, client: client, cwd: root, isDraft: true,
        session: AgentSession(backend: abkHarbor), editorInstructions: editorInstructions,
        capabilities: AgentCapabilities(streaming: true, text: true))
      if controlScope.instance.len > 0:
        result.controlScope = reg.controlRegistry.bindConversation(controlScope, id)
      reg.storeSession(result)
      return
    var instructions = ""
    if editorInstructions and reg.primerEnabled:
      if reg.backend != aakClaude:
        raise newException(AgentBackendUnavailableError,
          "System instruction delivery is unsupported for the selected ACP provider; configure a supported provider or explicitly disable instructions")
      if reg.assistantPromptPath.len == 0 or not fileExists(reg.assistantPromptPath):
        raise newException(AgentBackendUnavailableError, "IsoNim system instruction file is missing")
      instructions = readFile(reg.assistantPromptPath)
      if instructions.strip.len == 0:
        raise newException(AgentBackendUnavailableError, "IsoNim system instruction file is empty")
    var scoped: ControlScope
    var environment: string
    var prefix: seq[string]
    var accepted = false
    defer:
      if not accepted:
        if client.backend == abkAcp:
          try: shutdown(client)
          except CatchableError: discard
        if scoped.token.len > 0: reg.controlRegistry.revokeConversation(scoped.conversation)
        try:
          cleanupControlEnvironment(environment)
        except OSError as cleanupError:
          warn "failed creation control environment cleanup", reason = cleanupError.msg
    if controlScope.instance.len > 0:
      let launchId = "launch-" & $genOid()
      scoped = reg.controlRegistry.bindConversation(controlScope, launchId)
      environment = reg.prepareControlEnvironment(scoped, launchId)
      prefix = controlLaunchPrefix(environment)
    try:
      if idleTimeoutMs > 0:
        client = fromAcpAgent(reg.backend, reg.extraArgs,
                             cmd = reg.customCmd, args = reg.customArgs,
                             idleTimeoutMs = idleTimeoutMs, launchPrefix = prefix)
      else:
        client = fromAcpAgent(reg.backend, reg.extraArgs,
                             cmd = reg.customCmd, args = reg.customArgs, launchPrefix = prefix)
    except AcpError as e:
      if scoped.token.len > 0:
        reg.controlRegistry.revokeConversation(scoped.conversation)
        cleanupControlEnvironment(environment)
      error "agent backend unavailable", reason = e.msg,
        backend = $reg.backend
      raise newException(AgentBackendUnavailableError, e.msg)
    let initResp = client.acp.initialize(InitializeRequest(
      protocolVersion: 1,
      clientInfo: ClientInfo(name: "isonim-review", version: "0.1"),
      clientCapabilities: ClientCapabilities(streaming: true)))
    let resolvedCwd = root
    let session = client.startSession(resolvedCwd, systemInstructions = instructions)
    result = AgentSessionState(
      sessionId: session.id,
      client: client,
      session: session,
      capabilities: initResp.agentCapabilities, controlEnvFile: environment,
      cwd: resolvedCwd, editorInstructions: editorInstructions)
    if scoped.token.len > 0:
      result.controlScope = reg.controlRegistry.rebindConversation(scoped, result.sessionId)
    reg.storeSession(result)
    accepted = true
    info "agent session created", sessionId = session.id,
      cwd = resolvedCwd

# --------------------------------------------------------------------------- #
# Separate project context for actual user turns. Role instructions are delivered
# at session/new; no hidden session/prompt or acknowledgement turn is sent.
# --------------------------------------------------------------------------- #

const
  MaxAgentsMdBytes* = 4_096
    ## Cap on the AGENTS.md/CLAUDE.md body included in project context.
    ## Longer files are head+tail truncated with an ellipsis marker so
    ## the system prompt still fits inside the agent's context budget.
  PrimerHeadKeepBytes* = 2_048
  PrimerTailKeepBytes* = 2_048
  PrimerTruncMarker* = "\n\n[…truncated…]\n\n"

proc readAssistantPromptBody*(path: string): string =
  ## Read role instructions verbatim; missing content is an actionable error.
  if path.len == 0:
    return ""
  if not fileExists(path):
    return ""
  try:
    return readFile(path)
  except IOError as e:
    warn "assistant prompt unreadable", path = path, reason = e.msg
    return ""
  except OSError as e:
    warn "assistant prompt unreadable", path = path, reason = e.msg
    return ""

proc truncateAgentsMd*(body: string): string =
  ## Apply the head/tail truncation rule for the AGENTS.md block.
  if body.len <= MaxAgentsMdBytes:
    return body
  result = body[0 ..< PrimerHeadKeepBytes]
  result.add PrimerTruncMarker
  result.add body[body.len - PrimerTailKeepBytes .. ^1]

proc readAgentsMd*(projectRoot: string): tuple[present: bool; body: string] =
  ## CMP-M5 — return the contents of ``AGENTS.md`` (preferred) or
  ## ``CLAUDE.md`` at ``projectRoot``, truncated to
  ## :const:`MaxAgentsMdBytes`.  ``present=false`` when neither file
  ## exists.
  if projectRoot.len == 0:
    return (present: false, body: "")
  for name in ["AGENTS.md", "CLAUDE.md"]:
    let p = projectRoot / name
    if fileExists(p):
      try:
        let raw = readFile(p)
        return (present: true, body: truncateAgentsMd(raw))
      except IOError as e:
        debug "AGENTS.md unreadable", path = p, reason = e.msg
      except OSError as e:
        debug "AGENTS.md unreadable", path = p, reason = e.msg
  (present: false, body: "")

proc renderBriefIndexSummary*(projectRoot: string): string =
  ## CMP-M5 — one line per brief: ``<briefId> — <coversPreviews count>
  ## previews × <backends count> backends — <title>``.  Returns an
  ## empty string when the project has no ``briefs/`` directory.
  if projectRoot.len == 0:
    return ""
  let briefsDir = projectRoot / "briefs"
  if not dirExists(briefsDir):
    return ""
  let idx = try: buildBriefIndex(briefsDir)
            except CatchableError as e:
              debug "brief index build failed", projectRoot = projectRoot,
                reason = e.msg
              return ""
  if idx == nil or idx.byBriefId.len == 0:
    return ""
  for briefId, brief in idx.byBriefId.pairs:
    var beCount = 0
    for cov in brief.coversPreviews:
      beCount += cov.backends.len
    result.add "- " & briefId & " — " &
      $brief.coversPreviews.len & " previews × " &
      $beCount & " backends"
    if brief.title.len > 0:
      result.add " — " & brief.title
    result.add "\n"

proc renderActiveCampaigns*(reg: AgentRegistry): string =
  ## CMP-M5 — one line per active campaign:
  ##   ``<campaignId> — <briefRefs> — round=<latest>``
  ## Returns empty when no DB handle is attached or no campaigns
  ## exist.  Database errors are swallowed (logged at debug) — the
  ## project-context listing is best-effort.
  if reg == nil or reg.db == nil:
    return ""
  try:
    reg.db.asApp()
    let stmt = "SELECT design_review.list_campaigns('active', 50, 0)::text"
    let rows = reg.db.conn.getAllRows(sql(stmt))
    for row in rows:
      if row.len == 0 or row[0].len == 0: continue
      var node: JsonNode
      try: node = parseJson(row[0])
      except JsonParsingError: continue
      let campaignId = node{"campaign_id"}.getStr("")
      if campaignId.len == 0: continue
      var briefRefs = ""
      let refs = node{"brief_refs"}
      if refs != nil and refs.kind == JArray:
        var parts: seq[string]
        for it in refs.items:
          parts.add it.getStr("")
        briefRefs = parts.join(", ")
      var latestRound = 0
      try:
        let r = reg.db.conn.getValue(sql(
          "SELECT design_review.count_campaign_round_complete('" &
          campaignId.replace("'", "''") & "'::uuid)::text"))
        if r.len > 0:
          try: latestRound = parseInt(r)
          except ValueError: discard
      except CatchableError as e:
        debug "active campaign: round count failed",
          campaignId = campaignId, reason = e.msg
      result.add "- " & campaignId
      if briefRefs.len > 0:
        result.add " — " & briefRefs
      result.add " — round=" & $latestRound & "\n"
  except CatchableError as e:
    debug "active campaign listing failed", reason = e.msg
    return ""

proc assembleProjectContext*(projectRoot: string;
    agentsMdPresent: bool; agentsMdBody: string;
    briefIndexSummary, activeCampaigns: string): string =
  ## Project data remains separate from provider role instructions.
  result = "PROJECT CONTEXT:\n\n"
  result.add "Project root: "
  if projectRoot.len > 0:
    result.add projectRoot
  else:
    result.add "(unknown)"
  result.add "\n\n"
  result.add "AGENTS.md (if present): "
  if agentsMdPresent:
    result.add "\n"
    result.add agentsMdBody
    if not agentsMdBody.endsWith("\n"):
      result.add "\n"
  else:
    result.add "(none)\n"
  result.add "\nBrief index (loaded from <project>/briefs/):\n"
  if briefIndexSummary.len > 0:
    result.add briefIndexSummary
  else:
    result.add "(none — no briefs/ directory or no readable briefs)\n"
  result.add "\nActive campaigns:\n"
  if activeCampaigns.len > 0:
    result.add activeCampaigns
  else:
    result.add "(none active)\n"
  result.add "\nCLI tools available (invoke via shell):\n"
  result.add "- `isonim-review campaign list / show <id> / start --doc <path> / inject <id> <text> / edit-doc <id> / tail <id> / stop <id>`\n"
  result.add "- `isonim-review run-review --run <id> --acp-backend codex`\n"
  result.add "- `isonim-review seed-run --brief <id> --capture <be>=<path>...`\n"
  result.add "- `isonim-review capture --brief <id>` (requires clean workspace)\n"
  result.add "- `isonim-review briefs check --project <path>`\n"
  result.add "- `isonim-review db-health [--json]`\n\n"

proc capabilityJson*(c: AgentCapabilities): JsonNode =
  result = %* {
    "streaming": c.streaming,
    "text": c.text,
    "images": c.images,
    "audio": c.audio,
    "resources": c.resources,
    "permissions": c.permissions,
    "terminal": c.terminal,
    "filesystem": {
      "readTextFile": c.filesystemRead,
      "writeTextFile": c.filesystemWrite,
    },
  }

type
  PngAttachmentError* = object of CatchableError
    ## Raised by :proc:`parsePromptFromBody` when a ``pngPaths`` entry
    ## cannot be read or doesn't carry a valid PNG signature.  The
    ## handler maps this into an HTTP 400 with the offending path in
    ## the response body so the CLI caller can surface it directly.
    path*: string

const PngSignature = "\x89PNG\r\n\x1A\n"

proc loadPngAsContentBlock(path: string): ContentBlock =
  ## Read ``path`` and wrap it as an ACP ``image`` content block with
  ## base64-encoded payload and ``image/png`` mime type.  Raises
  ## :type:`PngAttachmentError` if the file is missing or doesn't
  ## start with the canonical PNG 8-byte signature — the daemon and
  ## CLI run on the same host so missing paths almost always mean a
  ## bug in the caller, not a transient FS issue.
  if not fileExists(path):
    var e = newException(PngAttachmentError,
      "could not read PNG " & path & ": file does not exist")
    e.path = path
    raise e
  var bytes = ""
  try:
    bytes = readFile(path)
  except IOError as ioe:
    var e = newException(PngAttachmentError,
      "could not read PNG " & path & ": " & ioe.msg)
    e.path = path
    raise e
  if bytes.len < PngSignature.len or
     bytes[0 ..< PngSignature.len] != PngSignature:
    var e = newException(PngAttachmentError,
      "could not read PNG " & path & ": not a valid PNG (bad signature)")
    e.path = path
    raise e
  result = ContentBlock(
    kind: cbImage,
    mimeType: "image/png",
    data: base64.encode(bytes))

proc parsePromptFromBody*(body: string):
    tuple[sessionId: string; prompt: seq[ContentBlock]] =
  ## Body shape:
  ##   {"sessionId": "...",
  ##    "messages": [{"role":"user","content":[...]}],
  ##    "pngPaths": ["/abs/...", ...]}
  ##
  ## We accept ``messages[].content[]`` items of the form
  ## ``{"type":"text", "text": "..."}`` for the text part.  When
  ## ``pngPaths`` is present each path is read off the local
  ## filesystem, base64-encoded, and appended as an ACP ``image``
  ## content block — these flow through ``sendPromptStreaming`` to the
  ## ACP agent as proper multimodal attachments instead of dropping
  ## out as they did in Phase B's text-only contract.
  ##
  ## Raises :type:`PngAttachmentError` when a ``pngPaths`` entry can't
  ## be read or doesn't carry a valid PNG signature.  The handler
  ## maps this onto an HTTP 400 so the CLI surface gets a clear
  ## diagnosis instead of a stalled agent that quietly received only
  ## the text block.
  let node = parseJson(body)
  result.sessionId = node{"sessionId"}.getStr("")
  let messages = node{"messages"}
  if messages != nil and messages.kind == JArray:
    for msg in messages.items:
      let content = msg{"content"}
      if content == nil or content.kind != JArray:
        continue
      for item in content.items:
        if item{"type"}.getStr("text") != "text":
          continue
        result.prompt.add textBlock(item{"text"}.getStr(""))
  if result.prompt.len == 0 and node.hasKey("text"):
    result.prompt.add textBlock(node["text"].getStr(""))
  let pngPaths = node{"pngPaths"}
  if pngPaths != nil and pngPaths.kind == JArray:
    for entry in pngPaths.items:
      let path = entry.getStr("")
      if path.len == 0: continue
      result.prompt.add loadPngAsContentBlock(path)

proc sessionUpdateJson*(update: SessionUpdate): JsonNode =
  ## Encode an ACP ``SessionUpdate`` back into JSON for the SSE wire
  ## format.  Mirror of :proc:`updateFromJson` in ``nim_acp/client``;
  ## we re-serialise the raw fields we actually filled in to keep the
  ## stream stable across protocol minor bumps.
  if update.raw != nil:
    return update.raw
  result = %* {
    "sessionId": update.sessionId,
    "update": {
      "sessionUpdate": $update.kind,
    },
  }
  case update.kind
  of sukAgentMessageChunk, sukAgentThoughtChunk:
    result["update"]["content"] = contentBlockToJson(update.content)
  of sukToolCall:
    result["update"]["toolCallId"] = %update.toolCallId
    result["update"]["title"] = %update.title
  of sukToolCallUpdate:
    result["update"]["toolCallId"] = %update.toolCallId
    result["update"]["status"] = %update.status
  of sukStatus:
    result["update"]["status"] = %update.status
  else:
    discard

proc isTextChunk*(update: SessionUpdate): bool =
  update.kind == sukAgentMessageChunk and
    update.content.kind == cbText and
    update.content.text.len > 0

# --------------------------------------------------------------------------- #
#  SSE framing.                                                                #
# --------------------------------------------------------------------------- #

proc sseHeaderBlock(): string =
  ## Headers + a blank line — the prelude every SSE response sends
  ## before the first event.
  ##
  ## CORS: the editor sidebar fetches from a different origin
  ## (editor on :8090, daemon on :8113), so the SSE response must
  ## carry ``Access-Control-Allow-Origin`` or Chromium will reject
  ## the body before the first ``data:`` frame is dispatched.
  result = "HTTP/1.1 200 OK\c\L"
  result.add "Content-Type: " & SseContentType & "\c\L"
  result.add "Cache-Control: no-store\c\L"
  result.add "Connection: close\c\L"
  result.add "X-Accel-Buffering: no\c\L"
  result.add "Access-Control-Allow-Origin: *\c\L"
  result.add "Access-Control-Allow-Methods: GET, POST, OPTIONS\c\L"
  result.add "Access-Control-Allow-Headers: Content-Type\c\L"
  result.add "\c\L"

proc encodeSseEvent*(eventType, data: string): string =
  ## Serialise one SSE event.  Multi-line ``data`` is split on ``\n``
  ## per the SSE spec.
  if eventType.len > 0:
    result.add "event: " & eventType & "\n"
  for line in data.split('\n'):
    result.add "data: " & line & "\n"
  result.add "\n"

# --------------------------------------------------------------------------- #
#  Route handlers.                                                            #
# --------------------------------------------------------------------------- #

proc respondJson*(req: Request; code: HttpCode; body: string)
    {.async, gcsafe.} =
  ## CORS: the editor sidebar fetches across origins
  ## (editor on :8090, daemon on :8113), so every JSON response must
  ## carry ``Access-Control-Allow-Origin`` or the browser will block
  ## the body even though the preflight succeeded.  Mirrors the
  ## headers already on ``api_handlers.respondJson`` for the
  ## ``/api/design-review/*`` routes.
  let headers = newHttpHeaders([
    ("Content-Type", "application/json"),
    ("Cache-Control", "no-store"),
    ("Access-Control-Allow-Origin", "*"),
    ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
    ("Access-Control-Allow-Headers", "Content-Type, X-IsoNim-Control"),
  ])
  await req.respond(code, body, headers)

proc respondBackendUnavailable*(req: Request; reason: string)
    {.async, gcsafe.} =
  let body = $(%* {
    "error": "agent_backend_unavailable",
    "reason": reason,
  })
  await respondJson(req, Http503, body)

proc requestPeerConnected(req: Request): bool =
  if req.client.isClosed: return false
  when defined(posix):
    # The accepted AsyncSocket is nonblocking. Peek without consuming any
    # pipelined request: EOF/reset means this pending admission has no recipient.
    var byte: char
    let count = posix.recv(cast[posix.SocketHandle](req.client.getFd), addr byte, 1, MSG_PEEK)
    if count == 0: return false
    if count < 0 and errno notin [EAGAIN, EWOULDBLOCK, EINTR]: return false
  true

proc handleSessions*(reg: AgentRegistry; req: Request)
    {.async, gcsafe.} =
  ## ``POST /api/agent/sessions`` handler.
  ##
  ## Enabled role instructions use session/new metadata for supported ACP;
  ## Harbor drafts inject them at provider launch. No user primer is sent.
  ## The request body may carry ``projectRoot`` to override the
  ## daemon's workspace-root fallback.
  if req.reqMethod != HttpPost:
    await respondJson(req, Http405,
      $(%* {"error": "method_not_allowed"}))
    return
  var cwd = ""
  var projectRoot = ""
  var scope: ControlScope
  if req.body.len > 0:
    try:
      let node = parseJson(req.body)
      cwd = node{"cwd"}.getStr("")
      projectRoot = node{"projectRoot"}.getStr("")
      if node{"editor"} != nil:
        if reg.controlRegistry == nil: raise newException(ControlError, "control_unavailable")
        scope = reg.controlRegistry.validateBrowserScope(node["editor"],
          req.headers.getOrDefault("X-IsoNim-Control"))
        if (cwd.len > 0 and cwd != reg.workspaceRoot) or
            (projectRoot.len > 0 and projectRoot != reg.workspaceRoot):
          raise newException(ControlError, "scoped_workspace_root_mismatch")
    except JsonParsingError:
      await respondJson(req, Http400, $(%* {"error": "invalid_json"}))
      return
    except ControlError as error:
      await respondJson(req, Http403, $(%* {"error": error.msg}))
      return
  try:
    if reg.prepareBackend != nil:
      info "agent session waiting for backend preparation", topics = "agent"
      await reg.prepareBackend()
      if not requestPeerConnected(req): return
      # Preparation yields to unrelated requests. Browser authority can change
      # during that wait; revalidate before admitting a session or instructions.
      if scope.instance.len > 0:
        let node = parseJson(req.body)
        scope = reg.controlRegistry.validateBrowserScope(node["editor"],
          req.headers.getOrDefault("X-IsoNim-Control"))
    var state: AgentSessionState
    {.cast(gcsafe).}:
      state = createAcpSession(reg,
        (if cwd.len > 0: cwd elif projectRoot.len > 0: projectRoot else: ""),
        controlScope = scope, editorInstructions = true)
    let body = $(%* {
      "sessionId": state.sessionId,
      "backendSessionId": state.session.id,
      "backend": (if state.client.backend == abkHarbor: "harbor" else: "acp"),
      "sessionState": (if state.isDraft: "draft" else: "ready"),
      "sessionCapabilities": {"persistent": true,
        "cancelTurn": state.client.backend == abkAcp, "closeSession": true},
      "agentCapabilities": capabilityJson(state.capabilities),
    })
    try:
      await respondJson(req, Http200, body)
    except CatchableError:
      # A newly admitted session is owned only after its identity is delivered.
      # Compensate a failed response; disconnects on later SSE keep sessions.
      reg.shutdownAndRelease(state.sessionId)
      raise
  except ControlError as error:
    await respondJson(req, Http403, $(%* {"error": error.msg}))
  except AgentBackendUnavailableError as e:
    await respondBackendUnavailable(req, e.msg)
  except CatchableError as e:
    error "agent session creation failed", reason = e.msg
    await respondJson(req, Http500,
      $(%* {"error": "agent_init_failed", "reason": e.msg}))

proc cancelSession(reg: AgentRegistry; sessionId: string) {.gcsafe.} =
  {.gcsafe.}:
    var idleState: AgentSessionState
    var state: ptr AgentSessionState
    acquire(reg.lock)
    try:
      if not reg.sessions.hasKey(sessionId): return
      if reg.activePromptStates.hasKey(sessionId):
        # This manually owned record is stable through the final worker join.
        state = reg.activePromptStates[sessionId]
      else:
        # No worker has started, so taking a temporary owned copy is safe.
        idleState = reg.sessions[sessionId]
        state = addr idleState
    finally:
      release(reg.lock)
    try:
      state.client.cancelSession(state.session)
      info "agent session cancelled", sessionId = sessionId
    except CatchableError as e:
      warn "agent cancel failed", sessionId = sessionId, reason = e.msg

proc handleClose*(reg: AgentRegistry; req: Request) {.async, gcsafe.} =
  if req.reqMethod != HttpPost:
    await respondJson(req, Http405, $(%* {"error": "method_not_allowed"}))
    return
  var id: string
  try:
    id = parseJson(req.body){"sessionId"}.getStr()
  except CatchableError:
    await respondJson(req, Http400, $(%* {"error": "invalid_json"}))
    return
  if id.len == 0 or reg.sessionBackend(id).isNone:
    await respondJson(req, Http404, $(%* {"error": "unknown_session"}))
    return
  try:
    {.cast(gcsafe).}:
      reg.shutdownAndRelease(id)
      if reg.controlRegistry != nil: reg.controlRegistry.revokeConversation(id)
    await respondJson(req, Http200, $(%* {"closed": true}))
  except CatchableError as error:
    await respondJson(req, Http502, $(%* {"error": "session_close_failed", "reason": error.msg}))

proc handleCancel*(reg: AgentRegistry; req: Request)
    {.async, gcsafe.} =
  ## ``POST /api/agent/cancel`` handler.
  if req.reqMethod != HttpPost:
    await respondJson(req, Http405,
      $(%* {"error": "method_not_allowed"}))
    return
  var sessionId = ""
  if req.body.len > 0:
    try:
      sessionId = parseJson(req.body){"sessionId"}.getStr("")
    except JsonParsingError:
      await respondJson(req, Http400,
        $(%* {"error": "invalid_json"}))
      return
  if sessionId.len == 0:
    await respondJson(req, Http400,
      $(%* {"error": "missing_sessionId"}))
    return
  let backend = reg.sessionBackend(sessionId)
  if backend.isSome and backend.get == abkHarbor:
    await respondJson(req, Http409, $(%* {"error": "unsupported_capability",
      "reason": "This provider cannot cancel a turn without closing its session"}))
    return
  cancelSession(reg, sessionId)
  await respondJson(req, Http202, $(%* {"accepted": true}))

proc sendSseLine(sock: AsyncSocket; payload: string): Future[bool] {.async.} =
  try:
    await sock.send(payload)
    return true
  except CatchableError as e:
    debug "SSE send failed (client likely disconnected)", reason = e.msg
    return false

proc emitUpdates(reg: AgentRegistry; sessionId: string;
                 sock: AsyncSocket): Future[bool] {.async, gcsafe.} =
  ## Drain pending ``session/update`` events and forward each as an SSE
  ## frame.  Returns ``false`` when the SSE socket has gone away.
  var updates: seq[SessionUpdate]
  {.gcsafe.}:
    let stateOpt = reg.getState(sessionId)
    if not stateOpt.isSome:
      return true
    var state = stateOpt.get
    if state.client.backend == abkAcp:
      updates = state.client.acp.drainUpdates()
  for update in updates:
    let evt = encodeSseEvent("session/update",
                             $sessionUpdateJson(update))
    if not await sendSseLine(sock, evt):
      return false
  return true

proc cleanupAbortedControlEnvironment(reg: AgentRegistry; state: AgentSessionState) =
  if state.controlEnvFile.len == 0: return
  acquire(reg.lock)
  try:
    # A still-registered draft owns this file for a legitimate provider retry.
    # Cleanup belongs only to the aborted launch whose owner has disappeared.
    if reg.sessions.hasKey(state.sessionId) and
        reg.sessions[state.sessionId].controlEnvFile == state.controlEnvFile: return
    try:
      cleanupControlEnvironment(state.controlEnvFile)
    except OSError as error:
      warn "aborted agent control environment cleanup failed", sessionId = state.sessionId, reason = error.msg
  finally:
    release(reg.lock)

proc runAgentTurn*(reg: AgentRegistry; state: AgentSessionState;
    promptBlocks: seq[ContentBlock]; onEvent: AgentEventCallback;
    editorContextIndex = -1; projectContextIndex = -1): PromptTurn {.gcsafe.} =
  {.cast(gcsafe).}:
    var client = state.client
    var active = state
    var turn: PromptTurn
    let wasDraft = active.isDraft
    const RestartEvents = ["session_started", "dispatcher_restarted", "dispatch_restart",
      "session_leadership_migrated"]
    if client.backend == abkHarbor and not active.isDraft and
        (active.deliveredContextJson.len > 0 or active.deliveredProjectContext.len > 0):
      var continuous = false
      try:
        let history = client.eventHistoryPage(active.session, limit = 200)
        let added = history.totalCount - active.contextHistoryCount
        continuous = added >= 0 and added <= history.events.len
        if continuous:
          for i in 0 ..< added:
            if history.events[i].sourceType in RestartEvents: continuous = false
      except CatchableError:
        discard # missing continuity proof means full data, never references
      if not continuous:
        active.deliveredContextJson = ""
        active.deliveredContextSources = ""
        active.deliveredProjectContext = ""
        acquire(reg.lock)
        try:
          if reg.sessions.hasKey(active.sessionId):
            inc active.contextCacheEpoch
            var invalidated = reg.sessions[active.sessionId]
            invalidated.contextCacheEpoch = active.contextCacheEpoch
            invalidated.deliveredContextJson = ""
            invalidated.deliveredContextSources = ""
            invalidated.deliveredProjectContext = ""
            reg.sessions[active.sessionId] = invalidated
        finally: release(reg.lock)
    var restarted = false
    var starts = 0
    var hadReferences = false
    var projectReferenced = false
    defer:
      if restarted:
        acquire(reg.lock)
        try:
          if reg.sessions.hasKey(active.sessionId):
            var invalidated = reg.sessions[active.sessionId]
            inc invalidated.contextCacheEpoch
            invalidated.deliveredContextJson = ""
            invalidated.deliveredContextSources = ""
            invalidated.deliveredProjectContext = ""
            reg.sessions[active.sessionId] = invalidated
        finally: release(reg.lock)
    let eventCallback: AgentEventCallback = proc(event: AgentEvent) {.gcsafe.} =
      {.cast(gcsafe).}:
        if event.sourceType == "session_started": inc starts
        if event.sourceType in RestartEvents and
            (event.sourceType != "session_started" or not wasDraft or starts > 1):
          restarted = true
        if onEvent != nil: onEvent(event)
        if restarted and hadReferences:
          raise newException(HarborError, "Provider restarted during context-reference delivery; acceptance is uncertain. Start a new conversation with full current context.")
    var deliveredBlocks: seq[ContentBlock]
    for item in promptBlocks: deliveredBlocks.add item
    let priorContext = if active.deliveredContextJson.len > 0:
      parseJson(active.deliveredContextJson) else: newJObject()
    var currentContextSources = newJObject()
    let priorSources = if active.deliveredContextSources.len > 0:
      parseJson(active.deliveredContextSources) else: newJObject()
    if editorContextIndex >= 0:
      let context = parseJson(promptBlocks[editorContextIndex].text[EditorContextLabel.len .. ^1])
      let wireContext = referenceContext(context, priorContext, priorSources)
      deliveredBlocks[editorContextIndex] = textBlock(EditorContextLabel & $wireContext)
      currentContextSources = contextSourceIdentities(context)
      # A complete-data escape changes bytes without depending on prior data.
      # Only the generated outer reference envelope requires that provider base.
      hadReferences = wireContext.kind == JObject and wireContext.hasKey("fromContext")
    if projectContextIndex >= 0 and active.deliveredProjectContext.len > 0 and
        promptBlocks[projectContextIndex].text == active.deliveredProjectContext:
      hadReferences = true
      projectReferenced = true
      deliveredBlocks[projectContextIndex] = textBlock("PROJECT CONTEXT: same " &
        $secureHash(active.deliveredProjectContext))
    if client.backend == abkHarbor and active.isDraft:
      var launchAccepted = false
      defer:
        if not launchAccepted: reg.cleanupAbortedControlEnvironment(active)
      acquire(reg.lock)
      try:
        if reg.shuttingDown or not reg.sessions.hasKey(active.sessionId):
          raise newException(HarborError, "Conversation closed before provider launch")
        if not reg.sessions[active.sessionId].isDraft:
          raise newException(HarborError, "Conversation changed before provider launch")
      finally:
        release(reg.lock)
      let software = if reg.harborAgent.len > 0: reg.harborAgent else: "claude"
      var binary = reg.customCmd
      var providerArgs = reg.customArgs
      if binary.len == 0:
        case software
        of "claude":
          binary = findExe("claude-agent-acp")
          if binary.len == 0: binary = findExe("claude-code-acp")
        of "codex": binary = findExe("codex-acp")
        else:
          raise newException(AgentBackendUnavailableError,
            "Persistent Harbor provider requires an explicit ACP launch command")
      if binary.len == 0:
        raise newException(AgentBackendUnavailableError, "Persistent ACP provider is unavailable: " & software)
      let instructionEnabled = active.editorInstructions and reg.primerEnabled
      if instructionEnabled and software != "claude":
        raise newException(AgentBackendUnavailableError,
          "System instruction delivery is not supported for this provider")
      let launcher = currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir /
        "tools" / "agent_session_launcher.py"
      if instructionEnabled and not fileExists(reg.assistantPromptPath):
        raise newException(AgentBackendUnavailableError, "IsoNim session instructions are missing")
      if instructionEnabled or active.controlScope.instance.len > 0 or reg.harborModel.len > 0:
        if not fileExists(launcher):
          raise newException(AgentBackendUnavailableError, "IsoNim provider launcher is missing")
        var launcherArgs = @[launcher]
        if instructionEnabled: launcherArgs.add @["--instructions", reg.assistantPromptPath]
        if active.controlScope.instance.len > 0:
          launcherArgs.add @["--environment", controlEnvironmentPath(active.sessionId)]
        providerArgs = launcherArgs & @["--", binary] & providerArgs
        binary = findExe("python3")
        if binary.len == 0:
          raise newException(AgentBackendUnavailableError, "Python is required for provider instructions and scoped terminals")
      if active.controlScope.instance.len > 0:
        # No credential in launch argv or instructions. The private handoff file
        # provides child environment; only its random path enters provider args.
        acquire(reg.lock)
        try:
          if reg.shuttingDown or not reg.sessions.hasKey(active.sessionId):
            raise newException(HarborError, "Conversation closed before provider launch")
          if not reg.sessions[active.sessionId].isDraft:
            raise newException(HarborError, "Conversation changed before provider launch")
          # Preparation and ownership transfer are atomic against session close.
          active.controlEnvFile = controlEnvironmentPath(active.sessionId)
          discard reg.prepareControlEnvironment(active.controlScope, active.sessionId)
          reg.sessions[active.sessionId] = active
        finally:
          release(reg.lock)
        let prefix = controlLaunchPrefix(active.controlEnvFile)
        providerArgs = prefix[1 .. ^1] & @[binary] & providerArgs
        binary = prefix[0]
      var workspace = defaultWorkspaceContext(active.cwd)
      workspace.workingCopyMode = "in_place"
      let config = AgentStartMode(workspace: workspace, allowNetwork: true,
        prompt: deliveredBlocks, acpAgent: acpAgentConfig(binary, providerArgs, model = reg.harborModel))
      acquire(reg.lock)
      try:
        if reg.shuttingDown or not reg.sessions.hasKey(active.sessionId):
          raise newException(HarborError, "Conversation closed before provider launch")
        discard reg.activeCreations.fetchAdd(1)
      finally:
        release(reg.lock)
      try:
        active.session = client.createSession(config)
        active.isDraft = false
        active.client = client
        if not reg.storeExistingSession(active):
          client.closeSession(active.session)
          raise newException(HarborError, "Conversation closed while backend session was being created")
      finally:
        discard reg.activeCreations.fetchSub(1)
      turn = streamAgentTurn(client, active.session, eventCallback)
      launchAccepted = true
    else:
      var retryBlocks: seq[ContentBlock]
      try:
        turn = sendPromptStreaming(client, active.session, deliveredBlocks, eventCallback)
      except PromptRejectedError as rejection:
        let quota = rejection.response
        if client.backend != abkHarbor or not quota.noOperation or
            quota.stopReason != "context_limit" or quota.remainingChars <= 0 or quota.sessionId != active.session.id:
          raise
        # Only a complete, validated no-operation rejection permits this single
        # intentional retry. All user/resource/project blocks remain exact.
        # Provenance belongs to the handler's constructed block, never a
        # user-authored string which happens to start with the same label.
        let contextIndex = editorContextIndex
        if contextIndex < 0 or contextIndex >= deliveredBlocks.len or
            deliveredBlocks[contextIndex].kind != cbText: raise
        let wireContext = parseJson(deliveredBlocks[contextIndex].text[EditorContextLabel.len .. ^1])
        let source = parseJson(promptBlocks[contextIndex].text[EditorContextLabel.len .. ^1])
        let original = deliveredContext(wireContext, priorContext, source)
        var compacted: seq[ContentBlock]
        for item in deliveredBlocks: compacted.add item
        compacted[contextIndex] = textBlock(EditorContextLabel)
        let fixedChars = runeLen(harborPromptText(compacted))
        let bounded = compactEditorContext(original, quota.remainingChars - fixedChars, priorContext)
        if bounded.isNone: raise
        let retryWire = referenceContext(bounded.get, priorContext, nil)
        compacted[contextIndex] = textBlock(EditorContextLabel & $retryWire)
        if runeLen(harborPromptText(compacted)) > quota.remainingChars: raise
        acquire(reg.lock)
        try:
          if reg.shuttingDown or not reg.sessions.hasKey(active.sessionId):
            raise newException(HarborError, "Conversation closed before context quota retry")
        finally:
          release(reg.lock)
        # A budget status is never provider admission. The actual retry's output
        # or successful completion establishes delivery of all protected edits.
        if onEvent != nil:
          var fields = @[AgentPresentationField(name: "Remaining Unicode characters", value: $quota.remainingChars)]
          for marker in bounded.get["contextAvailability"]:
            if marker.getStr().contains("quota truncated"):
              fields.add AgentPresentationField(name: "Optional context", value: marker.getStr())
          onEvent(AgentEvent(kind: aekStatus, sessionId: active.session.id,
            sourceType: "editor_context_budget",
            text: "Backend quota rejected this turn before delivery. Retrying once with bounded optional context; exact user text and pending edits are retained.",
            presentationFields: fields))
        # Recompute semantic dependence for the actual intentional retry,
        # preserving any independently referenced project guidance.
        hadReferences = projectReferenced or
          (retryWire.kind == JObject and retryWire.hasKey("fromContext"))
        retryBlocks = compacted
      # Leave the rejected request's exception frame before executing the one
      # genuine delivery retry; a second rejection propagates normally.
      if retryBlocks.len > 0:
        deliveredBlocks = retryBlocks
        turn = sendPromptStreaming(client, active.session, retryBlocks, eventCallback)
    if turn.stopReason in {srEndTurn, srMaxTokens} and not restarted:
      var historyCount = 0
      var historyKnown = client.backend != abkHarbor
      if client.backend == abkHarbor:
        try:
          historyCount = client.eventHistoryPage(active.session, limit = 1).totalCount
          historyKnown = true
        except CatchableError: discard
      # Only this actual provider's successful turn advances delivered cache.
      # Registry ownership and provider identity must still match after close.
      acquire(reg.lock)
      try:
        if not reg.shuttingDown and reg.sessions.hasKey(active.sessionId) and
            reg.sessions[active.sessionId].session.id == active.session.id and
            reg.sessions[active.sessionId].contextCacheEpoch == active.contextCacheEpoch and historyKnown:
          var updated = reg.sessions[active.sessionId]
          updated.contextHistoryCount = historyCount
          if editorContextIndex >= 0:
            let wire = parseJson(deliveredBlocks[editorContextIndex].text[EditorContextLabel.len .. ^1])
            let original = parseJson(promptBlocks[editorContextIndex].text[EditorContextLabel.len .. ^1])
            updated.deliveredContextJson = $deliveredContext(wire, priorContext, original)
            updated.deliveredContextSources = $currentContextSources
          if projectContextIndex >= 0:
            updated.deliveredProjectContext = promptBlocks[projectContextIndex].text
          reg.sessions[active.sessionId] = updated
      finally:
        release(reg.lock)
    return turn

type
  AgentPromptCompletion = object
    response: PromptResponse
    error: string
    rejectionDetails: string
  AgentStreamBridge = object
    frames: Channel[string]
    completion: Channel[AgentPromptCompletion]
  AgentPromptWork = object
    # Borrow the main-owned registry and input only until the final join.
    # The work record itself has no reference-counted owner shared by threads.
    registry: ptr AgentRegistry
    state: AgentSessionState
    prompt: seq[ContentBlock]
    editorContextIndex, projectContextIndex: int
    bridge: ptr AgentStreamBridge
    done: Atomic[bool]

proc streamBridgeCallback(bridge: ptr AgentStreamBridge; backend: AgentBackendKind): AgentEventCallback =
  # This factory MUST remain outside the async HTTP handler: the callback's
  # environment owns only this pointer, never an async Future/request graph.
  var providerObserved = false
  result = proc(ev: AgentEvent) {.gcsafe.} =
    {.cast(gcsafe).}:
      # A draft, REST reservation, durable user_input and SSE prelude can all
      # precede a failed provider launch. This turn's actual provider output (or
      # successful completion) proves delivery to the initialized provider.
      # Harbor log events also include harness/startup logs, so they cannot
      # establish provider admission. Direct ACP message notifications belong to
      # the active prompt callback; tools/thoughts and successful responses are
      # provider evidence on both transports.
      if not providerObserved and ((backend == abkAcp and ev.kind == aekMessageChunk) or
          ev.kind in {aekThoughtChunk, aekToolCall, aekToolCallUpdate} or
          (ev.kind == aekCompleted and ev.stopReason in {srEndTurn, srMaxTokens})):
        providerObserved = true
        bridge.frames.send(encodeSseEvent("admitted", $(%* {"accepted": true})))
      let payload = if ev.raw != nil and ev.raw.hasKey("update"):
                      ev.raw else: toJson(ev)
      let frame = encodeSseEvent("session/update", $payload)
      debug "agent.streaming.chunk", sessionId = ev.sessionId,
        kind = $ev.kind, bytes = frame.len
      bridge.frames.send(frame)

proc popStreamFrames(bridge: ptr AgentStreamBridge): seq[string] =
  while true:
    let message = bridge.frames.tryRecv()
    if not message.dataAvailable: break
    result.add message.msg

proc runPromptWorker(work: ptr AgentPromptWork) {.thread, gcsafe.} =
  {.cast(gcsafe).}:
    var completion: AgentPromptCompletion
    try:
      # Callback creation and destruction belong entirely to this worker.
      let callback = streamBridgeCallback(work.bridge, work.state.client.backend)
      let turn = runAgentTurn(work.registry[], work.state, work.prompt, callback, work.editorContextIndex, work.projectContextIndex)
      if turn.stopReason in {srEndTurn, srMaxTokens}:
        # ACP may return a successful response without any output notification.
        # This is still an actual provider response, never a reservation ACK.
        work.bridge.frames.send(encodeSseEvent("admitted", $(%* {"accepted": true})))
      completion.response = PromptResponse(sessionId: work.state.sessionId,
                                           stopReason: turn.stopReason)
    except PromptRejectedError as rejection:
      completion.error = rejection.msg
      let response = rejection.response
      var details = %* {"stopReason": response.stopReason,
        "operationId": (if response.operationIdNull: newJNull() else: %response.operationId),
        "noOperation": response.noOperation, "deliveryState": (if response.deliveryStateNull: newJNull() else: %response.deliveryState),
        "limitChars": response.limitChars, "usedChars": response.usedChars,
        "currentChars": response.currentChars, "remainingChars": response.remainingChars,
        "overLimitBy": response.overLimitBy}
      if not response.operationIdPresent: details.delete("operationId")
      if not response.deliveryStatePresent: details.delete("deliveryState")
      else: details["deliveryStateType"] = %response.deliveryStateType
      completion.rejectionDetails = $details
    except CatchableError as error:
      completion.error = error.msg
    # Channels transfer managed message ownership; the worker never writes
    # strings/references into the live main-thread async frame.
    work.bridge.completion.send(completion)
    work.done.store(true)

proc handlePrompts*(reg: AgentRegistry; req: Request)
    {.async, gcsafe.} =
  ## ``POST /api/agent/prompts`` handler.  Emits the SSE stream.
  ##
  ## Progressive delivery: ``sendPromptStreaming`` invokes a synchronous
  ## per-frame callback as each ``session/update`` arrives from the ACP
  ## child.  The callback enqueues the encoded SSE bytes onto a buffer
  ## the async dispatch loop drains while waiting for the prompt
  ## response.  Notifications received before the response therefore
  ## reach the SSE client immediately, not at end-of-turn.
  if req.reqMethod != HttpPost:
    await respondJson(req, Http405,
      $(%* {"error": "method_not_allowed"}))
    return
  var sessionId: string
  var prompt: seq[ContentBlock]
  var editorContextIndex = -1
  var projectContextIndex = -1
  try:
    let parsed = parsePromptFromBody(req.body)
    sessionId = parsed.sessionId
    prompt = parsed.prompt
    let body = parseJson(req.body)
    if body{"context"} != nil:
      let context = body["context"]
      if context.kind != JObject or ($context).len > 262144:
        await respondJson(req, Http400, $(%* {"error": "invalid_editor_context"}))
        return
      editorContextIndex = prompt.len
      prompt.add textBlock(EditorContextLabel & $context)
  except JsonParsingError:
    await respondJson(req, Http400,
      $(%* {"error": "invalid_json"}))
    return
  except PngAttachmentError as pe:
    warn "agent prompt rejected: bad png attachment",
      path = pe.path, reason = pe.msg
    await respondJson(req, Http400,
      $(%* {"error": "bad_png_attachment",
            "path": pe.path,
            "reason": pe.msg}))
    return
  if sessionId.len == 0:
    await respondJson(req, Http400,
      $(%* {"error": "missing_sessionId"}))
    return
  if prompt.len == 0:
    await respondJson(req, Http400,
      $(%* {"error": "empty_prompt"}))
    return
  let admitted = reg.admitPromptState(sessionId)
  if admitted.admission == paUnknown:
    await respondJson(req, Http404,
      $(%* {"error": "unknown_session", "sessionId": sessionId}))
    return
  if admitted.admission == paBusy:
    await respondJson(req, Http409, $(%* {"error": "turn_already_running"}))
    return
  defer: discard reg.setTurnWorking(sessionId, false)
  var state = admitted.state
  state.turnWorking = true
  {.cast(gcsafe).}:
    if state.editorInstructions:
      let agentsMd = readAgentsMd(state.cwd)
      var project = assembleProjectContext(state.cwd, agentsMd.present,
        agentsMd.body, renderBriefIndexSummary(state.cwd), renderActiveCampaigns(reg))
      projectContextIndex = prompt.len
      prompt.add textBlock(project)

  var textBlocks = 0
  var imageBlocks = 0
  for b in prompt:
    case b.kind
    of cbText: inc textBlocks
    of cbImage: inc imageBlocks
    else: discard
  info "agent prompt submitted", sessionId = sessionId,
    promptBlocks = prompt.len,
    textBlocks = textBlocks,
    imageBlocks = imageBlocks

  # Test hook: when ``$FAKE_ACP_CONTENT_LOG`` is set, append a JSON
  # summary of the inbound prompt's content blocks so test fixtures
  # can assert image bundling without inspecting ACP transport bytes.
  let contentLog = getEnv("FAKE_ACP_CONTENT_LOG")
  if contentLog.len > 0:
    var summary = %* {
      "sessionId": sessionId,
      "promptBlocks": prompt.len,
      "textBlocks": textBlocks,
      "imageBlocks": imageBlocks,
      "blocks": newJArray(),
    }
    for b in prompt:
      var entry = %* {"type": $b.kind}
      case b.kind
      of cbText:
        entry["textLen"] = %b.text.len
      of cbImage, cbAudio, cbResource:
        entry["mimeType"] = %b.mimeType
        entry["dataLen"] = %b.data.len
      summary["blocks"].add entry
    try:
      let f = open(contentLog, fmAppend)
      defer: f.close()
      f.write($summary & "\n")
    except IOError:
      discard
  let prelude = sseHeaderBlock()
  if not await sendSseLine(req.client, prelude):
    info "agent SSE client disconnected before prelude",
      sessionId = sessionId
    return
  # First drain — emit anything already buffered (e.g. greeting frames
  # the agent sent during ``initialize``).
  if not await emitUpdates(reg, sessionId, req.client):
    cancelSession(reg, sessionId)
    return

  # Keep the async Future/request graph on the event-loop thread. Native
  # channels transfer frame/completion ownership from the provider worker.
  # Their manually owned pointers stay alive until every worker exit is joined.
  let streamBridge = cast[ptr AgentStreamBridge](allocShared0(sizeof(AgentStreamBridge)))
  streamBridge.frames.open()
  streamBridge.completion.open()
  let work = cast[ptr AgentPromptWork](allocShared0(sizeof(AgentPromptWork)))
  work.registry = unsafeAddr(reg)
  work.state = state
  work.prompt = prompt
  work.editorContextIndex = editorContextIndex
  work.projectContextIndex = projectContextIndex
  work.bridge = streamBridge
  var worker: Thread[ptr AgentPromptWork]
  var workerStarted = false
  defer:
    if workerStarted: joinThread(worker)
    acquire(reg.lock)
    reg.activePromptStates.del(sessionId)
    release(reg.lock)
    # Channel.close frees its raw queue, so drain typed payloads explicitly on
    # every path (including disconnected streams and exceptional pump exits).
    discard popStreamFrames(streamBridge)
    while true:
      let remaining = streamBridge.completion.tryRecv()
      if not remaining.dataAvailable: break
    reset(work[])
    deallocShared(work)
    streamBridge.frames.close()
    streamBridge.completion.close()
    deallocShared(streamBridge)
  acquire(reg.lock)
  reg.activePromptStates[sessionId] = addr work.state
  release(reg.lock)
  createThread(worker, runPromptWorker, work)
  workerStarted = true

  var stopReason = "error"
  var promptError = ""
  var promptDone = false
  var promptResp: PromptResponse

  # Async pump: while the worker is running, periodically flush any
  # frames the callback enqueued onto the SSE socket.
  var disconnected = false
  while not work.done.load():
    let pending = popStreamFrames(streamBridge)
    if not disconnected:
      for frame in pending:
        if not await sendSseLine(req.client, frame):
          disconnected = true
          break
    # A disconnected response stream does not close a persistent session.
    # Continue draining without blocking the daemon's other HTTP/RPC handlers.
    await sleepAsync(10)

  joinThread(worker)
  workerStarted = false
  if disconnected: return
  promptDone = true
  let completion = streamBridge.completion.recv()
  promptResp = completion.response
  if completion.error.len > 0:
    promptError = completion.error
    error "agent prompt failed", sessionId = sessionId, reason = promptError
  else:
    stopReason = $promptResp.stopReason

  # Final flush — any frames that arrived right before the response.
  let trailing = popStreamFrames(streamBridge)
  for frame in trailing:
    if not await sendSseLine(req.client, frame):
      cancelSession(reg, sessionId)
      return

  # Clear the ACP transport's drain buffer — the streaming callback
  # already forwarded each notification to the SSE socket, so we MUST
  # NOT re-emit them via :proc:`drainUpdates` (that would duplicate
  # every chunk).  We still need to drain so the buffer doesn't grow
  # unboundedly across turns; just discard the result.
  {.gcsafe.}:
    let stOpt = reg.getState(sessionId)
    if stOpt.isSome:
      var s = stOpt.get
      if s.client.backend == abkAcp:
        discard s.client.acp.drainUpdates()

  if promptError.len > 0:
    let errEvent = encodeSseEvent("error",
      $(%* {"sessionId": sessionId, "reason": promptError,
        "rejection": (if completion.rejectionDetails.len > 0: parseJson(completion.rejectionDetails) else: newJNull())}))
    discard await sendSseLine(req.client, errEvent)
  let endEvent = encodeSseEvent("end", $(%* {"stopReason": stopReason}))
  discard await sendSseLine(req.client, endEvent)
  debug "agent.streaming.complete", sessionId = sessionId,
    stopReason = stopReason
  info "agent prompt complete", sessionId = sessionId,
    stopReason = stopReason
  # Close the connection — we replied with ``Connection: close`` so the
  # client should not be expecting another request on this socket.
  try: req.client.close() except CatchableError: discard
  discard promptDone

# --------------------------------------------------------------------------- #
#  Mount helpers — the daemon binds these handlers via registerHandler.       #
# --------------------------------------------------------------------------- #

type
  AgentHandlerProc* = proc(req: Request): Future[void] {.async, gcsafe.}

proc makeSessionsHandler*(reg: AgentRegistry): AgentHandlerProc =
  result = proc(req: Request): Future[void] {.async, gcsafe.} =
    await handleSessions(reg, req)

proc makePromptsHandler*(reg: AgentRegistry): AgentHandlerProc =
  result = proc(req: Request): Future[void] {.async, gcsafe.} =
    await handlePrompts(reg, req)

proc makeCancelHandler*(reg: AgentRegistry): AgentHandlerProc =
  result = proc(req: Request): Future[void] {.async, gcsafe.} =
    await handleCancel(reg, req)

proc makeCloseHandler*(reg: AgentRegistry): AgentHandlerProc =
  result = proc(req: Request): Future[void] {.async, gcsafe.} =
    await handleClose(reg, req)
