/**
 * IsoNim Demo App — Storybook Stories
 *
 * Each story renders the task manager UI in a specific state.
 * The DOM is built to match IsoNim's compiled output structure.
 * For full interactive stories, compile IsoNim to JS and import.
 */

// Helper: create the CSS styles used by the demo
function injectStyles(): HTMLStyleElement {
  const style = document.createElement("style");
  style.textContent = `
    body { font-family: sans-serif; }
    h1 { color: #333; margin: 0 0 16px; }
    .app { max-width: 500px; }
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
  return style;
}

// Helper: create a task list item
function createTaskItem(text: string, done: boolean = false): HTMLLIElement {
  const li = document.createElement("li");
  if (done) li.className = "completed";
  const checkbox = document.createElement("input");
  checkbox.type = "checkbox";
  checkbox.checked = done;
  li.appendChild(checkbox);
  const span = document.createElement("span");
  span.textContent = text;
  li.appendChild(span);
  const removeBtn = document.createElement("button");
  removeBtn.className = "remove";
  removeBtn.textContent = "\u00D7";
  li.appendChild(removeBtn);
  return li;
}

// Helper: create the app header
function createHeader(): HTMLElement {
  const header = document.createElement("header");
  const h1 = document.createElement("h1");
  h1.textContent = "Task Manager";
  header.appendChild(h1);
  const form = document.createElement("form");
  const input = document.createElement("input");
  input.type = "text";
  input.placeholder = "What needs to be done?";
  form.appendChild(input);
  const btn = document.createElement("button");
  btn.type = "submit";
  btn.textContent = "Add";
  form.appendChild(btn);
  header.appendChild(form);
  return header;
}

// Helper: create the footer
function createFooter(
  activeCount: number,
  completedCount: number,
  currentFilter: string = "All",
): HTMLElement {
  const footer = document.createElement("footer");
  footer.className = "task-footer";
  const count = document.createElement("span");
  const suffix = activeCount !== 1 ? "s" : "";
  count.textContent = `${activeCount} item${suffix} left`;
  footer.appendChild(count);
  const filters = document.createElement("div");
  filters.className = "filters";
  for (const f of ["All", "Active", "Completed"]) {
    const btn = document.createElement("button");
    btn.textContent = f;
    if (f === currentFilter) btn.className = "selected";
    filters.appendChild(btn);
  }
  footer.appendChild(filters);
  if (completedCount > 0) {
    const clearBtn = document.createElement("button");
    clearBtn.textContent = "Clear completed";
    footer.appendChild(clearBtn);
  }
  return footer;
}

export default {
  title: "Demo/TaskManager",
};

export const EmptyState = () => {
  const container = document.createElement("div");
  container.appendChild(injectStyles());
  const app = document.createElement("div");
  app.className = "app";
  app.appendChild(createHeader());
  const section = document.createElement("section");
  const empty = document.createElement("p");
  empty.className = "empty";
  empty.textContent = "No tasks";
  section.appendChild(empty);
  app.appendChild(section);
  container.appendChild(app);
  return container;
};
EmptyState.storyName = "Empty State";

export const WithTasks = () => {
  const container = document.createElement("div");
  container.appendChild(injectStyles());
  const app = document.createElement("div");
  app.className = "app";
  app.appendChild(createHeader());
  const section = document.createElement("section");
  const ul = document.createElement("ul");
  ul.className = "task-list";
  ul.appendChild(createTaskItem("Learn IsoNim"));
  ul.appendChild(createTaskItem("Build demo app"));
  ul.appendChild(createTaskItem("Write tests"));
  section.appendChild(ul);
  app.appendChild(section);
  app.appendChild(createFooter(3, 0));
  container.appendChild(app);
  return container;
};
WithTasks.storyName = "With Tasks";

export const MixedCompletion = () => {
  const container = document.createElement("div");
  container.appendChild(injectStyles());
  const app = document.createElement("div");
  app.className = "app";
  app.appendChild(createHeader());
  const section = document.createElement("section");
  const ul = document.createElement("ul");
  ul.className = "task-list";
  ul.appendChild(createTaskItem("Learn IsoNim", true));
  ul.appendChild(createTaskItem("Build demo app"));
  ul.appendChild(createTaskItem("Write tests", true));
  ul.appendChild(createTaskItem("Deploy"));
  section.appendChild(ul);
  app.appendChild(section);
  app.appendChild(createFooter(2, 2));
  container.appendChild(app);
  return container;
};
MixedCompletion.storyName = "Mixed Completion";

export const FilteredActive = () => {
  const container = document.createElement("div");
  container.appendChild(injectStyles());
  const app = document.createElement("div");
  app.className = "app";
  app.appendChild(createHeader());
  const section = document.createElement("section");
  const ul = document.createElement("ul");
  ul.className = "task-list";
  ul.appendChild(createTaskItem("Build demo app"));
  ul.appendChild(createTaskItem("Deploy"));
  section.appendChild(ul);
  app.appendChild(section);
  app.appendChild(createFooter(2, 2, "Active"));
  container.appendChild(app);
  return container;
};
FilteredActive.storyName = "Filtered — Active Only";

export const FilteredCompleted = () => {
  const container = document.createElement("div");
  container.appendChild(injectStyles());
  const app = document.createElement("div");
  app.className = "app";
  app.appendChild(createHeader());
  const section = document.createElement("section");
  const ul = document.createElement("ul");
  ul.className = "task-list";
  ul.appendChild(createTaskItem("Learn IsoNim", true));
  ul.appendChild(createTaskItem("Write tests", true));
  section.appendChild(ul);
  app.appendChild(section);
  app.appendChild(createFooter(2, 2, "Completed"));
  container.appendChild(app);
  return container;
};
FilteredCompleted.storyName = "Filtered — Completed Only";

export const AllCompleted = () => {
  const container = document.createElement("div");
  container.appendChild(injectStyles());
  const app = document.createElement("div");
  app.className = "app";
  app.appendChild(createHeader());
  const section = document.createElement("section");
  const ul = document.createElement("ul");
  ul.className = "task-list";
  ul.appendChild(createTaskItem("Task 1", true));
  ul.appendChild(createTaskItem("Task 2", true));
  section.appendChild(ul);
  app.appendChild(section);
  app.appendChild(createFooter(0, 2));
  container.appendChild(app);
  return container;
};
AllCompleted.storyName = "All Completed";
