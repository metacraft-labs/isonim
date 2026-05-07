## PoC: Monaco-like editor hosting pattern for CodeTracer migration.
##
## Demonstrates how CodeTracer would host Monaco, xterm.js, DataTables,
## noUiSlider, jstree, etc. using the ref + onMount + onCleanup pattern.
##
## This test uses MockRenderer so no browser is needed.

import unittest
import std/tables
import isonim/core/[signals, computation, owner, batch, graph]
import isonim/testing/mock_dom
import isonim/dsl/ui

# ---------------------------------------------------------------------------
# Mock Monaco editor API (simulates monaco.editor.create)
# ---------------------------------------------------------------------------

type
  MockMonacoEditor = ref object
    container*: MockNode
    code*: string
    language*: string
    disposed*: bool
    changeListeners*: seq[proc(newCode: string)]

proc createMonacoEditor(container: MockNode; code, language: string): MockMonacoEditor =
  result = MockMonacoEditor(
    container: container,
    code: code,
    language: language,
    disposed: false,
    changeListeners: @[],
  )
  container.attributes["data-editor"] = "monaco"
  container.attributes["data-language"] = language

proc setValue*(e: MockMonacoEditor; code: string) =
  if not e.disposed:
    e.code = code

proc getValue*(e: MockMonacoEditor): string =
  e.code

proc onDidChangeContent*(e: MockMonacoEditor; cb: proc(newCode: string)) =
  e.changeListeners.add(cb)

proc simulateUserEdit*(e: MockMonacoEditor; newCode: string) =
  ## Simulate user typing in the editor
  e.code = newCode
  for cb in e.changeListeners:
    cb(newCode)

proc destroy*(e: MockMonacoEditor) =
  e.disposed = true
  e.container.attributes.del("data-editor")
  e.container.attributes.del("data-language")

# ---------------------------------------------------------------------------
# Mock xterm.js API (simulates Terminal)
# ---------------------------------------------------------------------------

type
  MockXtermTerminal = ref object
    container*: MockNode
    lines*: seq[string]
    disposed*: bool

proc createXtermTerminal(container: MockNode): MockXtermTerminal =
  result = MockXtermTerminal(
    container: container,
    lines: @[],
    disposed: false,
  )
  container.attributes["data-terminal"] = "xterm"

proc writeln*(t: MockXtermTerminal; line: string) =
  if not t.disposed:
    t.lines.add(line)

proc destroy*(t: MockXtermTerminal) =
  t.disposed = true
  t.container.attributes.del("data-terminal")

# ---------------------------------------------------------------------------
# Component patterns (as CodeTracer would define them)
# ---------------------------------------------------------------------------

proc EditorPanel(r: MockRenderer; code: Signal[string]; language: string):
    tuple[root: MockNode, editor: ptr MockMonacoEditor] =
  ## A panel hosting a Monaco editor.
  ## Pattern: container div with ref -> onMount initializes Monaco -> onCleanup disposes.
  var editorContainer: MockNode
  var editorRef: MockMonacoEditor

  let panel = ui(r):
    tdiv(class="editor-panel"):
      tdiv(class="editor-toolbar"):
        span: text language
      tdiv(ref=editorContainer, class="monaco-container"):
        discard

  onMount proc() =
    editorRef = createMonacoEditor(editorContainer, code.val, language)
    onCleanup do:
      editorRef.destroy()

  # Reactive bridge: push code changes to Monaco
  createEffect do:
    if editorRef != nil and not editorRef.disposed:
      editorRef.setValue(code.val)

  result = (root: panel, editor: addr editorRef)

