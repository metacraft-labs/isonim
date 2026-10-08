## Functional colour popup shared by literal inspector values and token drafts.
## Values are validated before the caller's existing edit/commit path runs.
## Pointer plane/hue/alpha and typed channels edit the same cancelable draft.
## Only Apply invokes the caller's guarded source commit boundary.
import std/[strutils, math]
import isonim/core/[signals, computation, owner, batch]
import isonim/dsl/ui
import isonim/editor/css_color_literal
import isonim/editor/views/widgets/anchored_popover

type ColorPopoverState* = ref object
  open*: Signal[bool]
  draft*: Signal[string]
  diagnostic*: Signal[string]
  pending*: Signal[bool]

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

type ColorChannels* = object
  red*, green*, blue*, alpha*: int

func normalizedSourceColor*(raw: string): string =
  ## Picker drafts use hex channels; authored rgb/rgba literals keep their
  ## source spelling until the user actually applies an edit.
  let channels = literalColorChannels(raw)
  if not channels.valid: return ""
  result = "#" & toHex(channels.red,2) & toHex(channels.green,2) & toHex(channels.blue,2)
  if channels.alpha != 255: result.add toHex(channels.alpha,2)

func colorChannels*(raw: string): ColorChannels =
  let normalized = normalizedSourceColor(raw)
  result.alpha = 255
  if normalized.len == 0: return
  result.red = parseHexInt(normalized[1..2])
  result.green = parseHexInt(normalized[3..4])
  result.blue = parseHexInt(normalized[5..6])
  if normalized.len == 9: result.alpha = parseHexInt(normalized[7..8])

func channelsHex*(channels: ColorChannels): string =
  result = "#" & toHex(clamp(channels.red, 0, 255), 2) &
    toHex(clamp(channels.green, 0, 255), 2) & toHex(clamp(channels.blue, 0, 255), 2)
  if channels.alpha != 255: result.add toHex(clamp(channels.alpha, 0, 255), 2)

func colorHsv*(channels: ColorChannels): tuple[hue, saturation, value: float] =
  let red = channels.red.float / 255
  let green = channels.green.float / 255
  let blue = channels.blue.float / 255
  let greatest = max(red, max(green, blue))
  let least = min(red, min(green, blue))
  let delta = greatest - least
  result.value = greatest
  result.saturation = if greatest == 0: 0.0 else: delta / greatest
  if delta == 0: return
  if greatest == red: result.hue = 60 * ((green-blue) / delta)
  elif greatest == green: result.hue = 60 * (2 + (blue-red) / delta)
  else: result.hue = 60 * (4 + (red-green) / delta)
  if result.hue < 0: result.hue += 360

func hsvChannels*(hue, saturation, value: float; alpha = 255): ColorChannels =
  let h = clamp(hue, 0, 359.999) / 60
  let chroma = clamp(value, 0, 1) * clamp(saturation, 0, 1)
  let x = chroma * (1 - abs(h - floor(h / 2) * 2 - 1))
  let m = clamp(value, 0, 1) - chroma
  var red, green, blue: float
  case int(floor(h))
  of 0: red = chroma; green = x
  of 1: red = x; green = chroma
  of 2: green = chroma; blue = x
  of 3: green = x; blue = chroma
  of 4: red = x; blue = chroma
  else: red = chroma; blue = x
  result = ColorChannels(red: int(round((red+m)*255)), green: int(round((green+m)*255)),
    blue: int(round((blue+m)*255)), alpha: alpha)

proc createColorPopoverState*(): ColorPopoverState =
  ColorPopoverState(open: createSignal(false), draft: createSignal(""),
    diagnostic: createSignal(""), pending: createSignal(false))

