/**
 * IsoNim WebComponents — Storybook Stories
 *
 * Demonstrates IsoNim custom elements (<isonim-counter>, <isonim-task-item>)
 * in Storybook. These use the registerCustomElement API from
 * isonim/web/custom_element.nim, which creates real Web Components with
 * Shadow DOM and reactive internals.
 *
 * Prerequisites:
 *   nim js -o:storybook/dist/components.js src/storybook_components.nim
 *
 * The compiled JS exports registerStorybookWebComponents() which registers
 * the custom elements with the browser's customElements registry.
 */

import type { Meta, StoryObj } from "@storybook/html";
import { expect, userEvent } from "@storybook/test";

declare global {
  function registerStorybookWebComponents(): void;
}

// Load the compiled IsoNim bundle and register custom elements
let registered = false;
let loadPromise: Promise<void> | null = null;

function ensureWebComponentsRegistered(): Promise<void> {
  if (registered) {
    return Promise.resolve();
  }
  if (!loadPromise) {
    loadPromise = new Promise<void>((resolve, reject) => {
      // Check if already loaded (e.g., by ReactiveComponents stories)
      if (typeof registerStorybookWebComponents !== "undefined") {
        registerStorybookWebComponents();
        registered = true;
        resolve();
        return;
      }
      const script = document.createElement("script");
      script.src = "./dist/components.js";
      script.onload = () => {
        registerStorybookWebComponents();
        registered = true;
        resolve();
      };
      script.onerror = () =>
        reject(
          new Error(
            "Failed to load compiled IsoNim components. Run: just build-storybook-components",
          ),
        );
      document.head.appendChild(script);
    });
  }
  return loadPromise;
}

function tick(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

const meta: Meta = {
  title: "IsoNim/Web Components",
  parameters: {
    layout: "padded",
  },
};

export default meta;

// ---- Custom Counter ----

export const CustomCounter: StoryObj = {
  render: () => {
    const container = document.createElement("div");

    const description = document.createElement("p");
    description.textContent =
      "An <isonim-counter> custom element with Shadow DOM and reactive internals.";
    description.style.color = "#666";
    description.style.fontFamily = "sans-serif";
    container.appendChild(description);

    ensureWebComponentsRegistered().then(() => {
      const counter = document.createElement("isonim-counter");
      container.appendChild(counter);
    });

    return container;
  },
  play: async ({ canvasElement }) => {
    await ensureWebComponentsRegistered();
    await tick();

    const counterEl = canvasElement.querySelector("isonim-counter");
    expect(counterEl).toBeTruthy();

    // Access shadow DOM
    const shadow = counterEl!.shadowRoot;
    expect(shadow).toBeTruthy();

    const display = shadow!.querySelector(".count-display");
    expect(display).toBeTruthy();
    expect(display!.textContent).toBe("0");

    // Click increment in shadow DOM
    const incBtn = shadow!.querySelector(".inc-btn") as HTMLElement;
    expect(incBtn).toBeTruthy();
    await userEvent.click(incBtn);
    await tick();
    expect(display!.textContent).toBe("1");

    // Click decrement
    const decBtn = shadow!.querySelector(".dec-btn") as HTMLElement;
    await userEvent.click(decBtn);
    await tick();
    expect(display!.textContent).toBe("0");
  },
};
CustomCounter.storyName = "Custom Counter";

// ---- Custom Counter with Initial Value ----

export const CustomCounterWithInitial: StoryObj = {
  render: () => {
    const container = document.createElement("div");

    const description = document.createElement("p");
    description.textContent =
      'An <isonim-counter initial-count="5"> — starts at 5 via attribute.';
    description.style.color = "#666";
    description.style.fontFamily = "sans-serif";
    container.appendChild(description);

    ensureWebComponentsRegistered().then(() => {
      const counter = document.createElement("isonim-counter");
      counter.setAttribute("initial-count", "5");
      container.appendChild(counter);
    });

    return container;
  },
  play: async ({ canvasElement }) => {
    await ensureWebComponentsRegistered();
    await tick();

    const counterEl = canvasElement.querySelector("isonim-counter");
    const shadow = counterEl!.shadowRoot;
    const display = shadow!.querySelector(".count-display");
    expect(display!.textContent).toBe("5");
  },
};
CustomCounterWithInitial.storyName = "Custom Counter — Initial Value";

// ---- Custom Task Item — Active ----

export const CustomTaskItem: StoryObj = {
  render: () => {
    const container = document.createElement("div");

    const description = document.createElement("p");
    description.textContent =
      'An <isonim-task-item text="Buy groceries"> custom element.';
    description.style.color = "#666";
    description.style.fontFamily = "sans-serif";
    container.appendChild(description);

    ensureWebComponentsRegistered().then(() => {
      const item = document.createElement("isonim-task-item");
      item.setAttribute("text", "Buy groceries");
      container.appendChild(item);
    });

    return container;
  },
  play: async ({ canvasElement }) => {
    await ensureWebComponentsRegistered();
    await tick();

    const itemEl = canvasElement.querySelector("isonim-task-item");
    expect(itemEl).toBeTruthy();

    const shadow = itemEl!.shadowRoot;
    expect(shadow).toBeTruthy();

    const span = shadow!.querySelector("span");
    expect(span!.textContent).toBe("Buy groceries");

    const li = shadow!.querySelector("li");
    expect(li!.className).not.toContain("completed");

    // Toggle via checkbox
    const checkbox = shadow!.querySelector(
      'input[type="checkbox"]',
    ) as HTMLElement;
    await userEvent.click(checkbox);
    await tick();
    expect(li!.className).toContain("completed");
  },
};
CustomTaskItem.storyName = "Custom Task Item";

// ---- Custom Task Item — Completed ----

export const CustomTaskItemCompleted: StoryObj = {
  render: () => {
    const container = document.createElement("div");

    const description = document.createElement("p");
    description.textContent =
      'An <isonim-task-item text="Learn IsoNim" done="true"> — starts completed.';
    description.style.color = "#666";
    description.style.fontFamily = "sans-serif";
    container.appendChild(description);

    ensureWebComponentsRegistered().then(() => {
      const item = document.createElement("isonim-task-item");
      item.setAttribute("text", "Learn IsoNim");
      item.setAttribute("done", "true");
      container.appendChild(item);
    });

    return container;
  },
  play: async ({ canvasElement }) => {
    await ensureWebComponentsRegistered();
    await tick();

    const itemEl = canvasElement.querySelector("isonim-task-item");
    const shadow = itemEl!.shadowRoot;

    const li = shadow!.querySelector("li");
    expect(li!.className).toContain("completed");

    const span = shadow!.querySelector("span");
    expect(span!.textContent).toBe("Learn IsoNim");

    // Toggle back to active
    const checkbox = shadow!.querySelector(
      'input[type="checkbox"]',
    ) as HTMLElement;
    await userEvent.click(checkbox);
    await tick();
    expect(li!.className).not.toContain("completed");
  },
};
CustomTaskItemCompleted.storyName = "Custom Task Item — Completed";
