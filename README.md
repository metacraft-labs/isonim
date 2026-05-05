# IsoNim

Cross-platform reactive UI framework for Nim, inspired by SolidJS.

## Overview

IsoNim brings SolidJS's fine-grained reactivity model to Nim. It provides signals, effects, and memos as reactive primitives -- no virtual DOM diffing, no re-renders of entire component trees. Reactive updates target exactly the nodes that depend on changed data.

IsoNim is **cross-platform**: the same component code compiles to browser DOM (JS target), server-side HTML strings (C target), native iOS views (UIKit via objc_msgSend), native Android views (JNI command buffer), or desktop GUIs (Freya via Rust FFI). It ships with a pluggable renderer architecture, Yoga-based flexbox layout, and Tailwind CSS support across all targets.

## Features

- **Fine-grained reactivity** -- signals, effects, memos with automatic dependency tracking (no virtual DOM)
- **Cross-platform** -- same DSL renders to web, iOS (UIKit), Android (Material), desktop (Freya), terminal
- **Karax-style DSL** -- `ui` macro for type-safe, compile-time-checked HTML
- **Tailwind CSS** -- real Tailwind CLI integration; utility classes work on all platforms
- **Server-side rendering** -- `uiString`, `renderToString`, and streaming SSR with Suspense
- **Isomorphic components** -- `isomorphicUi` compiles the same code for server and client
- **Natural control flow** -- standard Nim `if`/`for`/`case` work inside the DSL macro
- **Natural control flow** -- standard Nim `if`/`else`, `for`, and `case` inside DSL blocks
- **Yoga layout engine** -- cross-platform flexbox positioning (embedded in renderer)
- **Native controls** -- compile-time switch between branded (identical) and native (UIKit/Material) controls
- **GUI-agnostic core** -- pluggable renderers (browser DOM, iOS, Android, Freya, terminal, mock, SSR)
- **Client hydration** with event replay
- **ViewModel/View testing** -- test reactive logic without a DOM
- **Pluggable clock** -- `TestClock` and `withFakeTime` for deterministic time-dependent tests
- **faststreams integration** -- optional high-performance streaming via `-d:useFaststreams`
- **js-framework-benchmark** participation -- keyed benchmark entry included

## Quick Start

```sh
# With Nix (recommended)
nix develop
just test-c

# Or manually
nimble install
nim c -r tests/test_signals.nim
```

Run the full test suite (C and JS backends, 18 test files):

```sh
just test      # both C and JS
just test-c    # C backend only
just test-js   # JS backend only
```

## Usage

### Signals and effects

```nim
import isonim/core/[signals, computation, owner]

createRoot proc(dispose: proc()) =
  var count = createSignal(0)
  createEffect proc() =
    echo "Count is: ", count.val
  count.val = 1  # prints "Count is: 1"
  count.val = 2  # prints "Count is: 2"
```

### Building HTML with the DSL

```nim
import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

let renderer = MockRenderer()
var count = createSignal(0)
let root = ui(renderer):
  tdiv(class = "counter"):
    span: text $count.val
    button(onclick = proc() = count.val = count.val + 1):
      text "+"
```

### Server-side rendering

```nim
import isonim/dsl/ui
import isonim/ssr/[renderer, escape]

let html = renderToString(proc(): string =
  uiString:
    tdiv(class = "app"):
      h1: text "Hello from SSR"
      if loggedIn:
        p: text "Welcome!"
      else:
        p: text "Please log in"
)
```

### Isomorphic components

```nim
proc myComponent(renderer: auto): auto =
  var count = createSignal(0)
  isomorphicUi(renderer):
    tdiv:
      span: text $count.val
# Compiles to DOM ops (default) or HTML strings (-d:isServer)
```

### DSL control flow

Standard Nim control flow works directly inside the `ui` macro -- no special directives needed:

```nim
ui(renderer):
  ul:
    for item in items:
      li: text item
  if loading:
    p: text "Loading..."
  else:
    p: text "Ready"
  case status
  of "ok": span: text "OK"
  of "error": span: text "Error"
  else: span: text "Unknown"
```

Use natural Nim control flow inside the DSL:

```nim
ui(renderer):
  ul:
    for index, item in items.val:
      li: text $item
  if loading.val:
    p: text "Loading..."
  else:
    p: text "Ready"
```

`showIf`/`showElse` and `forIn` are deprecated migration shims. New code should use natural Nim syntax immediately.

### Components

A component is a plain Nim proc that takes a renderer and returns a node. No base class, no registration — just functions:

