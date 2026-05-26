## CHRM-M4 — Spec-pane formatting toolbar.
##
## A fixed (always-visible) formatting toolbar that mounts immediately
## above the TipTap editable host in spec-pane Edit mode.  The toolbar
## exposes the canonical CommonMark feature set: headings, inline
## marks (bold / italic / strike / code), link, lists, blockquote,
## code block, horizontal rule, and undo / redo.
##
## **Pattern chosen: fixed toolbar (Linear-style).**
##
## Web-search anchors for the pattern + extension choice:
##
## - "Custom menu" — TipTap Editor Docs, retrieved 2026-05-26:
##   https://tiptap.dev/docs/editor/getting-started/style-editor/custom-menus
##   ("Fixed menus are popular and you can build one by creating a
##   ``<div>`` element and filling it with ``<button>`` elements.")
##
## - "Events in Tiptap" — TipTap Editor Docs:
##   https://tiptap.dev/docs/editor/api/events
##   ("The ``selectionUpdate`` event fires when the selection has
##   changed; use it together with ``isActive`` to refresh the active-
##   mark indicators on toolbar buttons.")
##
## - "Editor commands API" — TipTap Editor Docs:
##   https://tiptap.dev/docs/editor/api/commands
##   ("Chain commands via ``editor.chain().focus().toggleBold().run()``;
##   use ``editor.can().chain().focus().toggleBold().run()`` to test
##   whether the chain is applicable.")
##
## - "@tiptap/extension-link" — npmjs:
##   https://www.npmjs.com/package/@tiptap/extension-link
##   (Vendored as a direct dep; gives the editor ``setLink`` /
##   ``unsetLink`` / ``isActive('link')``.)
##
## - Comparison to Notion / Linear / Obsidian — Notion uses a bubble
##   menu (appears on selection) plus a slash menu for block
##   insertion; Linear uses primarily a fixed top toolbar; Obsidian
##   uses a fixed toolbar.  The fixed pattern is the simplest
##   discoverable surface for the CHRM-M4 brief's "spec-pane Edit
##   mode" target audience (designers reviewing render briefs), so we
##   ship that first.  A bubble menu can layer on top in a later
##   polish pass — the underlying VM + FFI is already split such that
##   either flavour can read the same active-marks signals.
##
## **Keyboard-shortcut map (mirrored in each button's ``title``
## tooltip):**
##
##   * Ctrl/Cmd + B           → toggleBold
##   * Ctrl/Cmd + I           → toggleItalic
##   * Ctrl/Cmd + Shift + X   → toggleStrike
##   * Ctrl/Cmd + E           → toggleCode (inline code)
##   * Ctrl/Cmd + Alt + 1/2/3 → toggleHeading(1|2|3)
##   * Ctrl/Cmd + Alt + 0     → setParagraph
##   * Ctrl/Cmd + Shift + 8   → toggleBulletList
##   * Ctrl/Cmd + Shift + 7   → toggleOrderedList
##   * Ctrl/Cmd + Shift + B   → toggleBlockquote
##   * Ctrl/Cmd + Alt + C     → toggleCodeBlock
##   * Ctrl/Cmd + K           → setLink (open popover for URL)
##   * Ctrl/Cmd + Z           → undo
##   * Ctrl/Cmd + Shift + Z   → redo
##
## (These are TipTap StarterKit + extension-link defaults; the toolbar
## tooltips surface them so a future maintainer can read the map off
## the live UI without reopening this file.)
##
## **Dogfood:** wrapper structure is built via the ``ui:`` DSL.  All
## ``setStyle`` / ``setAttribute`` writes live inside
## ``createRenderEffect`` closures or run once during mount; no
## imperative DOM tinkering outside the reactive layer.

import std/sets

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/editor/vendor/tiptap as tiptap_lib
import isonim/editor/vendor/tiptap_link as tiptap_link

when defined(js):
  import std/jsffi
  from std/dom import Event

