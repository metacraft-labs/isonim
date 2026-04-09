# IsoNim

Cross-platform reactive UI framework for Nim, inspired by SolidJS.

## Overview

IsoNim brings SolidJS's fine-grained reactivity model to Nim. It provides signals, effects, and memos as reactive primitives -- no virtual DOM diffing, no re-renders of entire component trees. Reactive updates target exactly the nodes that depend on changed data.

IsoNim is **cross-platform**: the same component code compiles to browser DOM (JS target), server-side HTML strings (C target), native iOS views (UIKit via objc_msgSend), native Android views (JNI command buffer), or desktop GUIs (Freya via Rust FFI). It ships with a pluggable renderer architecture, Yoga-based flexbox layout, and Tailwind CSS support across all targets.

## Features

- **Fine-grained reactivity** -- signals, effects, memos with automatic dependency tracking (no virtual DOM)
- **Cross-platform** -- same DSL renders to web, iOS (UIKit), Android (Material), desktop (Freya), terminal
- **Karax-style DSL** -- `buildHtml` macro for type-safe, compile-time-checked HTML
- **Tailwind CSS** -- real Tailwind CLI integration; utility classes work on all platforms
- **Server-side rendering** -- `buildHtmlString`, `renderToString`, and streaming SSR with Suspense
- **Isomorphic components** -- `isomorphicHtml` compiles the same code for server and client
- **DSL control flow** -- `showIf`/`showElse`, `forIn` directives integrated into the macro
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
import isonim/dsl/html
import isonim/testing/mock_dom

let renderer = MockRenderer()
var count = createSignal(0)
let root = buildHtml(renderer):
  tdiv(class = "counter"):
    span: text $count.val
    button(onclick = proc() = count.val = count.val + 1):
      text "+"
```

### Server-side rendering

```nim
import isonim/dsl/html
import isonim/ssr/[renderer, escape]

let html = renderToString(proc(): string =
  buildHtmlString:
    tdiv(class = "app"):
      h1: text "Hello from SSR"
      showIf(loggedIn):
        p: text "Welcome!"
      showElse:
        p: text "Please log in"
)
```

### Isomorphic components

```nim
proc myComponent(renderer: auto): auto =
  var count = createSignal(0)
  isomorphicHtml(renderer):
    tdiv:
      span: text $count.val
# Compiles to DOM ops (default) or HTML strings (-d:isServer)
```

### DSL control flow

```nim
buildHtml(renderer):
  ul:
    forIn(items.val):
      li: text $item
  showIf(loading.val):
    p: text "Loading..."
  showElse:
    p: text "Ready"
```

### Tailwind CSS (cross-platform)

```sh
# Build step: extract Tailwind styles from source
node tools/tailwind-extract.mjs
```

```nim
# Same classes work on web, iOS, Android, and desktop
buildHtml(renderer):
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
4. **DSL macros** (`dsl/html.nim`) -- `buildHtml`, `buildHtmlString`, `isomorphicHtml`, with Tailwind CSS expansion
5. **Control flow** (`dsl/components.nim`) -- `show`, `forEachKeyed`, `indexEach`, `errorBoundary`
6. **Component layer** (`components/`) -- cross-platform controls with compile-time backend selection
7. **Layout engine** (`layout/`) -- Yoga flexbox for cross-platform positioning
8. **Theme system** (`theming/`) -- branded, native, and adaptive theme modes

## Project Structure

```
src/isonim/
├── core/           # Reactive primitives (signals, effects, memos, batch, context, ...)
├── dsl/            # HTML DSL macros (buildHtml, buildHtmlString, isomorphicHtml)
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

| Repo | Platform | Renderer |
|------|----------|----------|
| `isonim` | Core framework + web | DomRenderer, MockRenderer, SSR |
| `isonim-cocoa` | iOS + macOS | UIKitRenderer (objc_msgSend + Yoga) |
| `isonim-android` | Android | AndroidRenderer (JNI command buffer) |
| `isonim-freya` | Desktop (Freya) | FreyaRenderer (Rust FFI) |

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
