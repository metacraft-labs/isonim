# IsoNim Storybook

Visual component development and interaction testing for IsoNim components.

## Quick Start

```bash
# From the isonim root directory:
just storybook
```

This compiles the IsoNim components to JS and starts Storybook at http://localhost:6006.

## Architecture

IsoNim compiles Nim to JavaScript via `nim js`. Storybook's `@storybook/html` framework expects stories that return DOM elements. The bridge between them:

```
Nim source                    Compiled JS                  Storybook story
(reactive signals,     -->    (mountCounter,        -->    render() {
 DOM creation)                 mountTaskManager,            const el = ...;
                               custom elements)             mountCounter(el);
                                                            return el;
                                                          }
```

### Build Pipeline

1. **Nim compilation**: `nim js -o:storybook/dist/components.js src/storybook_components.nim`
   - Compiles all storybook-facing components into a single JS bundle
   - Each component exports a `mount*` function that takes a container element
   - Mount functions return a `dispose()` cleanup function

2. **Static serving**: Storybook serves `dist/` as a static directory
   - Stories load `./dist/components.js` via a `<script>` tag at runtime
   - The compiled JS attaches `mountCounter`, `mountTaskManager`, etc. to the global scope

3. **Story rendering**: Each story creates a container element, calls the mount function, and returns the container

## Story Types

### Static Mockups (`TaskManager.stories.ts`)

Hand-crafted DOM that mirrors IsoNim's output structure. Useful for:

- CSS development without compiling Nim
- Documenting expected DOM structure
- Quick visual iteration

### Reactive Components (`ReactiveComponents.stories.ts`)

Real IsoNim components compiled from Nim. These are fully reactive:

- Signals update the DOM when state changes
- Event handlers fire through the reactive system
- Interaction tests verify reactive behavior

### Web Components (`WebComponents.stories.ts`)

IsoNim custom elements (`<isonim-counter>`, `<isonim-task-item>`) using the `registerCustomElement` API. These demonstrate:

- Shadow DOM encapsulation
- Attribute-based configuration
- Reactive internals within custom elements

## Interaction Tests (play functions)

Stories use `@storybook/test` for interaction testing via `play()` functions:

```typescript
import { expect, userEvent, within } from "@storybook/test";

export const Counter: StoryObj = {
  render: () => {
    /* ... mount component ... */
  },
  play: async ({ canvasElement }) => {
    // Find elements
    const display = canvasElement.querySelector(".count-display");
    expect(display!.textContent).toBe("0");

    // Interact
    const incBtn = canvasElement.querySelector(".inc-btn") as HTMLElement;
    await userEvent.click(incBtn);
    await tick();

    // Verify reactive update
    expect(display!.textContent).toBe("1");
  },
};
```

Key patterns:

- Use `await tick()` (a `setTimeout(0)` wrapper) after interactions to let reactive effects propagate
- Query the `canvasElement` directly for light DOM components
- Query `element.shadowRoot` for Web Components with Shadow DOM
- The `ensureComponentsLoaded()` helper lazy-loads the compiled JS bundle

## Creating New Stories

1. Add a new `mount*` function in `src/storybook_components.nim`:

```nim
proc mountMyWidget*(container: Element, label: cstring): proc() {.exportc.} =
  var disposer: proc()
  createRoot do (dispose: proc()):
    disposer = dispose
    # Build reactive DOM here...
    container.Node.appendChild(widget.Node)
  return proc() =
    if disposer != nil: disposer()
    container.innerHTML = ""
```

2. Recompile: `just build-storybook-components`

3. Add a story in `stories/`:

```typescript
export const MyWidget: StoryObj = {
  render: () => {
    const container = document.createElement("div");
    ensureComponentsLoaded().then(() => {
      mountMyWidget(container as unknown as Element, "Hello");
    });
    return container;
  },
};
```

## Commands

| Command                           | Description                                      |
| --------------------------------- | ------------------------------------------------ |
| `just storybook`                  | Build components + start Storybook dev server    |
| `just build-storybook-components` | Compile Nim components to JS only                |
| `just storybook-build`            | Build components + produce static Storybook site |
