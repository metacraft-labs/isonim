## Decoding style provenance into the editor's property model.
##
## This is the consumer half of `dsl/style_provenance.nim`. The DSL captures
## *authored syntax* at the only moment it exists — while the macro is looking
## at the attribute AST — and ships it as one encoded string per element. This
## module turns that string back into the editor's own vocabulary:
## `PropertyOrigin`, `originDetail`, `tokenName`, and diagnostics.
##
## ## Why this module exists at all
##
## `viewmodels.previewDomElementRef` builds the inspector's selection from
## `getComputedStyle` in the preview iframe. A computed style is a dead end for
## provenance: `padding: 12px` is the same string whether the author wrote
## `p-3`, `padding = "12px"`, or `padding: var(--space-3)`. Before this module
## every property the browser bridge produced was stamped `poInherited`,
## because that is the only honest thing to say about a value with no
## provenance. With the DSL's payload in hand there is something better to say.
##
## ## The join is by property name
##
## The DSL records the CSS property a binding sets; the computed style is keyed
## by the same CSS property name. That is the whole join. It is deliberately
## *not* a value comparison: the computed value is resolved and normalized
## (`p-3` → `12px`, `var(--surface)` → `rgb(248, 250, 252)`), so matching on
## values would fail exactly for the bindings this feature exists to find.
##
## ## Cascade order
##
## Two authored constructs can set one property — `tdiv(class = "p-4",
## padding = "20px")`. The browser resolved that already; this module only has
## to agree with it about *which one won*, so the inspector names the construct
## the user must edit. Inline style (a DSL style attribute or a `style="…"`
## declaration) beats a class, and among equals the last authored wins. That is
## the CSS rule, not a heuristic.
##
## ## Silence is the defect
##
## `Styling-Substrate-Evaluation.md` ranks a styling construct that quietly
## does nothing as one of the worst properties of the current pipeline. A
## binding that could not be resolved is therefore *not* dropped here: it
## becomes a `PropertyEditDiagnostic` that the inspector shows on selection.
## Dropping it would reproduce the exact defect the payload exists to expose.

import std/[strutils, sets]
import ../dsl/style_provenance
import ./types

export style_provenance

func propertyOriginFor*(kind: StyleBindingKind): PropertyOrigin =
  ## The editor's model of ownership for an authored construct.
  ##
  ## `sbkInlineStyle` and `sbkStyleAttr` both become `poSetStyle`: the editor's
  ## `poSetStyle` means "this element carries the value directly", which is
  ## true of `padding = "12px"` and of `style="padding: 12px"` alike, and the
  ## two are still told apart by `originDetail` (`attr:` vs `style-attr:`).
  case kind
  of sbkClassUtility: poTailwindClass
  of sbkTokenRef: poThemeToken
  of sbkStyleAttr, sbkInlineStyle: poSetStyle
  of sbkConstant: poConstant
  of sbkUnresolved: poInherited

func cascadeRank(binding: StyleBinding): int =
  ## Inline beats class, which is what the browser did to produce the computed
  ## value this binding is about to explain.
  if binding.detail.startsWith("class:"): 1 else: 2

func winningBinding*(bindings: seq[StyleBinding];
                     property: string): StyleBinding =
  ## The authored construct that actually set `property`, or a zero
  ## `StyleBinding` (`property.len == 0`) when nothing authored it — which is
  ## the honest answer for a property that really is inherited or a UA default.
  var bestRank = 0
  for b in bindings:
    if b.kind == sbkUnresolved:
      continue
    if cmpIgnoreCase(b.property, property) != 0:
      continue
    let rank = b.cascadeRank()
    if rank >= bestRank:
      bestRank = rank
      result = b

