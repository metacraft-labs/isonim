## metacraft-theme M2 deliverable verification: the CodeTracer docs theme
## honours the framework's `--docs-*` contract with no dangling variables,
## and carries the fidelity-critical WebFlow treatments.
##
## Drives the REAL theme artifacts this site ships:
##   * the emitted token layer (`theme_tokens.metacraftDocsTokenLayer`
##     resolved through the real `codetracer-design-system` token set), and
##   * the composed stylesheet the build serves -- the framework's bundled
##     default (`isonim-docs/assets/style.css`) plus this site's small
##     `assets/overrides.css` (see `composedConsumerCss`),
## exactly as `build_site.copyAssetsVerbatim` prepends the token layer onto the
## composed base at build time.
##
## Assertions are genuine: every `--docs-*` the framework components
## consume must be DEFINED by the emitted token layer (a dangling theme
## variable would render an unstyled component); every `var(--docs-*)` the
## consumer stylesheet references must resolve to a definition; and the
## signature CodeTracer treatments (underlined headings, warm canvas + warm
## `#E7E5E1` hover, 20rem sidebar, 10px search field, 6px code blocks,
## self-hosted Geist `@font-face`, blue-500 focus/admonition bindings) must
## be present.

import std/[unittest, os, strutils, sets]
import ../src/theme_tokens
import core/docs_tokens

const usersDir = currentSourcePath().parentDir().parentDir()
const frameworkCssPath = usersDir / "../../.." / "isonim-docs" / "assets" / "style.css"
const overridesPath = usersDir / "assets" / "overrides.css"
  ## This site no longer ships a full `style.css`: the structural RULES come
  ## from the framework's bundled default stylesheet, plus this site's small
  ## `assets/overrides.css`. The "consumer stylesheet" the build actually
  ## composes and serves is therefore the framework default + these overrides --
  ## which is exactly what these assertions validate.

proc composedConsumerCss(): string =
  ## The stylesheet this site actually ships: framework default + site overrides
  ## (mirrors `build_site.copyAssetsVerbatim`'s base + overrides composition).
  result = readFile(frameworkCssPath)
  if fileExists(overridesPath):
    result.add("\n" & readFile(overridesPath))

proc stripCssComments(css: string): string =
  ## Removes `/* ... */` comments so prose mentioning `--docs-*:` (e.g. this
  ## theme's own file headers) can't be mistaken for a real declaration.
  result = newStringOfCap(css.len)
  var i = 0
  while i < css.len:
    if css[i] == '/' and i + 1 < css.len and css[i + 1] == '*':
      let close = css.find("*/", i + 2)
      if close < 0: break
      i = close + 2
    else:
      result.add css[i]
      inc i

proc referencedDocsVars(css: string): HashSet[string] =
  ## Every `--docs-*` name appearing inside a `var(...)` reference.
  result = initHashSet[string]()
  const marker = "var(--docs-"
  var i = 0
  while true:
    let idx = css.find(marker, i)
    if idx < 0: break
    let nameStart = idx + "var(".len
    var j = nameStart
    while j < css.len and css[j] notin {')', ',', ' '}: inc j
    result.incl css[nameStart ..< j]
    i = j

proc definedDocsVars(css: string): HashSet[string] =
  ## Every `--docs-*` name given a definition (`--docs-x: value;`). A
  ## definition is a `--docs-` token immediately followed (after the name)
  ## by a colon; a `var(--docs-x)` reference is NOT (it is followed by `)`
  ## or `,`).
  result = initHashSet[string]()
  const marker = "--docs-"
  var i = 0
  while true:
    let idx = css.find(marker, i)
    if idx < 0: break
    # Skip if this is the tail of a `var(--docs-...` reference.
    let isRef = idx >= 4 and css[idx - 4 ..< idx] == "var("
    var j = idx
    while j < css.len and css[j] notin {':', ')', ',', ' ', ';', '\n'}: inc j
    if not isRef and j < css.len and css[j] == ':':
      result.incl css[idx ..< j]
    i = j + 1

suite "CodeTracer docs theme -- framework --docs-* contract (metacraft-theme M2)":

  let tokensCss = emitTokensCss(metacraftDocsTokenLayer(), designSystemTokens())
  let consumerCss = stripCssComments(composedConsumerCss())
  let frameworkCss = stripCssComments(readFile(frameworkCssPath))
  let combinedCss = tokensCss & "\n" & consumerCss

  test "the emitted token layer defines EVERY --docs-* the framework consumes":
    let consumed = referencedDocsVars(frameworkCss)
    let defined = definedDocsVars(tokensCss)
    check consumed.len >= 40   # the framework contract is ~44 vars
    var missing: seq[string] = @[]
    for name in consumed:
      if name notin defined:
        missing.add name
    check missing.len == 0
    if missing.len > 0:
      checkpoint("token layer missing framework vars: " & missing.join(", "))

  test "no dangling var: every var(--docs-*) the consumer stylesheet uses is defined":
    let referenced = referencedDocsVars(combinedCss)
    let defined = definedDocsVars(combinedCss)
    check referenced.len > 0
    var dangling: seq[string] = @[]
    for name in referenced:
      if name notin defined:
        dangling.add name
    check dangling.len == 0
    if dangling.len > 0:
      checkpoint("dangling theme vars: " & dangling.join(", "))

  test "the consumer stylesheet defines no --docs-* itself (values come from the token layer)":
    # The RULES file must not re-declare token VALUES; every definition
    # lives in the emitted layer. (Only `var(...)` references are allowed.)
    check definedDocsVars(consumerCss).len == 0

