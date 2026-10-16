/* Shared, mount-owned inspector popover geometry and focus lifecycle.
 * Manual top-layer popovers retain DOM ownership/event bubbling, while avoiding
 * clipping and transformed ancestor coordinate systems. */
(function () {
  if (globalThis.__isonimAnchoredPopover) return;
  function geometry(a, size, viewport) {
    const {x: vx, y: vy, width: vw, height: vh} = viewport;
    const margin = Math.min(8, vw / 4, vh / 4), gap = 6;
    const width = Math.min(size.width, Math.max(0, vw - margin * 2));
    const height = Math.min(size.height, Math.max(0, vh - margin * 2));
    const below = vy + vh - margin - a.bottom - gap;
    const above = a.top - gap - vy - margin;
    const candidate = height <= below || below >= above ? a.bottom + gap : a.top - gap - height;
    return {left: Math.max(vx + margin, Math.min(a.left, vx + vw - margin - width)),
      top: Math.max(vy + margin, Math.min(candidate, vy + vh - margin - height)),
      width, height, maxWidth: Math.max(0, vw - margin * 2), maxHeight: Math.max(0, vh - margin * 2)};
  }
  globalThis.__isonimPopoverGeometry = geometry;
  const stack = [];
  globalThis.__isonimCloseInspectorPopovers = function (ownerRoot) {
    for (const root of stack.slice().reverse())
      if (!ownerRoot || ownerRoot.contains(root)) root.__isonimPopover.requestClose();
  };
  globalThis.__isonimAnchoredPopover = function (root, closeEvent) {
    // Renderer-neutral JS tests use MockNode, not a browser Element. Their
    // event/state behavior still runs; browser-only geometry requires a DOM.
    if (!root || root.nodeType !== 1 || typeof root.getBoundingClientRect !== 'function')
      return {sync() {}, requestClose() {}, dispose() {}};
    let anchor = null, returnTo = null, returnResolver = null, frame = 0, open = false, disposed = false;
    let fallback = {x: 0, y: 0, w: 0, h: 0};
    const naturalWidth = root.style.width;
    const naturalMaxHeight = parseFloat(root.style.maxHeight) || Infinity;
    root.setAttribute('popover', 'manual');
    function close() { root.dispatchEvent(new Event(closeEvent)); }
    function focusResolver(invoker) {
      // A successful edit can replace its reactive value slot. Keep the same
      // logical control within its actual section, never an unrelated global row.
      const pane = invoker && invoker.closest('[data-inspector-selection-context]');
      const context = pane && pane.getAttribute('data-inspector-selection-context');
      const section = invoker && invoker.closest('[data-inspector-section-body]');
      const row = invoker && invoker.closest('[data-property-row]');
      const fill = invoker && invoker.closest('[data-fill-row]');
      const marker = ['data-choice-group-trigger', 'data-property-row-swatch', 'data-fill-row-bind', 'data-variable-chip-chevron']
        .find(name => invoker && invoker.hasAttribute(name));
      const rowName = row && row.getAttribute('data-property-row');
      const fillIndex = fill && fill.getAttribute('data-fill-row');
      return function () {
        if (pane && (!pane.isConnected || pane.getAttribute('data-inspector-selection-context') !== context)) return null;
        if (invoker && invoker.isConnected) return invoker;
        if (!section || !section.isConnected || !marker) return null;
        if (rowName !== null && rowName !== undefined)
          return section.querySelector('[data-property-row="' + CSS.escape(rowName) + '"] [' + marker + ']');
        if (fillIndex !== null && fillIndex !== undefined) {
          const current = section.querySelector('[data-fill-row="' + CSS.escape(fillIndex) + '"]');
          return current && (current.querySelector('[' + marker + ']') || current.querySelector('[data-variable-chip-chevron]'));
        }
        return null;
      };
    }
    function place() {
      if (!open || disposed) return;
      if (anchor && !anchor.isConnected) { close(); return; }
      const viewport = window.visualViewport;
      const vx = viewport ? viewport.offsetLeft : 0;
      const vy = viewport ? viewport.offsetTop : 0;
      const vw = viewport ? viewport.width : document.documentElement.clientWidth;
      const vh = viewport ? viewport.height : document.documentElement.clientHeight;
      const margin = Math.min(8, vw / 4, vh / 4), gap = 6;
      const a = anchor ? anchor.getBoundingClientRect() :
        {left: fallback.x, top: fallback.y, right: fallback.x + fallback.w, bottom: fallback.y + fallback.h};
      root.style.position = 'fixed'; root.style.margin = '0';
      root.style.inset = 'auto'; root.style.boxSizing = 'border-box';
      root.style.width = naturalWidth || '320px';
      root.style.minWidth = '0';
      root.style.maxWidth = Math.max(0, vw - margin * 2) + 'px';
      root.style.maxHeight = Math.min(naturalMaxHeight, Math.max(0, vh - margin * 2)) + 'px';
      root.style.overflowY = 'auto'; root.style.overflowX = 'hidden';
      const box = root.getBoundingClientRect();
      const position = geometry(a, box, {x: vx, y: vy, width: vw, height: vh});
      root.style.left = position.left + 'px'; root.style.top = position.top + 'px';
      frame = requestAnimationFrame(place);
    }
    function controls() {
      return Array.from(root.querySelectorAll('input,button,[tabindex="0"],[role="option"]'))
        .filter(el => el.getClientRects().length && getComputedStyle(el).visibility !== 'hidden' && !el.matches(':disabled') && !el.hasAttribute('disabled') && !el.closest('[inert]') && !el.hasAttribute('readonly') && el.getAttribute('aria-disabled') !== 'true');
    }
    function focusControl(control) {
      control.focus({preventScroll: true});
      // Focus must be visible inside an oversized popup. Scroll only its own
      // content ancestors; preserve inspector, sidebar and document positions.
      for (let parent = control.parentElement; parent; parent = parent.parentElement) {
        if (parent.scrollHeight > parent.clientHeight && /auto|scroll/.test(getComputedStyle(parent).overflowY)) {
          const box = parent.getBoundingClientRect(), item = control.getBoundingClientRect();
          const scale = parent.offsetHeight ? box.height / parent.offsetHeight : 1;
          const top = box.top + parent.clientTop * scale, bottom = top + parent.clientHeight * scale;
          // Large controls (such as the color plane in a short viewport)
          // cannot fit wholly. Keep their central interactive point visible.
          if (item.height > bottom - top)
            parent.scrollTop += ((item.top + item.bottom) / 2 - (top + bottom) / 2) / scale;
          else if (item.top < top) parent.scrollTop -= (top - item.top) / scale;
          else if (item.bottom > bottom) parent.scrollTop += (item.bottom - bottom) / scale;
        }
        if (parent === root) break;
      }
    }
    function tearingDown() { return disposed || !!root.closest('[data-isonim-unmounting="true"]'); }
    function sync(value, target, x, y, w, h) {
      fallback = {x, y, w, h};
      if (value && !open) {
        anchor = target && target.isConnected ? target : document.activeElement;
        if (!anchor || anchor === document.body || root.contains(anchor)) anchor = null;
        returnTo = anchor; returnResolver = focusResolver(anchor);
        open = true; stack.push(root);
        if (root.showPopover) root.showPopover();
        place();
        const first = controls()[0];
        if (first) focusControl(first);
      } else if (!value && open) {
        open = false; const index = stack.indexOf(root);
        if (index >= 0) stack.splice(index, 1);
        cancelAnimationFrame(frame);
        if (root.hidePopover && root.matches(':popover-open')) root.hidePopover();
        const invoker = returnTo, resolve = returnResolver || focusResolver(invoker);
        const previousTop = stack[stack.length - 1] || null;
        const editorOwner = root.closest('[data-isonim-editor]');
        const restore = function () {
          if ((editorOwner && (!editorOwner.isConnected || editorOwner.getAttribute('data-isonim-unmounting') === 'true')) ||
              (stack[stack.length - 1] || null) !== previousTop) return;
          // Reactive edits dispose the old slot before its replacement mounts.
          // Disposal may restore only a different live semantic replacement,
          // never focus a retained/disposed control or an unmounted editor.
          if (disposed && (!editorOwner || root.isConnected || (invoker && invoker.isConnected))) return;
          if (document.activeElement !== document.body && document.activeElement !== invoker) return;
          const target = resolve();
          if (target && (!disposed || target !== invoker) && target.getClientRects().length) target.focus({preventScroll: true});
        };
        // Return immediately for Escape, then once more after a synchronous
        // accepted commit has replaced the original slot. Explicit new focus wins.
        if (!tearingDown()) {
          const target = resolve();
          if (target && target.getClientRects().length) target.focus({preventScroll: true});
        }
        if (!editorOwner || editorOwner.getAttribute('data-isonim-unmounting') !== 'true') queueMicrotask(restore);
        anchor = returnTo = returnResolver = null;
      }
    }
    function key(e) {
      if (!open || !root.matches(':popover-open')) return;
      // Only the uppermost popup dismisses; a nested colour editor must not
      // close the variable editor behind it.
      if (stack[stack.length - 1] !== root) return;
      if (e.key === 'Escape') { e.preventDefault(); e.stopImmediatePropagation(); close(); }
      else if (root.contains(e.target) && (e.key === 'Enter' || e.key === ' ') && e.target.getAttribute('role') === 'button') {
        e.preventDefault(); e.stopImmediatePropagation(); e.target.click();
      } else if (e.key === 'Tab') {
        const list = controls();
        if (!list.length) return;
        const index = list.indexOf(document.activeElement);
        e.preventDefault(); e.stopImmediatePropagation();
        const next = e.shiftKey ? (index <= 0 ? list.length - 1 : index - 1) : (index + 1) % list.length;
        focusControl(list[next]);
      }
    }
    function pointer(e) {
      if (!open || root.contains(e.target) || (anchor && anchor.contains(e.target))) return;
      if (stack[stack.length - 1] !== root) return;
      close();
    }
    document.addEventListener('keydown', key, true);
    document.addEventListener('pointerdown', pointer, true);
    return {sync, requestClose: close, dispose() {
      if (disposed) return;
      disposed = true; sync(false, null, 0, 0, 0, 0);
      document.removeEventListener('keydown', key, true);
      document.removeEventListener('pointerdown', pointer, true);
      cancelAnimationFrame(frame);
    }};
  };
})();
