## isonim/dsl/templates.nim
##
## Static subtree templates: what the `ui` macro hands a renderer that can create a whole subtree
## in one call.
##
## The macro sees the markup before the program runs. Where an element's subtree is fixed — every
## tag, class, attribute and style is a literal, and what changes is only text, attribute or style
## values and event handlers — it describes the subtree once, as a `StaticTemplate`, and creates
## every instance with one renderer call instead of one call per node. The nodes that something
## writes to later (a dynamic text, an element with a listener or a reactive attribute) are the
## template's holes: the call returns them, root first, and the macro attaches the effects and
## listeners to them as it would to nodes it created one by one.
##
## A renderer opts in by implementing
##
##   proc createFromTemplate*(r: R; tpl: StaticTemplate): seq[N]
##
## returning the root first and then every hole in hole order. Only renderers that implement it are
## handed templates; the rest receive the per-node calls as before. `buildFromTemplate` is the same
## operation spelled with the 13 contract operations, for a renderer that wants templates without a
## faster path of its own and for tests that compare the two.
##
## A template's static styles — literal style attributes and the Tailwind utilities its literal
## classes expand to — are its nodes' precomputed inline style: a renderer can resolve them once per
## template rather than once per element.

type
  TemplateNode* = object
    ## One node of a template, after its parent and its earlier siblings.
    parent*: int                    ## index of the parent node, -1 for the root
    tag*: string                    ## the element's tag, "" for a text node
    text*: string                   ## a text node's text
    classes*: string                ## the element's literal class list
    attrs*: seq[(string, string)]   ## the element's literal attributes
    styles*: seq[(string, string)]  ## the element's literal style declarations
    hole*: int                      ## position among the holes, -1 for a node nothing writes to

  StaticTemplate* = object
    ## A subtree the `ui` macro described at compile time. `id` is unique per call site, so a
    ## renderer can keep what it prepared for a template between instantiations.
    id*: int
    nodes*: seq[TemplateNode]
    holes*: int

proc styleText*(node: TemplateNode): string =
  ## The node's static styles as one declaration list, `a: b; c: d`.
  for i, (prop, value) in node.styles:
    if i > 0: result.add "; "
    result.add prop
    result.add ": "
    result.add value

proc buildFromTemplate*[R, N](r: R; tpl: StaticTemplate): seq[N] =
  ## Creates `tpl` with the 13 contract operations, returning the root and then the holes, as
  ## `createFromTemplate` does.
  result = newSeq[N](tpl.holes + 1)
  var made = newSeq[N](tpl.nodes.len)
  for i, node in tpl.nodes:
    let created =
      if node.tag.len == 0:
        r.createTextNode(node.text)
      else:
        r.createElement(node.tag)
    if node.tag.len > 0:
      if node.classes.len > 0:
        r.setAttribute(created, "class", node.classes)
      for (name, value) in node.attrs:
        r.setAttribute(created, name, value)
      for (prop, value) in node.styles:
        r.setStyle(created, prop, value)
    if node.parent >= 0:
      r.appendChild(made[node.parent], created)
    if node.hole >= 0:
      result[node.hole + 1] = created
    made[i] = created
  result[0] = made[0]
