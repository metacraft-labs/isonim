// frame_applier.js — the host half of `frame_renderer.nim`.
//
// A ViewModel core that runs as WebAssembly (or anywhere apart from the
// document) cannot hold a DOM node. It renders through `FrameRenderer`, which
// writes every operation into a flat byte frame; this file reads that frame
// and applies it to a real document, holding the node table the core cannot.
//
// ## THE OPCODE TABLE COMES FROM THE CORE
//
// `createFrameApplier` takes the core's op manifest (`writeOpManifest` /
// `isonimFrameManifest`) and builds its dispatch from it, instead of from a
// switch with the numbers typed out here. It refuses a manifest that does not
// name every operation this file can apply, or the read operations the core
// must never put in a frame, so a renumbered or renamed `BoundaryOp` is a
// loud failure rather than a document that quietly says something else.
//
// ## EVENTS
//
// `AddEventListener` carries a callback id. The listener installed here
// gathers the payload the core's handlers would otherwise have to read back —
// the target's value, the key, the wheel delta, the modifier keys — and calls
// `dispatch(id, type, value, key, deltaY, modifiers)`. The returned bits are
// the handler's `preventDefault` (1) and `stopPropagation` (2), applied to the
// real event here.
//
// ## HOST-SIDE DECORATION
//
// `node(handle)` returns the DOM node behind a handle, so code that must read
// layout (fitting cells, measuring overflow) runs in the host against the
// nodes this applier owns, with no crossing. If such code writes a property
// the core also writes, it must call the core's `isonimFrameForget(handle)`
// so the core's same-value elision does not skip the core's next write.

'use strict';

