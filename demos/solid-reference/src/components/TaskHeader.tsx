import { createSignal } from "solid-js";
import { useTaskStore } from "../store/TaskStore";

export default function TaskHeader() {
  const { addTask } = useTaskStore();
  const [input, setInput] = createSignal("");

  const handleSubmit = (e: Event) => {
    e.preventDefault();
    addTask(input());
    setInput("");
  };

  return (
    <header>
      <h1>Task Manager</h1>
      <form onSubmit={handleSubmit}>
        <input
          type="text"
          placeholder="What needs to be done?"
          value={input()}
          onInput={(e) => setInput(e.currentTarget.value)}
        />
        <button type="submit">Add</button>
      </form>
    </header>
  );
}
