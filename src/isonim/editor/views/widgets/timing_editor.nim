## The Effects section's Bezier curve editor, for
## `transition-timing-function`.
##
## Editor spec "Specialized Editors": "Bezier curve editor -- for
## `transition-timing-function`; square with draggable control points;
## preset thumbnails (ease, ease-in, ease-out, ease-in-out, linear); custom
## curve via handle drag"; "Inspector Sections": Transitions cover
## `transition-timing-function`, and "Effects section consolidates
## Transitions + Filters". The clause that says how it commits is the drafted
## "Specialized editors" clause under "Specialized Editors".
##
## The editor follows the Timing row (`transition-timing-function`) behind
## the `Show advanced transition-timing-function controls` disclosure and
## edits that property through that row's wiring (`advanced_controls`). It
## reads one cubic Bezier curve (`css_compound_values.parseTimingFunction`):
##
## * the square (`Edit transition timing curve`) draws the curve from (0, 0)
##   to (1, 1); its two control points move with a drag, committed on
##   release, or with the arrow keys by 0.01 (Shift 0.1), each a commit. x
##   stays within 0..1, as CSS requires;
## * the preset thumbnails (`Set transition timing to ease-in-out`, ...)
##   commit their keyword;
## * `Run reduced-motion diagnostics` reports the selection's transition and
##   whether the project's stylesheet has a `prefers-reduced-motion` rule
##   that changes it for this element
##   (https://www.w3.org/TR/mediaqueries-5/#prefers-reduced-motion). It reads
##   and changes nothing else.
##
## A curve is written as its keyword when one names it, otherwise as
## `cubic-bezier()`. A value the square cannot draw (a list, `steps()`,
## `linear()` with stops) is named; only the presets, which replace it, act.

import std/[math, options, strutils]

import isonim/core/[signals, computation, owner]
from isonim/core/batch import untrack
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/css_compound_values
import isonim/editor/views/view_lifecycle
import ./advanced_controls
import ./property_commit

const
  timingProperty* = "transition-timing-function"
  timingCurveLabel* = "Edit transition timing curve"
  reducedMotionLabel* = "Run reduced-motion diagnostics"
  timingSearchText* = "Timing curve bezier transition-timing-function " &
    "easing ease reduced motion"
  curveSize* = 120.0
    ## The square's side in pixels: x and y from 0 to 1.
  curveOverflow* = 30.0
    ## The room above and below the square for a curve that overshoots.
  curveDots = 24

func timingPresetLabel*(keyword: string): string =
  "Set transition timing to " & keyword

func controlPointLabel*(index: int): string =
  "Move timing curve control point " & $index

func curvePixel*(x, y: float): tuple[left, top: float] =
  ## Where the square draws the point (``x``, ``y``).
  (left: x * curveSize, top: curveOverflow + (1.0 - y) * curveSize)

func draggedControlPoint*(startX, startY, dx, dy: float): tuple[x, y: float] =
  ## A control point at (``startX``, ``startY``) dragged by (``dx``, ``dy``)
  ## pixels: right increases x, up increases y. x stays within 0..1 (CSS
  ## requires it) and y within -1..2.
  (x: clamp(startX + dx / curveSize, 0.0, 1.0),
   y: clamp(startY - dy / curveSize, -1.0, 2.0))

func reducedMotionReport*(duration, timing, coverage: string;
    previewAvailable: bool): string =
  ## What `Run reduced-motion diagnostics` reports for a transition of
  ## ``duration`` and ``timing``: ``coverage`` is the selector of the
  ## `prefers-reduced-motion` rule that changes it, or "".
  let parsed = parseTimingFunction(timing)
  var lines: seq[string] = @[]
  var zero = true
  for part in splitTopLevel(duration):
    var number = 0.0
    var unit = ""
    if not (splitDimension(part, number, unit) and number == 0.0):
      zero = false
  if duration.strip().len == 0 or zero:
    lines.add "transition-duration is " &
      (if duration.strip().len > 0: duration.strip() else: "not set") &
      ": nothing animates, so reduced motion needs nothing here."
    return lines.join(" ")
  lines.add "Transition " & duration.strip() & " " &
    (if timing.strip().len > 0: timing.strip() else: "ease") & "."
  if parsed.ok and (parsed.curve.y1 < 0.0 or parsed.curve.y1 > 1.0 or
      parsed.curve.y2 < 0.0 or parsed.curve.y2 > 1.0):
    lines.add "The curve overshoots, which moves past its end and back."
  if not previewAvailable:
    lines.add "Whether a prefers-reduced-motion rule changes it needs the preview."
  elif coverage.len > 0:
    lines.add "The prefers-reduced-motion rule " & coverage &
      " changes it for people who ask for less motion."
  else:
    lines.add "No prefers-reduced-motion rule changes it: people who ask " &
      "for less motion still see it. Add one to the project's stylesheet."
  lines.join(" ")

