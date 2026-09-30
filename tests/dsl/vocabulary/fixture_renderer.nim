## Fixture renderer for the static-vocabulary tests.
##
## `VocabRenderer` forwards every backend call to `MockRenderer` (so trees
## build exactly as in `test_dsl.nim`) and declares a tiny vocabulary:
## `mailDocument` (document-root-only) > `mailSection` > `mailColumn` > `p`
## and `table` (whose nesting violation names an alternative), with
## `script`/`img` forbidden under the default code and `section` forbidden
## under its own code.
##
## MOCK POLICY (workspace rule: every mock justified in the header).
## `MockRenderer` is the framework's shipped in-memory `RendererBackend`
## (`isonim/testing/mock_dom`); it is the real boundary for asserting the
## built tree shape, and this fixture exists to exercise the compile-time
## vocabulary mechanism, which no production renderer's schema would pin
## in isolation.
## isonim's tests use this fixture so they never depend on isonim-email.
import isonim/testing/mock_dom
import isonim/dsl/vocabulary

type VocabRenderer* = object

proc createElement*(r: VocabRenderer; tag: string): MockNode =
  MockRenderer().createElement(tag)

proc createTextNode*(r: VocabRenderer; text: string): MockNode =
  MockRenderer().createTextNode(text)

proc appendChild*(r: VocabRenderer; parent, child: MockNode) =
  MockRenderer().appendChild(parent, child)

proc setAttribute*(r: VocabRenderer; node: MockNode; name, value: string) =
  MockRenderer().setAttribute(node, name, value)

proc setStyle*(r: VocabRenderer; node: MockNode; prop, value: string) =
  MockRenderer().setStyle(node, prop, value)

proc setTextContent*(r: VocabRenderer; node: MockNode; text: string) =
  MockRenderer().setTextContent(node, text)

proc addEventListener*(r: VocabRenderer; node: MockNode; event: string;
    handler: proc()) =
  MockRenderer().addEventListener(node, event, handler)

proc footerBlock*(r: VocabRenderer; label: string): MockNode =
  ## Data-only component: positional use only. Called with named
  ## arguments or a block it must fail with E-VOCAB-PROC-AS-ELEMENT,
  ## not silently become an unknown element.
  let node = MockRenderer().createElement("p")
  MockRenderer().setTextContent(node, label)
  node

proc staticVocabulary*(T: typedesc[VocabRenderer]): VocabularyRef {.compileTime.} =
  VocabularyRef(
    tags: @[
      # Document-root-only: may only be the top-level element of its block.
      TagDef(name: "mailDocument", attrs: @[], allowedParents: @[""]),
      # Requires a parent, so a block (or a proc) whose top-level element is
      # a mailSection exercises the unknown-parent rule at the block top.
      TagDef(name: "mailSection", attrs: @[
        AttrDef(name: "background_color", kind: akAttr),
        AttrDef(name: "padding", kind: akStyle),
      ], allowedParents: @["mailDocument"]),
      TagDef(name: "mailColumn", attrs: @[
        AttrDef(name: "width", kind: akAttr),
      ], allowedParents: @["mailSection"]),
      TagDef(name: "p", attrs: @[], allowedParents: @["mailColumn"]),
      # A nesting violation that names an alternative element.
      TagDef(name: "table", attrs: @[], allowedParents: @["mailColumn"],
        nestingAlternative: "mailTable"),
    ],
    forbidden: @[
      ForbiddenTag(tag: "script", reason: "email carries no scripts",
        alternative: ""),
      ForbiddenTag(tag: "img", reason: "bare images miss sizing and alt rules",
        alternative: "mailImage"),
      # A forbidden family reporting its own diagnostic code.
      ForbiddenTag(tag: "section",
        reason: "sectioning elements carry no meaning in mail clients",
        alternative: "mailSection", code: "E-A11Y-SECTIONING"),
    ])
