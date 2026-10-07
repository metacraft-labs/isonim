## Functional colour popup shared by literal inspector values and token drafts.
## Values are validated before the caller's existing edit/commit path runs.
## This first control supports hex entry and pointer-selectable palette colours;
## the complete plane/channel gesture controls belong to property interaction
## parity. No browser-owned native colour window is needed to use this editor.
import std/strutils
import isonim/core/[signals, computation, owner]
import isonim/dsl/ui
import isonim/editor/views/widgets/anchored_popover

type ColorPopoverState* = ref object
  open*: Signal[bool]
  draft*: Signal[string]
  diagnostic*: Signal[string]

func normalizedHexColor*(raw: string): string =
  let value = raw.strip()
  if value.len notin [4, 5, 7, 9] or value[0] != '#': return ""
  for ch in value[1 .. ^1]:
    if ch notin {'0'..'9', 'a'..'f', 'A'..'F'}: return ""
  result = "#"
  if value.len in [4, 5]:
    for ch in value[1 .. ^1]: result.add ch; result.add ch
  else: result.add value[1 .. ^1]
  result = result.toUpperAscii()

proc createColorPopoverState*(): ColorPopoverState =
  ColorPopoverState(open: createSignal(false), draft: createSignal(""),
    diagnostic: createSignal(""))

proc mountColorPopover*[R, E](r: R; parent, invoker: E;
    state: ColorPopoverState; current: proc(): string;
    commit: proc(value: string): bool): E =
  var rootNode, inputNode, errorNode, previewNode, applyNode, cancelNode: E
  let root = ui(r):
    tdiv(ref = rootNode, `data-color-popover` = "true", role = "dialog",
         `aria-label` = "Edit color", display = "none", width = "280px",
         padding = "12px", gap = "10px", flex_direction = "column",
         background_color = "#16171F", color = "#F1F5F9",
         border = "1px solid #2D2D3A", border_radius = "8px", z_index = "1300"):
      span(font_size = "12px", font_weight = "600"):
        text "Color"
      tdiv(ref = previewNode, `data-color-popover-preview` = "true",
           min_height = "36px", border_radius = "4px")
      input(ref = inputNode, `data-color-popover-input` = "true",
            `aria-label` = "Hex color", padding = "8px",
            background_color = "#0F0F18", color = "#F1F5F9",
            border = "1px solid #2F3140", border_radius = "4px")
      tdiv(ref = errorNode, role = "alert", `data-color-popover-error` = "true",
           color = "#F87171", font_size = "11px")
      tdiv(display = "flex", gap = "8px", justify_content = "flex-end"):
        tdiv(ref = cancelNode, role = "button", tabindex = "0",
             `data-color-popover-cancel` = "true", padding = "6px 12px",
             border = "1px solid #2F3140", border_radius = "4px", cursor = "pointer"):
          text "Cancel"
        tdiv(ref = applyNode, role = "button", tabindex = "0",
             `data-color-popover-apply` = "true", padding = "6px 12px",
             background_color = "#7C7AED", border_radius = "4px", cursor = "pointer"):
          text "Apply"
  var paletteHost: E
  let palette = ui(r):
    tdiv(ref = paletteHost, `data-color-popover-palette` = "true",
         display = "flex", flex_wrap = "wrap", gap = "8px")
  r.appendChild(rootNode, palette)
  proc addSwatch(color: string) =
    var swatch: E
    let tile = ui(r):
      tdiv(ref = swatch, role = "button", tabindex = "0",
           `data-color-popover-swatch` = color, `aria-label` = "Use " & color,
           width = "22px", height = "22px", flex_shrink = "0",
           border = "1px solid #A0A2B0", border_radius = "4px",
           cursor = "pointer", background_color = color)
    r.appendChild(paletteHost, tile)
    r.addEventListener(swatch, "click", proc() = state.draft.val = color)
  for color in ["#FFFFFF", "#000000", "#EF4444", "#F59E0B", "#22C55E", "#3B82F6", "#7C7AED", "#EC4899"]:
    addSwatch(color)
  installAnchoredPopover(rootNode, "isonim-color-close")
  r.addEventListener(rootNode, "isonim-color-close", proc() = state.open.val = false)
  r.addEventListener(cancelNode, "click", proc() = state.open.val = false)
  onCleanup(proc() = state.open.val = false)
  let apply = proc() =
    if not state.open.val: return
    when defined(js):
      var connected = false
      {.emit: [connected, " = ", rootNode, ".isConnected !== false;"].}
      if not connected:
        state.open.val = false
        return
    let value = normalizedHexColor(state.draft.val)
    if value.len == 0:
      state.diagnostic.val = "Enter a valid hex color (#RGB, #RGBA, #RRGGBB or #RRGGBBAA)."
    elif commit(value): state.open.val = false
    else: state.diagnostic.val = "The color edit was refused."
  r.addEventListener(applyNode, "click", apply)
  r.addEventListener(inputNode, "input", proc() =
    state.draft.val = r.inputValue(inputNode)
    state.diagnostic.val = "")
  r.addEventListener(invoker, "click", proc() =
    state.draft.val = current()
    state.diagnostic.val = ""
    when defined(js):
      {.emit: [state, ".__isonimAnchor = ", invoker, ";"].}
    state.open.val = true)
  installPopoverTrigger(invoker)
  when defined(js):
    {.emit: ["if (typeof ", inputNode, ".addEventListener === 'function') ", inputNode, ".addEventListener('keydown', function(e) { if(e.key === 'Enter') { e.preventDefault(); ", applyNode, ".click(); } });"].}
  createRenderEffect proc() =
    r.setStyle(rootNode, "display", if state.open.val: "flex" else: "none")
    r.setAttribute(rootNode, "data-color-popover-open", if state.open.val: "true" else: "false")
    syncAnchoredPopover(rootNode, state, state.open.val, 0, 0, 0, 0)
  createRenderEffect proc() =
    r.setInputValue(inputNode, state.draft.val)
    r.setStyle(previewNode, "background-color", normalizedHexColor(state.draft.val))
    r.setTextContent(errorNode, state.diagnostic.val)
  r.appendChild(parent, root)
  root
