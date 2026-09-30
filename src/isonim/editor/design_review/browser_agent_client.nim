## Phase C — browser-side HTTP / SSE client for the editor daemon's
## ``/api/agent/*`` routes.
##
## The editor's JS bundle cannot use ``std/httpclient``; this module
## wraps ``window.fetch`` and the ``ReadableStream`` body returned by
## ``POST /api/agent/prompts`` so the AI sidebar can drive the same
## daemon the CLI uses (no subprocess fallback — the whole point is
## "same backend as the CLI").
##
## Streaming choice
## ----------------
##
## Browsers don't ship an ``EventSource`` for ``POST`` requests.  Two
## viable approaches:
##
##   (a) iterate ``response.body.getReader()`` from the ``fetch`` reply
##       and split on the SSE ``\n\n`` boundary ourselves;
##   (b) have the daemon mint a ``promptId`` on ``POST`` and expose a
##       sibling ``GET /api/agent/prompts/<id>/events`` for the
##       ``EventSource`` subscription.
##
## We pick **(a)** so the daemon's SSE-on-POST contract from Phase B
## stays untouched.  The fallback for browsers without
## ``ReadableStream`` support is to await the full text body and
## replay the events synchronously — modern Chromium/Firefox/Safari all
## ship ``ReadableStream`` so the slow path is mostly defensive.
##
## Native shim
## -----------
##
## A native stub is provided so this module participates in the
## headless ``test_editor_*`` build without ``when defined(js)`` guards
## leaking into call sites.  The native ``submitPrompt`` is a no-op —
## VM tests inject a ``FakeBrowserAgentClient`` (in ``viewmodels``)
## that bypasses the network entirely.

import std/[strutils, json]

type
  BrowserAgentClientCallback* = proc(payload: cstring) {.closure.}
  BrowserAgentClientErrorCallback* = proc(message: cstring) {.closure.}
  BrowserAgentClientEndCallback* = proc(stopReason: cstring) {.closure.}

  BrowserAgentClient* = ref object
    baseUrl*: string
    editorScopeJson*: string
    editorControlToken*: string
    onControlClosed*: proc(conversation: string) {.closure.}
    bindEditor*: proc(done: proc(ok: bool) {.closure.}) {.closure.}
    activeSessionId*: string
    canCancelTurn*: bool
    canCloseSession*: bool
    closed*: bool
    onUpdate*: BrowserAgentClientCallback
      ## Called once per ``event: session/update`` frame with the JSON
      ## payload as a cstring.  The caller is responsible for parsing
      ## (the wire model is daemon-side ``agent_routes.sessionUpdateJson``).
    onEnd*: BrowserAgentClientEndCallback
      ## Called once on ``event: end``.  ``stopReason`` is the value
      ## from the JSON payload.
    onInterrupted*: BrowserAgentClientErrorCallback
      ## Stream delivery ended without a trustworthy terminal event. The backend
      ## may still be running; callers must close/reconcile before another prompt.
    onError*: BrowserAgentClientErrorCallback
      ## Called on transport errors (``daemon unreachable``, non-2xx
      ## responses, malformed SSE frames).  Distinct from
      ## ``event: error`` which is also dispatched here so the chat
      ## panel doesn't have to branch.

proc newBrowserAgentClient*(baseUrl: string): BrowserAgentClient =
  ## Allocate a client bound to ``baseUrl`` (no trailing slash).  The
  ## caller installs ``onUpdate`` / ``onEnd`` / ``onError`` before the
  ## first ``submitPrompt``.
  var normalised = baseUrl.strip()
  if normalised.endsWith("/"):
    normalised = normalised[0 ..< normalised.len - 1]
  BrowserAgentClient(baseUrl: normalised)

# ---------------------------------------------------------------------------
# Session creation: ``POST /api/agent/sessions``.
# ---------------------------------------------------------------------------

type
  CreateSessionCallback* = proc(sessionId: cstring) {.closure.}
    ## ``sessionId`` is an empty cstring when the POST failed (the
    ## ``onError`` callback will have been invoked separately).

