## Real Node fetch/HTTP boundary exercises BrowserAgentClient, production adapter
## and EditorVM. Only the daemon peer is controlled to hold create/close responses
## at deterministic barriers; no client, adapter or VM operation is substituted.
## The mock DOM records production view event bindings, allowing this headless
## test to click the rendered close control while HTTP remains real.
import isonim/viewmodel
import isonim/core/[signals, computation]
import isonim/editor/[types, viewmodels]
import isonim/editor/design_review/[browser_agent_client, editor_agent_adapter]
import std/[strutils, tables]
import isonim/testing/mock_dom
import isonim/editor/views/chat_panel

var editor: EditorVM
var client: BrowserAgentClient
var closingId: string
var expectedCount = 2
var previousClient: BrowserAgentClient
var expectedReply = "streaming reply 1"
proc expectReply(turn: int) = expectedReply = "streaming reply " & $turn
proc setup(url: cstring) =
  installAgentDispatcher()
  editor = createEditorVM()
  editor.configureChat = proc(chat: AgentChatVM) =
    client = newBrowserAgentClient($url)
    configureAgentAdaptersWithClient(chat, client)
  closingId = editor.createNewChat()
proc prompt() =
  editor.chat.inputText.val = "hello"
  doAssert editor.sendAgentPrompt()
  doAssert editor.chat.sessionStatus.val == asLoading
  editor.chat.inputText.val = "queued draft"
  doAssert not editor.sendAgentPrompt()
  doAssert editor.chat.inputText.val == "queued draft"
proc findClose(node: MockNode): MockNode =
  if node.attributes.getOrDefault("data-agent-close") == "true": return node
  for child in node.children:
    result = findClose(child)
    if result != nil: return
proc requestClose() =
  let panel = renderChatPanel[MockRenderer, MockNode](MockRenderer(), editor)
  let control = findClose(panel)
  doAssert control != nil
  doAssert control.tag == "button"
  doAssert control.attributes.getOrDefault("aria-label") == "Close conversation"
  control.fireEvent("click")
proc makeSingleChat() =
  doAssert editor.closeChat("chat-1")
  doAssert editor.chats.val.len == 1
  expectedCount = 1
  previousClient = client
proc requestCancel() =
  editor.chat.sessionStatus.val = asLoading
  editor.chat.connectionState.val = "streaming"
  discard editor.cancelAgentPrompt()
proc cancelRunning() =
  doAssert editor.chat.promptInFlight
  doAssert editor.chat.connectionState.val == "streaming"
  doAssert editor.chat.sessionStatus.val == asLoading
  discard editor.cancelAgentPrompt()
proc supportedCancel() =
  client.canCancelTurn = true
  discard editor.cancelAgentPrompt()
proc ready(stage: int): bool =
  if stage == 11:
    editor.chats.val.len == 1 and editor.activeChatId.val != closingId
  elif stage == 9:
    editor.chat.connectionState.val == "interrupted"
  elif stage == 7:
    not editor.chat.promptInFlight and editor.chat.connectionState.val == "completed"
  elif stage == 8:
    editor.chat.messages.val.len > 0 and editor.chat.messages.val[^1].text == expectedReply
  elif stage == 5:
    editor.chat.messages.val[^1].text.contains("HTTP 501")
  elif stage == 6:
    editor.chat.connectionState.val == "cancelling"
  elif stage == 3:
    editor.chat.messages.val.len > 0 and editor.chat.messages.val[^1].text.contains("HTTP 502")
  else:
    editor.chats.val.len == 1
