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

import std/[strutils]

type
  BrowserAgentClientCallback* = proc(payload: cstring) {.closure.}
  BrowserAgentClientErrorCallback* = proc(message: cstring) {.closure.}
  BrowserAgentClientEndCallback* = proc(stopReason: cstring) {.closure.}

  BrowserAgentClient* = ref object
    baseUrl*: string
    activeSessionId*: string
    onUpdate*: BrowserAgentClientCallback
      ## Called once per ``event: session/update`` frame with the JSON
      ## payload as a cstring.  The caller is responsible for parsing
      ## (the wire model is daemon-side ``agent_routes.sessionUpdateJson``).
    onEnd*: BrowserAgentClientEndCallback
      ## Called once on ``event: end``.  ``stopReason`` is the value
      ## from the JSON payload.
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

proc createSession*(c: BrowserAgentClient; cb: CreateSessionCallback) =
  ## ``POST /api/agent/sessions`` — mint a fresh ACP session id and
  ## cache it on the client.  ``cb`` is invoked exactly once.
  when defined(js):
    let urlStr = c.baseUrl & "/api/agent/sessions"
    let url = urlStr.cstring
    let onErr = c.onError
    let captured = c
    {.emit: ["""
      try {
        fetch(""", url, """, {
          method: 'POST', credentials: 'omit',
          headers: { 'Content-Type': 'application/json' },
          body: '{}'
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
    {.emit: ["""
      try {
        var body = JSON.stringify({
          sessionId: """, sid, """,
          messages: [{
            role: 'user',
            content: [{ type: 'text', text: """, p, """ }]
          }]
        });
        fetch(""", url, """, {
          method: 'POST', credentials: 'omit',
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream'
          },
          body: body
        }).then(function(resp) {
          if (resp.status < 200 || resp.status >= 300) {
            return resp.text().then(function(t) {
              if (""", onErr, """) {
                """, onErr, """('daemon returned HTTP ' + resp.status +
                  ' on POST /api/agent/prompts: ' + t);
              }
              if (""", onEnd, """) {
                """, onEnd, """('error');
              }
            });
          }
          if (!resp.body || !resp.body.getReader) {
            // Fallback for browsers without ReadableStream.
            return resp.text().then(function(buf) {
              window.__isonimAgentDispatchEvents(buf, """, onUpd, """,
                """, onEnd, """, """, onErr, """);
            });
          }
          var reader = resp.body.getReader();
          var decoder = new TextDecoder('utf-8');
          var buf = '';
          function pump() {
            return reader.read().then(function(chunk) {
              if (chunk.done) {
                if (buf.length > 0) {
                  window.__isonimAgentDispatchEvents(buf, """, onUpd, """,
                    """, onEnd, """, """, onErr, """);
                }
                return;
              }
              buf += decoder.decode(chunk.value, { stream: true });
              var idx;
              while ((idx = buf.indexOf('\n\n')) !== -1) {
                var raw = buf.substring(0, idx);
                buf = buf.substring(idx + 2);
                window.__isonimAgentDispatchEvents(raw + '\n\n', """, onUpd, """,
                  """, onEnd, """, """, onErr, """);
              }
              return pump();
            }).catch(function(err) {
              if (""", onErr, """) {
                """, onErr, """('SSE stream broke: ' + String(err));
              }
              if (""", onEnd, """) {
                """, onEnd, """('error');
              }
            });
          }
          return pump();
        }).catch(function(err) {
          if (""", onErr, """) {
            """, onErr, """('daemon unreachable: ' + String(err));
          }
          if (""", onEnd, """) {
            """, onEnd, """('error');
          }
        });
      } catch (e) {
        if (""", onErr, """) {
          """, onErr, """('daemon unreachable: ' + String(e));
        }
        if (""", onEnd, """) {
          """, onEnd, """('error');
        }
      }
    """].}
  else:
    discard

# ---------------------------------------------------------------------------
# Cancel: ``POST /api/agent/cancel``.
# ---------------------------------------------------------------------------

proc cancel*(c: BrowserAgentClient; sessionId: string) =
  ## ``POST /api/agent/cancel`` — fire-and-forget.  The daemon's SSE
  ## stream will close shortly afterwards and ``onEnd`` will fire with
  ## ``stopReason == "cancelled"``.
  when defined(js):
    let urlStr = c.baseUrl & "/api/agent/cancel"
    let url = urlStr.cstring
    let sid: cstring = sessionId
    {.emit: ["""
      try {
        var body = JSON.stringify({ sessionId: """, sid, """ });
        fetch(""", url, """, {
          method: 'POST', credentials: 'omit',
          headers: { 'Content-Type': 'application/json' },
          body: body
        }).catch(function() { /* swallow — fire and forget */ });
      } catch (e) { /* swallow */ }
    """].}
  else:
    discard

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
            if (data.length === 0) continue;
            if (eventType === 'end') {
              var stop = 'end_turn';
              try {
                var parsed = JSON.parse(data);
                if (parsed && parsed.stopReason) stop = parsed.stopReason;
              } catch (e) { /* ignore */ }
              if (onEnd) onEnd(stop);
            } else if (eventType === 'error') {
              if (onErr) onErr(data);
            } else {
              if (onUpd) onUpd(data);
            }
          }
        };
      }
    """].}
else:
  proc installAgentDispatcher*() = discard