proc createBoundSession(c: BrowserAgentClient; cb: CreateSessionCallback) =
  ## ``POST /api/agent/sessions`` — mint a fresh ACP session id and
  ## cache it on the client.  ``cb`` is invoked exactly once.
  when defined(js):
    let urlStr = c.baseUrl & "/api/agent/sessions"
    let url = urlStr.cstring
    let onErr = c.onError
    let captured = c
    let binding = c.editorScopeJson.cstring
    let controlToken = c.editorControlToken.cstring
    {.emit: ["""
      try {
        fetch(""", url, """, {
          method: 'POST', credentials: 'omit',
          headers: { 'Content-Type': 'application/json', 'X-IsoNim-Control': """, controlToken, """ },
          body: """, binding, """ ? JSON.stringify({editor: JSON.parse(""", binding, """)}) : '{}'
        })
          .then(function(resp) {
            return resp.text().then(function(body) {
              return { code: resp.status, body: body };
            });
          })
          .then(function(out) {
            if (out.code < 200 || out.code >= 300) {
              if (""", onErr, """) {
                """, onErr, """('daemon returned HTTP ' + out.code +
                  ' on POST /api/agent/sessions: ' + out.body);
              }
              """, cb, """('');
              return;
            }
            try {
              var parsed = JSON.parse(out.body);
              var caps = parsed.sessionCapabilities || {};
              """, captured, """.canCancelTurn = caps.cancelTurn === true;
              """, captured, """.canCloseSession = caps.closeSession === true;
              var sid = parsed && parsed.sessionId ? parsed.sessionId : '';
              """, captured, """.activeSessionId = sid;
              """, cb, """(sid);
            } catch (e) {
              if (""", onErr, """) {
                """, onErr, """('malformed JSON from daemon on session create: ' +
                  String(e));
              }
              """, cb, """('');
            }
          })
          .catch(function(err) {
            if (""", onErr, """) {
              """, onErr, """('daemon unreachable: ' + String(err));
            }
            """, cb, """('');
          });
      } catch (e) {
        if (""", onErr, """) {
          """, onErr, """('daemon unreachable: ' + String(e));
        }
        """, cb, """('');
      }
    """].}
  else:
    # Native shim — tests inject a fake client at the VM layer.
    cb("".cstring)

proc createSession*(c: BrowserAgentClient; cb: CreateSessionCallback) =
  ## A mounted editor binds its registered browser scope before session creation.
  ## Legacy CLI/transport callers without a binding preserve their existing API.
  if c.bindEditor != nil:
    c.bindEditor(proc(ok: bool) =
      if ok: c.createBoundSession(cb)
      else:
        if c.onError != nil: c.onError("Editor control registration is unavailable.".cstring)
        cb("".cstring))
  else: c.createBoundSession(cb)

# ---------------------------------------------------------------------------
# Prompt submission with SSE streaming via ``fetch`` ReadableStream.
# ---------------------------------------------------------------------------

proc submitPrompt*(c: BrowserAgentClient; sessionId, prompt: string) =
  ## ``POST /api/agent/prompts`` — open the SSE stream and drive the
  ## three callbacks (``onUpdate`` / ``onEnd`` / ``onError``) as
  ## events arrive.  Returns immediately; the actual streaming runs
  ## asynchronously in the JS event loop.
  ##
  ## The body shape mirrors the daemon contract from Phase B:
  ##
  ##   ``{"sessionId": "...", "messages": [{"role":"user",
  ##       "content": [{"type":"text","text":"..."}]}]}``
  ##
  ## We escape ``prompt`` into the JSON via ``JSON.stringify`` in the
  ## emitted JS so multi-line / unicode prompts survive intact.
  when defined(js):
    let urlStr = c.baseUrl & "/api/agent/prompts"
    let url = urlStr.cstring
    let sid: cstring = sessionId
    let p: cstring = prompt
    let onUpd = c.onUpdate
    let onEnd = c.onEnd
    let onErr = c.onError
    let onInterrupted = c.onInterrupted
    {.emit: ["""
      var terminal = false, failed = false;
      function report(message) {
        if (""", onInterrupted, """) """, onInterrupted, """(message);
        else if (""", onErr, """) """, onErr, """(message);
      }
      function fail(message) {
        if (terminal || failed) return;
        failed = true;
        report('Agent stream interrupted: ' + message +
          '. The agent may still be running. Close this chat and start a new one before retrying.');
      }
      function dispatch(raw) {
        window.__isonimAgentDispatchEvents(raw,
          function(payload) { if (!terminal && !failed && """, onUpd, """) """, onUpd, """(payload); },
          function(reason) {
            if (terminal || failed) return;
            terminal = true;
            if (""", onEnd, """) """, onEnd, """(reason);
          },
          function(message) { if (!terminal && !failed) report(message); });
      }
      Promise.resolve().then(function() {
        return fetch(""", url, """, {
          method: 'POST', credentials: 'omit',
          headers: {'Content-Type':'application/json', 'Accept':'text/event-stream'},
          body: JSON.stringify({sessionId: """, sid, """, messages:[{
            role:'user', content:[{type:'text', text: """, p, """}]}]})
        });
      }).then(async function(resp) {
        if (resp.status < 200 || resp.status >= 300) {
          fail('HTTP ' + resp.status + ': ' + await resp.text());
          return;
        }
        var buf = '';
        function consume(text) {
          buf += text;
          var idx;
          while (!terminal && !failed && (idx = buf.indexOf('\n\n')) !== -1) {
            var raw = buf.substring(0, idx + 2);
            buf = buf.substring(idx + 2);
            dispatch(raw);
          }
        }
        if (!resp.body || !resp.body.getReader) {
          consume(await resp.text());
          if (!terminal) fail('response ended without a complete terminal event');
          return;
        }
        var reader = resp.body.getReader();
        var decoder = new TextDecoder('utf-8');
        try {
          while (!terminal && !failed) {
            var chunk = await reader.read();
            if (chunk.done) {
              consume(decoder.decode());
              if (!terminal) fail('response ended without a complete terminal event');
              break;
            }
            consume(decoder.decode(chunk.value, {stream:true}));
          }
        } finally {
          await reader.cancel();
        }
      }).catch(function(err) { fail(String(err)); });
    """].}
  else:
    discard

