import { describe, it, expect } from "vitest";
import { createRoot, createEffect } from "solid-js";
import { createSignal, createMemo } from "solid-js";
import type { Task, Filter } from "../store/TaskStore";

// Test the store's ViewModel logic directly using SolidJS primitives,
// without mounting any components. This validates that signals, memos,
// and effects behave correctly — the same behaviors IsoNim must replicate.

let idCounter = 0;
function nextId(): number {
  return ++idCounter;
}

// Helper: create a minimal store (same logic as TaskStore, no Context needed)
function createTaskStore() {
  const [tasks, setTasks] = createSignal<Task[]>([]);
  const [filter, setFilter] = createSignal<Filter>("all");
  const [selectedId, setSelectedId] = createSignal<number | null>(null);

  const filteredTasks = createMemo(() => {
    const f = filter();
    const all = tasks();
    if (f === "all") return all;
    if (f === "active") return all.filter((t) => !t.done);
    return all.filter((t) => t.done);
  });

  const activeCount = createMemo(() => tasks().filter((t) => !t.done).length);
  const completedCount = createMemo(() => tasks().filter((t) => t.done).length);

  const addTask = (text: string) => {
    const trimmed = text.trim();
    if (!trimmed) return;
    setTasks((prev) => [...prev, { id: nextId(), text: trimmed, done: false }]);
  };

  const toggleTask = (id: number) => {
    setTasks((prev) =>
      prev.map((t) => (t.id === id ? { ...t, done: !t.done } : t)),
    );
  };

  const removeTask = (id: number) => {
    setTasks((prev) => prev.filter((t) => t.id !== id));
    if (selectedId() === id) setSelectedId(null);
  };

  const clearCompleted = () => {
    const completedIds = new Set(
      tasks()
        .filter((t) => t.done)
        .map((t) => t.id),
    );
    if (completedIds.has(selectedId()!)) setSelectedId(null);
    setTasks((prev) => prev.filter((t) => !t.done));
  };

  return {
    tasks,
    setTasks,
    filter,
    setFilter,
    selectedId,
    setSelectedId,
    filteredTasks,
    activeCount,
    completedCount,
    addTask,
    toggleTask,
    removeTask,
    clearCompleted,
  };
}

