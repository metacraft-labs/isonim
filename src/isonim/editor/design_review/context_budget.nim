## Optional editor context compaction after a proven no-operation REST quota
## rejection. No provider quota is guessed. User text, edits, constraints, diffs,
## target identities and project guidance are outside this compaction boundary.
import std/[json, options, sha1, strutils, unicode]
import ./context_policy

const EditorContextLabel* = "EDITOR CONTEXT:\n"
const OptionalArrays = ["diagnostics", "designSystemSchema", "selectedSchemaNodes",
  "componentVariantContext", "renderedComponentTree", "themeTokens", "sourceMap",
  "reviewAnnotations", "domSnapshots", "screenshotRefs", "tokenContext",
  "availableTailwindClasses"]

proc referenceContext*(current, delivered, sources: JsonNode): JsonNode

proc requiresCompleteContext(context: JsonNode): bool =
  ## Literal future fields must never be mistaken for protocol descriptors by
  ## a provider that has no access to the producer's original-value guard.
  if context == nil or context.kind != JObject: return false
  for key in ["fromContext", "completeContext", "current", "boundedInherited", "protectedV1", "protectedV2"]:
    if context.hasKey(key): return true
  for key, value in context:
    if value.kind == JObject:
      for marker in ["fromPreviousItems", "previouslyDelivered", "fromDelivered"]:
        if value.hasKey(marker): return true
  false


