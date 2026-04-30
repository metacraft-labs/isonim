## PoC: Hosting a third-party terminal emulator library in IsoNim.
##
## Demonstrates how IsoNim components can host libraries like xterm.js that
## manage their own DOM subtree inside a container element. The pattern:
##
## 1. IsoNim creates a container div and hands it to the library
## 2. The library attaches its own canvas/DOM to the container
## 3. IsoNim drives the library reactively via signals and effects
## 4. IsoNim UI (toolbar, status bar) coexists with the library-owned area
## 5. Cleanup disposes the library on unmount

import unittest
import std/[strutils, tables]
import isonim/testing/mock_dom
import isonim/core/[signals, computation, owner]

# =============================================================================
# Mock terminal library (stands in for xterm.js)
# =============================================================================

type
  MockTerminal* = ref object
    container*: MockNode     ## The container element passed via open()
    rows*, cols*: int
    buffer*: string          ## Accumulated output
    disposed*: bool
    onDataCallback*: proc(data: string)

proc newMockTerminal*(rows = 24; cols = 80): MockTerminal =
  MockTerminal(rows: rows, cols: cols, buffer: "", disposed: false)

proc open*(term: MockTerminal; container: MockNode) =
  ## Attach the terminal to a container element.
  ## In a real library this would create canvas/DOM children.
  term.container = container

proc write*(term: MockTerminal; text: string) =
  ## Write text to the terminal buffer.
  term.buffer.add(text)

proc resize*(term: MockTerminal; cols, rows: int) =
  ## Resize the terminal viewport.
  term.cols = cols
  term.rows = rows

proc onData*(term: MockTerminal; cb: proc(data: string)) =
  ## Register callback for user input.
  term.onDataCallback = cb

proc dispose*(term: MockTerminal) =
  ## Clean up resources.
  term.disposed = true

proc simulateInput*(term: MockTerminal; data: string) =
  ## Test helper: simulate the user typing in the terminal.
  if term.onDataCallback != nil:
    term.onDataCallback(data)

# =============================================================================
# IsoNim component that hosts the terminal
# =============================================================================

type
  TerminalPanel* = object
    root*: MockNode          ## Top-level container (toolbar + terminal + status)
    toolbar*: MockNode       ## IsoNim-rendered toolbar
    container*: MockNode     ## Container div owned by the terminal library
    statusBar*: MockNode     ## IsoNim-rendered status bar
    terminal*: MockTerminal  ## The hosted terminal instance

proc createTerminalPanel*(
    r: MockRenderer;
    output: Signal[string];
    dimensions: Signal[tuple[cols, rows: int]];
    onInput: proc(data: string);
): TerminalPanel =
  ## Creates a terminal panel with:
  ##   - A toolbar with copy/paste buttons (IsoNim-rendered)
  ##   - A terminal container (library-owned)
  ##   - A status bar showing dimensions (IsoNim-rendered, reactive)

  let root = r.createElement("div")
  r.setAttribute(root, "class", "terminal-panel")

  # -- Toolbar (IsoNim-rendered) --
  let toolbar = r.createElement("div")
  r.setAttribute(toolbar, "class", "toolbar")

  let copyBtn = r.createElement("button")
  r.appendChild(copyBtn, r.createTextNode("Copy"))
  r.appendChild(toolbar, copyBtn)

  let pasteBtn = r.createElement("button")
  r.appendChild(pasteBtn, r.createTextNode("Paste"))
  r.appendChild(toolbar, pasteBtn)

  r.appendChild(root, toolbar)

  # -- Terminal container (handed to the library) --
  let container = r.createElement("div")
  r.setAttribute(container, "class", "terminal-container")
  r.appendChild(root, container)

  # -- Initialize the mock terminal library --
  let dims = dimensions.val
  let term = newMockTerminal(rows = dims.rows, cols = dims.cols)
  term.open(container)

  # Register input callback: terminal input flows back to IsoNim
  term.onData(onInput)

  # -- Reactive effect: write output signal to terminal --
  createRenderEffect proc() =
    let text = output.val
    if text.len > 0:
      term.write(text)

  # -- Reactive effect: resize terminal when dimensions change --
  createRenderEffect proc() =
    let dims = dimensions.val
    term.resize(dims.cols, dims.rows)

  # -- Status bar (IsoNim-rendered, reactive) --
  let statusBar = r.createElement("div")
  r.setAttribute(statusBar, "class", "status-bar")
  let statusText = r.createTextNode("")
  r.appendChild(statusBar, statusText)
  r.appendChild(root, statusBar)

  createRenderEffect proc() =
    let dims = dimensions.val
    r.setTextContent(statusText, $dims.cols & "x" & $dims.rows)

  # -- Cleanup: dispose terminal on unmount --
  onCleanup proc() =
    term.dispose()

  TerminalPanel(
    root: root,
    toolbar: toolbar,
    container: container,
    statusBar: statusBar,
    terminal: term,
  )

# =============================================================================
# Tests
# =============================================================================

