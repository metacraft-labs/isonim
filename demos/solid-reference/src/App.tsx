import { ErrorBoundary, Suspense } from "solid-js";
import { TaskProvider } from "./store/TaskStore";
import TaskHeader from "./components/TaskHeader";
import TaskList from "./components/TaskList";
import TaskFooter from "./components/TaskFooter";
import TaskDetail from "./components/TaskDetail";
import EffectLog from "./components/EffectLog";

export default function App() {
  return (
    <ErrorBoundary
      fallback={(err) => (
        <div class="error">
          <h2>Something went wrong</h2>
          <p>{err.message}</p>
        </div>
      )}
    >
      <TaskProvider>
        <Suspense fallback={<div class="loading">Loading...</div>}>
          <div class="app">
            <TaskHeader />
            <TaskList />
            <TaskFooter />
            <TaskDetail />
            <EffectLog />
          </div>
        </Suspense>
      </TaskProvider>
    </ErrorBoundary>
  );
}