proc previewReducedMotionRule*(elementId, domPath: string): tuple[
    available: bool; selector: string] =
  ## The selector of a rule inside a `prefers-reduced-motion` media block of
  ## the preview's stylesheets that matches the element and sets a
  ## transition or animation property, or "" when there is none.
  ## ``available`` is false outside a browser or without the element in a
  ## preview.
  when defined(js):
    var found: cstring
    var ok = false
    let id = cstring(elementId)
    let path = cstring(domPath)
    {.emit: ["""
      (function (id, path) {
        if (typeof document === 'undefined' || (!id && !path)) return;
        var watched = /^(transition|animation)(-|$)/;
        function scan(rules, target, inside) {
          for (var i = 0; i < rules.length; i++) {
            var rule = rules[i];
            if (rule.type === CSSRule.MEDIA_RULE) {
              var reduced = inside || /prefers-reduced-motion/.test(rule.conditionText || '');
              var hit = scan(rule.cssRules, target, reduced);
              if (hit) return hit;
            } else if (rule.cssRules && rule.type !== CSSRule.STYLE_RULE) {
              var nested = scan(rule.cssRules, target, inside);
              if (nested) return nested;
            } else if (inside && rule.type === CSSRule.STYLE_RULE && rule.selectorText) {
              var matches = false;
              try { matches = target.matches(rule.selectorText); } catch (e) {}
              if (!matches) continue;
              for (var j = 0; j < rule.style.length; j++) {
                if (watched.test(rule.style[j])) return rule.selectorText;
              }
            }
          }
          return '';
        }
        for (const frame of document.querySelectorAll('iframe')) {
          try {
            var doc = frame.contentDocument;
            if (!doc) continue;
            var target = (id && doc.querySelector('[data-isonim-element-id="' + CSS.escape(id) + '"]')) ||
              (path && doc.querySelector(path));
            if (!target) continue;
            """, ok, """ = true;
            for (var s = 0; s < doc.styleSheets.length; s++) {
              var hit = '';
              try { hit = scan(doc.styleSheets[s].cssRules, target, false); } catch (e) {}
              if (hit) { """, found, """ = hit; return; }
            }
            return;
          } catch (e) {}
        }
      })(""", id, ",", path, ");"].}
    result = (ok, if found.isNil: "" else: $found)
  else:
    discard elementId
    discard domPath
    result = (false, "")