proc compactEditorContext*(original: JsonNode; maxChars: int; base: JsonNode = nil): Option[JsonNode] =
  if original == nil or original.kind != JObject or maxChars <= 0: return none(JsonNode)
  if original{"contextAvailability"} != nil and original["contextAvailability"].kind != JArray:
    return none(JsonNode)
  for field in OptionalArrays:
    if original{field} != nil and original[field].kind != JArray and
        not (original[field].kind == JObject and
          ((original[field].len in [1, 3] and original[field]{"previouslyDelivered"} != nil and
            original[field]["previouslyDelivered"].kind == JString) or
           (original[field].len == 2 and original[field]{"fromDelivered"} != nil and
             original[field]["fromDelivered"].kind == JString and original[field]{"items"} != nil and
             original[field]["items"].kind == JArray))): return none(JsonNode)
  let context = parseJson($original) # never mutate the submitted snapshot
  var availability = newJArray()
  if context{"contextAvailability"} != nil:
    for entry in context["contextAvailability"]:
      if entry.kind != JString: return none(JsonNode)
      var marker = entry.getStr()
      if not marker.startsWith("availableTailwindClasses: required minimum") and
          (marker.contains("budget") or marker.contains("truncated")):
        marker = marker.split(':')[0] & ": previously truncated"
      var duplicate = false
      for existing in availability:
        if existing.getStr() == marker: duplicate = true
      if not duplicate: availability.add %marker
  context["contextAvailability"] = availability
  var originalCounts = newJObject()
  for field in OptionalArrays:
    if context{field} != nil and context[field].kind == JArray:
      originalCounts[field] = %context[field].len
  var requiredTreeIds: seq[string]
  if context{"renderedComponentTree"} != nil and context["renderedComponentTree"].kind == JArray:
    for i in 0 ..< context["renderedComponentTree"].len:
      let row = context["renderedComponentTree"][i]
      if row.kind != JObject: continue
      let id = row{"id"}.getStr()
      var relevant = i < 8 or row{"selected"}.getBool() or
        (id.len > 0 and id == context{"selectedElement", "id"}.getStr())
      if context{"selectedElement", "ancestorIds"} != nil and context["selectedElement"]["ancestorIds"].kind == JArray:
        for ancestor in context["selectedElement"]["ancestorIds"]:
          if ancestor.kind == JString and ancestor.getStr() == id: relevant = true
      if context{"pendingSourceEdits"} != nil and context["pendingSourceEdits"].kind == JArray:
        for edit in context["pendingSourceEdits"]:
          if row{"schemaKey"}.getStr().len > 0 and row{"schemaKey"}.getStr() == edit{"schemaKey"}.getStr(): relevant = true
      if context{"accumulatedEdits"} != nil and context["accumulatedEdits"].kind == JArray:
        for edit in context["accumulatedEdits"]:
          if row{"sourceFile"}.getStr().len > 0 and row{"sourceFile"}.getStr() == edit{"file"}.getStr() and row{"sourceLine"}.getInt() == edit{"line"}.getInt(): relevant = true
      if relevant and id notin requiredTreeIds: requiredTreeIds.add id
    var addedAncestor = true
    while addedAncestor:
      addedAncestor = false
      for row in context["renderedComponentTree"]:
        if row.kind != JObject: continue
        let parent = row{"parentId"}.getStr()
        if row{"id"}.getStr() in requiredTreeIds and parent.len > 0 and parent notin requiredTreeIds:
          requiredTreeIds.add parent
          addedAncestor = true
    for id in requiredTreeIds:
      var present = false
      for row in context["renderedComponentTree"]:
        if row.kind == JObject and row{"id"}.getStr() == id: present = true
      if not present:
        availability.add %"renderedComponentTree: a required ancestor is unavailable in the published tree"
        break
  var declaredMinimum = 0
  for marker in availability:
    let declared = declaredCompiledClassMinimum(marker.getStr())
    if declared < 0: return none(JsonNode)
    if declared > 0:
      if declaredMinimum > 0 and declaredMinimum != declared: return none(JsonNode)
      declaredMinimum = declared
  var requiredClasses = 0
  if context{"availableTailwindClasses"} != nil and context["availableTailwindClasses"].kind == JArray:
    # A producer declares relevance beyond the stable inventory explicitly;
    # optional extras above that minimum can still yield to actual quota.
    if declaredMinimum > context["availableTailwindClasses"].len: return none(JsonNode)
    requiredClasses = compiledClassMinimum(context["availableTailwindClasses"].len, declaredMinimum)
  elif declaredMinimum > 0:
    return none(JsonNode) # a declared minimum needs actual current class data
  proc requiredRecord(field: string; index: int): bool =
    if field == "availableTailwindClasses": return index < requiredClasses
    let entry = context[field][index]
    if entry.kind != JObject: return index == 0
    if field == "renderedComponentTree": return index < 8 or entry{"id"}.getStr() in requiredTreeIds
    if field == "selectedSchemaNodes": return true
    if field == "diagnostics":
      # One current diagnostic per source/category remains actionable.
      let group = entry{"source"}.getStr() & ":" & entry{"category"}.getStr()
      for i in 0 ..< index:
        let prior = context[field][i]
        if prior.kind == JObject and prior{"source"}.getStr() & ":" & prior{"category"}.getStr() == group: return false
      return true
    if field in ["designSystemSchema", "sourceMap"]:
      let key = if field == "sourceMap": entry{"schemaKey"}.getStr() else: entry{"key"}.getStr()
      let property = entry{"property"}.getStr()
      if context{"pendingSourceEdits"} != nil and context["pendingSourceEdits"].kind == JArray:
        for edit in context["pendingSourceEdits"]:
          if key.len > 0 and key == edit{"schemaKey"}.getStr(): return true
      if context{"accumulatedEdits"} != nil and context["accumulatedEdits"].kind == JArray:
        for edit in context["accumulatedEdits"]:
          if property.len > 0 and property == edit{"property"}.getStr(): return true
      if field == "designSystemSchema" and context{"selectedSchemaNodes"} != nil and context["selectedSchemaNodes"].kind == JArray:
        for selected in context["selectedSchemaNodes"]:
          if key.len > 0 and key == selected{"key"}.getStr(): return true
    false
  # The base is immutable and only the array-removal branch changes context.
  # Repeated size checks between those mutations must reuse the same result;
  # serializing full optional inventories once per unrelated field repeats work.
  var cachedWireChars = -1
  proc updateMarkers() =
    cachedWireChars = -1
    var markers = parseJson($availability)
    for field in OptionalArrays:
      if originalCounts{field} != nil and context[field].len != originalCounts[field].getInt():
        markers.add %(field & ": " & $context[field].len & "/" & $originalCounts[field].getInt() & " records; quota truncated")
    context["contextAvailability"] = markers
  proc wireSize(): int =
    if cachedWireChars < 0:
      # Without a prior admitted base, referenceContext emits a full clone of
      # this exact object. Measure those same bytes directly without reparsing.
      cachedWireChars = if base == nil and not requiresCompleteContext(context): runeLen($context)
                        else: runeLen($referenceContext(context, base, nil))
    cachedWireChars
  var changed = true
  while wireSize() > maxChars and changed:
    changed = false
    for field in OptionalArrays:
      if wireSize() <= maxChars: break
      if context{field} != nil and context[field].kind == JArray and context[field].len > 1:
        var removeIndex = -1
        for i in countdown(context[field].len - 1, 0):
          if not requiredRecord(field, i):
            removeIndex = i
            break
        if removeIndex >= 0:
          var shorter = newJArray()
          for i in 0 ..< context[field].len:
            if i != removeIndex: shorter.add context[field][i]
          context[field] = shorter
          changed = true
          updateMarkers()
  if wireSize() <= maxChars: return some(context)
  # Keep at least one complete record and every field. If that minimum plus the
  # protected snapshot does not fit, return rejection rather than lose edits.
  none(JsonNode)