func withStyleProvenance*(prop: PropertyInfo;
                          bindings: seq[StyleBinding]): PropertyInfo =
  ## Restamp one computed-style property with its authored provenance.
  ##
  ## `value` is deliberately left alone. The computed value is what the element
  ## actually renders and what every editing path already round-trips; the
  ## authored value is preserved separately, in `originDetail`, so the inspector
  ## can show `12px (p-3)` without the edit path suddenly having to write back
  ## a utility class it was not asked to write.
  result = prop
  let binding = bindings.winningBinding(prop.name)
  if binding.property.len == 0:
    return
  result.origin = propertyOriginFor(binding.kind)
  result.originDetail = binding.detail
  if binding.token.len > 0:
    result.tokenName = binding.token
  # A value that came from a class or a token is not this element's to rewrite
  # in place; the inspector must route the edit to the class or token instead.
  # `directStyleAllowed` is the flag the edit path already consults for that.
  if binding.kind in {sbkClassUtility, sbkTokenRef}:
    result.directStyleAllowed = false
    # And it is not this element's FILE either. The property was captured off
    # the rendered element, so it arrived carrying that element's source
    # location -- but a value set by `.tagline` lives in the stylesheet, not
    # in the page that happens to use the class.
    #
    # Leaving the element's path on it misleads twice: the Source section
    # names a file that does not contain the declaration, and the edit
    # pipeline refuses the plan outright, because it checks the plan's file
    # against the file the project's schema says owns the property and sees
    # two different paths.
    #
    # Cleared rather than corrected, because provenance genuinely does not
    # know where the class is defined -- the DSL records WHICH class set the
    # value, and which file that class lives in is the project's to answer.
    # An empty file lets the schema entry supply it.
    result.sourceFile = ""
    result.sourceLine = 0

func withStyleProvenance*(props: seq[PropertyInfo];
                          encoded: string): seq[PropertyInfo] =
  ## Restamp a whole property list from one element's encoded payload. An
  ## empty payload returns the list untouched, so every surface that has no
  ## provenance (a hand-built story fixture, a non-IsoNim preview document)
  ## behaves exactly as it did before.
  if encoded.len == 0:
    return props
  let bindings = decodeStyleBindings(encoded)
  if bindings.len == 0:
    return props
  for prop in props:
    result.add prop.withStyleProvenance(bindings)

func authoredOnlyProperties*(props: seq[PropertyInfo];
                             encoded: string;
                             schemaPrefix = ""): seq[PropertyInfo] =
  ## The properties the AUTHOR set that the computed-style capture never asked
  ## for, as `PropertyInfo`s carrying their authored value and provenance.
  ##
  ## The DOM selection bridge reads a FIXED list of computed properties off
  ## the preview -- 17 of them. The DSL, by contrast, records provenance for
  ## whatever the author actually wrote, and the inspector renders rows for
  ## far more than 17. So a token bound to `letter-spacing`, `gap` or the
  ## `font` shorthand had provenance recorded, had a row to show it in, and
  ## still could not light the linked chip: nothing in the property list was
  ## named that, so `winningBinding` never matched.
  ##
  ## Measured on the grip pilot: `p.positioning` binds both `font` and
  ## `color` to `sys` tokens and only `color` -- the one in the 17 -- showed a
  ## chip. Widening the capture list would fix that pair and lose the next
  ## property someone binds; deriving the list from what the author wrote
  ## cannot fall behind, because it IS what the author wrote.
  ##
  ## The value is the AUTHORED one (`var(--sys-type-lead)`), not a computed
  ## one, and it is honest about that: no computed value was captured for
  ## these, and inventing one by re-reading the iframe here would put a second
  ## style-reading path next to the bridge's.
  if encoded.len == 0:
    return @[]
  var seen = initHashSet[string]()
  for prop in props:
    seen.incl prop.name.toLowerAscii()
  for binding in decodeStyleBindings(encoded):
    if binding.kind == sbkUnresolved or binding.property.len == 0:
      continue
    let key = binding.property.toLowerAscii()
    if key in seen:
      continue
    seen.incl key
    var prop = PropertyInfo(
      name: binding.property,
      value: binding.value,
      origin: propertyOriginFor(binding.kind),
      originDetail: binding.detail,
      # Same reason as the computed path: without a schema key the project's
      # adapter cannot tell which element's rule an edit belongs to.
      schemaKey: (if schemaPrefix.len > 0: schemaPrefix & "." & binding.property
                  else: ""),
      directStyleAllowed: binding.kind notin {sbkClassUtility, sbkTokenRef})
    if binding.token.len > 0:
      prop.tokenName = binding.token
    result.add prop

func isTokenBound*(prop: PropertyInfo): bool =
  ## The question the inspector's linked chip asks: binding, or literal?
  prop.origin == poThemeToken and prop.tokenName.len > 0

func unresolvedStyleBindings*(encoded: string): seq[StyleBinding] =
  ## The filter is spelled out rather than borrowed from
  ## `dsl/style_binding.unresolvedBindings`: that module imports `dsl/tailwind`,
  ## which `staticRead`s the class index at compile time. The editor must be
  ## able to read provenance without dragging the DSL's compile-time machinery
  ## into its import graph -- which is the reason `dsl/style_provenance` was
  ## split out dependency-light in the first place.
  if encoded.len == 0:
    return @[]
  for binding in decodeStyleBindings(encoded):
    if binding.kind == sbkUnresolved:
      result.add binding