# ---------------------------------------------------------------------------
# Cancel: ``POST /api/agent/cancel``.
# ---------------------------------------------------------------------------

type AgentOperationCallback* = proc(ok: bool; message: cstring) {.closure.}

proc sessionOperation(c: BrowserAgentClient; sessionId, operation: string;
    cb: AgentOperationCallback) =
  when defined(js):
    let url = (c.baseUrl & "/api/agent/" & operation).cstring
    let sid = sessionId.cstring
    {.emit: ["""
      Promise.resolve().then(function() {
        return fetch(""", url, """, {
          method: 'POST', credentials: 'omit',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({sessionId: """, sid, """})
        });
      }).then(function(resp) {
        return resp.text().then(function(body) {
          """, cb, """(resp.status >= 200 && resp.status < 300,
            resp.status >= 200 && resp.status < 300 ? '' :
              'Agent operation failed (HTTP ' + resp.status + '): ' + body);
        });
      }).catch(function(err) { """, cb, """(false, String(err)); });
    """].}
  else:
    cb(false, "Browser transport requires JavaScript")

proc cancel*(c: BrowserAgentClient; sessionId: string;
    cb: AgentOperationCallback) =
  if not c.canCancelTurn:
    cb(false, "This agent does not support cancelling a turn; the session remains active.")
    return
  c.sessionOperation(sessionId, "cancel", cb)

proc closeSession*(c: BrowserAgentClient; sessionId: string;
    cb: AgentOperationCallback) =
  c.sessionOperation(sessionId, "close", proc(ok: bool; message: cstring) =
    if ok:
      c.closed = true
      if c.onControlClosed != nil: c.onControlClosed(sessionId)
      c.activeSessionId = ""
    cb(ok, message))

# ---------------------------------------------------------------------------
# JS-side SSE frame dispatcher.  Installed on ``window`` so the emitted
# fetch chain can reach it from inside ``then`` callbacks without
# closing over Nim closures.
# ---------------------------------------------------------------------------

when defined(js):
  proc installAgentDispatcher*() =
    ## Idempotent installer.  ``mountEditor`` calls this before wiring
    ## the first ``BrowserAgentClient`` so the inline ``fetch`` chain
    ## inside ``submitPrompt`` has a global parser to call.
    {.emit: ["""
      if (!window.__isonimAgentDispatchEvents) {
        window.__isonimAgentDispatchEvents = function(raw, onUpd, onEnd, onErr) {
          var frames = raw.split('\n\n');
          for (var i = 0; i < frames.length; i++) {
            var frame = frames[i];
            if (!frame || frame.length === 0) continue;
            var lines = frame.split('\n');
            var eventType = 'session/update';
            var data = '';
            for (var j = 0; j < lines.length; j++) {
              var line = lines[j];
              if (line.indexOf('event:') === 0) {
                eventType = line.substring(6).trim();
              } else if (line.indexOf('data:') === 0) {
                if (data.length > 0) data += '\n';
                data += line.substring(5).replace(/^ /, '');
              }
            }
            if (eventType === 'end') {
              var parsed;
              try { parsed = JSON.parse(data); }
              catch (e) { throw new Error('Malformed terminal event JSON'); }
              if (!parsed || typeof parsed.stopReason !== 'string' ||
                  ['end_turn','cancelled','max_tokens','error'].indexOf(parsed.stopReason) < 0) {
                throw new Error('Missing or invalid terminal stopReason');
              }
              if (onEnd) onEnd(parsed.stopReason);
            } else if (eventType === 'error') {
              if (onErr) onErr(data);
            } else if (data.length > 0) {
              if (onUpd) onUpd(data);
            }
          }
        };
      }
    """].}
else:
  proc installAgentDispatcher*() = discard
