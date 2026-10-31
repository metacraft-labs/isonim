## isonim/content/directives -- the parser-level extension hooks of
## `isonim/content/markdown`: custom `:::name` directives, and transforms
## that run before and after parsing.
##
## A consumer (a documentation framework, a blog theme, a site) registers
## `ParseHooks`; each may carry:
##
##   preParse   (transform a page's raw Markdown before parsing)
##   postParse  (inspect or mutate the parsed `MarkdownDoc`)
##   directives (map a `:::name args ... :::` directive name to a renderer
##               that turns the directive's argument line and raw body
##               into `Block`s, spliced into the document where the
##               directive appeared)
##
## `parseMarkdownDocWithHooks` is the one entry point that runs them:
## every `preParse` in registration order, then the parse with the
## directives wired in, then every `postParse` in registration order. With
## no hooks it is exactly `parseMarkdownDoc`.
##
## Rules that make the result deterministic and easy to reason about:
##
## * Registration order is execution order, for every hook.
## * The earliest-registered renderer for a directive name wins
##   (`knowsDirective` and `renderDirectiveBlocks` always agree).
## * Registered directives are consulted after the built-in `:::tabs` and
##   content directives and before admonitions (see
##   `markdown.parseMarkdownBlocks`), so a consumer can define its own
##   `:::name` block but cannot shadow `:::tabs`.
##
## Hooks that act on rendered HTML, on configuration or on a finished
## build are not parser concerns and are not here; isonim-docs' `Plugin`
## keeps them and delegates its parser-level part to this module.
##
## Pure data and closures, no platform imports, so this behaves
## identically under `nim c` and `nim js`.

import ./markdown

type
  DirectiveRenderer* = proc(args: string; body: string): seq[Block] {.closure.}
    ## Renders one custom `:::name args ... :::` block. `args` is the rest
    ## of the opening `:::name` line (trimmed); `body` is the raw inner
    ## text between the opening line and the closing `:::` (verbatim, so a
    ## directive can re-parse it, treat it as data, etc.). The returned
    ## blocks are spliced into the document in place of the directive.

  DirectiveRegistration* = object
    ## One `name -> renderer` mapping. A directive `name` is matched
    ## case-sensitively against the first token after `:::` (e.g.
    ## `youtube` matches `:::youtube dQw4w9WgXcQ`).
    name*: string
    render*: DirectiveRenderer

  ParseHooks* = object
    ## One registered set of parser hooks. Every hook is optional -- a nil
    ## closure means "not interested". `name` is for diagnostics only.
    name*: string
    preParse*: proc(body: string): string {.closure.}
    postParse*: proc(doc: var MarkdownDoc) {.closure.}
    directives*: seq[DirectiveRegistration]
    renderers*: ContentRenderers ## Optional native math/diagram callbacks.

proc applyPreParse*(hooks: seq[ParseHooks]; body: string): string =
  ## Threads a page's raw Markdown through every `preParse` in order; each
  ## hook sees the previous hook's output.
  result = body
  for h in hooks:
    if not h.preParse.isNil:
      result = h.preParse(result)

proc applyPostParse*(hooks: seq[ParseHooks]; doc: var MarkdownDoc) =
  ## Fires every `postParse` in order over the parsed AST. Hooks mutate
  ## `doc.blocks` in place; a hook that changes the heading set is
  ## responsible for `doc.headingTree` too.
  for h in hooks:
    if not h.postParse.isNil:
      h.postParse(doc)

proc knowsDirective*(hooks: seq[ParseHooks]; name: string): bool =
  ## Whether any registered hook set contributes a directive named `name`.
  for h in hooks:
    for d in h.directives:
      if d.name == name:
        return true
  false

proc renderDirectiveBlocks*(hooks: seq[ParseHooks]; name, args, body: string): seq[Block] =
  ## Runs the first registered renderer for `name` over `(args, body)`.
  ## Returns no blocks when nothing owns `name` (the parser only calls it
  ## after `knowsDirective` said yes).
  for h in hooks:
    for d in h.directives:
      if d.name == name and not d.render.isNil:
        return d.render(args, body)
  @[]

proc parseMarkdownDocWithHooks*(hooks: seq[ParseHooks]; body: string;
    sourceRelPath: string = "";
    resolveContentPath: proc(contentRelPath: string): string {.closure.} = nil;
    resolveSymbol: proc(sym: string): string {.closure.} = nil;
    isComponentKnown: proc(name: string): bool {.closure.} = nil;
    firstLine: int = 1; tableCaptions: bool = false): MarkdownDoc =
  ## `preParse`, then `parseMarkdownDoc` with the registered directives
  ## wired in, then `postParse`. The other arguments are
  ## `parseMarkdownDoc`'s. With no hooks this is exactly
  ## `parseMarkdownDoc(body, ...)`.
  let transformed = hooks.applyPreParse(body)
  var renderers: ContentRenderers
  for h in hooks:
    if renderers.math == nil: renderers.math = h.renderers.math
    if renderers.diagram == nil: renderers.diagram = h.renderers.diagram
  let known = proc(name: string): bool = hooks.knowsDirective(name)
  let render = proc(name, args, dbody: string): seq[Block] =
    hooks.renderDirectiveBlocks(name, args, dbody)
  result = parseMarkdownDoc(transformed, sourceRelPath, resolveContentPath,
    resolveSymbol, isComponentKnown,
    knownDirective = known, renderDirective = render,
    renderers = renderers, firstLine = firstLine, tableCaptions = tableCaptions)
  hooks.applyPostParse(result)
