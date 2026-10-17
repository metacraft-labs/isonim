## Write a ui block once; get both the SSR string and the client mount.
##
## The `ui` macro has always compiled a DSL block either to string
## concatenation (`ui:`) or to renderer calls (`ui(r):`). What it had no way to
## express is "this block, both ways" -- so a project that needed both wrote
## the body twice, as `demos/isonim-replica` does with `pageHeader` and
## `renderTaskListSsr`. Two copies of a layout is two things to keep in step,
## and the ways they drift are silent: an attribute added to one, a class
## renamed in the other.
##
## It matters more than duplication usually does, because the editor's preview
## is the client mount and the shipped page is the SSR string. If they can
## disagree, the editor is showing something the site does not serve -- which
## is the one thing a design tool must not do.
##
## So the body is written once:
##
##   uiIsomorphic heroSection:
##     tdiv(class = "page-width"):
##       h1(class = "tagline"): text "Faster than C."
##
## and two definitions come out of it:
##
##   heroSection(): string              -- SSR, unchanged for existing callers
##   heroSectionMount(r, parent)        -- client, appends into `parent`
##
## The client arm is also where the editor's regime lives. Under
## `-d:isonimEditor` the `ui` macro compiles a literal attribute into a cell the
## editor can write, so mounting this block gives a surface that reacts to an
## edit through the ordinary reactive path rather than by being rebuilt. That
## happens because the block is PROJECT code, not because this macro asked for
## it -- see `isFrameworkBlock` in `ui.nim`. The SSR arm is untouched and
## compiles exactly as before, which is what keeps the flag off the shipped
## page.

import std/macros

# The SSR arm emits an unbound `escapeAttr`, which every `ui:` caller has had to
# import for itself. Supplied here instead: a macro that generates a call is
# better placed to satisfy it than every caller is, and the failure it replaces
# ("undeclared identifier: 'escapeAttr'", pointing into ui.nim) says nothing
# about the missing import. `ssr/escape` has no imports of its own, so this
# costs a client build nothing.
import ../ssr/escape
export escape

# The client arm wraps reactive reads in `createRenderEffect`, which the `ui`
# macro emits unbound. Supplied here for the same reason `escapeAttr` is: a
# module that GENERATES a call is better placed to satisfy it than every
# caller is. The SSR arm never reaches this code -- the mount proc is generic,
# so a build that only calls the string form never instantiates it.
import ../core/[signals, computation]
export signals, computation


macro uiIsomorphic*(name: untyped; body: untyped): untyped =
  ## Define `name(): string` and `nameMount(r, parent)` from one DSL block.
  ##
  ## The body is copied rather than shared, because the two `ui` expansions
  ## rewrite what they are given and a shared tree would let the first
  ## expansion corrupt the second.
  expectKind(name, nnkIdent)

  # Leading `##` comments are documentation, not DSL. Split them off and give
  # them to both generated procs, so the prose a section was written with stays
  # attached to it instead of reaching the macro as a node it cannot process.
  var docs: seq[NimNode] = @[]
  let dsl = newStmtList()
  if body.kind == nnkStmtList:
    for child in body:
      if child.kind == nnkCommentStmt and dsl.len == 0:
        docs.add child
      else:
        dsl.add child
  else:
    dsl.add body

  proc withDocs(stmts: NimNode): NimNode =
    result = newStmtList()
    for d in docs: result.add d.copyNimTree
    for s in stmts: result.add s

  let exported = nnkPostfix.newTree(ident"*", name)
  let mountName = nnkPostfix.newTree(ident"*", ident($name & "Mount"))

  let ssrProc = newProc(
    name = exported,
    params = [ident"string"],
    body = withDocs(newStmtList(newCall(ident"ui", dsl.copyNimTree))))

  # Generic over renderer and node so this module needs no renderer import and
  # the proc costs nothing until a client build instantiates it.
  let r = ident"r"
  let parent = ident"parent"
  let clientCall = newCall(ident"ui", r, dsl.copyNimTree)
  let mountProc = newProc(
    name = mountName,
    params = [newEmptyNode(),
              newIdentDefs(r, ident"R"),
              newIdentDefs(parent, ident"E")],
    body = withDocs(newStmtList(
      newCall(newDotExpr(r, ident"appendChild"), parent, clientCall))))
  mountProc[2] = nnkGenericParams.newTree(
    newIdentDefs(ident"R", newEmptyNode()),
    newIdentDefs(ident"E", newEmptyNode()))

  newStmtList(ssrProc, mountProc)
