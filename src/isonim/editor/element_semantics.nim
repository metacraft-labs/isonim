## What KIND of thing is selected, in one place.
##
## The inspector asks this question in several voices -- the selection
## header's label, which property the Fill section edits, which sections are
## worth showing at all -- and the answers have to agree. When they do not,
## the editor contradicts itself on screen: a paragraph labelled **Text**
## whose Fill section offers to edit its `background-color`, which is
## transparent, and so reports "nothing here" about an element that plainly
## has a colour.
##
## That is not hypothetical; it is what the grip pilot showed. `p.positioning`
## binds `color` to `sys.color.text.primary`, and the Fill section rendered
## its empty state because it only ever looked at `background-color`.
##
## Kept dependency-light on purpose: it is pure string semantics over an
## `ElementRef.tag`, so every surface can import it without dragging the
## inspector's view layer or the viewmodel graph behind it.

import std/strutils
import ./types

type
  ElementKind* = enum
    ## Coarse editing semantics, not a DOM taxonomy. Two tags share a kind
    ## when the inspector should treat them the same way.
    ekUnknown
    ekGroup      ## a container: children are the content
    ekText       ## the element's own text is the content
    ekButton
    ekLink
    ekImage
    ekVector
    ekField      ## form input of some kind
    ekList
    ekTable
    ekForm
    ekFrame

func elementKind*(tag: string): ElementKind =
  ## Classify a tag. Unknown tags are `ekUnknown` rather than being forced
  ## into `ekGroup`: a wrong confident answer is worse than an honest
  ## "I don't know", because the sections keyed off this would then hide
  ## controls that the element really does need.
  case tag.toLowerAscii()
  of "div", "section", "main", "article", "aside", "nav", "header",
      "footer": ekGroup
  of "span", "p", "h1", "h2", "h3", "h4", "h5", "h6", "label",
      "strong", "em", "small", "code", "pre": ekText
  of "button": ekButton
  of "a": ekLink
  of "img": ekImage
  of "svg": ekVector
  of "input", "textarea", "select": ekField
  of "ul", "ol", "li": ekList
  of "table", "thead", "tbody", "tr", "td", "th": ekTable
  of "form": ekForm
  of "iframe": ekFrame
  else: ekUnknown

func selectionDisplayName*(tag: string): string =
  ## The selection-header label. Unknown tags fall through to a capitalised
  ## echo of the tag rather than a generic "Element", so a tag this module
  ## has not been taught still identifies itself.
  let lower = tag.toLowerAscii()
  case lower.elementKind()
  of ekGroup: "Group"
  of ekText: "Text"
  of ekButton: "Button"
  of ekLink: "Link"
  of ekImage: "Image"
  of ekVector: "Vector"
  of ekList: "List"
  of ekTable: "Table"
  of ekForm: "Form"
  of ekFrame: "Frame"
  of ekField:
    case lower
    of "textarea": "Text area"
    of "select": "Select"
    else: "Input"
  of ekUnknown:
    if lower.len > 0: lower[0..0].toUpperAscii() & lower[1..^1] else: ""

func fillTargetProperty*(tag: string): string =
  ## Which CSS property the **Fill** section edits for this kind of element.
  ##
  ## Figma's model, which this inspector is shaped after: a text layer's fill
  ## IS its text colour. Reading `background-color` for a paragraph asks about
  ## a property that is transparent on almost every paragraph ever written,
  ## and so reports an empty section for an element whose colour is the most
  ## likely thing a designer came here to change -- and, on a design-system
  ## project, the most likely thing to carry a token.
  if tag.elementKind() == ekText: "color" else: "background-color"

func defaultExpandedSections*(tag: string; positioned: bool):
    seq[InspectorSection] =
  ## Which inspector sections open by default for this kind of element.
  ##
  ## The catalogue mounts all twelve sections for everything, and before this
  ## they all opened the same way regardless of what was selected. That is the
  ## opposite of adaptive: selecting a paragraph opened **Position** on a
  ## static-flow element -- three fields reading `0` that mean nothing and
  ## cannot be acted on -- while **Typography**, where that paragraph's font
  ## and letter-spacing tokens live, stayed shut.
  ##
  ## "Default" is the operative word. A section the user has opened or closed
  ## themselves is never re-decided here; `applyKindDefaultExpansion` keeps
  ## that set and consults this only for sections the user has not touched.
  ##
  ## Sections are not HIDDEN by kind, only closed. Typography genuinely
  ## applies to a `div` -- its children inherit -- so hiding it would be
  ## wrong, and a control nobody can find is a worse failure than a control
  ## that starts collapsed.
  result =
    case tag.elementKind()
    of ekText:
      @[isFill, isTypography, isLayout]
    of ekButton, ekLink, ekField:
      @[isFill, isTypography, isLayout, isStroke]
    of ekImage, ekVector:
      @[isLayout, isAppearance, isEffects]
    of ekGroup, ekFrame, ekList, ekTable, ekForm:
      @[isLayout, isFill, isAppearance]
    of ekUnknown:
      @[isLayout, isFill]
  # Position earns its place by being used. `position: static` is the default
  # for almost every element on a page, and for those the section's X / Y /
  # rotation are not merely zero -- they are inapplicable.
  if positioned:
    result.insert(isPosition, 0)