```nim
proc Button(r: auto; label: string; onClick: proc()): auto =
  ui(r):
    button(class="btn", onclick=onClick):
      text label

proc Counter(r: auto; count: Signal[int]): auto =
  ui(r):
    tdiv(class="counter"):
      span: text $count.val      # reactive — DSL auto-wraps in effect
      Button(r, "+1", proc() =
        count.val = count.val + 1)
```

Components compose naturally — call them inside a `ui` block and the result is appended to the parent:

```nim
ui(renderer):
  tdiv(class="app"):
    h1: text "My App"
    Counter(renderer, myCount)     # component call, appended as child
    Counter(renderer, otherCount)  # another instance
```

Components that take signals get fine-grained reactivity — only the DOM nodes that read a signal update when it changes. The DSL wraps dynamic attribute expressions in `createRenderEffect` automatically.

For lists of components, use natural Nim loops:

```nim
ui(renderer):
  ul:
    for index, todo in todos.val:
      TodoItem(renderer, todo, index)  # each item rendered by a component
```

### Tailwind CSS (cross-platform)

```sh
# Build step: extract Tailwind styles from source
node tools/tailwind-extract.mjs
```

```nim
# Same classes work on web, iOS, Android, and desktop
ui(renderer):
  tdiv(class = "flex flex-col p-4 bg-slate-50 rounded-lg gap-2"):
    span(class = "text-xl font-bold text-gray-900"):
      text "Powered by real Tailwind CSS"
    button(class = "px-4 py-2 bg-indigo-500 text-white rounded-md"):
      text "Click me"
```

On web, the classes use the generated `build/tailwind.css`. On native, they're expanded to `setStyle` calls at compile time using data from the real Tailwind CSS CLI.

## Architecture

IsoNim is layered so each concern is isolated:

1. **Reactive core** (`core/`) -- signals, effects, memos, owners, batch, context, resources, suspense, transitions
2. **rxcore adapter** (`rxcore.nim`) -- 7-proc interface that renderers import instead of core internals
3. **Renderers** -- MockRenderer (testing), browser DOM (`web/`), UIKit (`isonim-cocoa`), Android (`isonim-android`), Freya (`isonim-freya`), terminal (`renderers/`), SSR (`ssr/`)
4. **DSL macros** (`dsl/ui.nim`) -- `ui`, `uiString`, `isomorphicUi`, with Tailwind CSS expansion
5. **Control flow** (`dsl/components.nim`) -- reactive primitives: `show`, `forEachKeyed`, `indexEach`, `errorBoundary`
6. **Component layer** (`components/`) -- cross-platform controls with compile-time backend selection
7. **Layout engine** (`layout/`) -- Yoga flexbox for cross-platform positioning
8. **Theme system** (`theming/`) -- branded, native, and adaptive theme modes

## Project Structure

```
src/isonim/
├── core/           # Reactive primitives (signals, effects, memos, batch, context, ...)
├── dsl/            # HTML DSL macros (ui, uiString, isomorphicUi)
│   ├── html.nim    #   DSL entry points
│   ├── components.nim  # Control flow (show, forEachKeyed, errorBoundary)
│   ├── transform.nim   # AST helpers (tag resolution, style property detection)
│   ├── tailwind.nim    # Compile-time Tailwind CSS class expansion
│   └── sugar.nim       # Syntax sugar
├── components/     # Cross-platform UI components
│   ├── task_app.nim        # App orchestrator (show + forEachKeyed)
│   ├── task_manager.nim    # Data model + signal-based TaskStore
│   ├── branded_controls.nim    # Styled controls (identical on all platforms)
│   ├── native_ios_controls.nim # iOS UIKit controls
│   └── native_android_controls.nim # Android Material controls
├── layout/         # Yoga flexbox layout engine
├── theming/        # Cross-platform theme system
├── renderers/      # Alternative renderers (terminal, native prototype)
├── web/            # Browser DOM renderer, hydration, events
├── ssr/            # Server-side rendering (renderToString, streaming, escape)
├── ssr_nginx/      # nginx native SSR module
├── testing/        # MockRenderer and test utilities
├── rxcore.nim      # Adapter seam between core and renderers
└── viewmodel.nim   # ViewModel pattern for testable UI logic

tools/
└── tailwind-extract.mjs  # Build step: runs Tailwind CLI, generates JSON for native

tests/              # 18+ test files covering signals, effects, DSL, SSR, hydration, ...
demos/              # Demo apps (SolidJS reference, IsoNim replica, terminal counter)
benchmarks/         # js-framework-benchmark keyed entry
```

