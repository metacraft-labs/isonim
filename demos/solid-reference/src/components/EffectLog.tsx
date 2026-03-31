import { For, Show } from "solid-js";
import { useTaskStore } from "../store/TaskStore";

// Displays the effect log to demonstrate that createEffect is firing
export default function EffectLog() {
  const { log } = useTaskStore();

  return (
    <Show when={log().length > 0}>
      <details class="effect-log">
        <summary>Effect log ({log().length} entries)</summary>
        <ul>
          <For each={log()}>{(entry) => <li>{entry}</li>}</For>
        </ul>
      </details>
    </Show>
  );
}