const ProtectedFields = ["accumulatedEdits", "pendingSourceEdits", "designSystemConstraints",
  "currentFileDiffs", "selectedStory", "selectedElement"]

const ElementIdentityV1 = ["id", "sourceKey", "domPath", "schemaKey", "tag", "sourceFile",
  "sourceLine", "sourceColumn", "properties", "children", "ancestors", "ancestorIds", "depth"]
const ElementIdentityV2 = @ElementIdentityV1 & @["styleBindings"]

proc validElementTuple(values: JsonNode; version2 = false): bool =
  if values.kind != JArray or values.len != (if version2: ElementIdentityV2.len else: ElementIdentityV1.len): return false
  for i in 0 ..< values.len:
    let expected = if i < 6 or i == 13: JString elif i in [6, 7, 12]: JInt else: JArray
    if values[i].kind != expected: return false
  true

proc protectedTuple(context: JsonNode): JsonNode =
  for field in ProtectedFields:
    if context{field} == nil: return nil
  for field in ProtectedFields[0 .. 3]:
    if context[field].kind != JArray: return nil
  let story = context["selectedStory"]
  let element = context["selectedElement"]
  if story.kind != JObject or story.len != 4 or story{"group"} == nil or story{"name"} == nil or story{"kind"} == nil or story{"index"} == nil or
      story["group"].kind != JString or story["name"].kind != JString or story["kind"].kind != JInt or story["index"].kind != JInt: return nil
  if element.kind != JObject: return nil
  let version2 = element.hasKey("styleBindings")
  let fields = if version2: @ElementIdentityV2 else: @ElementIdentityV1
  if element.len != fields.len: return nil
  var identity = newJArray()
  for field in fields:
    if element{field} == nil: return nil
    identity.add parseJson($element[field])
  if not validElementTuple(identity, version2): return nil
  result = newJArray()
  for field in ProtectedFields[0 .. 3]: result.add parseJson($context[field])
  result.add(%* [story["group"], story["name"], story["kind"], story["index"]])
  result.add identity

proc contextSourceIdentities*(current: JsonNode): JsonNode =
  result = newJObject()
  for field, value in current: result[field] = %($secureHash($value))