suite "PoC: Terminal Host":

  test "container creation and library init":
    ## IsoNim creates a container div; the terminal attaches to it.
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let output = createSignal("")
      let dims = createSignal((cols: 80, rows: 24))
      let panel = createTerminalPanel(r, output, dims, proc(d: string) = discard)

      # The container div exists and has the right class
      check panel.container.attributes["class"] == "terminal-container"

      # The terminal is attached to that container
      check panel.terminal.container == panel.container
      check panel.terminal.rows == 24
      check panel.terminal.cols == 80
      check not panel.terminal.disposed

      dispose()

  test "reactive output — writing to signal causes terminal.write":
    ## Updating the output signal reactively pushes text to the terminal.
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let output = createSignal("")
      let dims = createSignal((cols: 80, rows: 24))
      let panel = createTerminalPanel(r, output, dims, proc(d: string) = discard)

      # Initial: buffer is empty (initial signal was "")
      check panel.terminal.buffer == ""

      # Write some output
      output.val = "Hello, terminal!\r\n"
      check panel.terminal.buffer == "Hello, terminal!\r\n"

      # Write more — buffer accumulates
      output.val = "$ ls\r\n"
      check panel.terminal.buffer == "Hello, terminal!\r\n$ ls\r\n"

      dispose()

  test "input callback — terminal input triggers IsoNim callback":
    ## User typing in the terminal fires the onInput callback.
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let output = createSignal("")
      let dims = createSignal((cols: 80, rows: 24))
      var received: seq[string]

      let panel = createTerminalPanel(r, output, dims, proc(data: string) =
        received.add(data)
      )

      # Simulate user typing
      panel.terminal.simulateInput("ls -la\r")
      check received.len == 1
      check received[0] == "ls -la\r"

      panel.terminal.simulateInput("cd /tmp\r")
      check received.len == 2
      check received[1] == "cd /tmp\r"

      dispose()

  test "resize handling — reactive dimensions signal triggers terminal.resize":
    ## Changing the dimensions signal reactively resizes the terminal.
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let output = createSignal("")
      let dims = createSignal((cols: 80, rows: 24))
      let panel = createTerminalPanel(r, output, dims, proc(d: string) = discard)

      check panel.terminal.cols == 80
      check panel.terminal.rows == 24

      # Resize
      dims.val = (cols: 120, rows: 40)
      check panel.terminal.cols == 120
      check panel.terminal.rows == 40

      # Resize again
      dims.val = (cols: 60, rows: 15)
      check panel.terminal.cols == 60
      check panel.terminal.rows == 15

      dispose()

  test "status bar reflects dimensions reactively":
    ## The IsoNim-rendered status bar updates when dimensions change.
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let output = createSignal("")
      let dims = createSignal((cols: 80, rows: 24))
      let panel = createTerminalPanel(r, output, dims, proc(d: string) = discard)

      # Status bar should show current dimensions
      check textContent(panel.statusBar) == "80x24"

      # Change dimensions — status bar updates reactively
      dims.val = (cols: 132, rows: 50)
      check textContent(panel.statusBar) == "132x50"

      dispose()

  test "surrounding IsoNim UI coexists with terminal container":
    ## The toolbar (IsoNim) + terminal container (library) + status bar
    ## (IsoNim) coexist in the same DOM tree.
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let output = createSignal("")
      let dims = createSignal((cols: 80, rows: 24))
      let panel = createTerminalPanel(r, output, dims, proc(d: string) = discard)

      # Root has three children: toolbar, container, statusBar
      check panel.root.children.len == 3
      check panel.root.children[0] == panel.toolbar
      check panel.root.children[1] == panel.container
      check panel.root.children[2] == panel.statusBar

      # Toolbar has copy and paste buttons
      check panel.toolbar.children.len == 2
      check textContent(panel.toolbar.children[0]) == "Copy"
      check textContent(panel.toolbar.children[1]) == "Paste"

      # Container is the library's playground
      check panel.container.attributes["class"] == "terminal-container"

      # Root has the panel class
      check panel.root.attributes["class"] == "terminal-panel"

      dispose()

  test "cleanup — dispose on unmount":
    ## Disposing the reactive root triggers terminal cleanup.
    var termRef: MockTerminal

    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let output = createSignal("")
      let dims = createSignal((cols: 80, rows: 24))
      let panel = createTerminalPanel(r, output, dims, proc(d: string) = discard)

      termRef = panel.terminal
      check not termRef.disposed

      # Disposing the root should trigger onCleanup -> terminal.dispose()
      dispose()

    check termRef.disposed

  test "full round-trip: output + input + resize":
    ## Integration test: exercises the full lifecycle.
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let output = createSignal("")
      let dims = createSignal((cols: 80, rows: 24))
      var inputLog: seq[string]

      let panel = createTerminalPanel(r, output, dims, proc(data: string) =
        inputLog.add(data)
      )

      # Server sends welcome message
      output.val = "Welcome to IsoNim Terminal\r\n$ "
      check "Welcome" in panel.terminal.buffer

      # User types a command
      panel.terminal.simulateInput("echo hello\r")
      check inputLog[0] == "echo hello\r"

      # Server responds
      output.val = "hello\r\n$ "
      check panel.terminal.buffer.endsWith("$ ")

      # User resizes the window
      dims.val = (cols: 100, rows: 30)
      check panel.terminal.cols == 100
      check panel.terminal.rows == 30
      check textContent(panel.statusBar) == "100x30"

      dispose()