type
  FormattingMark* = enum
    ## CHRM-M4 — set of inline-mark identifiers the toolbar tracks.
    ## Each maps 1:1 to a TipTap mark name (``"bold"``, ``"italic"``,
    ## ``"strike"``, ``"code"``, ``"link"``).
    fmBold
    fmItalic
    fmStrike
    fmCode
    fmLink

  BlockKind* = enum
    ## CHRM-M4 — set of block-node identifiers the toolbar tracks.
    ## ``btParagraph`` is the default "plain" block; the others map
    ## to TipTap node names + an optional ``level`` attribute on
    ## ``heading``.
    btParagraph
    btHeading1
    btHeading2
    btHeading3
    btBulletList
    btOrderedList
    btBlockquote
    btCodeBlock

  SpecEditorToolbarVM* = ref object
    ## CHRM-M4 — reactive VM for the formatting toolbar.  Mirrors the
    ## live TipTap state via ``onSelectionUpdate`` + ``onTransaction``
    ## subscriptions installed in :proc:`mountSpecEditorToolbar`.  The
    ## headless VM tests drive the setters directly without booting
    ## TipTap.
    activeMarks*: Signal[HashSet[FormattingMark]]
    activeBlockKind*: Signal[BlockKind]
    canUndo*: Signal[bool]
    canRedo*: Signal[bool]
    linkDraftOpen*: Signal[bool]
      ## True while the Link popover is showing.  The mount renders
      ## the URL input only when this flips to ``true``.
    linkDraftHref*: Signal[string]
      ## Current value of the URL input.

proc createSpecEditorToolbarVM*(): SpecEditorToolbarVM =
  ## Fresh VM in its empty state: no active marks, paragraph block,
  ## no undo/redo history.
  SpecEditorToolbarVM(
    activeMarks: createSignal(initHashSet[FormattingMark]()),
    activeBlockKind: createSignal(btParagraph),
    canUndo: createSignal(false),
    canRedo: createSignal(false),
    linkDraftOpen: createSignal(false),
    linkDraftHref: createSignal(""),
  )

proc setActiveMarks*(vm: SpecEditorToolbarVM; marks: HashSet[FormattingMark]) =
  ## CHRM-M4 — reactive write of the active inline-mark set.  Mount-
  ## side render effects mirror the change onto the per-button
  ## ``aria-pressed`` + ``data-active`` attributes.
  if vm == nil or vm.activeMarks == nil:
    return
  vm.activeMarks.val = marks

proc setActiveBlockKind*(vm: SpecEditorToolbarVM; kind: BlockKind) =
  ## CHRM-M4 — reactive write of the active block kind.
  if vm == nil or vm.activeBlockKind == nil:
    return
  vm.activeBlockKind.val = kind

proc setCanUndo*(vm: SpecEditorToolbarVM; can: bool) =
  if vm == nil or vm.canUndo == nil:
    return
  vm.canUndo.val = can

proc setCanRedo*(vm: SpecEditorToolbarVM; can: bool) =
  if vm == nil or vm.canRedo == nil:
    return
  vm.canRedo.val = can

proc openLinkDraft*(vm: SpecEditorToolbarVM; initialHref: string = "") =
  ## Open the Link popover with a fresh URL input.
  if vm == nil: return
  vm.linkDraftHref.val = initialHref
  vm.linkDraftOpen.val = true

proc closeLinkDraft*(vm: SpecEditorToolbarVM) =
  if vm == nil: return
  vm.linkDraftOpen.val = false
  vm.linkDraftHref.val = ""

# --------------------------------------------------------------------------- #
#  Active-state collection helpers — read out of a live TipTap editor.
#  Exposed as pure procs so the mount-side ``selectionUpdate`` /
#  ``transaction`` handlers stay tiny + readable.
# --------------------------------------------------------------------------- #

proc collectActiveMarks*(editor: tiptap_lib.TipTapEditor): HashSet[FormattingMark] =
  ## Walk the tracked mark names + return the set that are active at
  ## the current selection.  Empty when ``editor`` is nil (native
  ## build / fallback path).
  result = initHashSet[FormattingMark]()
  when defined(js):
    if editor.isNil:
      return
    if tiptap_lib.isActive(editor, "bold"):    result.incl fmBold
    if tiptap_lib.isActive(editor, "italic"):  result.incl fmItalic
    if tiptap_lib.isActive(editor, "strike"):  result.incl fmStrike
    if tiptap_lib.isActive(editor, "code"):    result.incl fmCode
    if tiptap_lib.isActive(editor, "link"):    result.incl fmLink

