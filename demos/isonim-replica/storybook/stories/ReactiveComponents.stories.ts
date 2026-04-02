/**
 * IsoNim Reactive Components — Storybook Stories
 *
 * These stories mount real IsoNim components compiled from Nim to JS.
 * Unlike the static mockups in TaskManager.stories.ts, these are fully
 * reactive: signals update the DOM, events fire through the reactive system.
 *
 * Prerequisites:
 *   nim js -o:storybook/dist/components.js src/storybook_components.nim
 *
 * The compiled JS exports:
 *   - mountCounter(container: Element): () => void
 *   - mountTaskItem(container: Element, text: string, done?: boolean): () => void
 *   - mountTaskManager(container: Element, initialTasks?: string[]): () => void
 *   - registerStorybookWebComponents(): void
 */

import type { Meta, StoryObj } from "@storybook/html";
import { expect, userEvent, within } from "@storybook/test";

// The compiled IsoNim bundle is served as a static asset from dist/.
// We declare the globals that the Nim JS output attaches to the window.
declare global {
  function mountCounter(container: Element): () => void;
  function mountTaskItem(
    container: Element,
    text: string,
    done?: boolean,
  ): () => void;
  function mountTaskManager(
    container: Element,
    initialTasks?: string[],
  ): () => void;
  function registerStorybookWebComponents(): void;
}

// Helper: inject the same CSS used by the demo app
function injectStyles(container: HTMLElement): void {
  const style = document.createElement("style");
  style.textContent = `
    body { font-family: sans-serif; }
    h1 { color: #333; margin: 0 0 16px; }
    .app { max-width: 500px; }
    .counter { display: flex; align-items: center; gap: 12px; }
    .count-display { font-size: 24px; min-width: 40px; text-align: center; }
    .counter button { padding: 8px 16px; font-size: 18px; cursor: pointer; }
    .task-list { list-style: none; padding: 0; margin: 0; }
    .task-list li {
      padding: 8px 0;
      border-bottom: 1px solid #eee;
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .task-list li.completed span {
      text-decoration: line-through;
      color: #999;
    }
    .remove {
      background: none;
      border: none;
      color: #cc3333;
      cursor: pointer;
      margin-left: auto;
      font-size: 16px;
    }
    .filters { display: flex; gap: 8px; margin: 12px 0; }
    .filters button { padding: 4px 8px; cursor: pointer; }
    .filters button.selected { font-weight: bold; text-decoration: underline; }
    .empty { color: #999; font-style: italic; }
    .task-footer {
      margin-top: 12px;
      padding-top: 12px;
      border-top: 1px solid #eee;
    }
    form { display: flex; gap: 8px; margin: 0 0 16px; }
    input[type="text"] { flex: 1; padding: 8px; }
    button[type="submit"] { padding: 8px 16px; }
  `;
  container.appendChild(style);
}

// Helper: load the compiled IsoNim bundle if not already loaded
let loadPromise: Promise<void> | null = null;
function ensureComponentsLoaded(): Promise<void> {
  if (typeof mountCounter !== "undefined") {
    return Promise.resolve();
  }
  if (!loadPromise) {
    loadPromise = new Promise<void>((resolve, reject) => {
      const script = document.createElement("script");
      script.src = "./dist/components.js";
      script.onload = () => resolve();
      script.onerror = () =>
        reject(
          new Error(
            "Failed to load compiled IsoNim components from dist/components.js. Run: just build-storybook-components",
          ),
        );
      document.head.appendChild(script);
    });
  }
  return loadPromise;
}