(function (root) {
  const MOD_SHIFT = 1, MOD_CTRL = 2, MOD_ALT = 4, MOD_META = 8;
  const FLAG_PREVENT_DEFAULT = 1, FLAG_STOP_PROPAGATION = 2;

  /** Operations that would have to answer BACK across the boundary. A frame
   *  that carries one is refused. */
  const READ_OPS = ['FirstChild', 'NextSibling', 'ParentNode', 'GetAttribute', 'InputValue'];

  function modifiersOf(ev) {
    return (ev.shiftKey ? MOD_SHIFT : 0) | (ev.ctrlKey ? MOD_CTRL : 0) |
           (ev.altKey ? MOD_ALT : 0) | (ev.metaKey ? MOD_META : 0);
  }

  /** The payload an event carries into the core. */
  function payloadOf(ev) {
    const t = ev.type;
    let value = '';
    if (t === 'paste') {
      // 'text/plain' first: Firefox does not alias 'text' to it on an event
      // a page constructed itself.
      const cd = ev.clipboardData;
      value = (cd && (cd.getData('text/plain') || cd.getData('text'))) || '';
    } else if (t === 'submit') {
      const field = ev.target && ev.target.querySelector &&
        ev.target.querySelector('input, textarea, select');
      value = field ? String(field.value) : '';
    } else if (ev.target && 'value' in ev.target && ev.target.value !== undefined) {
      value = String(ev.target.value);
    }
    return {
      value,
      key: typeof ev.key === 'string' ? ev.key : '',
      deltaY: typeof ev.deltaY === 'number' ? ev.deltaY : 0,
      modifiers: modifiersOf(ev),
    };
  }

  function makeCursor(bytes) {
    const dec = new TextDecoder('utf-8');
    const c = {
      at: 0,
      u32() {
        const b = bytes;
        const v = (b[c.at] | (b[c.at + 1] << 8) | (b[c.at + 2] << 16) | (b[c.at + 3] << 24)) >>> 0;
        c.at += 4;
        return v;
      },
      str() {
        const n = c.u32();
        const s = dec.decode(bytes.subarray(c.at, c.at + n));
        c.at += n;
        return s;
      },
    };
    return c;
  }

  /** Read an op manifest into `{ordinal: name}`. */
  function parseManifest(bytes) {
    const c = makeCursor(bytes);
    const byOrdinal = {};
    while (c.at < bytes.length) {
      const ord = bytes[c.at++];
      byOrdinal[ord] = c.str().replace(/^bo/, '');
    }
    return byOrdinal;
  }

  /**
   * Build an applier.
   *
   *   manifest   the core's op manifest frame (a Uint8Array)
   *   mount      the element handle 0 stands for
   *   dispatch   (id, type, value, key, deltaY, modifiers) => flag bits
   */
  function createFrameApplier({ manifest, mount, dispatch, document: doc }) {
    const d = doc || root.document;
    const nodes = [mount || null];
    const node = (h) => nodes[h];

    function listen(target, id, type) {
      target.addEventListener(type, (ev) => {
        const p = payloadOf(ev);
        const flags = dispatch(id, type, p.value, p.key, p.deltaY, p.modifiers) | 0;
        if (flags & FLAG_PREVENT_DEFAULT) ev.preventDefault();
        if (flags & FLAG_STOP_PROPAGATION) ev.stopPropagation();
      });
    }

    const APPLIERS = {
      CreateElement: (c) => { const h = c.u32(); nodes[h] = d.createElement(c.str()); },
      CreateTextNode: (c) => { const h = c.u32(); nodes[h] = d.createTextNode(c.str()); },
      AppendChild: (c) => { const p = c.u32(), ch = c.u32(); nodes[p].appendChild(nodes[ch]); },
      InsertBefore: (c) => {
        const p = c.u32(), ch = c.u32(), r = c.u32();
        nodes[p].insertBefore(nodes[ch], nodes[r] || null);
      },
      RemoveChild: (c) => {
        const p = c.u32(), ch = c.u32(); const n = nodes[ch];
        if (n && n.parentNode === nodes[p]) nodes[p].removeChild(n);
      },
      SetAttribute: (c) => { const h = c.u32(); const n = c.str(), v = c.str(); nodes[h].setAttribute(n, v); },
      RemoveAttribute: (c) => { const h = c.u32(); nodes[h].removeAttribute(c.str()); },
      SetTextContent: (c) => {
        const h = c.u32(); const t = c.str(); const n = nodes[h];
        if (n.nodeType === 3) n.data = t; else n.textContent = t;
      },
      SetStyle: (c) => { const h = c.u32(); const p = c.str(), v = c.str(); nodes[h].style.setProperty(p, v); },
      SetInnerHtml: (c) => { const h = c.u32(); nodes[h].innerHTML = c.str(); },
      AddEventListener: (c) => { const h = c.u32(), id = c.u32(); listen(nodes[h], id, c.str()); },
      ClearChildren: (c) => { nodes[c.u32()].textContent = ''; },
      // The DOM has no such call; the core re-creates listeners after a
      // clear, which is why `WebRenderer`'s implementation is a no-op too.
      ClearEventListeners: (c) => { c.u32(); },
      Focus: (c) => { nodes[c.u32()].focus(); },
      SetInputValue: (c) => { const h = c.u32(); nodes[h].value = c.str(); },
    };

    const opTable = parseManifest(manifest);
    const seen = new Set(Object.values(opTable));
    if (seen.size === 0) throw new Error('frame applier: the op manifest is empty');
    const missing = Object.keys(APPLIERS).filter((n) => !seen.has(n));
    if (missing.length) throw new Error('frame applier: the op manifest does not name: ' + missing.join(','));
    const missingReads = READ_OPS.filter((n) => !seen.has(n));
    if (missingReads.length) {
      throw new Error('frame applier: the op manifest does not name the read ops: ' + missingReads.join(','));
    }
    const table = [];
    for (const [ord, name] of Object.entries(opTable)) table[Number(ord)] = name;

    /** Apply one frame; returns the number of operations applied, for the
     *  caller to compare against the count the core wrote. */
    function apply(bytes) {
      const c = makeCursor(bytes);
      let applied = 0;
      while (c.at < bytes.length) {
        const code = bytes[c.at++];
        const name = table[code];
        if (name === undefined) throw new Error('frame applier: unknown opcode ' + code + ' at ' + (c.at - 1));
        const fn = APPLIERS[name];
        if (fn === undefined) {
          throw new Error('frame applier: the frame carries a read operation (' + name +
                          '); the boundary is write-only');
        }
        fn(c);
        applied += 1;
      }
      if (c.at !== bytes.length) throw new Error('frame applier: the frame did not consume exactly');
      return applied;
    }

    return { apply, node, nodes, opTable, appliers: APPLIERS };
  }

  /**
   * Bind an applier to an Emscripten module built with `frame_renderer`'s
   * exports (`_isonimFrameBase`, `_isonimFrameLen`, `_isonimFrameOps`,
   * `_isonimFrameManifest`, `_isonimFrameDispatch`, `_isonimFrameReset`) and
   * `HEAPU8` / `cwrap` among its runtime methods.
   *
   * `flush()` applies the frame the core has written since the last flush,
   * checks the applied count against the core's, and empties the frame.
   */
  function bindWasmCore(Module, mount, opts) {
    const call = (name, ret, args) => Module.cwrap(name, ret, args || []);
    const base = call('isonimFrameBase', 'number');
    const len = call('isonimFrameLen', 'number');
    const ops = call('isonimFrameOps', 'number');
    const reset = call('isonimFrameReset', null);
    const manifestFn = call('isonimFrameManifest', null);
    const dispatchRaw = call('isonimFrameDispatch', 'number',
      ['number', 'string', 'string', 'string', 'number', 'number']);
    const forget = call('isonimFrameForget', null, ['number']);
    // Re-read HEAPU8 every time: memory growth replaces the buffer, and a
    // cached view reads as an empty frame.
    const bytes = () => {
      const n = len();
      if (n === 0) return new Uint8Array(0);
      const b = base();
      return Module.HEAPU8.subarray(b, b + n);
    };
    manifestFn();
    const manifest = bytes().slice();
    reset();
    let applier = null;
    const flush = () => {
      const frame = bytes();
      const written = ops();
      const applied = frame.length ? applier.apply(frame) : 0;
      reset();
      if (applied !== written) {
        throw new Error('frame applier: applied ' + applied + ' of ' + written + ' operations');
      }
      return applied;
    };
    const dispatch = (id, type, value, key, deltaY, modifiers) => {
      const flags = dispatchRaw(id, type, value, key, deltaY, modifiers);
      if (opts && opts.afterDispatch) opts.afterDispatch();
      else flush();
      return flags;
    };
    applier = createFrameApplier({ manifest, mount, dispatch, document: opts && opts.document });
    return { applier, flush, node: applier.node, forget, bytes };
  }

  const api = { createFrameApplier, bindWasmCore, parseManifest, payloadOf, READ_OPS,
                MOD_SHIFT, MOD_CTRL, MOD_ALT, MOD_META,
                FLAG_PREVENT_DEFAULT, FLAG_STOP_PROPAGATION };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.IsonimFrameApplier = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