proc currentBlockKind*(editor: tiptap_lib.TipTapEditor): BlockKind =
  ## Resolve the active block to one of :enum:`BlockKind`.  Order is
  ## load-bearing: heading levels are checked before paragraph because
  ## TipTap's ``isActive("paragraph")`` returns true inside a heading
  ## on TipTap 3.x (the heading itself wraps a paragraph node in some
  ## schemas).
  when defined(js):
    if editor.isNil:
      return btParagraph
    if tiptap_lib.isActiveHeading(editor, 1): return btHeading1
    if tiptap_lib.isActiveHeading(editor, 2): return btHeading2
    if tiptap_lib.isActiveHeading(editor, 3): return btHeading3
    if tiptap_lib.isActive(editor, "codeBlock"): return btCodeBlock
    if tiptap_lib.isActive(editor, "blockquote"): return btBlockquote
    if tiptap_lib.isActive(editor, "bulletList"): return btBulletList
    if tiptap_lib.isActive(editor, "orderedList"): return btOrderedList
    btParagraph
  else:
    btParagraph

# --------------------------------------------------------------------------- #
#  Visual tokens.  Match the chrome bar + popover so the toolbar reads
#  as part of the editor surface, not a foreign affordance.
# --------------------------------------------------------------------------- #

const
  tbBg         = "#15151C"
  tbBorder     = "#2D2D3A"
  tbBtnBg      = "transparent"
  tbBtnBgOn    = "#3B82F6"
  tbBtnBorder  = "transparent"
  tbBtnBorderOn = "#3B82F6"
  tbText       = "#A0A2B0"
  tbTextOn     = "#FFFFFF"
  tbSeparator  = "#2D2D3A"

# --------------------------------------------------------------------------- #
#  Button kinds — internal enum used to dispatch click handlers
#  through a single ``applyButton`` proc.  Keeps the mount body small.
# --------------------------------------------------------------------------- #

type
  ToolbarButtonKind = enum
    tbkBold
    tbkItalic
    tbkStrike
    tbkInlineCode
    tbkLink
    tbkBulletList
    tbkOrderedList
    tbkBlockquote
    tbkCodeBlock
    tbkHorizontalRule
    tbkUndo
    tbkRedo

  ToolbarIconButtonSpec = object
    kind: ToolbarButtonKind
    glyph: string       ## Unicode glyph shown on the button face.
    label: string       ## ``aria-label`` text (e.g. "Bold").
    shortcut: string    ## Keyboard-shortcut hint shown in ``title``.

const ToolbarIconButtons: array[12, ToolbarIconButtonSpec] = [
  ToolbarIconButtonSpec(kind: tbkBold,
    glyph: "B", label: "Bold", shortcut: "Ctrl/Cmd+B"),
  ToolbarIconButtonSpec(kind: tbkItalic,
    glyph: "I", label: "Italic", shortcut: "Ctrl/Cmd+I"),
  ToolbarIconButtonSpec(kind: tbkStrike,
    glyph: "S", label: "Strikethrough", shortcut: "Ctrl/Cmd+Shift+X"),
  ToolbarIconButtonSpec(kind: tbkInlineCode,
    glyph: "</>", label: "Inline code", shortcut: "Ctrl/Cmd+E"),
  ToolbarIconButtonSpec(kind: tbkLink,
    glyph: "\xF0\x9F\x94\x97", label: "Link", shortcut: "Ctrl/Cmd+K"),
  ToolbarIconButtonSpec(kind: tbkBulletList,
    glyph: "\xE2\x80\xA2", label: "Bullet list", shortcut: "Ctrl/Cmd+Shift+8"),
  ToolbarIconButtonSpec(kind: tbkOrderedList,
    glyph: "1.", label: "Numbered list", shortcut: "Ctrl/Cmd+Shift+7"),
  ToolbarIconButtonSpec(kind: tbkBlockquote,
    glyph: "\xE2\x80\x9D", label: "Blockquote", shortcut: "Ctrl/Cmd+Shift+B"),
  ToolbarIconButtonSpec(kind: tbkCodeBlock,
    glyph: "{ }", label: "Code block", shortcut: "Ctrl/Cmd+Alt+C"),
  ToolbarIconButtonSpec(kind: tbkHorizontalRule,
    glyph: "\xE2\x80\x94", label: "Horizontal rule", shortcut: ""),
  ToolbarIconButtonSpec(kind: tbkUndo,
    glyph: "\xE2\x86\xB6", label: "Undo", shortcut: "Ctrl/Cmd+Z"),
  ToolbarIconButtonSpec(kind: tbkRedo,
    glyph: "\xE2\x86\xB7", label: "Redo", shortcut: "Ctrl/Cmd+Shift+Z"),
]

