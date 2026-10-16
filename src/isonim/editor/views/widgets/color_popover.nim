## Functional colour popup shared by literal inspector values and token drafts.
## Values are validated before the caller's existing edit/commit path runs.
## Pointer plane/hue/alpha, swatches and the typed hex / RGB / HSL fields edit
## the same cancelable draft. The draft reaches the caller's guarded commit
## boundary only through Apply or Enter in a typed field (editor spec "Color
## Picker": "Hex / RGB / HSL input -- text fields for precise values";
## "Planned interaction parity": one validation/write-back/preview/undo path).
## Enter in the hex field applies and closes, like Apply. Enter in an RGB
## channel or the HSL field commits and keeps the picker open, so the next
## channel can be typed; Tab or blur leave a typed value as a draft.
import std/[strutils, math]
import isonim/core/[signals, computation, owner, batch]
import isonim/dsl/ui
import isonim/editor/css_color_literal
import isonim/editor/views/widgets/anchored_popover

when defined(js):
  import std/dom
  import isonim/web/dom_api

  proc readPickerKey[E: dom.Event | dom_api.Event](ev: E): cstring
    {.importjs: "(#.key || '')".}

  proc pickerKey(ev: dom.Event | dom_api.Event): string =
    # A plain Event has no key; normalize it before Nim string conversion.
    $readPickerKey(ev)

proc pickerKey[E](ev: E): string =
  ev.key

type ColorDraftSnapshot* = object
  draft*: string
  hue*, saturation*, brightness*: float

type ColorPopoverState* = ref object
  open*: Signal[bool]
  draft*: Signal[string]
  diagnostic*: Signal[string]
  pending*: Signal[bool]
  hue*, saturation*, brightness*: Signal[float]
  projectedDraft: string
  commitCloses*: bool
    ## Set by the popup immediately before it calls the caller's commit:
    ## true for Apply / Enter in the hex field, false for Enter in a channel
    ## or the HSL field. A caller that completes asynchronously reads it when
    ## the commit starts to decide whether success closes the picker.
  cancelPoint: ColorDraftSnapshot
    ## What Cancel / Escape / an outside click restore: the draft the picker
    ## opened with, moved to each committed colour while it stays open.
  transparentOrigin: bool
    ## The picker opened on a fully transparent colour and the user has not
    ## chosen an opacity since. Only then does a typed RGB channel make the
    ## draft opaque; a deliberate Alpha of 0% is kept.

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

func colorHslText*(channels: ColorChannels): string =
  ## The draft as a CSS `hsl()` literal, rounded to whole units for display,
  ## with the alpha only when it is not opaque.
  let red = channels.red.float / 255
  let green = channels.green.float / 255
  let blue = channels.blue.float / 255
  let greatest = max(red, max(green, blue))
  let least = min(red, min(green, blue))
  let lightness = (greatest + least) / 2
  let delta = greatest - least
  var hue, saturation = 0.0
  if delta > 0:
    saturation = delta / (1 - abs(2 * lightness - 1))
    if greatest == red: hue = 60 * ((green - blue) / delta)
    elif greatest == green: hue = 60 * (2 + (blue - red) / delta)
    else: hue = 60 * (4 + (red - green) / delta)
    if hue < 0: hue += 360
  result = "hsl(" & $(int(round(hue)) mod 360) & " " &
    $int(round(saturation * 100)) & "% " & $int(round(lightness * 100)) & "%"
  if channels.alpha != 255:
    result.add " / " & $int(round(channels.alpha.float * 100 / 255)) & "%"
  result.add ")"

func hslDraftColor*(raw: string): string =
  ## A typed HSL value as a picker draft (`#RRGGBB[AA]`), or "" when it is not
  ## a complete HSL color. Accepts the CSS forms `hsl()` / `hsla()` with comma
  ## or space notation, and the bare channel list (`217 91% 60%`).
  let text = raw.strip()
  if text.len == 0: return ""
  let lower = text.toLowerAscii()
  let literal =
    if lower.startsWith("hsl"): text
    else: "hsl(" & text & ")"
  normalizedSourceColor(literal)

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
    diagnostic: createSignal(""), pending: createSignal(false),
    hue: createSignal(0.0), saturation: createSignal(0.0), brightness: createSignal(0.0),
    commitCloses: true)

