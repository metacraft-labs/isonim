## Deliberately privileged compiler fixture: uses the owning DSL's actual
## parser and tag resolver. No copied parser, browser or Sensitive substitute.
import std/macros
import isonim/dsl/ui {.all.}
import isonim/dsl/transform
import isonim/dsl/stable_ids
import isonim/dsl/private/input_privacy

macro privacyProbe*(element: untyped): untyped =
  let head = if element.kind == nnkIdent: element.strVal else: callHeadName(element)
  newLit($inputPrivacy(element, resolveTagName(head), attrNameStr))

macro checkedProbe*(element, attribute, value: untyped): untyped =
  let tag = resolveTagName(callHeadName(element))
  let privacy = inputPrivacy(element, tag, attrNameStr)
  checkedPrivacyValue(privacy, tag, attribute.strVal, value)