const HeadingLabels = ["Paragraph", "Heading 1", "Heading 2", "Heading 3"]

proc isActiveButton(kind: ToolbarButtonKind;
                    marks: HashSet[FormattingMark];
                    blockKind: BlockKind): bool =
  case kind
  of tbkBold:           fmBold in marks
  of tbkItalic:         fmItalic in marks
  of tbkStrike:         fmStrike in marks
  of tbkInlineCode:     fmCode in marks
  of tbkLink:           fmLink in marks
  of tbkBulletList:     blockKind == btBulletList
  of tbkOrderedList:    blockKind == btOrderedList
  of tbkBlockquote:     blockKind == btBlockquote
  of tbkCodeBlock:      blockKind == btCodeBlock
  of tbkHorizontalRule: false
  of tbkUndo:           false
  of tbkRedo:           false

proc kindToDataAttr(kind: ToolbarButtonKind): string =
  case kind
  of tbkBold:           "bold"
  of tbkItalic:         "italic"
  of tbkStrike:         "strike"
  of tbkInlineCode:     "code"
  of tbkLink:           "link"
  of tbkBulletList:     "bullet-list"
  of tbkOrderedList:    "ordered-list"
  of tbkBlockquote:     "blockquote"
  of tbkCodeBlock:      "code-block"
  of tbkHorizontalRule: "horizontal-rule"
  of tbkUndo:           "undo"
  of tbkRedo:           "redo"

# --------------------------------------------------------------------------- #
#  Mount.
# --------------------------------------------------------------------------- #

type
  EditorLookup* = proc(): tiptap_lib.TipTapEditor {.closure.}
    ## CHRM-M4 — lazy lookup the toolbar uses to dispatch commands
    ## against the live TipTap editor.  The toolbar mount runs
    ## synchronously (outside the bootstrap effect) while the editor
    ## itself is created asynchronously inside ``bootstrapEditor``; a
    ## lookup closure lets clicks that land before the editor exists
    ## be no-ops rather than crashes.  The closure is allowed to
    ## return ``nil`` — the toolbar's click dispatchers guard.

