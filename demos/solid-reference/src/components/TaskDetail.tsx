import { Show, Suspense, createResource } from "solid-js";
import { useTaskStore, type TaskDetails } from "../store/TaskStore";

// Simulates fetching task details from an API
async function fetchTaskDetails(id: number): Promise<TaskDetails> {
  await new Promise((r) => setTimeout(r, 500));
  return {
    id,
    notes: `Notes for task ${id}`,
    createdAt: new Date().toISOString(),
  };
}

export default function TaskDetail() {
  const { selectedId, tasks } = useTaskStore();

  const [details] = createResource(
    () => selectedId(),
    (id) => fetchTaskDetails(id),
  );

  const selectedTask = () => tasks().find((t) => t.id === selectedId());

  return (
    <Show when={selectedId() !== null}>
      <aside class="task-detail">
        <h3>Task Details</h3>
        <Show when={selectedTask()}>
          <p>
            <strong>{selectedTask()!.text}</strong>
          </p>
        </Show>
        <Suspense fallback={<div class="loading">Loading details...</div>}>
          <Show when={!details.loading && details()}>
            <p>{details()!.notes}</p>
            <p class="meta">Created: {details()!.createdAt}</p>
          </Show>
        </Suspense>
      </aside>
    </Show>
  );
}