// Small delay helper for reactive effects to propagate
function tick(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

const meta: Meta = {
  title: "IsoNim/Reactive Components",
  parameters: {
    layout: "padded",
  },
};

export default meta;

// ---- Counter ----

export const Counter: StoryObj = {
  render: () => {
    const container = document.createElement("div");
    injectStyles(container);

    const mountPoint = document.createElement("div");
    container.appendChild(mountPoint);

    // Load and mount asynchronously
    ensureComponentsLoaded().then(() => {
      const dispose = mountCounter(mountPoint as unknown as Element);
      // Store dispose for cleanup
      (container as any).__dispose = dispose;
    });

    return container;
  },
  play: async ({ canvasElement }) => {
    await ensureComponentsLoaded();
    await tick();

    const canvas = within(canvasElement);

    // Find the count display
    const display = canvasElement.querySelector(".count-display");
    expect(display).toBeTruthy();
    expect(display!.textContent).toBe("0");

    // Click increment
    const incBtn = canvasElement.querySelector(".inc-btn") as HTMLElement;
    expect(incBtn).toBeTruthy();
    await userEvent.click(incBtn);
    await tick();
    expect(display!.textContent).toBe("1");

    // Click increment again
    await userEvent.click(incBtn);
    await tick();
    expect(display!.textContent).toBe("2");

    // Click decrement
    const decBtn = canvasElement.querySelector(".dec-btn") as HTMLElement;
    expect(decBtn).toBeTruthy();
    await userEvent.click(decBtn);
    await tick();
    expect(display!.textContent).toBe("1");

    // Decrement back to 0
    await userEvent.click(decBtn);
    await tick();
    expect(display!.textContent).toBe("0");
  },
};
Counter.storyName = "Counter";

// ---- Task Manager — Empty ----

export const TaskManagerEmpty: StoryObj = {
  render: () => {
    const container = document.createElement("div");
    injectStyles(container);

    const mountPoint = document.createElement("div");
    container.appendChild(mountPoint);

    ensureComponentsLoaded().then(() => {
      const dispose = mountTaskManager(mountPoint as unknown as Element);
      (container as any).__dispose = dispose;
    });

    return container;
  },
  play: async ({ canvasElement }) => {
    await ensureComponentsLoaded();
    await tick();

    // Should show "No tasks" message
    const emptyMsg = canvasElement.querySelector(".empty");
    expect(emptyMsg).toBeTruthy();
    expect(emptyMsg!.textContent).toBe("No tasks");

    // Should not have any task list items
    const items = canvasElement.querySelectorAll(".task-list li");
    expect(items.length).toBe(0);
  },
};
TaskManagerEmpty.storyName = "Task Manager — Empty";

// ---- Task Manager — With Tasks ----

export const TaskManagerWithTasks: StoryObj = {
  render: () => {
    const container = document.createElement("div");
    injectStyles(container);

    const mountPoint = document.createElement("div");
    container.appendChild(mountPoint);

    ensureComponentsLoaded().then(() => {
      const dispose = mountTaskManager(mountPoint as unknown as Element, [
        "Learn IsoNim",
        "Build demo app",
        "Write tests",
      ]);
      (container as any).__dispose = dispose;
    });

    return container;
  },
  play: async ({ canvasElement }) => {
    await ensureComponentsLoaded();
    await tick();

    // 1. Verify initial tasks rendered
    const items = canvasElement.querySelectorAll(".task-list li");
    expect(items.length).toBe(3);

    // Verify task text
    const spans = canvasElement.querySelectorAll(".task-list li span");
    expect(spans[0].textContent).toBe("Learn IsoNim");
    expect(spans[1].textContent).toBe("Build demo app");
    expect(spans[2].textContent).toBe("Write tests");

    // 2. Toggle first task — click its checkbox
    const firstCheckbox = items[0].querySelector(
      'input[type="checkbox"]',
    ) as HTMLElement;
    expect(firstCheckbox).toBeTruthy();
    await userEvent.click(firstCheckbox);
    await tick();

    // 3. Verify completion state changed
    const updatedItems = canvasElement.querySelectorAll(".task-list li");
    expect(updatedItems[0].className).toContain("completed");

    // 4. Verify footer count updated (2 active items now)
    const countEl = canvasElement.querySelector(".count");
    expect(countEl).toBeTruthy();
    expect(countEl!.textContent).toBe("2 items left");

    // 5. Add a new task via the form
    const input = canvasElement.querySelector(
      'input[type="text"]',
    ) as HTMLInputElement;
    expect(input).toBeTruthy();
    await userEvent.type(input, "Deploy app");

    const addBtn = canvasElement.querySelector(
      'button[type="submit"]',
    ) as HTMLElement;
    await userEvent.click(addBtn);
    await tick();

    // 6. Verify task count increased
    const finalItems = canvasElement.querySelectorAll(".task-list li");
    expect(finalItems.length).toBe(4);
  },
};
TaskManagerWithTasks.storyName = "Task Manager — With Tasks";

// ---- Task Item — Active ----

export const TaskItemActive: StoryObj = {
  render: () => {
    const container = document.createElement("div");
    injectStyles(container);

    const mountPoint = document.createElement("div");
    mountPoint.style.maxWidth = "400px";
    container.appendChild(mountPoint);

    ensureComponentsLoaded().then(() => {
      // Wrap in a ul for proper list styling
      const ul = document.createElement("ul");
      ul.className = "task-list";
      mountPoint.appendChild(ul);
      const dispose = mountTaskItem(
        ul as unknown as Element,
        "Buy groceries",
        false,
      );
      (container as any).__dispose = dispose;
    });

    return container;
  },
  play: async ({ canvasElement }) => {
    await ensureComponentsLoaded();
    await tick();

    const li = canvasElement.querySelector("li");
    expect(li).toBeTruthy();
    expect(li!.className).not.toContain("completed");

    const span = li!.querySelector("span");
    expect(span!.textContent).toBe("Buy groceries");

    // Toggle it to completed
    const checkbox = li!.querySelector('input[type="checkbox"]') as HTMLElement;
    await userEvent.click(checkbox);
    await tick();

    expect(li!.className).toContain("completed");
  },
};
TaskItemActive.storyName = "Task Item — Active";

// ---- Task Item — Completed ----

export const TaskItemCompleted: StoryObj = {
  render: () => {
    const container = document.createElement("div");
    injectStyles(container);

    const mountPoint = document.createElement("div");
    mountPoint.style.maxWidth = "400px";
    container.appendChild(mountPoint);

    ensureComponentsLoaded().then(() => {
      const ul = document.createElement("ul");
      ul.className = "task-list";
      mountPoint.appendChild(ul);
      const dispose = mountTaskItem(
        ul as unknown as Element,
        "Learn IsoNim",
        true,
      );
      (container as any).__dispose = dispose;
    });

    return container;
  },
  play: async ({ canvasElement }) => {
    await ensureComponentsLoaded();
    await tick();

    const li = canvasElement.querySelector("li");
    expect(li).toBeTruthy();
    expect(li!.className).toContain("completed");

    const span = li!.querySelector("span");
    expect(span!.textContent).toBe("Learn IsoNim");

    // Toggle it back to active
    const checkbox = li!.querySelector('input[type="checkbox"]') as HTMLElement;
    await userEvent.click(checkbox);
    await tick();

    expect(li!.className).not.toContain("completed");
  },
};
TaskItemCompleted.storyName = "Task Item — Completed";
