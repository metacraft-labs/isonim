## Shared mount-owned top-layer geometry, live anchor tracking and focus cleanup.
## Browser placement measures the actual popup and visual viewport every frame
## while open, including ancestor scrolling, resize and zoom. DOM ownership is
## retained by the browser top layer, so renderer disposal and event bubbling
## remain intact. Native callers retain their renderer-neutral anchor state.
import isonim/core/owner

when defined(js):
  {.emit: staticRead("anchored_popover.js").}

proc installAnchoredPopover*[E](root: E; closeEvent: string) =
  when defined(js):
    let eventName = closeEvent.cstring
    {.emit: [root, ".__isonimPopover = globalThis.__isonimAnchoredPopover(", root, ", ", eventName, ");"].}
    onCleanup(proc() =
      {.emit: [root, ".__isonimPopover.dispose();"].})

proc syncAnchoredPopover*[E, S](root: E; state: S; open: bool;
                                x, y, w, h: float) =
  when defined(js):
    {.emit: [root, ".__isonimPopover.sync(", open, ", ", state, ".__isonimAnchor, ", x, ", ", y, ", ", w, ", ", h, ");"].}

proc installDetailsPopover*[E](details, trigger, popup: E) =
  ## Preserve native details/summary opening semantics and DOM ancestry while
  ## putting the actual overflow contents in the same measured browser top layer.
  when defined(js):
    installAnchoredPopover(popup, "isonim-details-close")
    {.emit: ["(function(details, trigger, popup) {\n",
      "if (!details || typeof details.addEventListener !== 'function') { popup.__isonimDetailsCleanup = function() {}; return; }\n",
      "function sync() { popup.__isonimPopover.sync(details.open, trigger, 0, 0, 0, 0); }\n",
      "function close() { details.open = false; sync(); }\n",
      "details.addEventListener('toggle', sync); popup.addEventListener('isonim-details-close', close);\n",
      "popup.__isonimDetailsCleanup = function() { details.removeEventListener('toggle', sync); popup.removeEventListener('isonim-details-close', close); };\n",
      "})(", details, ", ", trigger, ", ", popup, ");"].}
    onCleanup(proc() =
      {.emit: [popup, ".__isonimDetailsCleanup();"].})

proc installPopoverTrigger*[E](trigger: E) =
  ## Renderer callbacks have no keyboard event argument. Decode only activation
  ## keys here; Tab/arrows/Escape must never accidentally open a picker.
  when defined(js):
    {.emit: ["(function(trigger) {\n",
      "if (!trigger || typeof trigger.addEventListener !== 'function') { trigger.__isonimTriggerCleanup = function() {}; return; }\n",
      "function activate(e) { if(e.key !== 'Enter' && e.key !== ' ') return; e.preventDefault(); e.stopImmediatePropagation(); trigger.click(); }\n",
      "trigger.addEventListener('keydown', activate); trigger.__isonimTriggerCleanup = function() { trigger.removeEventListener('keydown', activate); };\n",
      "})(", trigger, ");"].}
    onCleanup(proc() =
      {.emit: [trigger, ".__isonimTriggerCleanup();"].})
