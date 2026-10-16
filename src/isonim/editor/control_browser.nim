## Browser transport for the shared production control host. Scope and callbacks
## belong to a single mounted shell; browser application ACK is the completion edge.
when not defined(js): {.error: "Browser control transport requires JS".}
import std/[dom, json, tables]
import isonim/core/[signals, computation, owner]
import isonim/editor/[control, viewmodels]
import isonim/editor/design_review/[browser_agent_client, editor_daemon_url]

type
  BrowserControlBridge* = ref object
    vm: EditorVM
    root: Element
    endpoint, scopeJson, browserToken: string
    connected: bool
    disposed: bool
    pollTimer: int
    onClosed*: proc(conversation: string) {.closure.}

proc fetchRpc(bridge: BrowserControlBridge; methodName: string; params: JsonNode;
    done: proc(reply: JsonNode) {.closure.}) =
  if bridge.disposed and methodName != "editor.disconnect": return
  let url = (bridge.endpoint & "/api/editor/rpc").cstring
  var auth = bridge.browserToken
  if methodName == "editor.register":
    var bootstrap: cstring
    {.emit: [bootstrap, " = (document.querySelector('meta[name=isonim-editor-bootstrap]') || {}).content || '';"].}
    auth = $bootstrap
  let token = auth.cstring
  let body = $(%* {"jsonrpc": "2.0", "id": "browser", "method": methodName, "params": params})
  let raw = body.cstring
  proc receive(value: cstring) =
    if bridge.disposed: return
    try: done(parseJson($value))
    except CatchableError: done(newJNull())
  let receiveCallback = receive
  {.emit: ["""
    fetch(""", url, """, {method:'POST', credentials:'omit',
      headers:{'Content-Type':'application/json','X-IsoNim-Control':""", token, """},
      body:""", raw, """}).then(function(r){return r.text();}).then(function(body){
        """, receiveCallback, """(body);
      }).catch(function(){""", receiveCallback, """('null');});
  """].}

proc scope(bridge: BrowserControlBridge): JsonNode =
  parseJson(bridge.scopeJson)

proc acknowledge(bridge: BrowserControlBridge; operation: JsonNode) =
  if not bridge.connected: return
  var params = bridge.scope()
  params["operation"] = operation
  params["state"] = bridge.vm.controlSnapshot()
  bridge.fetchRpc("editor.ack", params, proc(reply: JsonNode) = discard)

proc bindClient*(bridge: BrowserControlBridge; client: BrowserAgentClient) =
  client.onControlClosed = proc(conversation: string) = bridge.vm.revokeControlConversation(conversation)
  client.bindEditor = proc(done: proc(ok: bool) {.closure.}) =
    var attempts = 0
    proc ready() =
      if bridge.disposed: done(false)
      elif bridge.connected:
        client.editorScopeJson = bridge.scopeJson
        client.editorControlToken = bridge.browserToken
        done(true)
      elif attempts >= 50: done(false)
      else:
        inc attempts
        let readyCallback = ready
        {.emit: ["setTimeout(", readyCallback, ", 100);"].}
    ready()

