import { Show } from "solid-js";
import { useTaskStore, type Filter } from "../store/TaskStore";

const FILTERS: Filter[] = ["all", "active", "completed"];

export default function TaskFooter() {
  const {
    tasks,
    filter,
    setFilter,
    activeCount,
    completedCount,
    clearCompleted,
  } = useTaskStore();

  return (
    <Show when={tasks().length > 0}>
      <footer class="task-footer">
        <span>
          {activeCount()} item{activeCount() !== 1 ? "s" : ""} left
        </span>
        <div class="filters">
          {FILTERS.map((f) => (
            <button
              class={filter() === f ? "selected" : ""}
              onClick={() => setFilter(f)}
            >
              {f}
            </button>
          ))}
        </div>
        <Show when={completedCount() > 0}>
          <button onClick={clearCompleted}>Clear completed</button>
        </Show>
      </footer>
    </Show>
  );
}
