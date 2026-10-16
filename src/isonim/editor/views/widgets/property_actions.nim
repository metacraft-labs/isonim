## Property actions menu — Copy property / Paste property / Reset / Detach.
##
## Editor spec "Universal Patterns": "Copy/Paste properties — right-click
## property → Copy, then paste onto another element" and "Reset to default —
## right-click → Reset"; "Property row pattern": "More (⫶): overflow for Copy
## property, Paste property, Reset, and Right-click -> Detach Variable".
##
## One menu serves both entry points of a property: the row's More (⫶)
## button and a right-click on the property itself (a property row, or a Fill
## entry, which has no More slot). The widget owns presentation and keyboard
## behaviour only. What "copy", "paste", "reset" and "detach" do is supplied
## by the caller, which is how a paste reaches the SAME commit path as typing
## into the target control: validation, source write-back, preview and undo
## are the row's, not the menu's.
##
## Placement, Escape, outside-click dismissal and focus return use the shared
## anchored popover (`anchored_popover`), like every other inspector popup.

import std/strutils

import isonim/core/signals
import isonim/core/computation
import isonim/core/owner
import isonim/core/batch
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/views/widgets/anchored_popover

export PropertyClipboardEntry

type
  PropertyActionsConfig* = object
    name*: string
      ## The property's display name, for the menu's accessible name.
    clipboard*: Signal[PropertyClipboardEntry]
      ## The editor's property clipboard. Nil disables Copy and Paste with a
      ## reason instead of pretending they work.
    copyValue*: proc(): string {.closure.}
      ## The property's current value as CSS text; empty when there is
      ## nothing to copy.
    copyProperty*: string
      ## The CSS property the value belongs to (recorded with the copy).
    paste*: proc(value: string) {.closure.}
      ## Commit `value` through the property's own commit path.
    unavailableReason*: proc(): string {.closure.}
      ## Non-empty when the property cannot be edited at all (read-only
      ## workspace, unmapped row). Paste is then disabled with this reason.
    resetReason*: proc(): string {.closure.}
      ## Non-empty while Reset cannot run: it is then shown disabled and says
      ## why. Read each time the menu opens, because whether the removal
      ## Reset commits can be written depends on the selection, the scope and
      ## the file. Nil disables Reset with `propertyResetUnavailableReason`.
    reset*: proc() {.closure.}
      ## Reset to default: commit an empty value through the property's own
      ## commit path, which plans it as removing the declaration that sets
      ## the property (validated, written and undoable like any edit).
    detach*: proc() {.closure.}
      ## Non-nil, together with `isBound`, adds "Detach variable".
    isBound*: proc(): bool {.closure.}

  PropertyActionsMenu*[E] = object
    root*: E
    state*: PropertyActionsState
    open*: proc() {.closure.}
    close*: proc() {.closure.}

  PropertyActionsState* = ref object
    isOpen*: Signal[bool]
    message*: Signal[string]

const
  propertyResetUnavailableReason* =
    "Reset returns the property to its token, class or inherited value. " &
    "This property is not connected to a source writer, so Reset is unavailable."
  menuBg = "#16171F"
  menuBorder = "#2D2D3A"
  itemColor = "#F1F5F9"
  itemDisabledColor = "#6B6F80"
  copyNothingReason = "This property has no value to copy."
  pasteEmptyReason = "Copy a property first."

proc isEditableEventTarget*[T](ev: T): bool =
  ## Whether a (context-menu) event comes from a field the user types in.
  ## Right-click there keeps the browser's own Cut / Copy / Paste menu for
  ## the text: the property menu opens only outside editable fields.
  when compiles(ev.target.tag):
    # The test renderer's event (MockEvent), natively and under Node.
    ev.target != nil and ev.target.tag in ["input", "textarea", "select"]
  elif defined(js):
    var editable: bool
    {.emit: [editable, " = !!(", ev, " && ", ev, ".target && typeof ", ev,
      ".target.closest === 'function' && ", ev,
      ".target.closest('input, textarea, select, [contenteditable]:not([contenteditable=\"false\"])'));"].}
    editable
  else:
    false