proc referenceContext*(current, delivered, sources: JsonNode): JsonNode =
  ## One identity refers exclusively to the actual prior admitted semantic
  ## representation. Every protected field remains explicit and exact. Optional
  ## fields absent from current inherit their prior delivered representation.
  result = parseJson($current)
  if requiresCompleteContext(current):
    result = %* {"completeContext":result}
    return
  if delivered == nil or delivered.kind != JObject: return
  if current.len != delivered.len: return
  for field, value in current:
    if not delivered.hasKey(field): return
  var changes = newJObject()
  var bounded = newJArray()
  for field, value in current:
    if field in ProtectedFields or delivered{field} == nil:
      changes[field] = parseJson($value)
      continue
    if value == delivered[field]: continue
    let sourceId = $secureHash($value)
    if sources != nil and sources{field} != nil and sources[field].getStr() == sourceId:
      bounded.add %field
      continue
    changes[field] = parseJson($value)
    if value.kind == JArray and delivered[field].kind == JArray:
      var items = newJArray()
      var reused = false
      for item in value:
        var previousIndex = -1
        for i in 0 ..< delivered[field].len:
          if item == delivered[field][i]:
            previousIndex = i
            break
        if previousIndex >= 0:
          items.add(%* {"reuse":previousIndex})
          reused = true
        else:
          var encoded = %* {"value":item}
          # Any object can be reconstructed exactly from an admitted object;
          # no schema whitelist or identity guess drops future fields. Indices
          # refer only to the hash-verified base and preserve duplicates/order.
          if item.kind == JObject:
            for i in 0 ..< delivered[field].len:
              let prior = delivered[field][i]
              if prior.kind != JObject: continue
              var replacements = newJObject()
              var removed = newJArray()
              for key, currentValue in item:
                if prior{key} == nil or prior[key] != currentValue:
                  replacements[key] = parseJson($currentValue)
              for key, priorValue in prior:
                if not item.hasKey(key): removed.add %key
              let patch = %* {"reuse":i, "set":replacements, "remove":removed}
              if runeLen($patch) < runeLen($encoded): encoded = patch
          if encoded.hasKey("reuse"): reused = true
          items.add encoded
      let delta = %* {"fromPreviousItems":items}
      if reused and runeLen($delta) < runeLen($value): changes[field] = delta
  var envelope = %* {"fromContext": $secureHash($delivered), "current":changes}
  let exactProtected = protectedTuple(current)
  if exactProtected != nil:
    for field in ProtectedFields: changes.delete(field)
    envelope[if exactProtected[5].len == ElementIdentityV2.len: "protectedV2" else: "protectedV1"] = exactProtected
  if bounded.len > 0: envelope["boundedInherited"] = bounded
  if runeLen($envelope) < runeLen($result): result = envelope