proc mountTimingContents*[R, E](r: R; panel: E; vm: EditorVM;
    wiring: InspectorRowWiring) =
  let status = newCompoundEditorStatus()
  let draft = createSignal(none(CubicBezier))
  var alive = true
  onCleanup(proc() = alive = false)

  proc parsed(): TimingParse =
    let value = vm.compoundValue(timingProperty)
    parseTimingFunction(if value.isSome: value.get else: "")
  proc base(): CubicBezier =
    let p = parsed()
    if p.ok: p.curve else: timingPresets[1][1]
  proc shown(): CubicBezier =
    let d = draft.val
    if d.isSome: d.get else: base()
  proc refusal(): string = vm.compoundRefusal(timingProperty, wiring)
  proc curveRefusal(): string =
    result = refusal()
    if result.len > 0: return
    let p = parsed()
    if not p.ok:
      result = "The curve editor cannot change this " & timingProperty &
        ": " & p.reason & "."
  proc commitCurve(next: CubicBezier; label: string): bool {.discardable.} =
    draft.val = none(CubicBezier)
    commitThrough(vm, timingProperty, wiring, status, label,
      serializeTimingFunction(clampedCurve(next)))
  proc reject(reason: string) =
    status.failed.val = true
    status.message.val = reason

  let epoch = createSignal(0)
  watchSelection(vm, proc() =
    epoch.val = epoch.val + 1
    draft.val = none(CubicBezier)
    status.message.val = "")

  var square, dots, readout, presets, diagnose, note: E
  let editor = ui(r):
    tdiv(`data-timing-editor` = "true", role = "group",
         `aria-label` = "Timing curve editor",
         display = "flex", flex_direction = "column", gap = "6px",
         padding = "6px", border = "1px solid " & advBorder,
         border_radius = "6px", min_width = "0"):
      tdiv(display = "flex", gap = "8px", align_items = "flex-start"):
        tdiv(ref = square, `data-timing-curve` = "true", role = "group",
             position = "relative", width = "120px", height = "180px",
             flex_shrink = "0", touch_action = "none"):
          tdiv(`aria-hidden` = "true", position = "absolute", left = "0",
               top = "30px", width = "120px", height = "120px",
               border = "1px solid " & advBorder, box_sizing = "border-box",
               background_color = advTrough, border_radius = "3px")
          tdiv(ref = dots, `aria-hidden` = "true", position = "absolute",
               left = "0", top = "0", width = "120px", height = "180px",
               pointer_events = "none")
        tdiv(display = "flex", flex_direction = "column", gap = "4px",
             flex = "1", min_width = "0"):
          span(ref = readout, `data-timing-readout` = "true",
               font_family = "monospace", font_size = "10px",
               color = advTextPrimary, overflow_wrap = "anywhere"):
            text ""
          tdiv(ref = presets, `data-timing-presets` = "true",
               display = "flex", flex_wrap = "wrap", gap = "3px")
          button(ref = diagnose, `type` = "button",
                 `data-timing-reduced-motion` = "true",
                 height = "22px", padding = "0 6px",
                 border = "1px solid " & advBorder, border_radius = "4px",
                 background_color = "transparent", color = advTextPrimary,
                 font_family = "inherit", font_size = "10px",
                 cursor = "pointer", text_align = "left"):
            text "Reduced-motion check"
      tdiv(ref = note, `data-timing-note` = "true", role = "note",
           font_size = "10px", color = advTextMuted, overflow_wrap = "anywhere")
  r.setAttribute(square, "aria-label", timingCurveLabel)
  r.setAttribute(diagnose, "aria-label", reducedMotionLabel)
  r.appendChild(panel, editor)

  # ----- The curve --------------------------------------------------------- #
  var curveDotNodes: seq[E] = @[]
  for i in 0 .. curveDots:
    let node = r.createElement("div")
    r.setStyle(node, "position", "absolute")
    r.setStyle(node, "width", "3px")
    r.setStyle(node, "height", "3px")
    r.setStyle(node, "border-radius", "50%")
    r.setStyle(node, "background-color", advTextPrimary)
    r.setStyle(node, "transform", "translate(-50%, -50%)")
    r.appendChild(dots, node)
    curveDotNodes.add node
  createRenderEffect proc() =
    let curve = shown()
    for i, node in curveDotNodes:
      let point = bezierPoint(curve, i.float / curveDots.float)
      let place = curvePixel(point.x, point.y)
      r.setStyle(node, "left", compoundNumber(place.left, 1) & "px")
      r.setStyle(node, "top", compoundNumber(place.top, 1) & "px")
    r.setTextContent(readout, serializeTimingFunction(curve))

  proc mountHandle(index: int) =
    var handle: E
    let el = ui(r):
      button(ref = handle, `type` = "button", `data-timing-handle` = $index,
             position = "absolute", width = "12px", height = "12px",
             padding = "0", border = "2px solid #FFFFFF", border_radius = "50%",
             background_color = advAccent, transform = "translate(-50%, -50%)",
             cursor = "grab", touch_action = "none")
    r.setAttribute(handle, "aria-label", controlPointLabel(index))
    r.appendChild(square, el)
    proc point(curve: CubicBezier): tuple[x, y: float] =
      if index == 1: (x: curve.x1, y: curve.y1) else: (x: curve.x2, y: curve.y2)
    proc moved(curve: CubicBezier; x, y: float): CubicBezier =
      result = curve
      if index == 1:
        result.x1 = x
        result.y1 = y
      else:
        result.x2 = x
        result.y2 = y
    createRenderEffect proc() =
      let p = point(shown())
      let place = curvePixel(p.x, clamp(p.y, -0.25, 1.25))
      r.setStyle(handle, "left", compoundNumber(place.left, 1) & "px")
      r.setStyle(handle, "top", compoundNumber(place.top, 1) & "px")
      r.setAttribute(handle, "aria-valuetext",
        "x " & compoundNumber(p.x) & ", y " & compoundNumber(p.y))
      let reason = curveRefusal()
      r.setAttribute(handle, "aria-disabled", if reason.len > 0: "true" else: "false")
      r.setAttribute(handle, "title",
        if reason.len > 0: reason
        else: "Drag to shape the curve; arrow keys move it by 0.01 (Shift 0.1)")
    var pressed = false
    var dragging = false
    var pressEpoch = 0
    var startX, startY = 0.0
    var startPoint = (x: 0.0, y: 0.0)
    proc cancel() =
      if pressed and dragging: draft.val = none(CubicBezier)
      pressed = false
      dragging = false
    when isDomViewHost(E):
      r.addEventListener(handle, "pointerdown", proc(ev: auto) =
        if advButton(ev) == 0: captureAdvPointer(handle, ev))
    r.addPointerListener(handle, "pointerdown", proc(x, y: float; shift, alt: bool) =
      let reason = untrack(curveRefusal)
      if reason.len > 0:
        reject(reason)
        return
      pressed = true
      dragging = false
      pressEpoch = untrack(proc(): int = epoch.val)
      startX = x
      startY = y
      startPoint = point(untrack(base)))
    r.addPointerListener(handle, "pointermove", proc(x, y: float; shift, alt: bool) =
      if not pressed: return
      if untrack(proc(): int = epoch.val) != pressEpoch:
        pressed = false
        return
      if not dragging:
        if abs(x - startX) + abs(y - startY) < scrubThreshold: return
        dragging = true
      let p = draggedControlPoint(startPoint.x, startPoint.y, x - startX, y - startY)
      draft.val = some(moved(untrack(base), p.x, p.y)))
    r.addPointerListener(handle, "pointerup", proc(x, y: float; shift, alt: bool) =
      if not pressed: return
      pressed = false
      if not dragging: return
      dragging = false
      if untrack(proc(): int = epoch.val) != pressEpoch: return
      let p = draggedControlPoint(startPoint.x, startPoint.y, x - startX, y - startY)
      let next = moved(untrack(base), p.x, p.y)
      if serializeTimingFunction(next) == serializeTimingFunction(untrack(base)):
        draft.val = none(CubicBezier)
        return
      commitCurve(next, "Curve"))
    r.addEventListener(handle, "pointercancel", proc() = cancel())
    r.addEventListener(handle, "lostpointercapture", proc() = cancel())
    r.addEventListener(handle, "keydown", proc(ev: auto) =
      let key = advKey(ev)
      if key == "Escape" and pressed:
        stopAdvPropagation(ev)
        cancel()
        return
      if key in ["Enter", " "]:
        stopAdvPropagation(ev)
        return
      if key notin ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"]: return
      preventAdvDefault(ev)
      stopAdvPropagation(ev)
      let reason = untrack(curveRefusal)
      if reason.len > 0:
        reject(reason)
        return
      let size = if advShift(ev): 0.1 else: 0.01
      let current = untrack(base)
      let p = point(current)
      var x = p.x
      var y = p.y
      case key
      of "ArrowLeft": x -= size
      of "ArrowRight": x += size
      of "ArrowUp": y += size
      else: y -= size
      commitCurve(moved(current, clamp(x, 0.0, 1.0), clamp(y, -1.0, 2.0)), "Curve"))
    onCleanup(proc() = cancel())
  mountHandle(1)
  mountHandle(2)

  # ----- Presets ----------------------------------------------------------- #
  proc mountPreset(keyword: string; curve: CubicBezier) =
    var node, thumb: E
    let el = ui(r):
      button(ref = node, `type` = "button", `data-timing-preset` = keyword,
             `aria-pressed` = "false",
             display = "flex", align_items = "center", gap = "4px",
             height = "22px", padding = "0 5px",
             border = "1px solid " & advBorder, border_radius = "4px",
             background_color = "transparent", color = advTextPrimary,
             font_family = "inherit", font_size = "10px", cursor = "pointer"):
        span(ref = thumb, `aria-hidden` = "true", position = "relative",
             width = "14px", height = "14px", flex_shrink = "0")
        span():
          text keyword
    r.setAttribute(node, "aria-label", timingPresetLabel(keyword))
    r.appendChild(presets, el)
    # The thumbnail: the curve in eight dots.
    for i in 0 .. 8:
      let point = bezierPoint(curve, i.float / 8.0)
      let d = r.createElement("span")
      r.setStyle(d, "position", "absolute")
      r.setStyle(d, "width", "2px")
      r.setStyle(d, "height", "2px")
      r.setStyle(d, "background-color", advTextMuted)
      r.setStyle(d, "left", compoundNumber(point.x * 12.0, 1) & "px")
      r.setStyle(d, "top", compoundNumber((1.0 - point.y) * 12.0, 1) & "px")
      r.appendChild(thumb, d)
    createRenderEffect proc() =
      let p = parsed()
      let pressed = p.ok and timingPresetFor(p.curve) == keyword
      r.setAttribute(node, "aria-pressed", if pressed: "true" else: "false")
      r.setStyle(node, "background-color", if pressed: advPressed else: "transparent")
      setButtonAvailability(r, node, refusal(), keyword & " = cubic-bezier(" &
        compoundNumber(curve.x1) & ", " & compoundNumber(curve.y1) & ", " &
        compoundNumber(curve.x2) & ", " & compoundNumber(curve.y2) & ")")
    r.addEventListener(node, "click", proc() =
      if not alive: return
      let reason = untrack(refusal)
      if reason.len > 0:
        reject(reason)
        return
      draft.val = none(CubicBezier)
      commitThrough(vm, timingProperty, wiring, status, keyword, keyword))
    stopAdvActivationKeys(r, node)
  for (keyword, curve) in timingPresets: mountPreset(keyword, curve)

  # ----- Reduced motion ---------------------------------------------------- #
  r.addEventListener(diagnose, "click", proc() =
    if not alive: return
    let element = untrack(proc(): ElementRef = vm.inspector.selectedElement.val)
    if element.tag.len == 0:
      reject("Select an element to check its transition.")
      return
    let duration = untrack(proc(): Option[string] =
      vm.compoundValue("transition-duration"))
    let timing = untrack(proc(): Option[string] = vm.compoundValue(timingProperty))
    let coverage = previewReducedMotionRule(element.id, element.domPath)
    status.failed.val = false
    status.message.val = reducedMotionReport(
      if duration.isSome: duration.get else: "",
      if timing.isSome: timing.get else: "",
      coverage.selector, coverage.available))
  stopAdvActivationKeys(r, diagnose)

  createRenderEffect proc() =
    let p = parsed()
    r.setTextContent(note,
      if p.ok: ""
      else: "The curve editor cannot change this " & timingProperty & ": " &
        p.reason & ". A preset replaces it.")
    r.setStyle(note, "display", if p.ok: "none" else: "block")
  mountScopeNote(r, editor, timingProperty, wiring, timingProperty)
  mountEditorStatus(r, editor, status, "data-timing-message")

proc mountTimingEditor*[R, E](r: R; parent: E; vm: EditorVM;
    wiring: InspectorRowWiring) =
  ## The disclosure, at the end of ``parent``; its contents are mounted when
  ## it is first opened. ``wiring`` is the Timing row's.
  discard mountAdvancedDisclosure[R, E](r, parent, vm, timingProperty,
    "Timing curve", timingSearchText, proc(panel: E) =
      mountTimingContents[R, E](r, panel, vm, wiring))
