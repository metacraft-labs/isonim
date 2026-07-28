## isonim/docs/users -- Metacraft / CodeTracer docs theme: the DATA half.
##
## The `--docs-*` design tokens are NO LONGER defined here. They live in the
## single shared **CodeTracer docs design system**:
##
##   codetracer-design-system/docs/codetracer-docs.tokens.json
##
## the one source of truth every Metacraft docs site (this one,
## isonim-docs/site, codetracer/docs/book-isonim) and the design-system editor
## consume, so a tweak there updates all sites on rebuild. This module only
## LOADS it (via the framework's `core/docs_tokens.loadDocsTokenLayer`) and
## supplies the brand `TokenSet` that its `bkToken` bindings (focus ring,
## admonition severity borders) resolve against. The RULES half -- the CSS that
## USES these variables -- lives in `assets/style.css`.
##
## The design system is an INDEPENDENT lineage from the canonical brand tokens
## (Geist font, blue #4168cc accent, warm #f0eeea canvas); every divergence is
## catalogued in codetracer-design-system/docs/DESIGN-DIVERGENCES.md so the
## design team can decide whether to reconcile. Edit the tokens THERE (or via
## the editor), not here.

import std/os
import core/[tokens, docs_tokens]

export docs_tokens.emitTokensCss

const usersRoot = currentSourcePath().parentDir().parentDir()
  ## `.../isonim/docs/users` (this module lives in `users/src/`).
const designSystemRoot = usersRoot / "../../.." / "codetracer-design-system"
  ## `users/../../..` -> the workspace root; the design system is a sibling.

const docsDesignSystemJson = staticRead(
  designSystemRoot / "docs" / "codetracer-docs.tokens.json")
  ## The shared docs design system, embedded at compile time.

proc designSystemTokens*(): TokenSet =
  ## Loads the canonical Metacraft brand/alias/mapped DTCG token set so the
  ## docs layer's `bkToken` bindings resolve to concrete primitives.
  loadTokens(
    designSystemRoot / "brand" / "brand.json",
    designSystemRoot / "alias" / "alias.json",
    designSystemRoot / "mapped" / "mapped.json")

proc metacraftDocsTokenLayer*(): DocsTokenLayer =
  ## The CodeTracer docs token layer, loaded from the shared design system
  ## (codetracer-design-system/docs/codetracer-docs.tokens.json) -- the exact
  ## same tokens every Metacraft docs site + the editor use.
  loadDocsTokenLayer(docsDesignSystemJson)
