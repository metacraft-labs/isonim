## isonim/theming/dtcg -- the W3C DTCG token loader and alias resolver.
## Dual-target where the code is (`loadTokensFromStrings`); `loadTokens`
## reads files and so runs on the C target only.
##
## Moved unchanged from isonim-docs' resolver suite with the module. It
## proves the resolver (a) merges a `brand`/`alias`/`mapped` layering,
## (b) resolves a 3-level `{alias}` chain across those layers down to the
## concrete primitive, (c) errors on a dangling reference, and (d) errors
## on a cyclic reference -- and that the required sibling design-system
## files resolve a real 3-level mapped->alias->brand chain to its real hex
## primitive. Missing runtime fixtures fail the suite. No test doubles.

import std/[unittest, os]
import isonim/theming/dtcg

const
  # A hermetic brand/alias/mapped layering in the exact DTCG shape the
  # real design system uses: `{"$type","$value"}` leaves, `{dotted.path}`
  # aliases, and cross-layer references (alias -> brand, mapped -> alias).
  brandJson = """
  {
    "colors": {
      "grey": {
        "50":  { "$type": "color", "$value": "#f3f3f3" },
        "900": { "$type": "color", "$value": "#111111" }
      },
      "base": {
        "blue": { "$type": "color", "$value": "#0055ff" }
      }
    },
    "scale": {
      "0": { "$type": "number", "$value": 0 },
      "4": { "$type": "number", "$value": 16 }
    }
  }
  """
  aliasJson = """
  {
    "colors": {
      "neutral": {
        "50": { "$type": "color", "$value": "{colors.grey.50}" }
      },
      "brand": {
        "primary": { "$type": "color", "$value": "{colors.base.blue}" }
      }
    }
  }
  """
  mappedJson = """
  {
    "colors": {
      "ui": {
        "text":   { "primary": { "$type": "color", "$value": "{colors.neutral.50}" } },
        "accent": { "$type": "color", "$value": "{colors.brand.primary}" }
      }
    }
  }
  """

suite "isonim/theming/dtcg -- loader and alias resolver":

  test "merges layers and resolves a 3-level mapped->alias->brand chain to the concrete primitive":
    let ts = loadTokensFromStrings([brandJson, aliasJson, mappedJson])

    # colors.ui.text.primary  -> {colors.neutral.50}   (mapped -> alias)
    #                          -> {colors.grey.50}      (alias -> brand)
    #                          -> #f3f3f3               (concrete)
    check ts.resolve("colors.ui.text.primary") == "#f3f3f3"

    # A second independent 3-level chain through a different primitive,
    # to prove it isn't hard-coded to one path.
    check ts.resolve("colors.ui.accent") == "#0055ff"

    # Intermediate hops resolve too (alias -> brand, 2 levels).
    check ts.resolve("colors.neutral.50") == "#f3f3f3"
    check ts.resolve("colors.brand.primary") == "#0055ff"

    # A concrete primitive resolves to itself.
    check ts.resolve("colors.grey.900") == "#111111"

    # Non-color scalars resolve and stringify (number token).
    check ts.resolve("scale.4") == "16"
    check ts.resolve("scale.0") == "0"

  test "exposes a typed category for the resolved token":
    let ts = loadTokensFromStrings([brandJson, aliasJson, mappedJson])
    check ts.categoryOf("colors.ui.accent") == tcColor
    check ts.categoryOf("scale.4") == tcNumber
    let rt = ts.resolveToken("colors.ui.text.primary")
    check rt.category == tcColor
    check rt.value == "#f3f3f3"
    check rt.key == "colors.ui.text.primary"

  test "errors on a dangling reference":
    # mapped points at colors.neutral.50, but the alias layer is absent, so
    # the chain hits a token that does not exist.
    let ts = loadTokensFromStrings([brandJson, mappedJson])
    check ts.contains("colors.ui.text.primary")   # the token itself exists
    check not ts.contains("colors.neutral.50")     # its target does not
    expect TokenError:
      discard ts.resolve("colors.ui.text.primary")

  test "errors on a direct dangling alias to a missing path":
    let bad = """
    { "a": { "$type": "color", "$value": "{does.not.exist}" } }
    """
    let ts = loadTokensFromStrings([bad])
    expect TokenError:
      discard ts.resolve("a")

  test "errors on a cyclic reference":
    let cyclic = """
    {
      "a": { "$type": "color", "$value": "{b}" },
      "b": { "$type": "color", "$value": "{c}" },
      "c": { "$type": "color", "$value": "{a}" }
    }
    """
    let ts = loadTokensFromStrings([cyclic])
    expect TokenError:
      discard ts.resolve("a")

  test "resolves a real design-system 3-level chain":
    # The declared execute-edge inputs are the real sibling token files.
    # Missing prerequisites fail the test instead of turning it into a skip.
    # The generic loader consumes the REAL DTCG files unchanged and resolves a
    # real mapped -> alias -> brand chain to its real primitive.
    let dsRoot = "../codetracer-design-system"
    let brand = dsRoot / "brand" / "brand.json"
    let aliasF = dsRoot / "alias" / "alias.json"
    let mapped = dsRoot / "mapped" / "mapped.json"
    require fileExists(brand) and fileExists(aliasF) and fileExists(mapped)
    let ts = loadTokens(brand, aliasF, mapped)
    # colors.ui.text.primary.headings
    #   -> {colors.neutral.50} -> {colors.grey.50} -> #f3f3f3
    check ts.resolve("colors.ui.text.primary.headings") == "#f3f3f3"
    check ts.categoryOf("colors.ui.text.primary.headings") == tcColor
    # The merged set carries hundreds of tokens from all three layers.
    check ts.len > 100
