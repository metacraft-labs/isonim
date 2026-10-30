## Internal preparation for the explicit input declaration policy.
##
## This module is deliberately absent from ordinary builds and is not wired
## into ui. A declaration result alone provides no protected event or binding
## sink. The caller supplies the existing DSL attribute-name parser; policy
## follows the actual emitted attribute name, without inventing aliases.
when defined(isonimInternalInputPrivacy):
  import std/[macros, strutils]

  type InputPrivacy* = enum
    ipNone, ipPublic, ipSensitive

  const textTypes = ["text", "search", "email", "tel", "url", "password"]
  const otherTypes = ["hidden", "date", "month", "week", "time", "datetime-local",
    "number", "range", "color", "checkbox", "radio", "file", "submit", "image",
    "reset", "button"]
  const htmlSpace = {' ', '\t', '\n', '\r', '\f'}

  func credentialAutocomplete(value: string): bool =
    ## HTML token lists use ASCII whitespace. Unicode whitespace is not a
    ## token separator and must not silently change the assigned attribute.
    for token in value.toLowerAscii.split(htmlSpace):
      if token.startsWith("cc-") or token in
          ["current-password", "new-password", "one-time-code"]:
        return true

  proc requirePublicInputType*(value: string): string =
    ## Conversion to this exact string happens once at the call boundary.
    ## Validate before a renderer/SSR consumer can observe an assignment.
    let lowered = value.toLowerAscii
    if lowered == "password":
      raise newException(ValueError, "credential input cannot be public")
    if lowered notin textTypes and lowered notin otherTypes:
      raise newException(ValueError, "unsupported private input type")
    value

  proc requirePublicAutocomplete*(value: string): string =
    ## Return the checked bytes, rather than re-running a converter or `$`.
    if credentialAutocomplete(value):
      raise newException(ValueError, "credential input cannot be public")
    value

  proc checkedPrivacyValue*(privacy: InputPrivacy; tag, attribute: string;
      value: NimNode): NimNode {.compileTime.} =
    ## Trusted future macro code wraps a string-taking assignment expression.
    ## `ttype` is not an attribute alias in the current DSL.
    if privacy == ipPublic:
      case attribute.toLowerAscii
      of "type":
        if tag == "input": return newCall(bindSym"requirePublicInputType", value)
      of "autocomplete": return newCall(bindSym"requirePublicAutocomplete", value)
      else: discard
    value

  proc inputPrivacy*(node: NimNode; tag: string;
      attributeName: proc(node: NimNode): string): InputPrivacy {.compileTime.} =
    ## Analyze one authored element using the owning DSL's attribute parser.
    ## Unsupported HTML default/inheritance cases are refused in this private
    ## preparation rather than being certified as non-editable or non-text.
    var publicChoice, sensitiveChoice: NimNode
    var inputType = "text"
    var dynamicType, editable, credential: bool
    var seen: seq[string]
    for i in 1 ..< node.len:
      let attr = node[i]
      if attr.kind != nnkExprEqExpr or attr[0].kind == nnkRefTy: continue
      let name = attributeName(attr[0]).toLowerAscii
      let value = attr[1]
      if name in ["type", "autocomplete", "contenteditable", "public", "sensitive"]:
        if name in seen: error("duplicate input privacy attribute: " & name, attr)
        seen.add(name)
      case name
      of "record", "data-isonim-record":
        error("record is retired; choose public = true or sensitive = true", attr)
      of "data-isonim-public", "data-isonim-sensitive":
        error("use public = true or sensitive = true", attr)
      of "public", "sensitive":
        if not (value.eqIdent("true") or value.eqIdent("false")):
          error("input privacy requires literal public = true or sensitive = true", attr)
        if name == "public": publicChoice = value
        else: sensitiveChoice = value
      of "type":
        if value.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
          inputType = value.strVal.toLowerAscii
          if tag == "input" and inputType notin textTypes and inputType notin otherTypes:
            error("unsupported private input type", attr)
        else: dynamicType = true
      of "contenteditable":
        if value.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
          case value.strVal.toLowerAscii
          of "false": discard
          of "", "true", "plaintext-only": editable = true
          else: error("unsupported private contenteditable state", attr)
        elif value.eqIdent("false"): discard
        else: editable = true
      of "autocomplete":
        if value.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
          credential = credentialAutocomplete(value.strVal)
      else: discard
    credential = credential or (tag == "input" and inputType == "password")
    let isPublic = publicChoice != nil and publicChoice.eqIdent("true")
    let isSensitive = sensitiveChoice != nil and sensitiveChoice.eqIdent("true")
    if credential and (isPublic or (sensitiveChoice != nil and not isSensitive)):
      error("credential input must be sensitive; public = true and sensitive = false are forbidden", node)
    if publicChoice != nil and sensitiveChoice != nil:
      error("choose exactly one of public = true or sensitive = true", node)
    if (publicChoice != nil and not isPublic) or
        (sensitiveChoice != nil and not isSensitive):
      error("input privacy requires public = true or sensitive = true", node)
    let freeText = tag == "textarea" or editable or
      (tag == "input" and (dynamicType or inputType in textTypes))
    if freeText and not (isPublic or isSensitive or credential):
      error("free-text " & tag & " requires explicit public = true or sensitive = true", node)
    if credential or isSensitive: ipSensitive
    elif isPublic: ipPublic
    else: ipNone
