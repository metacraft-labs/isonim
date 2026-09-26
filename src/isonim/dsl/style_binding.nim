## Resolving an authored attribute into style bindings.
##
## This is the producer the editor was missing. It runs in the `ui` macro, on
## the attribute AST, before anything has been resolved to a value — which is
## the only moment at which `p-3`, `padding = "12px"` and
## `style="padding: var(--space-3)"` are still distinguishable.
##
## Everything here is an ordinary `func` rather than a `{.compileTime.}` one
## so the same code runs in the macro and in a unit test. Nothing references
## it at runtime, so nothing is emitted.
##
## ## The class index
##
## Resolving a class token to properties needs an index. Today the only one
## in the tree is the Tailwind extract (`build/tailwind-styles.json`, via
## `dsl/tailwind.nim`), so that is what is consulted. The index is a
## parameter of the design, not a commitment to Tailwind: a vocabulary
## generated from the project's DTCG tokens would plug in here unchanged, and
## would additionally keep its `var()` indirection, which this module already
## promotes to `sbkTokenRef`.
##
## ## Silence is the defect
##
## `expandTailwindClasses` documents that "unrecognized classes are silently
## skipped", and that silence is exactly what
## `Styling-Substrate-Evaluation.md` §7.4 ranks as the second-worst thing
## about the current pipeline. Nothing here is skipped: a class that does not
## resolve produces an `sbkUnresolved` record naming the class and saying
## why, and that record reaches the inspector. Under
## `-d:isonimStyleBindingStrict` it is a compile error instead.

import std/strutils
import ./style_provenance
import ./tailwind

const styleBindingStrict* = defined(isonimStyleBindingStrict)
  ## Opt-in: turn an unresolvable class into a compile error.
  ##
  ## Not the default, and the reason is measured rather than squeamish: no
  ## project in this workspace styles with an indexed vocabulary. `grip`
  ## writes `class="panel"` against a bespoke stylesheet, and
  ## `isonim-examples` has 3 Tailwind-shaped classes out of 307. Erroring by
  ## default would fail every build in the workspace on day one, which is how
  ## a diagnostic gets switched off rather than fixed. The record is always
  ## produced; this flag only decides whether it also stops the build.

func classIndexLoaded*(): bool =
  ## Whether any class -> properties index is available to this compilation.
  hasTailwindStyles

func lookupClass*(cls: string): seq[tuple[prop, val: string]] =
  parseTailwindClass(cls)

func constantOrTokenBinding(property, value, detail: string;
    literalKind: StyleBindingKind): StyleBinding =
  let token = tokenReferenceIn(value)
  if token.len > 0:
    StyleBinding(property: property, value: value, kind: sbkTokenRef,
                 detail: detail, token: token)
  else:
    StyleBinding(property: property, value: value, kind: literalKind,
                 detail: detail)

func classBindings*(classStr: string): seq[StyleBinding] =
  ## One or more records per class token. A class that resolves contributes a
  ## record per CSS property it sets; a class that does not contributes one
  ## record saying so.
  for cls in classStr.splitWhitespace():
    let styles = lookupClass(cls)
    if styles.len == 0:
      result.add StyleBinding(
        kind: sbkUnresolved,
        detail: "class:" & cls,
        note:
          if classIndexLoaded():
            "class is not in the compile-time class index, so it contributes " &
            "no properties on backends without a CSS engine"
          else:
            "no class index is loaded for this build, so no class can be " &
            "resolved to properties")
      continue
    for (prop, val) in styles:
      result.add constantOrTokenBinding(prop, val, "class:" & cls,
                                        sbkClassUtility)

func styleAttrBinding*(cssName, value: string): StyleBinding =
  ## A DSL style-property attribute — `padding = "12px"`, which the macro
  ## turns into `setStyle`. `poSetStyle` is the editor's name for this.
  constantOrTokenBinding(cssName, value, "attr:" & cssName, sbkStyleAttr)

func inlineStyleBindings*(styleStr: string): seq[StyleBinding] =
  ## Declarations inside a literal `style="a: b; c: d"`.
  for decl in styleStr.split(';'):
    let text = decl.strip()
    if text.len == 0:
      continue
    let colon = text.find(':')
    if colon <= 0:
      result.add StyleBinding(kind: sbkUnresolved, detail: "style-attr:" & text,
        note: "inline style declaration has no `property: value` form")
      continue
    let prop = text[0 ..< colon].strip()
    let val = text[colon + 1 .. ^1].strip()
    result.add constantOrTokenBinding(prop, val, "style-attr:" & prop,
                                      sbkInlineStyle)

func dynamicBinding*(detail, what: string): StyleBinding =
  ## A styling attribute whose value is an expression. The macro sees an AST
  ## node, not a string, so there is nothing to resolve — and saying nothing
  ## would make it indistinguishable from an element with no styling at all.
  StyleBinding(kind: sbkUnresolved, detail: detail,
    note: what & " is computed at runtime, so its provenance cannot be " &
          "recovered at compile time")

func unresolvedBindings*(bindings: seq[StyleBinding]): seq[StyleBinding] =
  for b in bindings:
    if b.kind == sbkUnresolved:
      result.add b
