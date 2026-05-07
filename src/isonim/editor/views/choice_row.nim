## Compact one-of-many choice rows used by IsoNim editor panels.

import isonim/dsl/ui

const
  bgSurface = "#1E293B"
  bgInput = "#0F172A"
  bgSidebar = "#151D2E"
  border = "#334155"
  textPrimary = "#F1F5F9"
  textMuted = "#64748B"
  textDim = "#475569"
  accent = "#3B82F6"

type
  CompactChoiceOption* = object
    label*: string
    shortLabel*: string
    ariaLabel*: string
    selected*: bool
    enabled*: bool
    dataAttrs*: seq[(string, string)]
    onChoose*: proc()

  CompactChoiceRow*[E] = object
    root*: E
    optionNodes*: seq[E]
    optionIndexes*: seq[int]
    overflowNode*: E

func visibleText(option: CompactChoiceOption): string =
  if option.shortLabel.len > 0: option.shortLabel else: option.label

proc compactChoiceHandler(enabled: bool; callback: proc()): proc() =
  let capturedEnabled = enabled
  let capturedCallback = callback
  result = proc() =
    if capturedEnabled and capturedCallback != nil:
      capturedCallback()

proc renderCompactChoiceRow*[R, E](r: R; label, ariaLabel: string;
    options: seq[CompactChoiceOption]; visibleLimit = 2;
    labelWidth = "72px"; minHeight = "24px"): CompactChoiceRow[E] =
  let safeVisibleLimit = max(1, visibleLimit)
  let hasLabel = label.len > 0
  var visibleCount = 0
  for option in options:
    if option.selected or visibleCount < safeVisibleLimit:
      inc visibleCount
  visibleCount = min(max(visibleCount, min(options.len, safeVisibleLimit)),
    options.len)
  let chipColumns =
    if visibleCount <= 0: "1fr 22px"
    else: "repeat(" & $visibleCount & ", minmax(0, 1fr)) 22px"
  let rootColumns =
    if hasLabel: labelWidth & " minmax(0, 1fr)" else: "minmax(0, 1fr)"

  var rowRoot: E
  var stripNode: E
  result = CompactChoiceRow[E](optionNodes: @[], optionIndexes: @[])
  rowRoot = ui(r):
    tdiv(display = "grid",
          `grid-template-columns` = rootColumns,
          align_items = "center", gap = "6px",
          min_height = minHeight,
          max_width = "100%",
          overflow = "visible",
          role = "group",
          `aria-label` = ariaLabel,
          `data-compact-choice-row` = "true"):
      if hasLabel:
        span(font_size = "10px", color = textMuted,
              white_space = "nowrap", overflow = "hidden",
              text_overflow = "ellipsis"):
          text label
      tdiv(ref = stripNode,
            display = "grid",
            `grid-template-columns` = chipColumns,
            align_items = "center",
            min_width = "0",
            border = "1px solid " & border,
            border_radius = "4px",
            overflow = "visible",
            background_color = bgInput,
            `data-compact-choice-strip` = "true"):
        var renderedVisible = 0
        for i in 0 ..< options.len:
          let option = options[i]
          if not option.selected and renderedVisible >= safeVisibleLimit:
            continue
          if renderedVisible >= visibleCount:
            continue
          var optionNode: E
          let enabled = option.enabled
          let selected = option.selected
          let choose = compactChoiceHandler(enabled, option.onChoose)
          tdiv(ref = optionNode,
                role = "button", tabindex = (if enabled: "0" else: "-1"),
                `aria-label` = option.ariaLabel,
                `aria-pressed` = (if selected: "true" else: "false"),
                `data-compact-choice-enabled` = (if enabled: "true" else: "false"),
                min_width = "0",
                height = "22px",
                display = "flex", align_items = "center",
                justify_content = "center",
                padding = "0 6px",
                border_right = "1px solid " & border,
                background_color = (if selected: accent & "44" else: "transparent"),
                color = (if enabled: (if selected: textPrimary else: textMuted) else: textDim),
                font_size = "10px",
                cursor = (if enabled: "pointer" else: "default"),
                white_space = "nowrap", overflow = "hidden",
                text_overflow = "ellipsis",
                onclick = choose,
                onkeydown = choose):
            text option.visibleText()
          result.optionNodes.add optionNode
          result.optionIndexes.add i
          for (key, value) in option.dataAttrs:
            r.setAttribute(optionNode, key, value)
          if enabled and option.onChoose != nil:
            r.addEventListener(optionNode, "click", option.onChoose)
            r.addEventListener(optionNode, "keydown", option.onChoose)
          inc renderedVisible
        details(position = "relative",
                height = "22px",
                color = textDim,
                font_size = "10px"):
          summary(ref = result.overflowNode,
                  display = "flex", align_items = "center",
                  justify_content = "center",
                  width = "22px", height = "22px",
                  list_style = "none", cursor = "pointer",
                  `aria-label` = "More " & ariaLabel):
            text "v"
          tdiv(position = "absolute", right = "0", top = "23px",
                z_index = "30", min_width = "170px",
                display = "flex", flex_direction = "column", gap = "2px",
                padding = "4px", border = "1px solid " & border,
                border_radius = "5px", background_color = bgSidebar,
                box_shadow = "0 8px 24px rgba(0,0,0,0.28)"):
            for i in 0 ..< options.len:
              let option = options[i]
              var optionNode: E
              let enabled = option.enabled
              let selected = option.selected
              let choose = compactChoiceHandler(enabled, option.onChoose)
              tdiv(ref = optionNode,
                    role = "button", tabindex = (if enabled: "0" else: "-1"),
                    `aria-label` = option.ariaLabel,
                    `aria-pressed` = (if selected: "true" else: "false"),
                    `data-compact-choice-enabled` = (if enabled: "true" else: "false"),
                    display = "grid",
                    `grid-template-columns` = "34px minmax(0, 1fr)",
                    align_items = "center", gap = "5px",
                    min_height = "22px",
                    padding = "3px 4px",
                    border_radius = "4px",
                    background_color = (if selected: bgSurface else: "transparent"),
                    color = (if enabled: textPrimary else: textDim),
                    font_size = "10px",
                    cursor = (if enabled: "pointer" else: "default"),
                    onclick = choose,
                    onkeydown = choose):
                span(color = (if selected: accent else: textMuted),
                      white_space = "nowrap", overflow = "hidden",
                      text_overflow = "ellipsis"):
                  text option.visibleText()
                span(white_space = "nowrap", overflow = "hidden",
                      text_overflow = "ellipsis"):
                  text option.label
              result.optionNodes.add optionNode
              result.optionIndexes.add i
              for (key, value) in option.dataAttrs:
                r.setAttribute(optionNode, key, value)
              if enabled and option.onChoose != nil:
                r.addEventListener(optionNode, "click", option.onChoose)
                r.addEventListener(optionNode, "keydown", option.onChoose)
  result.root = rowRoot