describe("TaskStore ViewModel", () => {
  it("starts with an empty task list", () => {
    createRoot((dispose) => {
      const store = createTaskStore();
      expect(store.tasks()).toEqual([]);
      expect(store.filteredTasks()).toEqual([]);
      expect(store.activeCount()).toBe(0);
      expect(store.completedCount()).toBe(0);
      dispose();
    });
  });

  it("adds a task", () => {
    createRoot((dispose) => {
      const store = createTaskStore();
      store.addTask("Buy milk");
      expect(store.tasks().length).toBe(1);
      expect(store.tasks()[0].text).toBe("Buy milk");
      expect(store.tasks()[0].done).toBe(false);
      dispose();
    });
  });

  it("ignores blank tasks", () => {
    createRoot((dispose) => {
      const store = createTaskStore();
      store.addTask("");
      store.addTask("   ");
      expect(store.tasks().length).toBe(0);
      dispose();
    });
  });

  it("toggles a task", () => {
    createRoot((dispose) => {
      const store = createTaskStore();
      store.addTask("Task A");
      const id = store.tasks()[0].id;

      store.toggleTask(id);
      expect(store.tasks()[0].done).toBe(true);

      store.toggleTask(id);
      expect(store.tasks()[0].done).toBe(false);
      dispose();
    });
  });

  it("removes a task", () => {
    createRoot((dispose) => {
      const store = createTaskStore();
      store.addTask("Task A");
      store.addTask("Task B");
      expect(store.tasks().length).toBe(2);
      const id = store.tasks()[0].id;

      store.removeTask(id);
      expect(store.tasks().length).toBe(1);
      expect(store.tasks()[0].text).toBe("Task B");
      dispose();
    });
  });

  it("removes task deselects if that task was selected", () => {
    createRoot((dispose) => {
      const store = createTaskStore();
      store.addTask("Task A");
      const id = store.tasks()[0].id;
      store.setSelectedId(id);
      expect(store.selectedId()).toBe(id);

      store.removeTask(id);
      expect(store.selectedId()).toBeNull();
      dispose();
    });
  });

  it("filters tasks by active", () => {
    createRoot((dispose) => {
      const store = createTaskStore();
      store.addTask("Task A");
      store.addTask("Task B");
      expect(store.tasks().length).toBe(2);
      store.toggleTask(store.tasks()[0].id);

      store.setFilter("active");
      expect(store.filteredTasks().length).toBe(1);
      expect(store.filteredTasks()[0].text).toBe("Task B");
      dispose();
    });
  });

  it("filters tasks by completed", () => {
    createRoot((dispose) => {
      const store = createTaskStore();
      store.addTask("Task A");
      store.addTask("Task B");
      expect(store.tasks().length).toBe(2);
      store.toggleTask(store.tasks()[0].id);

      store.setFilter("completed");
      expect(store.filteredTasks().length).toBe(1);
      expect(store.filteredTasks()[0].text).toBe("Task A");
      dispose();
    });
  });

  it("shows all tasks with 'all' filter", () => {
    createRoot((dispose) => {
      const store = createTaskStore();
      store.addTask("Task A");
      store.addTask("Task B");
      store.toggleTask(store.tasks()[0].id);

      store.setFilter("all");
      expect(store.filteredTasks().length).toBe(2);
      dispose();
    });
  });

  it("counts active and completed correctly", () => {
    createRoot((dispose) => {
      const store = createTaskStore();
      store.addTask("A");
      store.addTask("B");
      store.addTask("C");
      expect(store.tasks().length).toBe(3);
      store.toggleTask(store.tasks()[0].id);

      expect(store.activeCount()).toBe(2);
      expect(store.completedCount()).toBe(1);
      dispose();
    });
  });

  it("clears completed tasks", () => {
    createRoot((dispose) => {
      const store = createTaskStore();
      store.addTask("A");
      store.addTask("B");
      store.addTask("C");
      expect(store.tasks().length).toBe(3);
      store.toggleTask(store.tasks()[0].id);
      store.toggleTask(store.tasks()[2].id);

      store.clearCompleted();
      expect(store.tasks().length).toBe(1);
      expect(store.tasks()[0].text).toBe("B");
      dispose();
    });
  });

  it("clears completed deselects if selected task was completed", () => {
    createRoot((dispose) => {
      const store = createTaskStore();
      store.addTask("A");
      const id = store.tasks()[0].id;
      store.toggleTask(id);
      store.setSelectedId(id);

      store.clearCompleted();
      expect(store.selectedId()).toBeNull();
      dispose();
    });
  });

  it("effect fires on task count change", () =>
    new Promise<void>((resolve) => {
      createRoot((dispose) => {
        const effectLog: number[] = [];
        const [tasks, setTasks] = createSignal<Task[]>([]);

        createEffect(() => {
          effectLog.push(tasks().length);
        });

        // After the initial effect + first update, check log
        // Use queueMicrotask to let batched effects flush
        queueMicrotask(() => {
          // Initial effect should have run with 0
          expect(effectLog[0]).toBe(0);

          setTasks([{ id: 1, text: "A", done: false }]);

          queueMicrotask(() => {
            // Effect should have fired again
            expect(effectLog.length).toBeGreaterThanOrEqual(2);
            expect(effectLog[effectLog.length - 1]).toBeGreaterThan(0);
            dispose();
            resolve();
          });
        });
      });
    }));

  it("memo recomputes only when dependencies change", () => {
    createRoot((dispose) => {
      let memoCallCount = 0;
      const [tasks, setTasks] = createSignal<Task[]>([]);
      const [filter, setFilter] = createSignal<Filter>("all");

      const filtered = createMemo(() => {
        memoCallCount++;
        const f = filter();
        const all = tasks();
        if (f === "all") return all;
        if (f === "active") return all.filter((t) => !t.done);
        return all.filter((t) => t.done);
      });

      // Initial computation
      filtered();
      expect(memoCallCount).toBe(1);

      // Reading again without changes should not recompute
      filtered();
      expect(memoCallCount).toBe(1);

      // Changing filter triggers recomputation
      setFilter("active");
      filtered();
      expect(memoCallCount).toBe(2);

      dispose();
    });
  });
});