proc deliveredContext*(wire, previous: JsonNode; original: JsonNode = nil): JsonNode =
  if wire.kind == JObject and wire.hasKey("completeContext") and
      (original == nil or wire != original):
    if wire.len != 1 or wire["completeContext"].kind != JObject:
      raise newException(ValueError, "Invalid complete context representation")
    return parseJson($wire["completeContext"])
  if wire.kind == JObject and wire.hasKey("fromContext") and
      (original == nil or wire != original):
    if previous == nil or previous.kind != JObject or
        wire["fromContext"].kind != JString or
        wire["fromContext"].getStr() != $secureHash($previous) or
        wire{"current"} == nil or wire["current"].kind != JObject:
      raise newException(ValueError, "Invalid prior admitted context identity")
    for field, value in wire:
      if field notin ["fromContext", "current", "protectedV1", "protectedV2", "boundedInherited"]:
        raise newException(ValueError, "Unknown context envelope key")
    result = parseJson($previous)
    if wire{"protectedV1"} != nil and wire{"protectedV2"} != nil:
      raise newException(ValueError, "Duplicate protected context versions")
    if wire{"protectedV1"} != nil or wire{"protectedV2"} != nil:
      let version2 = wire.hasKey("protectedV2")
      let values = wire[if version2: "protectedV2" else: "protectedV1"]
      if values.kind != JArray or values.len != 6:
        raise newException(ValueError, "Invalid protected context tuple arity")
      for i in 0 .. 3:
        if values[i].kind != JArray:
          raise newException(ValueError, "Invalid protected context tuple type")
        result[ProtectedFields[i]] = parseJson($values[i])
      if values[4].kind != JArray or values[4].len != 4 or
          values[4][0].kind != JString or values[4][1].kind != JString or values[4][2].kind != JInt or values[4][3].kind != JInt or not validElementTuple(values[5], version2):
        raise newException(ValueError, "Invalid protected target tuple")
      result["selectedStory"] = %* {"group":values[4][0], "name":values[4][1], "kind":values[4][2], "index":values[4][3]}
      result["selectedElement"] = newJObject()
      let fields = if version2: @ElementIdentityV2 else: @ElementIdentityV1
      for i, field in fields: result["selectedElement"][field] = parseJson($values[5][i])
      for field in ProtectedFields:
        if wire["current"]{field} != nil:
          raise newException(ValueError, "Duplicate protected context representation")
    else:
      for field in ProtectedFields:
        if (previous{field} != nil or (original != nil and original{field} != nil)) and wire["current"]{field} == nil:
          raise newException(ValueError, "Protected current context must remain explicit")
    if wire{"boundedInherited"} != nil:
      if wire["boundedInherited"].kind != JArray:
        raise newException(ValueError, "Invalid bounded inherited context fields")
      for field in wire["boundedInherited"]:
        if field.kind != JString or field.getStr() in ProtectedFields or
            previous{field.getStr()} == nil or wire["current"]{field.getStr()} != nil:
          raise newException(ValueError, "Invalid bounded inherited context field")
    for field, value in wire["current"]:
      if (original == nil or original{field} == nil or value != original[field]) and
          value.kind == JObject and value.len == 1 and value.hasKey("fromPreviousItems"):
        if field in ProtectedFields:
          raise newException(ValueError, "Protected context cannot inherit prior records")
        if previous{field} == nil or previous[field].kind != JArray or value["fromPreviousItems"].kind != JArray:
          raise newException(ValueError, "Invalid inherited context array")
        var reconstructed = newJArray()
        for item in value["fromPreviousItems"]:
          if item.kind != JObject or (item.len != 1 and item.len != 3):
            raise newException(ValueError, "Invalid inherited context record")
          if item.hasKey("reuse"):
            if item["reuse"].kind != JInt: raise newException(ValueError, "Invalid inherited context index")
            let index = item["reuse"].getInt(-1)
            if index < 0 or index >= previous[field].len: raise newException(ValueError, "Invalid inherited context index")
            var record = parseJson($previous[field][index])
            if item.len == 3:
              if not item.hasKey("set") or not item.hasKey("remove") or
                  item["set"].kind != JObject or item["remove"].kind != JArray or
                  record.kind != JObject:
                raise newException(ValueError, "Invalid changed admitted record")
              var removedKeys: seq[string]
              for key in item["remove"]:
                if key.kind != JString or key.getStr() in removedKeys or
                    not record.hasKey(key.getStr()) or item["set"].hasKey(key.getStr()):
                  raise newException(ValueError, "Invalid changed record removal")
                removedKeys.add key.getStr()
                record.delete(key.getStr())
              for key, replacement in item["set"]:
                record[key] = parseJson($replacement)
            reconstructed.add record
          elif item.len == 1 and item.hasKey("value"): reconstructed.add parseJson($item["value"])
          else: raise newException(ValueError, "Invalid inherited context record")
        result[field] = reconstructed
      else: result[field] = parseJson($value)
    return
  result = parseJson($wire)
  for field, value in wire:
    if (original == nil or original{field} == nil or value != original[field]) and
        value.kind == JObject and value.hasKey("previouslyDelivered") and
        previous != nil and previous{field} != nil and
        value["previouslyDelivered"].getStr() == $secureHash($previous[field]):
      result[field] = parseJson($previous[field])
    elif (original == nil or original{field} == nil or value != original[field]) and
        value.kind == JObject and value.hasKey("fromDelivered") and
        previous != nil and previous{field} != nil and previous[field].kind == JArray and
        value["fromDelivered"].getStr() == $secureHash($previous[field]):
      var reconstructed = newJArray()
      for item in value["items"]:
        if item.hasKey("reuse"):
          let index = item["reuse"].getInt(-1)
          if index < 0 or index >= previous[field].len:
            raise newException(ValueError, "Invalid prior delivered context record")
          reconstructed.add parseJson($previous[field][index])
        else: reconstructed.add parseJson($item["value"])
      result[field] = reconstructed