proc mountColorPopover*[R, E](r: R; parent, invoker: E;
    state: ColorPopoverState; current: proc(): string;
    commit: proc(value: string): bool): E =
  var rootNode, inputNode, errorNode, previewNode, applyNode, cancelNode: E
  var planeNode, hueNode, alphaNode, channelHost: E
  var channelInputs: array[4, E]
  let hue = createSignal(0.0)
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
      tdiv(ref = planeNode, `data-color-plane` = "true", tabindex = "0",
           role = "slider", `aria-label` = "Color saturation and brightness",
           height = "130px", min_height = "130px", flex_shrink = "0",
           border_radius = "4px", cursor = "crosshair",
           touch_action = "none")
      input(ref = hueNode, `type` = "range", min = "0", max = "359", step = "1",
            `data-color-hue` = "true", `aria-label` = "Hue", width = "100%")
      input(ref = alphaNode, `type` = "range", min = "0", max = "100", step = "1",
            `data-color-alpha` = "true", `aria-label` = "Opacity", width = "100%")
      tdiv(ref = channelHost, display = "flex", gap = "4px", `data-color-channels` = "true")
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
  proc updateChannel(index: int; node: E) =
    if not state.open.val or state.pending.val: return
    let raw = r.inputValue(node).strip()
    try:
      let number = parseInt(raw)
      if $number != raw or number < 0 or number > (if index == 3: 100 else: 255):
        raise newException(ValueError, "Channel outside range")
      var channels = colorChannels(state.draft.val)
      case index
      of 0: channels.red = number
      of 1: channels.green = number
      of 2: channels.blue = number
      else: channels.alpha = int(round(number.float * 255 / 100))
      state.draft.val = channelsHex(channels)
      state.diagnostic.val = ""
    except ValueError:
      state.diagnostic.val = if index == 3: "Opacity must be from 0 to 100%."
        else: "RGB channels must be whole numbers from 0 to 255."
  proc addChannel(index: int; label: string) =
    var node: E
    let control = ui(r):
      tdiv(display = "flex", flex_direction = "column", width = "25%", gap = "3px"):
        span(font_size = "10px"): text label
        input(ref = node, `data-color-channel` = label, `aria-label` = label,
          width = "100%", padding = "4px", background_color = "#0F0F18",
          color = "#F1F5F9", border = "1px solid #2F3140", border_radius = "3px")
    channelInputs[index] = node
    r.appendChild(channelHost, control)
    r.addEventListener(node, "change", proc() = updateChannel(index, node))
  for index, label in ["Red", "Green", "Blue", "Alpha %"]: addChannel(index, label)
  proc setHsv(saturation, brightness: float) =
    if state.open.val and not state.pending.val:
      state.draft.val = channelsHex(hsvChannels(hue.val, saturation, brightness,
        colorChannels(state.draft.val).alpha))
      state.diagnostic.val = ""
  r.addEventListener(hueNode, "input", proc() =
    if not state.open.val or state.pending.val: return
    try:
      let nextHue = parseFloat(r.inputValue(hueNode))
      if classify(nextHue) in {fcNan, fcInf, fcNegInf} or nextHue < 0 or nextHue > 359: return
      let hsv = colorHsv(colorChannels(state.draft.val))
      batch(proc() =
        hue.val = nextHue
        setHsv(hsv.saturation, hsv.value))
    except ValueError: discard)
  r.addEventListener(alphaNode, "input", proc() = updateChannel(3, alphaNode))
  when defined(js):
    let planeChange = proc(saturation, brightness: float) = setHsv(saturation, brightness)
    let planeCancel = proc(original: cstring) = state.draft.val = $original
    let currentDraft = proc(): cstring = cstring(state.draft.val)
    var removePointerListeners: proc() {.closure.}
    {.emit: ["if (typeof ", planeNode, ".addEventListener === 'function') {\n",
      "const plane = ", planeNode, "; let active = null, before = '';\n",
      "function move(e) { if(active !== e.pointerId) return; const b=plane.getBoundingClientRect(); ",
      planeChange, "(Math.max(0,Math.min(1,(e.clientX-b.left)/b.width)), Math.max(0,Math.min(1,1-(e.clientY-b.top)/b.height))); }\n",
      "function down(e) { if(e.button!==0) return; e.preventDefault(); active=e.pointerId; before=", currentDraft, "(); plane.setPointerCapture(active); move(e); }\n",
      "function finish(e) { if(active!==e.pointerId) return; move(e); const id=active; active=null; if(plane.hasPointerCapture(id)) plane.releasePointerCapture(id); }\n",
      "function cancel() { if(active===null) return; const id=active; active=null; ", planeCancel, "(before); if(plane.hasPointerCapture(id)) plane.releasePointerCapture(id); }\n",
      "function key(e) { if(e.key==='Escape') cancel(); }\n",
      "plane.addEventListener('pointerdown',down); plane.addEventListener('pointermove',move); plane.addEventListener('pointerup',finish); plane.addEventListener('pointercancel',cancel); plane.addEventListener('lostpointercapture',cancel); window.addEventListener('blur',cancel); window.addEventListener('keydown',key);\n",
      removePointerListeners, "=function() { cancel(); plane.removeEventListener('pointerdown',down); plane.removeEventListener('pointermove',move); plane.removeEventListener('pointerup',finish); plane.removeEventListener('pointercancel',cancel); plane.removeEventListener('lostpointercapture',cancel); window.removeEventListener('blur',cancel); window.removeEventListener('keydown',key); }; }"].}
    onCleanup(proc() =
      if removePointerListeners != nil: removePointerListeners())
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
    if not state.open.val or state.pending.val: return
    when defined(js):
      var connected = false
      {.emit: [connected, " = ", rootNode, ".isConnected !== false;"].}
      if not connected:
        state.open.val = false
        return
    let value = normalizedHexColor(state.draft.val)
    if value.len == 0:
      state.diagnostic.val = "Enter a valid hex color (#RGB, #RGBA, #RRGGBB or #RRGGBBAA)."
    else:
      state.diagnostic.val = ""
      if commit(value): state.open.val = false
      elif not state.pending.val and state.diagnostic.val.len == 0:
        state.diagnostic.val = "The color edit was refused."
  r.addEventListener(applyNode, "click", apply)
  r.addEventListener(inputNode, "input", proc() =
    state.draft.val = r.inputValue(inputNode)
    state.diagnostic.val = "")
  r.addEventListener(invoker, "click", proc() =
    state.draft.val = normalizedSourceColor(current())
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
    let open = state.open.val
    # Native focus/blur dispatch is imperative and can read editor state.
    # Keep those handlers from becoming dependencies of this display effect.
    untrack(proc() = syncAnchoredPopover(rootNode, state, open, 0, 0, 0, 0))
  createRenderEffect proc() =
    r.setInputValue(inputNode, state.draft.val)
    let channels = colorChannels(state.draft.val)
    let hsv = colorHsv(channels)
    if hsv.saturation > 0 and abs(hue.val-hsv.hue) > 0.5: hue.val = hsv.hue
    r.setInputValue(hueNode, $int(round(hue.val)))
    let opacity = int(round(channels.alpha.float * 100 / 255))
    r.setInputValue(alphaNode, $opacity)
    for index, number in [channels.red, channels.green, channels.blue, opacity]:
      r.setInputValue(channelInputs[index], $number)
    r.setStyle(planeNode, "background", "linear-gradient(to top, #000, transparent), linear-gradient(to right, #fff, transparent), " & channelsHex(hsvChannels(hue.val, 1, 1)))
    r.setAttribute(planeNode, "aria-valuetext", "Saturation " & $int(round(hsv.saturation*100)) & "%, brightness " & $int(round(hsv.value*100)) & "%")
    r.setStyle(previewNode, "background-color", normalizedHexColor(state.draft.val))
    r.setTextContent(errorNode, if state.pending.val: "Saving source…" else: state.diagnostic.val)
    r.setAttribute(applyNode, "aria-disabled", if state.pending.val: "true" else: "false")
  r.appendChild(parent, root)
  root