## Platform Repos

| Repo             | Platform             | Renderer                             |
| ---------------- | -------------------- | ------------------------------------ |
| `isonim`         | Core framework + web | DomRenderer, MockRenderer, SSR       |
| `isonim-cocoa`   | iOS + macOS          | UIKitRenderer (objc_msgSend + Yoga)  |
| `isonim-android` | Android              | AndroidRenderer (JNI command buffer) |
| `isonim-freya`   | Desktop (Freya)      | FreyaRenderer (Rust FFI)             |

## Testing

```sh
just test           # Full suite: C + JS backends
just test-signals   # Signals only (C + JS)
just test-effects   # Effects, memos, owners, batch (C + JS)
just test-dsl       # DSL and SSR DSL (C + JS)
just test-ssr       # SSR, streaming, round-trip (C only)
just test-web       # Browser DOM renderer (JS only)
just bench-test     # Benchmark correctness tests
```

Individual test files can be run directly:

```sh
nim c -r tests/test_signals.nim
nim js -r tests/test_dsl.nim
```

## IsoNim Editor

The editor is packaged as framework code under `isonim/editor`. Applications
own their workspace definitions and import the editor package instead of copying
the editor shell.

Stable public imports:

- `isonim/editor` exports the workspace, type, and ViewModel contract for
  native tests, build-time workspace construction, and browser entry points.
- `isonim/editor/browser` is the JS-only browser mount surface. It should only
  be imported from `nim js` entry points.

The editor package does not require the in-repo examples. Example projects such
as Wanderlust may import their own story data and then pass an `EditorWorkspace`
to the public package.

```nim
import isonim/editor

let workspace = newEditorWorkspace(
  title = "Metacraft Back Office",
  id = "metacraft-web",
  storyGroups = @[
    StoryGroup(
      name: "Operations dashboard",
      kind: skPage,
      expanded: true,
      description: "Customers, licenses, partners, and settlements",
      items: @[
        StoryItem(
          name: "Seeded local data",
          description: "Dashboard with realistic billing and license data",
          kind: skPage,
          group: "Operations dashboard")
      ])
  ],
  initialView = evPagePreview)
```

Browser entry points additionally import `isonim/editor/browser` and mount the
workspace:

```nim
when defined(js):
  import isonim/editor/browser

  discard mountEditor(workspace)
```

### Editor Consumer Contract

Consumers own the workspace data. A valid `EditorWorkspace` supplies
`storyGroups` and may also supply `canvasItems`, `connections`, `flowSteps`,
`vectorSymbols`, `initialStory`, `initialInspectorElement`,
`initialInspectorSection`, `initialVectorSymbol`, `initialReviewBaseline`,
`previewHook`, `platform`, and `panels`. The editor reads those values into an
`EditorVM`; it does not read consumer source files directly.

Agent integration is optional. Projects can pass `agentPromptAdapter` and
`agentCancelAdapter` when constructing the workspace. The core editor remains
usable without adapter packages; a missing prompt adapter is reported in chat
state instead of introducing a hard dependency.

The browser mount contract is:

```nim
when defined(js):
  import isonim/editor
  import isonim/editor/browser

  let vm = mountEditor(workspace, root = document.body)
```

`mountEditor` injects editor styles by default, renders into the supplied DOM
root, and returns the live `EditorVM` for host tests or controlled integrations.
Consumer browser entry points should import only `isonim/editor` and
`isonim/editor/browser`, plus their own workspace module.

The in-repo Wanderlust editor demo uses the same API:

```sh
just editor-build
just editor-serve
```

The editor maturity gate is documented in
`docs/editor-dogfood-release.md`. The machine-checkable feature matrix lives in
`docs/editor-feature-matrix.json` and is verified by
`tests/test_editor_release_gate.nim`. Every editor feature must list its target
workflow, maturity status, headless ViewModel tests, Playwright tests required
for pointer/focus/iframe/canvas behavior, visual assertion plan, and IsoNim
example plus metacraft-web consumer coverage. `functional` is not a Figma-grade
claim.

## Development

### Nix flake

The project includes a Nix flake with Nim, Nimble, Node.js, and just:

```sh
nix develop    # enter dev shell
```

### faststreams

Streaming SSR uses an `OutputStream` abstraction. Enable the high-performance faststreams backend with:

```sh
nim c -d:useFaststreams -r tests/test_streaming.nim
```

### Metacraft workspace

To add IsoNim to a metacraft workspace:

```sh
cd ~/metacraft
just init isonim
```

## License

MIT