proc mountPropertyActionsMenu*[R, E](r: R; parent, anchor: E;
    cfg: PropertyActionsConfig): PropertyActionsMenu[E] =
  ## Mount the (closed) menu under `parent`, anchored to `anchor` when open.
  let state = PropertyActionsState(isOpen: createSignal(false),
    message: createSignal(""))
  var rootNode, copyNode, pasteNode, resetNode, detachNode, messageNode: E
  let root = ui(r):
    tdiv(ref = rootNode, role = "menu",
         `data-property-actions-menu` = "true",
         `aria-label` = "Actions for " & cfg.name,
         display = "none", flex_direction = "column",
         width = "200px", padding = "4px", gap = "2px",
         background_color = menuBg, color = itemColor,
         border = "1px solid " & menuBorder, border_radius = "6px",
         box_shadow = "0 8px 24px rgba(0,0,0,0.28)", z_index = "1300"):
      tdiv(ref = copyNode, role = "menuitem", tabindex = "0",
           `data-property-action` = "copy",
           padding = "6px 8px", border_radius = "4px", font_size = "12px",
           cursor = "pointer"):
        text "Copy property"
      tdiv(ref = pasteNode, role = "menuitem", tabindex = "0",
           `data-property-action` = "paste",
           padding = "6px 8px", border_radius = "4px", font_size = "12px",
           cursor = "pointer"):
        text "Paste property"
      tdiv(ref = resetNode, role = "menuitem", tabindex = "0",
           `data-property-action` = "reset",
           padding = "6px 8px", border_radius = "4px", font_size = "12px",
           cursor = "pointer"):
        text "Reset"
      tdiv(ref = detachNode, role = "menuitem", tabindex = "0",
           `data-property-action` = "detach",
           padding = "6px 8px", border_radius = "4px", font_size = "12px",
           cursor = "pointer"):
        text "Detach variable"
      tdiv(ref = messageNode, role = "status",
           `data-property-actions-message` = "true",
           padding = "2px 8px", font_size = "10px", line_height = "1.35",
           color = "#FBBF24")

  var alive = true
  onCleanup(proc() = alive = false)

  proc copyReason(): string =
    if cfg.clipboard == nil or cfg.copyValue == nil:
      return "Copy is not available for this property."
    if cfg.copyValue().strip().len == 0: return copyNothingReason
    ""

  proc pasteReason(): string =
    if cfg.clipboard == nil or cfg.paste == nil:
      return "Paste is not available for this property."
    if cfg.unavailableReason != nil:
      let reason = cfg.unavailableReason()
      if reason.len > 0: return reason
    if cfg.clipboard.val.value.len == 0: return pasteEmptyReason
    ""

  proc resetReason(): string =
    if cfg.reset == nil or cfg.resetReason == nil:
      return propertyResetUnavailableReason
    cfg.resetReason()

  proc bound(): bool =
    cfg.detach != nil and cfg.isBound != nil and cfg.isBound()

  proc setItemState(node: E; reason: string) =
    r.setAttribute(node, "aria-disabled", if reason.len > 0: "true" else: "false")
    r.setAttribute(node, "title", reason)
    r.setStyle(node, "color", if reason.len > 0: itemDisabledColor else: itemColor)
    r.setStyle(node, "cursor", if reason.len > 0: "default" else: "pointer")

  # Installed before the effect below first syncs it.
  installAnchoredPopover(rootNode, "isonim-property-actions-close")
  createRenderEffect proc() =
    let open = state.isOpen.val
    r.setStyle(rootNode, "display", if open: "flex" else: "none")
    r.setAttribute(rootNode, "data-property-actions-open",
      if open: "true" else: "false")
    if open:
      # Re-evaluated on every opening (and while open) so a copy made in
      # another row enables this row's Paste.
      setItemState(copyNode, copyReason())
      setItemState(pasteNode, pasteReason())
      setItemState(resetNode, untrack(resetReason))
      r.setStyle(detachNode, "display", if bound(): "block" else: "none")
      setItemState(detachNode, "")
    r.setTextContent(messageNode, state.message.val)
    r.setStyle(messageNode, "display",
      if state.message.val.len > 0: "block" else: "none")
    untrack(proc() = syncAnchoredPopover(rootNode, state, open, 0, 0, 0, 0))

  proc close() =
    state.isOpen.val = false

  proc open() =
    if not alive: return
    when defined(js):
      {.emit: [state, ".__isonimAnchor = ", anchor, ";"].}
    batch(proc() =
      state.message.val = ""
      state.isOpen.val = true)

  proc activate(action: string) =
    if not alive or not state.isOpen.val: return
    case action
    of "copy":
      let reason = copyReason()
      if reason.len > 0:
        state.message.val = reason
        return
      cfg.clipboard.val = PropertyClipboardEntry(property: cfg.copyProperty,
        value: cfg.copyValue().strip())
      close()
    of "paste":
      let reason = pasteReason()
      if reason.len > 0:
        state.message.val = reason
        return
      let value = cfg.clipboard.val.value
      # Close first: the commit can rebuild the row (and with it this menu),
      # and a refusal is reported by the row's own message line.
      close()
      cfg.paste(value)
    of "reset":
      let reason = resetReason()
      if reason.len > 0:
        state.message.val = reason
        return
      # Close first, as for Paste: the commit can rebuild the row.
      close()
      cfg.reset()
    of "detach":
      if bound():
        close()
        cfg.detach()
    else: discard

  # A helper rather than a loop body: closures created in a Nim loop share
  # the loop's variables, so every item would act as the last one.
  proc bindItem(node: E; action: string) =
    r.addEventListener(node, "click", proc() = activate(action))
  bindItem(copyNode, "copy")
  bindItem(pasteNode, "paste")
  bindItem(resetNode, "reset")
  bindItem(detachNode, "detach")
  r.addEventListener(rootNode, "isonim-property-actions-close", proc() = close())
  when defined(js):
    # Menu keyboard: Enter / Space activate the focused item (the shared
    # popover only does that for role=button), arrows move between items.
    {.emit: ["""
      (function (menu) {
        if (!menu || typeof menu.addEventListener !== 'function') return;
        menu.addEventListener('keydown', function (e) {
          var items = Array.prototype.slice.call(menu.querySelectorAll('[role="menuitem"]'))
            .filter(function (el) { return el.getClientRects().length; });
          var index = items.indexOf(document.activeElement);
          if (e.key === 'Enter' || e.key === ' ') {
            if (index >= 0) { e.preventDefault(); e.stopPropagation(); items[index].click(); }
          } else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
            if (!items.length) return;
            e.preventDefault(); e.stopPropagation();
            var next = e.key === 'ArrowDown' ? (index + 1) % items.length
              : (index <= 0 ? items.length - 1 : index - 1);
            items[next].focus({ preventScroll: true });
          }
        });
      })(""", rootNode, """);
    """].}
  onCleanup(proc() = state.isOpen.val = false)
  r.appendChild(parent, root)
  PropertyActionsMenu[E](root: root, state: state, open: open, close: close)
