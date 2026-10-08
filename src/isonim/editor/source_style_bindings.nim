## Compiler-owned bindings for opted-in CSS constants. No DOM, filesystem or
## caller-supplied source paths: the project owns source declarations and the
## rendered catalog owns target identity. Complex/ambiguous rules are refused.
import std/[json, strutils, tables, sha1, options]
import isonim/editor/[html_classes, css_patch, source_catalog, source_style_values, types, viewmodels]

type SourceReader* = proc(file: string): string {.closure.}

func simpleSelectorMatches*(element: SourceHtmlElement; selector: string): bool =
  ## A single compound type/class/ID selector. Combinators, attributes, state
  ## selectors and escapes require richer provenance and are never guessed.
  var at = 0
  if selector.len == 0: return false
  if selector[0] notin {'.', '#'}:
    let start = at
    while at < selector.len and selector[at] in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}: inc at
    if at == start or element.tag != selector[start ..< at].toLowerAscii(): return false
  while at < selector.len:
    let kind = selector[at]
    if kind notin {'.', '#'}: return false
    inc at
    let start = at
    while at < selector.len and selector[at] in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}: inc at
    if at == start: return false
    let name = selector[start ..< at]
    if kind == '#':
      if element.attributes.getOrDefault("id") != name: return false
    elif name notin element.attributes.getOrDefault("class").splitWhitespace(): return false
  true

func selectorCouldMatch(element: SourceHtmlElement; selector: string): bool =
  ## Only required terminal type/class/ID can prove a rule unrelated. Attribute,
  ## ancestor and state predicates are never evaluated to infer a winner.
  if selector.strip() == ":root": return element.tag == "html"
  var start, depth, brackets = 0
  var quote: char
  var escaped = false
  for index, character in selector:
    if escaped:
      escaped = false
      continue
    if character == '\\':
      if brackets == 0: return true
      escaped = true
      continue
    if quote != '\0':
      if character == quote: quote = '\0'
      continue
    if character in {'\'', '"'}:
      quote = character
    elif character == '[': inc brackets
    elif character == ']':
      dec brackets
      if brackets < 0: return true
    elif brackets == 0:
      if character == '(': inc depth
      elif character == ')':
        dec depth
        if depth < 0: return true
      elif depth == 0 and character in {' ', '\t', '\n', '\r', '>', '+', '~'}:
        start = index + 1
  if depth != 0 or brackets != 0 or quote != '\0' or escaped: return true
  let subject = selector[start .. ^1].strip()
  var stop = subject.len
  for index, character in subject:
    if character in {':', '['}: stop = index; break
  let simple = subject[0 ..< stop]
  if simple.len == 0 or '*' in simple: return true
  for character in simple:
    if character notin {'a'..'z','A'..'Z','0'..'9','-','_','.','#'}: return true
  element.simpleSelectorMatches(simple)

