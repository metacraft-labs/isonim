import { For, Show } from "solid-js";
import { useTaskStore } from "../store/TaskStore";

export default function TaskList() {
  const { filteredTasks, toggleTask, removeTask, setSelectedId } =
    useTaskStore();

  return (
    <section>
      <Show
        when={filteredTasks().length > 0}
        fallback={<p class="empty">No tasks</p>}
      >
        <ul class="task-list">
          <For each={filteredTasks()}>
            {(task) => (
              <li class={task.done ? "completed" : ""}>
                <input
                  type="checkbox"
                  checked={task.done}
                  onChange={() => toggleTask(task.id)}
                />
                <span onClick={() => setSelectedId(task.id)}>{task.text}</span>
                <button class="remove" onClick={() => removeTask(task.id)}>
                  &times;
                </button>
              </li>
            )}
          </For>
        </ul>
      </Show>
    </section>
  );
}