proc mountSpecEditorToolbar*[R, E](r: R; parent: E;
                                   vm: SpecEditorToolbarVM;
                                   editorLookup: EditorLookup) =
  ## Mount the formatting toolbar inside ``parent``.  ``editorLookup``
  ## resolves to the live TipTap instance the toolbar drives via the
  ## ``vendor/tiptap.nim`` command bindings.  Lookup is called on
  ## every click so a click that lands before the editor exists is a
  ## no-op rather than a crash.  On native builds the editor handle
  ## is inert and command calls are no-ops, which keeps the headless
  ## test pipeline buildable without a JS runtime.
  let capturedVm = vm
  let capturedLookup = editorLookup

  var iconButtons: array[12, E]
  var headingTrigger: E
  var headingLabel: E
  var headingPopup: E
  var headingOptions: array[4, E]
  var linkPopover: E
  var linkInput: E
  var linkSubmit: E
  var linkCancel: E

  proc separatorBox(rt: R): E =
    var n: E
    discard ui(rt):
      tdiv(
        ref = n,
        `data-spec-editor-toolbar-separator` = "true",
        `aria-hidden` = "true",
        display = "inline-block",
        width = "1px",
        height = "16px",
        margin = "0 6px",
        background_color = tbSeparator)
    n

  let root = ui(r):
    tdiv(
      `data-spec-editor-toolbar` = "true",
      `role` = "toolbar",
      `aria-label` = "Formatting toolbar",
      display = "flex",
      flex_direction = "row",
      flex_wrap = "wrap",
      align_items = "center",
      gap = "2px",
      padding = "6px 10px",
      margin_bottom = "8px",
      background_color = tbBg,
      border = "1px solid " & tbBorder,
      border_radius = "6px",
      position = "relative")

  # ----- Heading group: ChoiceGroup-shape chevron popup -----------------------
  let headingWrapper = ui(r):
    tdiv(
      `data-spec-editor-toolbar-group` = "heading",
      display = "inline-block",
      position = "relative")
  discard ui(r):
    tdiv(
      ref = headingTrigger,
      `role` = "button",
      tabindex = "0",
      `aria-haspopup` = "listbox",
      `aria-expanded` = "false",
      `data-spec-editor-toolbar-heading-trigger` = "true",
      title = "Block type",
      display = "inline-flex",
      align_items = "center",
      justify_content = "space-between",
      min_width = "92px",
      gap = "6px",
      padding = "3px 10px",
      font_size = "11px",
      font_weight = "500",
      line_height = "1",
      color = tbTextOn,
      background_color = tbBtnBg,
      border = "1px solid " & tbBorder,
      border_radius = "4px",
      cursor = "pointer",
      user_select = "none"):
      span(
        ref = headingLabel,
        font_size = "11px",
        font_weight = "500"):
        text "Paragraph"
      span(
        `aria-hidden` = "true",
        font_size = "9px",
        color = tbText,
        margin_left = "4px"):
        text "\xE2\x96\xBE"
  r.appendChild(headingWrapper, headingTrigger)

  discard ui(r):
    tdiv(
      ref = headingPopup,
      `role` = "listbox",
      tabindex = "-1",
      `aria-label` = "Block type options",
      `data-spec-editor-toolbar-heading-popup` = "true",
      position = "absolute",
      left = "0",
      top = "100%",
      margin_top = "4px",
      min_width = "120px",
      padding = "4px",
      background_color = "#151D2E",
      border = "1px solid #334155",
      border_radius = "6px",
      box_shadow = "0 8px 24px rgba(0,0,0,0.28)",
      z_index = "40",
      display = "none",
      flex_direction = "column")
  r.appendChild(headingWrapper, headingPopup)
  for i in 0 ..< HeadingLabels.len:
    closureScope:
      let idx = i
      var optNode: E
      discard ui(r):
        tdiv(
          ref = optNode,
          `role` = "option",
          tabindex = "-1",
          `aria-selected` = "false",
          `data-spec-editor-toolbar-heading-option` = $idx,
          display = "flex",
          align_items = "center",
          padding = "4px 10px",
          font_size = "11px",
          font_weight = "500",
          color = "#F1F5F9",
          background_color = "transparent",
          border_radius = "4px",
          cursor = "pointer"):
          text HeadingLabels[idx]
      headingOptions[idx] = optNode
      r.appendChild(headingPopup, optNode)
  r.appendChild(root, headingWrapper)

  # Separator
  r.appendChild(root, separatorBox(r))

  # ----- Icon buttons + interleaved group separators --------------------------
  # Groups:
  #   inline marks  : Bold, Italic, Strike, InlineCode
  #   link           : Link  (its own group so the separator reads
  #                     correctly with a single-button group)
  #   lists          : Bullet, Ordered
  #   block          : Blockquote, CodeBlock, HorizontalRule
  #   history        : Undo, Redo
  let groupBoundaries = [4, 5, 7, 10]  # indices after which to insert a separator

  for idx in 0 ..< ToolbarIconButtons.len:
    closureScope:
      let i = idx
      let spec = ToolbarIconButtons[i]
      let tipText =
        if spec.shortcut.len > 0:
          spec.label & " (" & spec.shortcut & ")"
        else:
          spec.label
      var btn: E
      discard ui(r):
        tdiv(
          ref = btn,
          `role` = "button",
          tabindex = "0",
          `aria-label` = spec.label,
          `aria-pressed` = "false",
          title = tipText,
          `data-spec-editor-toolbar-button` = kindToDataAttr(spec.kind),
          display = "inline-flex",
          align_items = "center",
          justify_content = "center",
          min_width = "26px",
          height = "22px",
          padding = "0 6px",
          font_size = "11px",
          font_weight = "600",
          color = tbText,
          background_color = tbBtnBg,
          border = "1px solid " & tbBtnBorder,
          border_radius = "4px",
          cursor = "pointer",
          user_select = "none",
          white_space = "nowrap"):
          text spec.glyph
      iconButtons[i] = btn
      r.appendChild(root, btn)
    if idx in groupBoundaries:
      r.appendChild(root, separatorBox(r))

  # ----- Link popover (initially hidden) --------------------------------------
  discard ui(r):
    tdiv(
      ref = linkPopover,
      `data-spec-editor-toolbar-link-popover` = "true",
      position = "absolute",
      left = "0",
      top = "100%",
      margin_top = "4px",
      display = "none",
      flex_direction = "row",
      gap = "6px",
      padding = "8px 10px",
      background_color = "#151D2E",
      border = "1px solid #334155",
      border_radius = "6px",
      box_shadow = "0 8px 24px rgba(0,0,0,0.28)",
      z_index = "40"):
      input(
        ref = linkInput,
        `type` = "url",
        placeholder = "https://example.com",
        `data-spec-editor-toolbar-link-input` = "true",
        `aria-label` = "Link URL",
        padding = "4px 8px",
        font_size = "12px",
        color = "#F1F5F9",
        background_color = "#0F0F18",
        border = "1px solid #2D2D3A",
        border_radius = "4px",
        outline = "none",
        min_width = "240px")
      button(
        ref = linkSubmit,
        `type` = "button",
        `data-spec-editor-toolbar-link-submit` = "true",
        padding = "4px 10px",
        font_size = "11px",
        color = "#FFFFFF",
        background_color = "#7C7CDA",
        border = "1px solid #7C7CDA",
        border_radius = "4px",
        cursor = "pointer"):
        text "Apply"
      button(
        ref = linkCancel,
        `type` = "button",
        `data-spec-editor-toolbar-link-cancel` = "true",
        padding = "4px 10px",
        font_size = "11px",
        color = "#D5D6DB",
        background_color = "transparent",
        border = "1px solid #2D2D3A",
        border_radius = "4px",
        cursor = "pointer"):
        text "Cancel"
  r.appendChild(root, linkPopover)

  # --------------------------------------------------------------------------- #
  # Click dispatch.  Each icon button routes through a single proc so
  # the per-button closure stays tiny.
  # --------------------------------------------------------------------------- #
  proc dispatchButton(kind: ToolbarButtonKind) =
    when defined(js):
      let ed = capturedLookup()
      if kind == tbkLink:
        # Open the URL popover; the submit handler issues setLink.
        # Independent of editor availability so the popover open/close
        # flow is exercisable even before the editor mounts.
        openLinkDraft(capturedVm, "")
        return
      if ed.isNil:
        return
      case kind
      of tbkBold:           tiptap_lib.toggleBold(ed)
      of tbkItalic:         tiptap_lib.toggleItalic(ed)
      of tbkStrike:         tiptap_lib.toggleStrike(ed)
      of tbkInlineCode:     tiptap_lib.toggleCode(ed)
      of tbkLink:           discard  # handled above
      of tbkBulletList:     tiptap_lib.toggleBulletList(ed)
      of tbkOrderedList:    tiptap_lib.toggleOrderedList(ed)
      of tbkBlockquote:     tiptap_lib.toggleBlockquote(ed)
      of tbkCodeBlock:      tiptap_lib.toggleCodeBlock(ed)
      of tbkHorizontalRule: tiptap_lib.setHorizontalRule(ed)
      of tbkUndo:           tiptap_lib.undo(ed)
      of tbkRedo:           tiptap_lib.redo(ed)
    else:
      # Native build: keep the API surface stable but inert.  The Link
      # button still opens the popover so the headless test can exercise
      # the open/close flow without a TipTap instance.
      if kind == tbkLink:
        openLinkDraft(capturedVm, "")

  for idx in 0 ..< iconButtons.len:
    closureScope:
      let i = idx
      let spec = ToolbarIconButtons[i]
      let btn = iconButtons[i]
      let handler = proc() = dispatchButton(spec.kind)
      r.addEventListener(btn, "click", handler)

  # --------------------------------------------------------------------------- #
  # Heading dropdown wiring.
  # --------------------------------------------------------------------------- #
  let popupOpen = createSignal(false)

  proc applyHeadingOption(idx: int) =
    popupOpen.val = false
    when defined(js):
      let ed = capturedLookup()
      if ed.isNil:
        return
      case idx
      of 0: tiptap_lib.setParagraph(ed)
      of 1: tiptap_lib.toggleHeading(ed, 1)
      of 2: tiptap_lib.toggleHeading(ed, 2)
      of 3: tiptap_lib.toggleHeading(ed, 3)
      else: discard
    else:
      # Native: surface the picked option as a data-attribute so the
      # headless tests can assert routing without TipTap.
      r.setAttribute(root, "data-spec-editor-toolbar-last-heading-pick",
                     $idx)

  let triggerToggle = proc() =
    popupOpen.val = not popupOpen.val
  r.addEventListener(headingTrigger, "click", triggerToggle)

  for idx in 0 ..< headingOptions.len:
    closureScope:
      let i = idx
      let opt = headingOptions[i]
      let pick = proc() = applyHeadingOption(i)
      r.addEventListener(opt, "click", pick)

  createRenderEffect proc() =
    let open = popupOpen.val
    r.setAttribute(headingTrigger, "aria-expanded",
                   if open: "true" else: "false")
    r.setAttribute(headingPopup, "data-popup-open",
                   if open: "true" else: "false")
    r.setStyle(headingPopup, "display",
               if open: "flex" else: "none")

  # --------------------------------------------------------------------------- #
  # Link popover wiring.
  # --------------------------------------------------------------------------- #
  proc submitLink() =
    when defined(js):
      let href = r.inputValue(linkInput)
      if href.len == 0:
        closeLinkDraft(capturedVm)
        return
      let ed = capturedLookup()
      if not ed.isNil and tiptap_link.isAvailable():
        tiptap_lib.setLink(ed, href.cstring)
      closeLinkDraft(capturedVm)
    else:
      closeLinkDraft(capturedVm)

  proc cancelLink() =
    closeLinkDraft(capturedVm)

  r.addEventListener(linkSubmit, "click", submitLink)
  r.addEventListener(linkCancel, "click", cancelLink)

  when defined(js):
    # Plain JS keydown listener — reads ``event.key`` via a tiny
    # ``{.importjs.}`` proc so we avoid ``{.emit.}`` blocks.  Enter
    # submits, Escape cancels — matches the comment-popover affordance.
    proc readKey(ev: Event): cstring
      {.importjs: "(#).key".}
    let onLinkInputKey = proc(ev: Event) {.closure.} =
      let key = $readKey(ev)
      if key == "Enter":
        submitLink()
      elif key == "Escape":
        cancelLink()
    r.addEventListener(linkInput, "keydown", onLinkInputKey)
    # Mirror linkInput's value back into the VM signal as the user
    # types — the submit handler reads ``r.inputValue`` so a one-way
    # mirror is sufficient.
    let onInput = proc() =
      capturedVm.linkDraftHref.val = r.inputValue(linkInput)
    r.addEventListener(linkInput, "input", onInput)

  createRenderEffect proc() =
    let open = capturedVm.linkDraftOpen.val
    r.setAttribute(linkPopover, "data-popover-open",
                   if open: "true" else: "false")
    r.setStyle(linkPopover, "display",
               if open: "flex" else: "none")
    when defined(js):
      if open:
        # Position the popover under the Link button.  We approximate
        # by leaving it at ``left: 0; top: 100%`` of the toolbar root
        # — the design-review wave will refine if needed.
        if r.inputValue(linkInput) != capturedVm.linkDraftHref.val:
          r.setInputValue(linkInput, capturedVm.linkDraftHref.val)
        r.focus(linkInput)

  # --------------------------------------------------------------------------- #
  # Reactive active-state + canUndo / canRedo binding.
  # --------------------------------------------------------------------------- #
  createRenderEffect proc() =
    let marks = capturedVm.activeMarks.val
    let blockKind = capturedVm.activeBlockKind.val
    for i in 0 ..< iconButtons.len:
      let spec = ToolbarIconButtons[i]
      let isActive = isActiveButton(spec.kind, marks, blockKind)
      r.setAttribute(iconButtons[i], "aria-pressed",
                     if isActive: "true" else: "false")
      r.setAttribute(iconButtons[i], "data-active",
                     if isActive: "true" else: "false")
      var inline =
        if isActive:
          "background-color: " & tbBtnBgOn &
            "; color: " & tbTextOn &
            "; border-color: " & tbBtnBorderOn & ";"
        else:
          "background-color: " & tbBtnBg &
            "; color: " & tbText &
            "; border-color: " & tbBtnBorder & ";"
      inline.add " display: inline-flex; align-items: center;"
      inline.add " justify-content: center; min-width: 26px;"
      inline.add " height: 22px; padding: 0 6px; font-size: 11px;"
      inline.add " font-weight: 600; border-radius: 4px;"
      inline.add " user-select: none; white-space: nowrap;"
      # Disable Undo / Redo when the editor reports no history.
      var disabled = false
      if spec.kind == tbkUndo and not capturedVm.canUndo.val:
        disabled = true
      elif spec.kind == tbkRedo and not capturedVm.canRedo.val:
        disabled = true
      if disabled:
        inline.add " opacity: 0.4; cursor: not-allowed;"
        r.setAttribute(iconButtons[i], "aria-disabled", "true")
        r.setAttribute(iconButtons[i], "data-disabled", "true")
      else:
        inline.add " opacity: 1; cursor: pointer;"
        r.setAttribute(iconButtons[i], "aria-disabled", "false")
        r.setAttribute(iconButtons[i], "data-disabled", "false")
      r.setAttribute(iconButtons[i], "style", inline)

  # Heading dropdown — keep the label in sync with the active block.
  createRenderEffect proc() =
    let kind = capturedVm.activeBlockKind.val
    let labelText =
      case kind
      of btHeading1: "Heading 1"
      of btHeading2: "Heading 2"
      of btHeading3: "Heading 3"
      else: "Paragraph"
    r.setTextContent(headingLabel, labelText)
    r.setAttribute(root, "data-spec-editor-toolbar-active-block",
                   labelText)
    # Reflect aria-selected on each heading option for screen readers.
    for i in 0 ..< headingOptions.len:
      let optionIsActive =
        (i == 0 and kind == btParagraph) or
        (i == 1 and kind == btHeading1) or
        (i == 2 and kind == btHeading2) or
        (i == 3 and kind == btHeading3)
      r.setAttribute(headingOptions[i], "aria-selected",
                     if optionIsActive: "true" else: "false")

  r.appendChild(parent, root)

proc subscribeToEditor*(vm: SpecEditorToolbarVM;
                       editor: tiptap_lib.TipTapEditor) =
  ## CHRM-M4 — wire the live editor's ``selectionUpdate`` /
  ## ``transaction`` events into the toolbar's VM signals.  Called by
  ## ``spec_pane.nim`` once ``bootstrapEditor`` has produced the
  ## editor handle.  Idempotent only as far as ``onSelectionUpdate``
  ## allows — callers should invoke this exactly once per editor.
  when defined(js):
    if vm == nil or editor.isNil:
      return
    let capturedVm = vm
    let capturedEditor = editor
    let refreshState = proc() =
      setActiveMarks(capturedVm, collectActiveMarks(capturedEditor))
      setActiveBlockKind(capturedVm, currentBlockKind(capturedEditor))
      setCanUndo(capturedVm, tiptap_lib.canUndo(capturedEditor))
      setCanRedo(capturedVm, tiptap_lib.canRedo(capturedEditor))
    tiptap_lib.onSelectionUpdate(capturedEditor, refreshState)
    tiptap_lib.onTransaction(capturedEditor, refreshState)
    # Prime the signals with the initial state so first paint is
    # correct even before the user clicks into the editor.
    refreshState()
  else:
    discard