proc captureColorDraft*(state: ColorPopoverState): ColorDraftSnapshot =
  ColorDraftSnapshot(draft: state.draft.val, hue: state.hue.val,
    saturation: state.saturation.val, brightness: state.brightness.val)

proc restoreColorDraft*(state: ColorPopoverState; snapshot: ColorDraftSnapshot) =
  batch(proc() =
    state.projectedDraft = snapshot.draft
    state.hue.val = snapshot.hue
    state.saturation.val = snapshot.saturation
    state.brightness.val = snapshot.brightness
    state.draft.val = snapshot.draft)

proc markColorDraftCommitted*(state: ColorPopoverState) =
  ## The draft was committed and the picker stays open: Cancel / Escape now
  ## return to it, not to the colour the picker opened with. Called by the
  ## popup for a synchronous commit, and by a caller whose commit completed
  ## asynchronously (edits are blocked while one is pending, so the draft is
  ## still the committed colour).
  if state.open.val:
    state.cancelPoint = state.captureColorDraft()

proc setColorHsv*(state: ColorPopoverState; hue, saturation, brightness: float; alpha: int) =
  ## Coordinates retain user intent through black/grey and RGB quantization.
  for coordinate in [hue, saturation, brightness]:
    if classify(coordinate) in {fcNan, fcInf, fcNegInf}: return
  batch(proc() =
    state.hue.val = clamp(hue, 0, 359)
    state.saturation.val = clamp(saturation, 0, 1)
    state.brightness.val = clamp(brightness, 0, 1)
    let value = channelsHex(hsvChannels(state.hue.val, state.saturation.val,
      state.brightness.val, alpha))
    state.projectedDraft = value
    state.draft.val = value)

proc syncColorCoordinates*(state: ColorPopoverState) =
  let raw = state.draft.val
  if raw == state.projectedDraft: return
  state.projectedDraft = raw
  if normalizedSourceColor(raw).len == 0: return
  let hsv = colorHsv(colorChannels(raw))
  batch(proc() =
    if hsv.saturation > 0: state.hue.val = hsv.hue
    state.saturation.val = hsv.saturation
    state.brightness.val = hsv.value)

proc adjustColorPlane*(state: ColorPopoverState; key: string): bool =
  if not state.open.val or state.pending.val: return false
  var saturation = state.saturation.val
  var brightness = state.brightness.val
  case key
  of "ArrowLeft": saturation -= 0.01
  of "ArrowRight": saturation += 0.01
  of "ArrowUp": brightness += 0.01
  of "ArrowDown": brightness -= 0.01
  else: return false
  state.setColorHsv(state.hue.val, saturation, brightness, colorChannels(state.draft.val).alpha)
  state.diagnostic.val = ""
  true