proc compiledStyleBindings*(catalog, manifest: JsonNode; readSource: SourceReader): JsonNode =
  result = newJArray()
  if manifest{"editableStyleSources"} == nil: return
  if manifest["editableStyleSources"].kind != JArray:
    raise newException(ValueError, "Editable stylesheet declarations must be an array.")
  var declarations = newJArray()
  var tokens = newJArray()
  var optedInCss: seq[string]
  var tokenNames: seq[string]
  var attributionProperties: seq[string]
  var sourceTexts = initTable[string,string]()
  var sourceHashes = initTable[string,string]()
  for source in manifest["editableStyleSources"]:
    if source.kind != JObject or source{"file"} == nil or source{"file"}.kind != JString or
        source{"const"} == nil or source{"const"}.kind != JString or
        source{"properties"} == nil or source{"properties"}.kind != JArray:
      raise newException(ValueError, "Invalid editable stylesheet declaration.")
    let sourceFile = source["file"].getStr()
    if not sourceTexts.hasKey(sourceFile):
      sourceTexts[sourceFile] = readSource(sourceFile)
      sourceHashes[sourceFile] = $secureHash(sourceTexts[sourceFile])
    let text = sourceTexts[sourceFile]
    let sourceHash = sourceHashes[sourceFile]
    let css = nimConstBody(text, source["const"].getStr())
    optedInCss.add css
    if css.len == 0: raise newException(ValueError, "Editable stylesheet constant not found.")
    var allowed: seq[string]
    for property in source["properties"]:
      if property.kind != JString or property.getStr().len == 0:
        raise newException(ValueError, "Invalid editable stylesheet property.")
      allowed.add property.getStr()
      if property.getStr().startsWith("--") and property.getStr() notin tokenNames: tokenNames.add property.getStr()
    var scanAllowed = allowed
    for shorthand in ["padding", "border-radius"]:
      if shorthand notin allowed: continue
      for side in (if shorthand == "padding": @["padding-top","padding-right","padding-bottom","padding-left"] else:
          @["border-top-left-radius","border-top-right-radius","border-bottom-right-radius","border-bottom-left-radius"]):
        if side notin scanAllowed: scanAllowed.add side
    # Even uneditable shorthands can reset an allowed longhand.
    if "background" in allowed or "background-color" in allowed:
      for name in ["background", "background-color"]:
        if name notin scanAllowed: scanAllowed.add name
    for name in scanAllowed:
      if not name.startsWith("--") and name notin attributionProperties:
        attributionProperties.add name
    for rule in cssUnconditionalLiterals(css, scanAllowed):
      var values = newJObject()
      var owners = newJObject()
      var blockedShorthands: seq[string]
      for shorthand in ["padding","border-radius"]:
        if shorthand in rule.blockedProperties: blockedShorthands.add shorthand
      for declaration in rule.values:
        if declaration.property in ["padding","border-radius"] and
            "!important" in declaration.value.toLowerAscii(): blockedShorthands.add declaration.property
      for declaration in rule.values:
        if "!important" in declaration.value.toLowerAscii(): continue
        if ("padding" in blockedShorthands and declaration.property.startsWith("padding-")) or
            ("border-radius" in blockedShorthands and declaration.property in
              ["border-top-left-radius","border-top-right-radius","border-bottom-right-radius","border-bottom-left-radius"]): continue
        if rule.selector == ":root" and declaration.property.startsWith("--"):
          if directCssVariable(declaration.value).len == 0 and "var(" notin declaration.value:
            tokens.add(%* {"file":source["file"],"const":source["const"],"selector":":root",
              "name":declaration.property,"value":declaration.value,"sourceHash":sourceHash})
          continue
        values[declaration.property] = %declaration.value
        owners[declaration.property] = %* {"property":declaration.property,"value":declaration.value}
      # Declaration order decides whether a shorthand or explicit longhand
      # owns a side. Derivation never revives a conditional/duplicate side.
      for shorthand in ["padding", "border-radius"]:
        if values{shorthand} == nil: continue
        let quad = cssQuadValues(shorthand,values[shorthand].getStr())
        if quad.isNone: continue
        let sides = if shorthand == "padding": @["padding-top","padding-right","padding-bottom","padding-left"] else:
          @["border-top-left-radius","border-top-right-radius","border-bottom-right-radius","border-bottom-left-radius"]
        for index,side in sides:
          if side in rule.blockedProperties: continue
          if values{side} != nil:
            var shorthandPosition, sidePosition: int
            for location in rule.declarationPositions:
              if location.property == shorthand: shorthandPosition = location.position
              if location.property == side: sidePosition = location.position
            if sidePosition > shorthandPosition: continue
          values[side] = %quad.get[index]
          owners[side] = %* {"property":shorthand,"value":values[shorthand],"component":index}
      # Background resets its color even when its owner is not editable.
      # Only a supported winning declaration may supply the current value.
      var backgroundPosition, colorPosition = -1
      for location in rule.declarationPositions:
        if location.property == "background": backgroundPosition = location.position
        if location.property == "background-color": colorPosition = location.position
      let backgroundBlocked = "background" in rule.blockedProperties or
        (values{"background"} != nil and "!important" in values["background"].getStr().toLowerAscii())
      # Priority declarations were withheld above, so inspect the projection too.
      var backgroundPriority = false
      var colorPriority = false
      for declaration in rule.values:
        if declaration.property == "background" and "!important" in declaration.value.toLowerAscii():
          backgroundPriority = true
        if declaration.property == "background-color" and "!important" in declaration.value.toLowerAscii():
          colorPriority = true
      if backgroundBlocked or backgroundPriority or colorPriority or "background-color" in rule.blockedProperties:
        if values{"background-color"} != nil: values.delete("background-color")
        if owners{"background-color"} != nil: owners.delete("background-color")
        if values{"background"} != nil: values.delete("background")
        if owners{"background"} != nil: owners.delete("background")
      elif backgroundPosition > colorPosition:
        if values{"background-color"} != nil: values.delete("background-color")
        if owners{"background-color"} != nil: owners.delete("background-color")
        if values{"background"} != nil and "background" in allowed and
            "background-color" notin rule.blockedProperties:
          let raw = values["background"].getStr()
          if directCssVariable(raw).len > 0 or parseCssPropertyValue("background-color",raw).kind == cvkColor:
            values["background-color"] = values["background"]
            owners["background-color"] = owners["background"]
      if values{"background"} != nil:
        let raw = values["background"].getStr()
        if directCssVariable(raw).len == 0 and parseCssPropertyValue("background-color",raw).kind != cvkColor:
          values.delete("background")
          owners.delete("background")
      # Projection-only declarations never gain a write capability.
      if "background" notin allowed:
        if values{"background"} != nil: values.delete("background")
        if owners{"background"} != nil: owners.delete("background")
      if values{"background-color"} != nil:
        let actualOwner = owners["background-color"]["property"].getStr()
        if actualOwner notin allowed:
          values.delete("background-color")
          owners.delete("background-color")
      if colorPosition > backgroundPosition:
        # The earlier shorthand is not the current color owner either.
        if values{"background"} != nil: values.delete("background")
        if owners{"background"} != nil: owners.delete("background")
      if values.len > 0:
        declarations.add(%* {"file": source["file"], "const": source["const"],
          "selector": rule.selector, "values": values, "sourceDeclarations": owners,"sourceHash":sourceHash})
  var elements: seq[tuple[story: string, element: SourceHtmlElement]]
  for story in catalog{"stories"}:
    let storyId = story{"group"}.getStr() & " / " & story{"name"}.getStr()
    let markup = sourceElementMarkup(story{"documentHtml"}.getStr(), sourceStoryIdentityPrefix(storyId))
    for element in markup.elements: elements.add((storyId, element))
  var unsupportedTokens: seq[string]
  var tokenOwnerCount = initCountTable[string]()
  for css in optedInCss:
    for owner in cssCustomPropertyOwners(css,tokenNames):
      tokenOwnerCount.inc owner.property
      if owner.selector != ":root" or owner.condition.len > 0:
        if owner.property notin unsupportedTokens: unsupportedTokens.add owner.property
  for name,count in tokenOwnerCount:
    if count != 1 and name notin unsupportedTokens: unsupportedTokens.add name
  # Inline variable owners also prevent authority from being assigned to root.
  var selectorCounts = initTable[string,int]()
  for declaration in declarations:
    let selector = declaration["selector"].getStr()
    if selectorCounts.hasKey(selector): continue
    var count = 0
    for target in elements:
      if simpleSelectorMatches(target.element,selector): inc count
    selectorCounts[selector] = count
  var possibleOwners: seq[tuple[selector, condition, property: string]]
  for css in optedInCss:
    possibleOwners.add cssPropertyOwners(css,attributionProperties)
  var bindingsByKey = initTable[string,JsonNode]()
  for target in elements:
    let inlineStyle = target.element.attributes.getOrDefault("style")
    if inlineStyle.len > 0:
      for owner in cssCustomPropertyOwners(".inline {" & inlineStyle & "}",tokenNames):
        if owner.property notin unsupportedTokens: unsupportedTokens.add owner.property
  for target in elements:
    let inlineStyle = target.element.attributes.getOrDefault("style")
    var candidates = newJArray()
    for declaration in declarations:
      if simpleSelectorMatches(target.element, declaration["selector"].getStr()): candidates.add declaration
    for declaration in candidates:
      for property,raw in declaration["values"]:
        var ownerCount = 0
        for candidate in candidates:
          if candidate{"values",property} != nil: inc ownerCount
        if ownerCount != 1: continue
        # This provider hydrates the current property origin, not an explicitly
        # chosen overridden scope. Unknown cascade attribution stays read-only.
        var attributionBlocked = false
        for other in possibleOwners:
          if other.property != property: continue
          let matches = simpleSelectorMatches(target.element,other.selector)
          var selectorSupported = other.selector.len > 0
          for character in other.selector:
            if character notin {'a'..'z','A'..'Z','0'..'9','-','_','.','#'}: selectorSupported = false
          if matches and (other.condition.len > 0 or other.selector != declaration["selector"].getStr()):
            attributionBlocked = true
          elif not selectorSupported and target.element.selectorCouldMatch(other.selector):
            attributionBlocked = true
        if inlineStyle.len > 0 and cssPropertyOwners(".inline {" & inlineStyle & "}",@[property]).len > 0:
          attributionBlocked = true
        if attributionBlocked: continue
        var value = raw
        var owner = declaration
        var sourceDeclaration = declaration["sourceDeclarations"][property]
        var scope = "shared-class"
        let tokenName = directCssVariable(raw.getStr())
        if tokenName.len > 0:
          if tokenName in unsupportedTokens: continue
          var tokenOwner: JsonNode
          for token in tokens:
            if token["name"].getStr() == tokenName:
              if tokenOwner != nil: tokenOwner = nil; break
              tokenOwner = token
          if tokenOwner == nil: continue
          value = tokenOwner["value"]
          let parsed = parseCssPropertyValue(property,value.getStr())
          if validateCssPropertyValue(PropertyInfo(name:property,directStyleAllowed:true),
              PropertyEditRequest(property:property,newValue:value.getStr(),kind:pekCss),parsed).len > 0: continue
          owner = tokenOwner
          scope = "semantic-token"
          sourceDeclaration = %* {"property":tokenName,"value":value}
        elif "var(" in raw.getStr(): continue
        let count = selectorCounts[declaration["selector"].getStr()]
        let key = (if scope == "semantic-token": "tokens.native." else: "classes.native.") &
          $secureHash(target.story & "\n" & target.element.id & "\n" & owner["file"].getStr() &
            "\n" & owner["const"].getStr() & "\n" & owner["selector"].getStr() & "\n" & tokenName)
        var binding = bindingsByKey.getOrDefault(key)
        if binding == nil:
          binding = %* {"key":key,"elementId":target.element.id,"storyId":target.story,
            "file":owner["file"],"const":owner["const"],"selector":owner["selector"],
            "sourceHash":owner["sourceHash"],"properties":[],"values":{},"sourceDeclarations":{},
            "scope":scope,"sharedCount":count,"tokenName":tokenName}
          result.add binding
          bindingsByKey[key] = binding
        binding["properties"].add %property
        binding["values"][property] = value
        binding["sourceDeclarations"][property] = sourceDeclaration
  # Token impact includes every directly bound rendered target, across selectors.
  var knownTokenCounts = initCountTable[string]()
  proc tokenKey(binding:JsonNode): string =
    binding["file"].getStr() & "\n" & binding["const"].getStr() & "\n" & binding["tokenName"].getStr()
  for binding in result:
    if binding["scope"].getStr() == "semantic-token": knownTokenCounts.inc tokenKey(binding)
  for binding in result:
    if binding["scope"].getStr() != "semantic-token": continue
    binding["sharedCount"] = %knownTokenCounts[tokenKey(binding)]