proc installControlBridge*(vm: EditorVM; root: Element): BrowserControlBridge =
  let bridge = BrowserControlBridge(vm: vm, root: root, endpoint: resolveDaemonUrl())
  result = bridge
  # DOM focus requires a visible control in this exact mounted editor. Human focus
  # events update the same signal, including focus within its preview iframe.
  vm.controlStoryRevealAdapter = proc() =
    # A microtask follows synchronous reactive tree updates without stealing
    # keyboard focus. A newer selection or unmount invalidates the queued scroll.
    let shell = root
    let selected = (vm.selectedStory.val.group & "/" & vm.selectedStory.val.name).cstring
    proc stillMounted(): bool = not bridge.disposed
    let live = stillMounted
    {.emit: ["""
      queueMicrotask(function() {
        if (!""", live, """() || !""", shell, """.isConnected) return;
        const row = Array.from(""", shell, """.querySelectorAll('[data-story-row][aria-current="true"]'))
          .find(node => node.getAttribute('data-story-row') === """, selected, """);
        if (row && row.getClientRects().length) row.scrollIntoView({block:'nearest',inline:'nearest'});
      });
    """].}
  vm.controlFocusAdapter = proc(target: string): bool =
    let shell = root
    let name = target.cstring
    var applied = false
    {.emit: ["""
      (function(){
        const selectors = {composer:'[data-editor-control-focus="composer"]',
          'sidebar-search':'.editor-sidebar input',
          'inspector-search':'[data-isonim-focus-id="section-search"]',
          preview:'.editor-preview iframe'};
        const matches = Array.from(""", shell, """.querySelectorAll(selectors[""", name, """] || ':not(*)'));
        const node = matches.find(n => n.getClientRects().length && getComputedStyle(n).visibility !== 'hidden');
        if (!node) return;
        if (node.tagName === 'IFRAME') node.tabIndex = 0;
        node.focus({preventScroll:true});
        """, applied, """ = document.activeElement === node;
      })();
    """].}
    applied
  vm.controlHighlightAdapter = proc(target: string): bool =
    let shell = root
    let name = target.cstring
    var applied = false
    {.emit: ["""
      (function(){
        const shell = """, shell, """;
        const candidates = [];
        for (const frame of shell.querySelectorAll('iframe')) {
          if (!frame.getClientRects().length) continue;
          try { if (frame.contentDocument) candidates.push(...frame.contentDocument.querySelectorAll('[data-element-id], [data-isonim-element-id], [data-test-id]')); } catch(_) {}
        }
        candidates.push(...shell.querySelectorAll('[data-element-id], [data-isonim-element-id], [data-layer-id]'));
        const node = candidates.find(n => [n.getAttribute('data-element-id'),n.getAttribute('data-isonim-element-id'),n.getAttribute('data-layer-id'),n.getAttribute('data-test-id')].includes(""", name, """) && n.getClientRects().length);
        if (!node) return;
        for (const previous of shell.__isonimControlHighlights || []) {
          previous.node.style.outline = previous.outline;
          previous.node.style.outlineOffset = previous.offset;
          previous.node.removeAttribute('data-editor-agent-highlight');
        }
        shell.__isonimControlHighlights = [{node,outline:node.style.outline,offset:node.style.outlineOffset}];
        node.style.outline = '2px solid #818cf8'; node.style.outlineOffset = '3px';
        node.setAttribute('data-editor-agent-highlight','true');
        """, applied, """ = true;
      })();
    """].}
    applied
  vm.controlSelectionAdapter = proc(target: string; focus, highlight: bool): bool =
    let shell = root
    let name = target.cstring
    let shouldFocus = focus
    let shouldHighlight = highlight
    var applied = false
    {.emit: ["""
      (function(){
        const shell = """, shell, """;
        const candidates = [];
        for (const frame of shell.querySelectorAll('iframe')) {
          if (!frame.getClientRects().length) continue;
          try { if (frame.contentDocument) candidates.push(...frame.contentDocument.querySelectorAll('[data-element-id],[data-isonim-element-id],[data-test-id]')); } catch(_) {}
        }
        const node = candidates.find(n => [n.getAttribute('data-element-id'),n.getAttribute('data-isonim-element-id'),n.getAttribute('data-test-id')].includes(""", name, """) && n.getClientRects().length);
        if (!node) return;
        const doc = node.ownerDocument, previousFocus = doc.activeElement;
        const previousTabindex = node.getAttribute('tabindex');
        if (""", shouldFocus, """) {
          if (!node.matches('button,input,select,textarea,a[href],[tabindex]')) node.tabIndex = -1;
          node.focus({preventScroll:true});
          if (doc.activeElement !== node) {
            if (previousTabindex === null) node.removeAttribute('tabindex');
            else node.setAttribute('tabindex',previousTabindex);
            if (previousFocus) previousFocus.focus({preventScroll:true});
            return;
          }
        }
        if (""", shouldHighlight, """) {
          for (const previous of shell.__isonimControlHighlights || []) {
            previous.node.style.outline = previous.outline;
            previous.node.style.outlineOffset = previous.offset;
            previous.node.removeAttribute('data-editor-agent-highlight');
          }
          shell.__isonimControlHighlights = [{node,outline:node.style.outline,offset:node.style.outlineOffset}];
          node.style.outline = '2px solid #818cf8'; node.style.outlineOffset = '3px';
          node.setAttribute('data-editor-agent-highlight','true');
        }
        """, applied, """ = true;
      })();
    """].}
    applied
  proc userFocus(name: cstring) =
    vm.controlFocusTarget.val = $name
    discard vm.refreshControlRevision()
  let shell = root
  let userFocusCallback = userFocus
  {.emit: ["""
    const controlShell = """, shell, """;
    controlShell.__isonimControlCleanups = [];
    const previewFocusRecords = new Map();
    controlShell.__isonimControlCleanups.push(function(){
      for (const record of previewFocusRecords.values()) record.doc.removeEventListener('focusin',record.listener);
      previewFocusRecords.clear();
    });
    function wirePreviewFocus(frame) {
      try {
        const doc = frame.contentDocument;
        const previous = previewFocusRecords.get(frame);
        if (!doc || (previous && previous.doc === doc)) return;
        if (previous) previous.doc.removeEventListener('focusin',previous.listener);
        const previewFocus = function(event) {
          if (controlShell.__isonimControlRestoringFocus || !controlShell.contains(frame) || !frame.getClientRects().length) return;
          controlShell.__isonimControlReturnFocus = event.target;
          const id = event.target.getAttribute('data-isonim-element-id') || event.target.getAttribute('data-element-id');
          """, userFocusCallback, """(id ? 'element:' + id : 'preview');
        };
        doc.addEventListener('focusin',previewFocus);
        previewFocusRecords.set(frame,{doc,listener:previewFocus});
      } catch(_) {}
    }
    const previewLoad = function(event) {
      if (event.target.tagName === 'IFRAME') wirePreviewFocus(event.target);
    };
    controlShell.addEventListener('load',previewLoad,true);
    controlShell.__isonimControlCleanups.push(() => controlShell.removeEventListener('load',previewLoad,true));
    for (const frame of controlShell.querySelectorAll('iframe')) wirePreviewFocus(frame);
    const shellFocus = function(event){
      if (controlShell.__isonimControlRestoringFocus || event.target.matches('[data-editor-control-approve],[data-editor-control-reject]')) return;
      controlShell.__isonimControlReturnFocus = event.target;
      let name = event.target.getAttribute('data-editor-control-focus') ||
        (event.target.closest('.editor-sidebar') ? 'sidebar-search' :
         event.target.tagName === 'IFRAME' ? 'preview' : 'editor');
      """, userFocusCallback, """(name);
    };
    controlShell.addEventListener('focusin',shellFocus);
    controlShell.__isonimControlCleanups.push(() => controlShell.removeEventListener('focusin',shellFocus));
  """].}
  vm.controlSourceTransport = proc(request: JsonNode; done: proc(data: JsonNode) {.closure.}) =
    if bridge.disposed or not bridge.connected:
      done(%* {"ok": false, "diagnostic": "Editor control connection unavailable."})
      return
    var registered: JsonNode
    proc sendSource() =
      var params = bridge.scope()
      params["operationId"] = request{"commandId"}
      let sourceUrl = (bridge.endpoint & "/api/editor/source/operation").cstring
      let sourceAuth = bridge.browserToken.cstring
      let sourceBody = ($params).cstring
      proc receiveSource(raw: cstring) =
        if bridge.disposed: return
        var reply: JsonNode
        try: reply = parseJson($raw)
        except CatchableError: reply = %* {"ok": false, "diagnostic": "Source bridge returned an invalid response."}
        done(reply)
        if registered != nil:
          registered["status"] = %(if reply{"ok"}.getBool(): "applied" else: "failed")
          if not reply{"ok"}.getBool(): registered["error"] = reply{"diagnostic"}
          bridge.acknowledge(registered)
      let receiveSourceCallback = receiveSource
      {.emit: ["""
        fetch(""", sourceUrl, """, {method:'POST',credentials:'omit',headers:{
          'Content-Type':'application/json','X-IsoNim-Control':""", sourceAuth, """},body:""", sourceBody, """})
          .then(r=>r.text()).then(""", receiveSourceCallback, """)
          .catch(()=>""", receiveSourceCallback, """('{"ok":false,"diagnostic":"Source bridge connection failed."}'));
      """].}
    if request{"command"}.getStr() in ["inspector-edit", "bindings-save"]:
      var registration = bridge.scope()
      let state = vm.controlSnapshot()
      request["expectedRevision"] = state["revision"]
      registration["request"] = request
      registration["state"] = state
      bridge.fetchRpc(if request{"command"}.getStr() == "bindings-save": "editor.bindings-source" else: "editor.inspector-source", registration, proc(reply: JsonNode) =
        if reply{"result"} == nil:
          done(%* {"ok": false, "diagnostic": reply{"error", "message"}.getStr("Inspector source admission failed.")})
        else:
          registered = reply["result"]
          sendSource())
    else:
      sendSource()
  vm.controlCaptureAdapter = proc(): JsonNode =
    let captureShell = root
    let expectedStory = controlStoryId(vm.selectedStory.val).cstring
    let expectedGeneration = vm.livePreviewReloadGeneration.val
    var capture: cstring
    {.emit: ["""
      const candidates = [...""", captureShell, """.querySelectorAll(
        'iframe[data-component-project-frame],iframe[data-component-edit-frame],iframe[data-page-project-frame],iframe[data-foundation-project-frame]')]
        .filter(frame=>frame.getClientRects().length);
      let captureResult={ready:false,format:'text/html',diagnostic:'The current preview document is not rendered yet.'};
      for(const frame of candidates) {
        try {
          const doc=frame.contentDocument;
          const story=doc && doc.querySelector('meta[name=isonim-rendered-story]');
          const generation=doc && doc.querySelector('meta[name=isonim-rendered-generation]');
          if(doc && doc.readyState==='complete' && doc.body && doc.body.childElementCount &&
              story && story.content===""", expectedStory, """ && generation && Number(generation.content)===""", expectedGeneration, """) {
            captureResult={ready:true,format:'text/html',documentHtml:'<!doctype html>\n'+doc.documentElement.outerHTML,
              storyId:story.content,previewGeneration:Number(generation.content),width:frame.clientWidth,height:frame.clientHeight};
            break;
          }
        } catch(_) {}
      }
      """, capture, """ = JSON.stringify(captureResult);
    """].}
    parseJson($capture)
  proc consumeDelivery(operation: JsonNode) =
    if not bridge.connected or bridge.disposed: return
    if operation{"status"}.getStr() in ["approved", "rejected"]:
      # Restore only temporary approval focus. A human who moved to another
      # control keeps that focus, and shared revision validation detects it.
      let approvalShell = root
      {.emit: ["""
        const activeApproval = document.activeElement;
        const returnFocus = """, approvalShell, """.__isonimControlReturnFocus;
        if (activeApproval && activeApproval.matches('[data-editor-control-approve],[data-editor-control-reject]') &&
            returnFocus && returnFocus.isConnected && returnFocus.getClientRects().length) {
          // Restoring the pre-decision element crosses outer/iframe focus events.
          // Those intermediate events are approval bookkeeping, not human edits.
          const controlRoot = """, approvalShell, """;
          controlRoot.__isonimControlRestoringFocus = true;
          try { returnFocus.focus({preventScroll:true}); }
          finally { controlRoot.__isonimControlRestoringFocus = false; }
        }
      """].}
    bridge.acknowledge(vm.deliverControlOperation(operation))
  vm.requestControlApproval = proc(id: string; approve: bool) =
    if not bridge.connected: return
    var params = bridge.scope()
    params["operationId"] = %id
    params["approve"] = %approve
    bridge.fetchRpc("editor.approve", params, proc(reply: JsonNode) =
      if reply{"result"} != nil: consumeDelivery(reply["result"])
      # Lost responses and conflicting duplicates never revoke unrelated work.
      # The server's durable decision is recovered by the normal poll stream.
    )
  vm.controlConnected = false
  var registering = false
  proc register()
  proc pollBrowser()
  proc schedulePoll() =
    if bridge.disposed: return
    let pollCallback = pollBrowser
    {.emit: [bridge.pollTimer, " = setTimeout(", pollCallback, ", 200);"].}
  proc register() =
    if registering or bridge.disposed: return
    registering = true
    bridge.fetchRpc("editor.register", %* {"workspace": vm.workspaceId, "state": vm.controlSnapshot()},
      proc(reply: JsonNode) =
        registering = false
        let registration = reply{"result"}
        if registration == nil or registration.kind != JObject:
          schedulePoll()
          return
        bridge.browserToken = registration{"browserToken"}.getStr()
        bridge.scopeJson = $(%* {"workspace": registration["workspace"],
          "instance": registration["instance"], "epoch": registration["epoch"]})
        vm.controlInstanceId = registration{"instance"}.getStr()
        # A new connection is a new target identity. Pending work from the old
        # connection may never apply in a replacement tab or connection epoch.
        vm.controlOperations.clear()
        vm.controlActivity.val = @[]
        bridge.connected = true
        vm.controlConnected = true
        schedulePoll())
  proc pollBrowser() =
    if bridge.disposed: return
    if bridge.connected and bridge.scope(){"workspace"}.getStr() != vm.workspaceId:
      bridge.fetchRpc("editor.disconnect", bridge.scope(), proc(reply: JsonNode) = discard)
      bridge.connected = false
      vm.controlConnected = false
    if not bridge.connected:
      register()
      return
    var params = bridge.scope()
    params["state"] = vm.controlSnapshot()
    bridge.fetchRpc("editor.poll", params, proc(reply: JsonNode) =
      if reply{"result"} == nil:
        # A transport loss preserves this mounted tab's identity and provider
        # scope. An authenticated poll can renew its expired lease. A real RPC
        # rejection still revokes this binding and registers a replacement.
        if reply != nil and reply{"error"} != nil: bridge.connected = false
        vm.controlConnected = false
        schedulePoll()
        return
      vm.controlConnected = true
      for operation in reply{"result", "commands"}:
        consumeDelivery(operation)
      schedulePoll())
  createEffect proc() =
    for operation in vm.controlActivity.val:
      if operation{"status"}.getStr() in ["applied", "failed", "rejected"]:
        bridge.acknowledge(operation)
  proc unload() =
    if bridge.disposed: return
    bridge.disposed = true
    let cleanupShell = root
    {.emit: ["clearTimeout(", bridge.pollTimer, "); for (const cleanup of ", cleanupShell,
      ".__isonimControlCleanups || []) cleanup();", cleanupShell, ".__isonimControlCleanups = [];"].}
    if bridge.connected:
      bridge.fetchRpc("editor.disconnect", bridge.scope(), proc(reply: JsonNode) = discard)
      bridge.connected = false
      vm.controlConnected = false
    vm.controlConnected = false
    var conversations: seq[string]
    for operation in vm.controlActivity.val:
      let conversation = operation{"request", "conversation"}.getStr()
      if conversation notin conversations: conversations.add conversation
    for conversation in conversations: vm.revokeControlConversation(conversation)
  let unloadCallback = unload
  {.emit: ["""
    window.addEventListener('pagehide',""", unloadCallback, """);
    const disconnectObserver = new MutationObserver(function(){
      if (!""", root, """.isConnected) """, unloadCallback, """();
    });
    disconnectObserver.observe(document.documentElement,{childList:true,subtree:true});
    """, root, """.__isonimControlCleanups.push(function(){
      window.removeEventListener('pagehide',""", unloadCallback, """);
      disconnectObserver.disconnect();
    });
  """].}
  onCleanup(unload)
  register()