proc mountColorPopover*[R, E](r: R; parent, invoker: E;
    state: ColorPopoverState; current: proc(): string;
    commit: proc(value: string): bool): E =
  var rootNode, inputNode, errorNode, previewNode, applyNode, cancelNode: E
  var planeNode, markerNode, hueNode, alphaNode, channelHost, hslNode: E
  var channelInputs: array[4, E]
  let hue = state.hue
  var canceledRangeInput = false
  var mountedActive = true
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
           `aria-description` = "Left and right adjust saturation; up and down adjust brightness by one percent.",
           `aria-keyshortcuts` = "ArrowLeft ArrowRight ArrowUp ArrowDown",
           width = "100%", flex_shrink = "0",
           position = "relative", border_radius = "4px", cursor = "crosshair",
           touch_action = "none"):
        tdiv(ref = markerNode, `data-color-plane-marker` = "true", `aria-hidden` = "true",
             position = "absolute", width = "12px", height = "12px",
             border = "2px solid #FFFFFF", border_radius = "50%",
             box_shadow = "0 0 0 1px #000000, inset 0 0 0 1px #000000",
             transform = "translate(-50%, -50%)", pointer_events = "none")
      input(ref = hueNode, `type` = "range", min = "0", max = "359", step = "1",
            `data-color-hue` = "true", `aria-label` = "Hue", width = "100%")
      input(ref = alphaNode, `type` = "range", min = "0", max = "100", step = "1",
            `data-color-alpha` = "true", `aria-label` = "Opacity", width = "100%")
      tdiv(ref = channelHost, display = "flex", gap = "4px", `data-color-channels` = "true")
      input(ref = hslNode, `data-color-hsl` = "true",
            `aria-label` = "HSL color", padding = "6px 8px",
            background_color = "#0F0F18", color = "#F1F5F9",
            border = "1px solid #2F3140", border_radius = "4px")
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
  r.setStyle(planeNode, "aspect-ratio", "1 / 1")
  # Assigned below, once Apply's guards exist: Enter in a typed field commits
  # through exactly the same path as the Apply button.
  var commitDraft: proc(close: bool) {.closure.}
  proc onEnter(node: E; update: proc(): bool {.closure.}; close: bool) =
    ## Enter in a typed field: take the field's value into the draft (the
    ## `change` that Enter also raises may arrive after this keydown), then
    ## commit it. A value the field refuses stays uncommitted with its reason.
    r.addEventListener(node, "keydown", proc(ev: auto) =
      mixin preventDefault
      if pickerKey(ev) != "Enter": return
      when compiles(ev.preventDefault()):
        ev.preventDefault()
      elif defined(js):
        proc prevent(event: typeof(ev)) {.importjs: "#.preventDefault()".}
        prevent(ev)
      if update() and commitDraft != nil: commitDraft(close))
  proc updateChannel(index: int; node: E): bool {.discardable.} =
    if not mountedActive or not state.open.val or state.pending.val: return false
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
      # A colour typed into a fully transparent draft (a fill that is
      # `transparent`, i.e. no visible colour) would stay invisible and the
      # edit would look like it did nothing. A typed hex or HSL value without
      # alpha is opaque; so is a typed channel here -- but only for a colour
      # that was transparent when the picker opened, before any opacity was
      # chosen. An Alpha of 0% the user set deliberately is kept.
      if index == 3: state.transparentOrigin = false
      elif channels.alpha == 0 and state.transparentOrigin:
        channels.alpha = 255
        state.transparentOrigin = false
      if index == 3:
        state.setColorHsv(hue.val, state.saturation.val, state.brightness.val, channels.alpha)
      else:
        state.draft.val = channelsHex(channels)
      state.diagnostic.val = ""
      result = true
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
    onEnter(node, proc(): bool = updateChannel(index, node), close = false)
  for index, label in ["Red", "Green", "Blue", "Alpha %"]: addChannel(index, label)
  proc updateHsl(): bool =
    if not mountedActive or not state.open.val or state.pending.val: return false
    let raw = r.inputValue(hslNode)
    let color = hslDraftColor(raw)
    if color.len == 0:
      state.diagnostic.val = "Enter an HSL color such as hsl(217 91% 60%)."
      return false
    if normalizedHexColor(color) != normalizedHexColor(state.draft.val):
      state.draft.val = color
    # A typed HSL value carries its own alpha (opaque when it has none).
    state.transparentOrigin = false
    state.diagnostic.val = ""
    true
  r.addEventListener(hslNode, "change", proc() = discard updateHsl())
  onEnter(hslNode, updateHsl, close = false)
  proc setHsv(saturation, brightness: float) =
    if mountedActive and state.open.val and not state.pending.val:
      state.setColorHsv(hue.val, saturation, brightness, colorChannels(state.draft.val).alpha)
      state.diagnostic.val = ""
  r.addEventListener(hueNode, "input", proc() =
    if canceledRangeInput:
      r.setInputValue(hueNode, $int(round(hue.val)))
      return
    if not mountedActive or not state.open.val or state.pending.val: return
    try:
      let nextHue = parseFloat(r.inputValue(hueNode))
      if classify(nextHue) in {fcNan, fcInf, fcNegInf} or nextHue < 0 or nextHue > 359: return
      state.setColorHsv(nextHue, state.saturation.val, state.brightness.val,
        colorChannels(state.draft.val).alpha)
    except ValueError: discard)
  r.addEventListener(alphaNode, "input", proc() =
    if canceledRangeInput:
      r.setInputValue(alphaNode, $int(round(colorChannels(state.draft.val).alpha.float * 100 / 255)))
    else: updateChannel(3, alphaNode))
  when defined(js):
    let planeChange = proc(saturation, brightness: float) = setHsv(saturation, brightness)
    let planeCancel = proc(original: ColorDraftSnapshot) = state.restoreColorDraft(original)
    let currentDraft = proc(): ColorDraftSnapshot = state.captureColorDraft()
    let planeKey = proc(key: cstring): bool = state.adjustColorPlane($key)
    var removePointerListeners: proc() {.closure.}
    {.emit: ["if (typeof ", planeNode, ".addEventListener === 'function') {\n",
      "const plane = ", planeNode, "; let active = null, before = null;\n",
      "function move(e) { if(active !== e.pointerId) return; const b=plane.getBoundingClientRect(); ",
      planeChange, "(Math.max(0,Math.min(1,(e.clientX-b.left)/b.width)), Math.max(0,Math.min(1,1-(e.clientY-b.top)/b.height))); }\n",
      "function down(e) { if(e.button!==0) return; e.preventDefault(); plane.focus({preventScroll:true}); active=e.pointerId; before=", currentDraft, "(); plane.setPointerCapture(active); move(e); }\n",
      "function finish(e) { if(active!==e.pointerId) return; move(e); const id=active; active=null; if(plane.hasPointerCapture(id)) plane.releasePointerCapture(id); }\n",
      "function cancel() { if(active===null) return; const id=active; active=null; ", planeCancel, "(before); if(plane.hasPointerCapture(id)) plane.releasePointerCapture(id); }\n",
      "function key(e) { if(e.key==='Escape' && active!==null) { cancel(); e.preventDefault(); e.stopImmediatePropagation(); } }\n",
      "function planeKeys(e) { if(e.key==='Escape' && active!==null) { cancel(); e.preventDefault(); e.stopImmediatePropagation(); return; } if(", planeKey, "(e.key)) { e.preventDefault(); e.stopImmediatePropagation(); } }\n",
      "plane.addEventListener('keydown',planeKeys); plane.addEventListener('pointerdown',down); plane.addEventListener('pointermove',move); plane.addEventListener('pointerup',finish); plane.addEventListener('pointercancel',cancel); plane.addEventListener('lostpointercapture',cancel); window.addEventListener('blur',cancel); window.addEventListener('keydown',key,true);\n",
      removePointerListeners, "=function() { cancel(); plane.removeEventListener('keydown',planeKeys); plane.removeEventListener('pointerdown',down); plane.removeEventListener('pointermove',move); plane.removeEventListener('pointerup',finish); plane.removeEventListener('pointercancel',cancel); plane.removeEventListener('lostpointercapture',cancel); window.removeEventListener('blur',cancel); window.removeEventListener('keydown',key,true); }; }"].}
    onCleanup(proc() =
      if removePointerListeners != nil: removePointerListeners())
  createRenderEffect proc() =
    discard state.draft.val
    untrack(proc() = state.syncColorCoordinates())
  let trackStyle = r.createElement("style")
  r.setTextContent(trackStyle, """
[data-color-popover] input[type=range] { appearance:none; -webkit-appearance:none; height:14px; flex-shrink:0; margin:2px 0; border-radius:7px; cursor:pointer; }
[data-color-popover] [data-color-hue] { background:linear-gradient(to right,#f00,#ff0,#0f0,#0ff,#00f,#f0f,#f00); }
[data-color-popover] input[type=range]::-webkit-slider-runnable-track { height:14px; background:transparent; border-radius:7px; }
[data-color-popover] input[type=range]::-moz-range-track { height:14px; background:transparent; border-radius:7px; }
[data-color-popover] input[type=range]::-webkit-slider-thumb { appearance:none; -webkit-appearance:none; width:14px; height:14px; border:2px solid white; border-radius:50%; background:#242633; box-shadow:0 0 0 1px black; }
[data-color-popover] input[type=range]::-moz-range-thumb { width:10px; height:10px; border:2px solid white; border-radius:50%; background:#242633; box-shadow:0 0 0 1px black; }
[data-color-popover] input[type=range]:focus-visible, [data-color-popover] [data-color-plane]:focus-visible { outline:2px solid #a5b4fc; outline-offset:2px; }
""")
  r.appendChild(rootNode, trackStyle)
  when defined(js):
    let captureRange = proc(): ColorDraftSnapshot = state.captureColorDraft()
    let restoreRange = proc(snapshot: ColorDraftSnapshot) = state.restoreColorDraft(snapshot)
    var cleanupRanges: proc() {.closure.}
    {.emit: ["if (typeof ", hueNode, ".addEventListener === 'function') { const nodes=[", hueNode, ",", alphaNode, "]; let active=null, before=null, canceledId=null, generation=0, disposed=false;\n",
      "function down(e) { if(disposed || e.button!==0) return; generation++; canceledId=null; ", canceledRangeInput, "=false; active={node:e.currentTarget,id:e.pointerId}; before=", captureRange, "(); active.node.setPointerCapture(active.id); }\n",
      "function finish(e) { if(canceledId===e.pointerId) { canceledId=null; const g=generation; queueMicrotask(()=>{if(!disposed && generation===g) ", canceledRangeInput, "=false;}); return; } if(!active || active.id!==e.pointerId) return; const a=active; active=null; if(a.node.hasPointerCapture(a.id)) a.node.releasePointerCapture(a.id); }\n",
      "function cancel() { if(!active) return; const a=active; active=null; canceledId=a.id; ", canceledRangeInput, "=true; ", restoreRange, "(before); if(a.node.hasPointerCapture(a.id)) a.node.releasePointerCapture(a.id); }\n",
      "function key(e) { if(e.key==='Escape' && active) { cancel(); e.preventDefault(); e.stopImmediatePropagation(); } else if(['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Home','End','PageUp','PageDown'].includes(e.key)) e.stopImmediatePropagation(); }\n",
      "function escape(e) { if(e.key==='Escape' && active) key(e); } nodes.forEach(n=>{n.addEventListener('pointerdown',down);n.addEventListener('pointerup',finish);n.addEventListener('pointercancel',cancel);n.addEventListener('lostpointercapture',cancel);n.addEventListener('keydown',key);});window.addEventListener('blur',cancel);window.addEventListener('keydown',escape,true);document.addEventListener('pointerup',finish,true);\n",
      cleanupRanges, "=function(){disposed=true;generation++;cancel();nodes.forEach(n=>{n.removeEventListener('pointerdown',down);n.removeEventListener('pointerup',finish);n.removeEventListener('pointercancel',cancel);n.removeEventListener('lostpointercapture',cancel);n.removeEventListener('keydown',key);});window.removeEventListener('blur',cancel);window.removeEventListener('keydown',escape,true);document.removeEventListener('pointerup',finish,true);}; }"].}
    onCleanup(proc() =
      if cleanupRanges != nil: cleanupRanges())
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
    r.addEventListener(swatch, "click", proc() =
      if mountedActive and state.open.val and not state.pending.val:
        state.draft.val = color
        state.diagnostic.val = "")
  for color in ["#FFFFFF", "#000000", "#EF4444", "#F59E0B", "#22C55E", "#3B82F6", "#7C7AED", "#EC4899"]:
    addSwatch(color)
  installAnchoredPopover(rootNode, "isonim-color-close")
  proc cancelDraft() =
    if state.open.val: state.restoreColorDraft(state.cancelPoint)
    state.open.val = false
  r.addEventListener(rootNode, "isonim-color-close", cancelDraft)
  r.addEventListener(cancelNode, "click", cancelDraft)
  onCleanup(proc() =
    cancelDraft()
    mountedActive = false)
  proc applyDraft(close: bool) =
    if not mountedActive or not state.open.val or state.pending.val: return
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
      state.commitCloses = close
      let accepted = commit(value)
      state.commitCloses = true
      if accepted:
        if close: state.open.val = false
        else:
          # Committed and still open: the committed value is the new point
          # Cancel / Escape return to, not the colour the picker opened with.
          state.markColorDraftCommitted()
      elif not state.pending.val and state.diagnostic.val.len == 0:
        state.diagnostic.val = "The color edit was refused."
  commitDraft = applyDraft
  let apply = proc() = applyDraft(true)
  r.addEventListener(applyNode, "click", apply)
  r.addEventListener(inputNode, "input", proc() =
    if not mountedActive or not state.open.val or state.pending.val: return
    state.draft.val = r.inputValue(inputNode)
    # A typed hex value carries its own alpha (opaque when it has none).
    state.transparentOrigin = false
    state.diagnostic.val = "")
  r.addEventListener(invoker, "click", proc() =
    if not mountedActive: return
    state.projectedDraft = ""
    state.draft.val = normalizedSourceColor(current())
    state.syncColorCoordinates()
    state.cancelPoint = state.captureColorDraft()
    state.transparentOrigin = colorChannels(state.draft.val).alpha == 0
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
    let saturation = state.saturation.val
    let brightness = state.brightness.val
    r.setInputValue(hueNode, $int(round(hue.val)))
    let opacity = int(round(channels.alpha.float * 100 / 255))
    r.setInputValue(alphaNode, $opacity)
    for index, number in [channels.red, channels.green, channels.blue, opacity]:
      r.setInputValue(channelInputs[index], $number)
    r.setInputValue(hslNode, colorHslText(channels))
    r.setStyle(planeNode, "background", "linear-gradient(to top, #000, transparent), linear-gradient(to right, #fff, transparent), " & channelsHex(hsvChannels(hue.val, 1, 1)))
    r.setAttribute(planeNode, "aria-valuetext", "Saturation " & $int(round(saturation*100)) & "%, brightness " & $int(round(brightness*100)) & "%")
    r.setStyle(markerNode, "left", $(saturation * 100) & "%")
    r.setStyle(markerNode, "top", $((1 - brightness) * 100) & "%")
    let rgb = "rgb(" & $channels.red & ", " & $channels.green & ", " & $channels.blue & ")"
    r.setStyle(alphaNode, "background", "linear-gradient(to right, rgba(" & $channels.red & ", " & $channels.green & ", " & $channels.blue & ", 0), " & rgb & "), conic-gradient(#747785 25%, #333642 0 50%, #747785 0 75%, #333642 0)")
    r.setStyle(alphaNode, "background-size", "auto, 8px 8px")
    r.setStyle(previewNode, "background-color", normalizedHexColor(state.draft.val))
  # Separate from the field values above: a diagnostic or pending change used
  # to re-run that effect and rewrite every field from the draft. That threw
  # away the text a refusal was about, and the field's `change` on the next
  # blur then re-validated the rewritten value and cleared the message --
  # shrinking the popup under the pointer, so the click that caused the blur
  # (a swatch, Apply) landed on whatever moved into its place.
  createRenderEffect proc() =
    r.setTextContent(errorNode, if state.pending.val: "Saving source…" else: state.diagnostic.val)
    r.setAttribute(applyNode, "aria-disabled", if state.pending.val: "true" else: "false")
  r.appendChild(parent, root)
  root