proc TerminalPanel(r: MockRenderer):
    tuple[root: MockNode, terminal: ptr MockXtermTerminal] =
  ## A panel hosting an xterm.js terminal.
  var termContainer: MockNode
  var termRef: MockXtermTerminal

  let panel = ui(r):
    tdiv(class="terminal-panel"):
      tdiv(ref=termContainer, class="xterm-container"):
        discard

  onMount proc() =
    termRef = createXtermTerminal(termContainer)
    onCleanup do:
      termRef.destroy()

  result = (root: panel, terminal: addr termRef)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "Monaco-like editor hosting":
  test "EditorPanel creates and mounts editor":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let code = createSignal("proc main() =\n  echo \"hello\"")
      let (panel, editorPtr) = EditorPanel(r, code, "nim")

      check panel.tag == "div"
      check panel.attributes["class"] == "editor-panel"

      # Editor should be mounted
      let editor = editorPtr[]
      check editor != nil
      check editor.disposed == false
      check editor.code == "proc main() =\n  echo \"hello\""
      check editor.language == "nim"

      # Container should have data attributes from mock library
      check editor.container.attributes["data-editor"] == "monaco"
      check editor.container.attributes["data-language"] == "nim"

  test "EditorPanel reacts to code signal changes":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let code = createSignal("let x = 1")
      let (panel, editorPtr) = EditorPanel(r, code, "nim")
      let editor = editorPtr[]

      check editor.code == "let x = 1"

      code.val = "let x = 2"
      check editor.code == "let x = 2"

      code.val = "let x = 3\nlet y = 4"
      check editor.code == "let x = 3\nlet y = 4"

  test "EditorPanel cleans up on dispose":
    var editor: MockMonacoEditor
    var myDispose: proc()

    createRoot do (dispose: proc()):
      myDispose = dispose
      let r = MockRenderer()
      let code = createSignal("hello")
      let (panel, editorPtr) = EditorPanel(r, code, "nim")
      editor = editorPtr[]

    check editor != nil
    check editor.disposed == false

    myDispose()
    check editor.disposed == true

  test "TerminalPanel creates and mounts terminal":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let (panel, termPtr) = TerminalPanel(r)
      let term = termPtr[]

      check term != nil
      check term.disposed == false
      check term.container.attributes["data-terminal"] == "xterm"

      term.writeln("$ nim c main.nim")
      term.writeln("Hint: operation successful")
      check term.lines.len == 2

  test "TerminalPanel cleans up on dispose":
    var term: MockXtermTerminal
    var myDispose: proc()

    createRoot do (dispose: proc()):
      myDispose = dispose
      let r = MockRenderer()
      let (panel, termPtr) = TerminalPanel(r)
      term = termPtr[]

    check term.disposed == false
    myDispose()
    check term.disposed == true

  test "multiple third-party widgets in one layout":
    ## CodeTracer pattern: editor + terminal in a split layout
    var myDispose: proc()
    var editor: MockMonacoEditor
    var terminal: MockXtermTerminal

    createRoot do (dispose: proc()):
      myDispose = dispose
      let r = MockRenderer()
      let code = createSignal("echo 42")

      var editorHost: MockNode
      var terminalHost: MockNode

      let layout = ui(r):
        tdiv(class="split-layout"):
          tdiv(ref=editorHost, class="editor-pane"):
            discard
          tdiv(ref=terminalHost, class="terminal-pane"):
            discard

      onMount proc() =
        editor = createMonacoEditor(editorHost, code.val, "nim")
        terminal = createXtermTerminal(terminalHost)

      block:
        let edRef = editor
        let tmRef = terminal
        proc cleanup() =
          edRef.destroy()
          tmRef.destroy()
        onCleanup(cleanup)

      # Reactive bridge
      createEffect do:
        if editor != nil and not editor.disposed:
          editor.setValue(code.val)

      check editor != nil
      check terminal != nil
      check editor.code == "echo 42"

      # Simulate editing and terminal output
      code.val = "echo 100"
      check editor.code == "echo 100"

      terminal.writeln("100")
      check terminal.lines == @["100"]

    # Dispose should clean up both
    myDispose()
    check editor.disposed == true
    check terminal.disposed == true

  test "editor with bidirectional sync":
    ## Pattern: Monaco fires onChange -> updates signal -> other UI reacts
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let code = createSignal("initial")
      var editorHost: MockNode
      var editor: MockMonacoEditor
      var statusText = ""

      let root = ui(r):
        tdiv:
          tdiv(ref=editorHost, class="editor"):
            discard

      onMount proc() =
        editor = createMonacoEditor(editorHost, code.val, "nim")
        # When user edits in Monaco, push back to signal
        editor.onDidChangeContent proc(newCode: string) =
          code.val = newCode
        onCleanup do:
          editor.destroy()

      # A reactive effect that mirrors code to statusText
      createEffect do:
        statusText = "Code: " & code.val

      check statusText == "Code: initial"

      # Simulate user typing in Monaco
      editor.simulateUserEdit("modified")
      check code.val == "modified"
      check statusText == "Code: modified"
