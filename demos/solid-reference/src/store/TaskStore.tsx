import {
  createContext,
  useContext,
  createSignal,
  createMemo,
  createEffect,
  type JSX,
} from "solid-js";

// -- Types --

export interface Task {
  id: number;
  text: string;
  done: boolean;
}

export type Filter = "all" | "active" | "completed";

export interface TaskDetails {
  id: number;
  notes: string;
  createdAt: string;
}

export interface TaskStore {
  // Signals
  tasks: () => Task[];
  setTasks: (v: Task[] | ((prev: Task[]) => Task[])) => void;
  filter: () => Filter;
  setFilter: (v: Filter) => void;
  selectedId: () => number | null;
  setSelectedId: (v: number | null) => void;

  // Derived
  filteredTasks: () => Task[];
  activeCount: () => number;
  completedCount: () => number;

  // Actions
  addTask: (text: string) => void;
  toggleTask: (id: number) => void;
  removeTask: (id: number) => void;
  clearCompleted: () => void;

  // Effect-tracked log (demonstrates createEffect)
  log: () => string[];
}

// -- ID generator --

let nextId = 0;
export function generateId(): number {
  return ++nextId;
}

// -- Context --

const TaskContext = createContext<TaskStore>();

export function useTaskStore(): TaskStore {
  const ctx = useContext(TaskContext);
  if (!ctx) throw new Error("useTaskStore must be used inside TaskProvider");
  return ctx;
}

// -- Provider --

export function TaskProvider(props: { children: JSX.Element }) {
  const [tasks, setTasks] = createSignal<Task[]>([]);
  const [filter, setFilter] = createSignal<Filter>("all");
  const [selectedId, setSelectedId] = createSignal<number | null>(null);
  const [log, setLog] = createSignal<string[]>([]);

  // Derived state via createMemo
  const filteredTasks = createMemo(() => {
    const f = filter();
    const all = tasks();
    if (f === "all") return all;
    if (f === "active") return all.filter((t) => !t.done);
    return all.filter((t) => t.done);
  });

  const activeCount = createMemo(() => tasks().filter((t) => !t.done).length);
  const completedCount = createMemo(() => tasks().filter((t) => t.done).length);

  // Side-effect: log task count changes (demonstrates createEffect)
  createEffect(() => {
    const count = tasks().length;
    setLog((prev) => [...prev, `Task count changed to ${count}`]);
  });

  // Actions
  const addTask = (text: string) => {
    const trimmed = text.trim();
    if (!trimmed) return;
    setTasks((prev) => [
      ...prev,
      { id: generateId(), text: trimmed, done: false },
    ]);
  };

  const toggleTask = (id: number) => {
    setTasks((prev) =>
      prev.map((t) => (t.id === id ? { ...t, done: !t.done } : t)),
    );
  };

  const removeTask = (id: number) => {
    setTasks((prev) => prev.filter((t) => t.id !== id));
    // Deselect if the removed task was selected
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

  const store: TaskStore = {
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
    log,
  };

  return (
    <TaskContext.Provider value={store}>{props.children}</TaskContext.Provider>
  );
}
