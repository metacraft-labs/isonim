## isonim/content/directives -- the parser-level hooks: `preParse`,
## `postParse` and custom `:::name` directives. Dual-target: `nim c -r`
## and `nim js -r` must both pass.
##
## The directive cases are isonim-docs' plugin-directive cases, restated
## against `ParseHooks` (the parser-level part of its `Plugin`, which now
## delegates here); the ordering cases restate its registration-order
## cases for the two parser hooks. AST assertions replace the HTML ones,
## because this module has no renderer. No test doubles: every hook is a
## real closure recording what it saw.

import std/[unittest, strutils]
import isonim/content/[markdown, directives]

type Log = ref object
  entries: seq[string]

proc sampleHooks(tag: string; log: Log): ParseHooks =
  ## A fully-exercised hook set. `tag` namespaces its log entries so two
  ## instances prove registration-order determinism. Its `:::rating N`
  ## directive renders N stars as a paragraph.
  result.name = tag
  result.preParse = proc(body: string): string =
    log.entries.add tag & ":preParse"
    body.replace("PLACEHOLDER", "expanded-by-" & tag)
  result.postParse = proc(doc: var MarkdownDoc) =
    log.entries.add tag & ":postParse"
    doc.blocks.add Block(kind: bkParagraph,
      spans: @[InlineSpan(kind: ikText, text: "postparse-marker-" & tag)])
  let rating = proc(args, body: string): seq[Block] =
    let n = try: args.strip().parseInt() except ValueError: 0
    @[Block(kind: bkParagraph,
      spans: @[InlineSpan(kind: ikText, text: "*".repeat(n))])]
  result.directives = @[DirectiveRegistration(name: "rating", render: rating)]

proc texts(doc: MarkdownDoc): seq[string] =
  for b in doc.blocks:
    if b.kind == bkParagraph: result.add spansText(b.spans)

suite "isonim/content/directives -- hook order":
  test "preParse then postParse, each applied to the document":
    let log = Log()
    let doc = parseMarkdownDocWithHooks(@[sampleHooks("P", log)],
                                        "# Title\n\nA PLACEHOLDER token.")
    check log.entries == @["P:preParse", "P:postParse"]
    check doc.texts == @["A expanded-by-P token.", "postparse-marker-P"]

  test "two hook sets fire in registration order (A before B)":
    let log = Log()
    discard parseMarkdownDocWithHooks(@[sampleHooks("A", log), sampleHooks("B", log)],
                                      "# T\n\nbody")
    check log.entries == @["A:preParse", "B:preParse", "A:postParse", "B:postParse"]

  test "a later preParse sees the earlier one's output":
    let first = ParseHooks(preParse: proc(b: string): string = b & " one")
    let second = ParseHooks(preParse: proc(b: string): string = b & " two")
    check applyPreParse(@[first, second], "zero") == "zero one two"

  test "no hooks is exactly parseMarkdownDoc":
    let body = "# T\n\none paragraph\n\n:::note\nx\n:::"
    let hooked = parseMarkdownDocWithHooks(@[], body)
    let plain = parseMarkdownDoc(body)
    check hooked.blocks.len == plain.blocks.len
    for i in 0 ..< plain.blocks.len:
      check hooked.blocks[i].kind == plain.blocks[i].kind
    check hooked.texts == plain.texts
    check applyPreParse(@[], "raw") == "raw"

suite "isonim/content/directives -- custom directives":
  test "a registered ':::rating N' directive is recognised and renders its blocks":
    let log = Log()
    let doc = parseMarkdownDocWithHooks(@[sampleHooks("P", log)],
                                        ":::rating 5\nignored body\n:::")
    # The directive yields one paragraph; postParse then appends its marker.
    check doc.blocks.len == 2
    check doc.texts == @["*****", "postparse-marker-P"]

  test "a custom directive composes with ordinary blocks in document order":
    let log = Log()
    let doc = parseMarkdownDocWithHooks(@[sampleHooks("P", log)],
                                        "## Head\n\n:::rating 2\n:::\n\nafter")
    check doc.blocks[0].kind == bkHeading
    check doc.texts == @["**", "after", "postparse-marker-P"]

  test "':::tabs' stays a built-in even when custom directives are registered":
    let doc = parseMarkdownDocWithHooks(@[sampleHooks("P", Log())],
                                        ":::tabs\n@tab A\nBody.\n:::")
    check doc.blocks[0].kind == bkTabs

  test "an unregistered ':::note' still falls through to the built-in admonition":
    let doc = parseMarkdownDocWithHooks(@[sampleHooks("P", Log())],
                                        ":::note\nHeads up.\n:::")
    check doc.blocks[0].kind == bkAdmonition
    check doc.blocks[0].admonitionKind == akNote

  test "a registered directive shadows an admonition of the same name":
    let warning = ParseHooks(directives: @[DirectiveRegistration(name: "warning",
      render: proc(args, body: string): seq[Block] =
        @[Block(kind: bkParagraph, spans: @[InlineSpan(kind: ikText, text: "custom:" & body)])])])
    let doc = parseMarkdownDocWithHooks(@[warning], ":::warning\nCareful.\n:::")
    check doc.blocks.len == 1
    check doc.blocks[0].kind == bkParagraph
    check spansText(doc.blocks[0].spans) == "custom:Careful."

  test "the earliest registration of a name wins, and knowsDirective agrees":
    proc one(text: string): ParseHooks =
      ParseHooks(directives: @[DirectiveRegistration(name: "x",
        render: proc(args, body: string): seq[Block] =
          @[Block(kind: bkParagraph, spans: @[InlineSpan(kind: ikText, text: text)])])])
    let hooks = @[one("first"), one("second")]
    check hooks.knowsDirective("x")
    check not hooks.knowsDirective("y")
    check spansText(hooks.renderDirectiveBlocks("x", "", "")[0].spans) == "first"
    check hooks.renderDirectiveBlocks("y", "", "").len == 0
