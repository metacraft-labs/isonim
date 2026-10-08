## DOM resources belong to the reactive view that installed them. Persistent
## editor models and agent clients have independent lifetimes.
import isonim/core/owner
when defined(js):
  from std/dom import Element

template isDomViewHost*(E: typedesc): bool =
  ## Browser bridges require a real renderer DOM host, independent of JS target.
  when defined(js): E is Element
  else: false

when defined(js):
  {.emit: """
  (function () {
    if (globalThis.__isonimViewRuntime?.version === 1) return;
    const bridges = new Map();
    globalThis.__isonimViewRuntime = {version: 1, bridges};
    globalThis.__isonimDisposeView = function (owner) {
      if (!owner) return;
      owner.__isonimViewDisposed = true;
      const cleanups = owner.__isonimViewCleanups || new Set();
      owner.__isonimViewCleanups = new Set();
      for (const cleanup of cleanups) cleanup();
      cleanups.clear();
    };
    globalThis.__isonimViewCleanup = function (owner, cleanup) {
      if (owner.__isonimViewDisposed) { cleanup(); return function () {}; }
      const cleanups = owner.__isonimViewCleanups ||= new Set();
      cleanups.add(cleanup);
      return () => cleanups.delete(cleanup);
    };
    globalThis.__isonimDeferView = function (owner, callback, delay) {
      if (!owner || owner.__isonimViewDisposed) return;
      let release;
      const timer = setTimeout(() => {
        release();
        if (!owner.__isonimViewDisposed && owner.isConnected !== false) callback();
      }, delay);
      release = globalThis.__isonimViewCleanup(owner, () => clearTimeout(timer));
    };
    globalThis.__isonimFrameView = function (owner, callback) {
      if (!owner || owner.__isonimViewDisposed) return;
      let release;
      const frame = requestAnimationFrame(() => {
        release();
        if (!owner.__isonimViewDisposed && owner.isConnected !== false) callback();
      });
      release = globalThis.__isonimViewCleanup(owner, () => cancelAnimationFrame(frame));
    };
    // Several mounted preview frames share the editor model. Deliver each
    // parent preview event once, retaining a live frame's callback. Disposing
    // one frame must neither retain its model closure nor remove other owners.
    globalThis.__isonimPreviewBridge = function (owner, type, callback) {
      if (!owner || typeof window === 'undefined' || !window.addEventListener ||
          typeof owner.getBoundingClientRect !== 'function') return;
      let bridge = bridges.get(type);
      if (!bridge) {
        bridge = {owners: new Map(), listener: function (event) {
          for (const [node, deliver] of bridge.owners) {
            if (node.isConnected && !node.__isonimViewDisposed &&
                node.getClientRects().length && getComputedStyle(node).visibility !== 'hidden') {
              deliver(event); return;
            }
          }
        }};
        bridges.set(type, bridge);
        window.addEventListener(type, bridge.listener);
      }
      bridge.owners.set(owner, callback);
      globalThis.__isonimViewCleanup(owner, () => {
        bridge.owners.delete(owner);
        if (!bridge.owners.size) {
          window.removeEventListener(type, bridge.listener);
          bridges.delete(type);
        }
      });
    };
  })();
  """.}

proc ownViewResources*[E](node: E) =
  when defined(js):
    onCleanup proc() =
      {.emit: ["globalThis.__isonimDisposeView(", node, ");"].}