proc verify(stage: int) =
  case stage
  of 0:
    doAssert editor.chats.val.len == expectedCount
    doAssert client.activeSessionId == ""
  of 1:
    doAssert editor.chats.val.len == expectedCount
    doAssert client.activeSessionId == "backend"
    doAssert not client.closed
    doAssert client.canCloseSession
  of 2:
    doAssert editor.chat.connectionState.val == "streaming"
    doAssert editor.chat.sessionStatus.val == asLoading
    doAssert editor.chat.messages.val[^1].text.contains("does not support")
  of 3:
    doAssert editor.chats.val.len == expectedCount
    doAssert not client.closed
    doAssert editor.chat.messages.val[^1].text.contains("HTTP 502")
    doAssert editor.chat.inputText.val == "queued draft"
  of 11:
    doAssert editor.chats.val.len == 1
    doAssert previousClient.closed
    doAssert client != previousClient
    doAssert client.activeSessionId == ""
    doAssert editor.activeChatId.val != closingId
    doAssert editor.chat.inputText.val == ""
    doAssert editor.chat.promptAdapter != nil
  of 9:
    doAssert editor.chat.connectionState.val == "interrupted"
    doAssert editor.chat.sessionStatus.val == asError
    doAssert editor.chat.promptInFlight
    doAssert editor.chat.stopReason.val != "end_turn"
    doAssert client.activeSessionId == "backend"
    doAssert not client.closed
    doAssert editor.chat.inputText.val == "queued draft"
    doAssert not editor.sendAgentPrompt()
    doAssert editor.chat.inputText.val == "queued draft"
    doAssert editor.chat.messages.val[^1].text.contains("Close this chat")
  of 8:
    doAssert editor.chats.val.len == expectedCount
    doAssert not client.closed
    doAssert editor.chat.messages.val[^1].text == expectedReply
  of 5:
    doAssert editor.chat.connectionState.val == "streaming"
    doAssert editor.chat.stopReason.val != "cancelled"
  of 6:
    doAssert editor.chat.connectionState.val == "cancelling"
    doAssert editor.chat.stopReason.val != "cancelled"
    doAssert editor.chat.sessionStatus.val == asLoading
  of 4:
    doAssert editor.chats.val.len == 1
    doAssert client.closed
    doAssert client.activeSessionId == ""
    let newId = editor.createNewChat()
    doAssert newId != closingId
    closingId = newId
    doAssert editor.chat.promptAdapter != nil
  else: doAssert false