suite "CodeTracer docs theme -- fidelity-critical values (metacraft-theme M2)":

  let tokensCss = emitTokensCss(metacraftDocsTokenLayer(), designSystemTokens())
  let consumerCss = stripCssComments(composedConsumerCss())

  test "warm canvas: --docs-bg #f0eeea light, #161719 dark (in both dark blocks)":
    check "--docs-bg: #f0eeea;" in tokensCss
    check tokensCss.count("--docs-bg: #161719;") == 2  # toggle + media query
    check tokensCss.count("--docs-bg: #f0eeea;") == 1  # light :root only

  test "self-hosted Geist @font-face referenced as url(/assets/...)":
    check "@font-face" in tokensCss
    check "\"Geist\"" in tokensCss
    check "url(/assets/fonts/Geist-Variable.woff2)" in tokensCss
    check "--docs-font-sans: \"Geist\"" in tokensCss

  test "bkToken bindings resolved through the real design-system token set":
    # blue.500 -> #3b82f6 for the focus ring AND the note admonition border;
    # a wrong key would have raised TokenError at emit time.
    check "--docs-focus-ring: #3b82f6;" in tokensCss
    check "--docs-admonition-note-border: #3b82f6;" in tokensCss
    check "--docs-admonition-tip-border: #22c55e;" in tokensCss     # green.500
    check "--docs-admonition-warning-border: #f59e0b;" in tokensCss # amber.500
    check "--docs-admonition-danger-border: #ef4444;" in tokensCss  # red.500

  test "radii vocabulary present in the token layer (4/6/8/10/999px)":
    check "--docs-radius-sm: 4px;" in tokensCss
    check "--docs-radius-code: 6px;" in tokensCss
    check "--docs-radius-md: 8px;" in tokensCss
    check "--docs-radius-lg: 10px;" in tokensCss
    check "--docs-radius-pill: 999px;" in tokensCss

  test "warm hover surface #E7E5E1 (light) bound to --docs-bg-raised":
    check "--docs-bg-raised: #E7E5E1;" in tokensCss

  test "UNDERLINED content headings: .docs-md-heading gets a bottom rule":
    let hIdx = consumerCss.find(".docs-md-heading {")
    check hIdx >= 0
    let blk = consumerCss[hIdx ..< consumerCss.find('}', hIdx)]
    check "border-bottom: 1px solid var(--docs-border);" in blk
    check "padding-bottom: 0.25em;" in blk

  test "sidebar: 20rem width column with the warm raised hover surface":
    check "--docs-sidebar-width: 20rem;" in tokensCss
    let sIdx = consumerCss.find(".docs-nav-sidebar {")
    check sIdx >= 0
    let blk = consumerCss[sIdx ..< consumerCss.find('}', sIdx)]
    check "max-width: var(--docs-sidebar-width);" in blk
    check "border-right: 1px solid var(--docs-border);" in blk
    # the active/hover item paints the warm raised surface, not the accent.
    check "background: var(--docs-bg-raised);" in consumerCss

  test "search field: 38px tall, 10px radius, blue focus ring":
    let idx = consumerCss.find(".docs-search-input {")
    check idx >= 0
    let blk = consumerCss[idx ..< consumerCss.find('}', idx)]
    check "height: 38px;" in blk
    check "border-radius: var(--docs-radius-lg);" in blk
    check "box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.15);" in consumerCss

  test "code: pre uses the 6px radius + #f6f8fa surface, inline the #f1f5f9 tint":
    check "--docs-code-bg: #f6f8fa;" in tokensCss
    check "--docs-code-inline-bg: #f1f5f9;" in tokensCss
    # Anchor to the standalone rule, not the nested
    # `.docs-md-code-block .docs-md-code-fence` reset.
    let idx = consumerCss.find("\n.docs-md-code-fence {")
    check idx >= 0
    let blk = consumerCss[idx ..< consumerCss.find('}', idx)]
    check "border-radius: var(--docs-radius-code);" in blk
    check "background: var(--docs-code-bg);" in blk

  test "tables: #e5e7eb border, 8px/12px cell padding":
    check "--docs-border: #e5e7eb;" in tokensCss
    check "padding: 8px 12px;" in consumerCss

  test "paragraph rhythm: 2.5rem bottom margin":
    let idx = consumerCss.find(".docs-md-paragraph {")
    check idx >= 0
    let blk = consumerCss[idx ..< consumerCss.find('}', idx)]
    check "margin: 0 0 2.5rem;" in blk

  test "dark chrome inversion via filter: invert(1)":
    check "filter: invert(1);" in consumerCss

  test "M3 (Gap A): the logo is a real .docs-logo <img>, not the M2 ::before stopgap":
    check ".docs-logo {" in consumerCss
    check ".docs-title::before" notin consumerCss
    # dark-mode inversion moved from the ::before mark onto the real image.
    check "[data-theme=\"dark\"] .docs-logo," in consumerCss

  test "M3 (Gap D): important=violet.500 / caution=red.500 bound + styled distinctly":
    check "--docs-admonition-important-border: #8b5cf6;" in tokensCss  # violet.500
    check "--docs-admonition-caution-border: #ef4444;" in tokensCss    # red.500
    check ".docs-md-admonition-important {" in consumerCss
    check ".docs-md-admonition-caution {" in consumerCss
