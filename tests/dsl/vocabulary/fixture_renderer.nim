## Fixture renderer for the static-vocabulary tests.
##
## `VocabRenderer` forwards every backend call to `MockRenderer` (so trees
## build exactly as in `test_dsl.nim`) and declares a tiny vocabulary:
## `mailSection` > `mailColumn` > `p`, with `script`/`img` forbidden.
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
      TagDef(name: "mailSection", attrs: @[
        AttrDef(name: "background_color", kind: akAttr),
        AttrDef(name: "padding", kind: akStyle),
      ], allowedParents: @[]),
      TagDef(name: "mailColumn", attrs: @[
        AttrDef(name: "width", kind: akAttr),
      ], allowedParents: @["mailSection"]),
      TagDef(name: "p", attrs: @[], allowedParents: @["mailColumn"]),
    ],
    forbidden: @[
      ForbiddenTag(tag: "script", reason: "email carries no scripts",
        alternative: ""),
      ForbiddenTag(tag: "img", reason: "bare images miss sizing and alt rules",
        alternative: "mailImage"),
    ])