when defined(js):
  {.emit: ["""
  global.window = global;
  const http = require('node:http');
  let createResponse, closeResponse, promptResponse, prompts = 0, cancels = 0, closes = 0, cancelCode = 501;
  const server = http.createServer((req, res) => {
    let body = ''; req.on('data', b => body += b); req.on('end', () => {
      if (req.url === '/api/agent/sessions') createResponse = res;
      else if (req.url === '/api/agent/close') {
        if (JSON.parse(body).sessionId !== 'backend') throw Error('wrong close session');
        closes++; closeResponse = res;
      } else if (req.url === '/api/agent/cancel') { cancels++; res.statusCode = cancelCode; res.end('{}'); }
      else if (req.url === '/api/agent/prompts') {
        prompts++; promptResponse = res;
        res.writeHead(200, {'Content-Type':'text/event-stream'});
        res.write('event: session/update\ndata: '+JSON.stringify({sessionId:'backend',
          update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text:'streaming reply '+prompts}}})+'\n\n');
      }
      else { res.statusCode = 404; res.end(); }
    });
  });
  const wait = async p => {
    const deadline = Date.now() + 5000;
    while (!p()) { if(Date.now() > deadline) throw Error('barrier timeout');
      await new Promise(r => setTimeout(r, 2)); }
  };
  server.listen(0, '127.0.0.1', async () => {
    try {
      """, setup, """('http://127.0.0.1:' + server.address().port);
      """, prompt, """(); await wait(() => createResponse);
      """, requestClose, """(); """, verify, """(0);
      createResponse.end(JSON.stringify({sessionId:'backend',
        sessionCapabilities:{cancelTurn:false,closeSession:true}}));
      await wait(() => closeResponse); """, verify, """(1);
      if(prompts !== 0) throw Error('closed draft delivered a prompt');
      closeResponse.statusCode = 502; closeResponse.end('close failed');
      closeResponse = null; await wait(() => """, ready, """(3)); """, verify, """(3);
      """, requestCancel, """(); """, verify, """(2);
      if(cancels !== 0) throw Error('unsupported cancellation sent');
      """, supportedCancel, """(); await wait(() => """, ready, """(5)); """, verify, """(5);
      cancelCode = 200;
      """, supportedCancel, """(); await wait(() => """, ready, """(6)); """, verify, """(6);
      if(cancels !== 2) throw Error('cancel request count');
      """, requestClose, """(); await wait(() => closeResponse);
      """, verify, """(1); closeResponse.end('{}');
      await wait(() => """, ready, """(4)); """, verify, """(4);
      if(closes !== 2) throw Error('wrong close count');
      createResponse = null; closeResponse = null;
      """, prompt, """(); await wait(() => createResponse);
      createResponse.end(JSON.stringify({sessionId:'backend',
        sessionCapabilities:{cancelTurn:false,closeSession:true}}));
      await wait(() => """, ready, """(8)); """, verify, """(8);
      promptResponse.end('event: end\ndata: {"stopReason":"end_turn"}\n\n');
      await wait(() => """, ready, """(7));
      promptResponse = null; """, expectReply, """(2); """, prompt, """();
      await wait(() => """, ready, """(8)); """, verify, """(8);
      """, cancelRunning, """(); """, verify, """(2);
      cancelCode = 501;
      """, supportedCancel, """(); await wait(() => """, ready, """(5)); """, verify, """(5);
      cancelCode = 200;
      """, supportedCancel, """(); await wait(() => """, ready, """(6)); """, verify, """(6);
      """, requestClose, """(); await wait(() => closeResponse);
      """, verify, """(1); closeResponse.end('{}');
      await wait(() => """, ready, """(4));
      promptResponse.end('event: end\ndata: {"stopReason":"error"}\n\n');
      """, verify, """(4);
      if(prompts !== 2 || closes !== 3) throw Error('stream close requests');
      for (const terminal of [
        '',
        'event: session/update\ndata: {"incomplete":',
        'event: end\ndata: {bad}\n\n',
        'event: end\ndata: {}\n\n',
        'event: end\n\n',
        'event: end\ndata: {"stopReason":"unknown"}\n\n',
        'event: end\ndata: {"stopReason":"end_turn"}',
        null
      ]) {
        createResponse = null; closeResponse = null; promptResponse = null;
        """, expectReply, """(prompts + 1);
        """, prompt, """(); await wait(() => createResponse);
        createResponse.end(JSON.stringify({sessionId:'backend',
          sessionCapabilities:{cancelTurn:false,closeSession:true}}));
        await wait(() => """, ready, """(8));
        const delivered = prompts;
        if (terminal === null) promptResponse.destroy();
        else promptResponse.end(terminal);
        await wait(() => """, ready, """(9)); """, verify, """(9);
        """, requestClose, """(); await wait(() => closeResponse);
        """, verify, """(1);
        if (prompts !== delivered) throw Error('uncertain turn delivered a duplicate prompt');
        closeResponse.end('{}');
        await wait(() => """, ready, """(4)); """, verify, """(4);
      }
      """, makeSingleChat, """();
      createResponse = null; closeResponse = null; promptResponse = null;
      """, expectReply, """(prompts + 1);
      """, prompt, """(); await wait(() => createResponse);
      createResponse.end(JSON.stringify({sessionId:'backend',
        sessionCapabilities:{cancelTurn:false,closeSession:true}}));
      await wait(() => """, ready, """(8)); promptResponse.end();
      await wait(() => """, ready, """(9)); """, verify, """(9);
      """, requestClose, """(); await wait(() => closeResponse);
      """, verify, """(1); closeResponse.statusCode = 502; closeResponse.end('close failed');
      closeResponse = null;
      await wait(() => """, ready, """(3)); """, verify, """(3);
      """, requestClose, """(); await wait(() => closeResponse);
      """, verify, """(1); closeResponse.end('{}');
      await wait(() => """, ready, """(11)); """, verify, """(11);
      console.log('PASS browser HTTP lifecycle, EOF and visible single-chat recovery');
    } catch(e) { console.error(e); process.exitCode = 1; }
    finally { server.close(); server.closeAllConnections(); }
  });
  """].}
else:
  {.error: "This integration test requires the JavaScript backend".}
