// The .nim module is imported for side effects only: it publishes
// the mount entry on globalThis (Nim's JS output is a script, not
// an ES module). After import resolves, the entry is callable.
//
// On HMR: Vite replaces the .nim-derived module and re-executes
// its top-level code. The new init re-registers slots via
// hmrRegisterFactory; mountUiHot's reactive effect re-runs against
// the new factory and reconciles the DOM in place. We mount only
// ONCE here; subsequent updates are slot-driven.
import "./counter.nim";

declare global {
  // eslint-disable-next-line no-var
  var __isonim_demo_mountCounter: () => void;
}

globalThis.__isonim_demo_mountCounter();