func styleBindingMessage*(binding: StyleBinding): string =
  ## The sentence the inspector shows for a binding that resolved to nothing.
  ## It names the construct *as authored* — `class:p-4`, not `padding` — because
  ## the authored text is what the user has to go and change.
  let what =
    if binding.detail.len > 0: binding.detail
    else: "a styling attribute"
  if binding.note.len > 0:
    what & " resolves to no properties: " & binding.note
  else:
    what & " resolves to no properties."

func styleBindingDiagnostics*(encoded, file: string;
                              line: int): seq[PropertyEditDiagnostic] =
  ## Requirement 8 of `Styling-Substrate-Evaluation.md`: a styling construct
  ## that does nothing must not do it quietly. 16% of the Tailwind classes in
  ## this workspace currently contribute nothing on a native backend and say
  ## so nowhere; these are the diagnostics that end that.
  for binding in unresolvedStyleBindings(encoded):
    result.add PropertyEditDiagnostic(
      kind: pedUnresolvedStyleBinding,
      message: binding.styleBindingMessage(),
      file: file,
      line: line,
      property: binding.property)

const inspectorEditableCssProperties* = [
  # Position / Layout
  "left", "top", "transform", "width", "height", "display", "position",
  "gap", "overflow",
  "padding", "padding-top", "padding-right", "padding-bottom", "padding-left",
  "margin", "margin-top", "margin-right", "margin-bottom", "margin-left",
  # Appearance / Fill / Stroke / Effects
  "opacity", "mix-blend-mode", "background-color", "color", "box-shadow",
  "border-radius", "border-top-left-radius", "border-top-right-radius",
  "border-bottom-right-radius", "border-bottom-left-radius",
  "border-color", "border-width", "border-style",
  # Typography
  "font", "font-family", "font-weight", "font-size", "line-height",
  "letter-spacing", "text-align", "text-decoration", "text-transform",
  "list-style-type", "text-wrap"
]
  ## Every CSS property the inspector renders a row for.
  ##
  ## ONE list, read by both sides of the preview boundary: the injected
  ## bridge reads these off `getComputedStyle` and the editor turns them into
  ## the element's property list. Before it existed the bridge captured a
  ## fixed 17 while the panel rendered 51 rows, so two thirds of the panel
  ## edited a property the selection did not have -- and the commit refused
  ## with "The selected element does not expose margin-bottom", which reads
  ## like a bug in the element rather than a gap in the capture.
  ##
  ## Adding a row to a section means adding its property here. That is a
  ## second place to remember, and the alternative -- deriving it from the
  ## section widgets -- would mean the preview bridge importing the whole
  ## inspector view layer to render a string.

func computedStyleProperties*(props: seq[PropertyInfo];
                              encoded: string;
                              schemaPrefix = ""): seq[PropertyInfo] =
  ## Decode the bridge's `prop=value;prop=value` capture into the properties
  ## the element does not already carry.
  ##
  ## Appended rather than merged: anything already in `props` arrived either
  ## from the named capture or from the author's own provenance, and both are
  ## better sources than a bare computed value -- the first because it is
  ## already restamped, the second because it knows what wrote it.
  if encoded.len == 0:
    return @[]
  var seen = initHashSet[string]()
  for prop in props:
    seen.incl prop.name.toLowerAscii()
  for record in encoded.split(';'):
    if record.len == 0:
      continue
    let sep = record.find('=')
    if sep <= 0:
      continue
    let name = record[0 ..< sep]
    let value = record[sep + 1 .. ^1]
    if value.len == 0 or name.toLowerAscii() in seen:
      continue
    seen.incl name.toLowerAscii()
    result.add PropertyInfo(
      name: name,
      value: value,
      # `poInherited` is the honest origin for a computed value with no
      # provenance: something set it, and this capture cannot say what.
      origin: poInherited,
      originDetail: "computed:" & name,
      # The schema key identifies the element to the project's edit adapter,
      # and without it the adapter cannot tell WHICH element's rule to edit.
      # The named capture sets it; this path must too, or every property that
      # only this capture provides is uneditable -- which was two thirds of
      # the inspector.
      schemaKey: (if schemaPrefix.len > 0: schemaPrefix & "." & name else: ""),
      directStyleAllowed: true)
