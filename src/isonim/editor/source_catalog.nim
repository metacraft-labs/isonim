## Portable catalog data for an opt-in project source/build bridge. The producer
## owns rendering and source schemas; this module only reads its typed output.
import std/[json, tables, sets, strutils]
import isonim/editor/[types, workspace, html_classes]

proc sourceStoryIdentityPrefix*(storyId: string): string =
  result = "isonim-source"
  for character in storyId:
    result.add toHex(ord(character), 2)

proc sourceCatalogMarkup*(catalog, manifest: JsonNode): JsonNode =
  ## The opt-in producer declares source capability; compiler-owned identities
  ## are inserted with the same lossless tokenizer used for native bindings.
  result = catalog.copy()
  if manifest{"editableStyleSources"} == nil: return
  for row in result{"stories"}:
    let storyId = row{"group"}.getStr() & " / " & row{"name"}.getStr()
    row["documentHtml"] = %sourceElementMarkup(row{"documentHtml"}.getStr(),
      sourceStoryIdentityPrefix(storyId)).html

proc sourceStoryKind*(row: JsonNode): StoryKind =
  case row{"kind"}.getStr()
  of "page": skPage
  of "component": skComponent
  of "foundation": skFoundation
  of "pattern": skPattern
  of "flow": skFlow
  of "guideline": skGuideline
  of "vector-symbol": skVectorSymbol
  else: raise newException(ValueError, "Unknown catalog story kind.")

proc sourceFixtures*(manifest: JsonNode): seq[ComponentVariantDefinition] =
  for fixture in manifest{"fixtures"}:
    let component = fixture{"component"}.getStr()
    let variant = fixture{"variant"}.getStr()
    var position = -1
    for index, entry in result:
      if entry.component == component and entry.variantKey == variant: position = index
    if position < 0:
      result.add ComponentVariantDefinition(component: component, variantKey: variant)
      position = result.high
    result[position].stateControls.add ComponentStateControl(
      key: fixture{"state"}.getStr(), sourceFile: fixture{"file"}.getStr(),
      sourceLine: 1, schemaKey: fixture{"schemaKey"}.getStr())

proc sourceCatalogWorkspace*(catalog, manifest: JsonNode; base: EditorWorkspace): EditorWorkspace =
  if catalog == nil or catalog.kind != JObject or catalog{"stories"} == nil or catalog["stories"].kind != JArray:
    raise newException(ValueError, "Rendered story catalog required.")
  if manifest == nil or manifest.kind != JObject or manifest{"fixtures"} == nil or manifest["fixtures"].kind != JArray:
    raise newException(ValueError, "Source fixture contract required.")
  var identities = initTable[string, StoryKind]()
  for group in base.storyGroups:
    for item in group.items:
      let id = item.group & " / " & item.name
      if identities.hasKey(id): raise newException(ValueError, "Ambiguous existing story ID: " & id)
      identities[id] = item.kind
  var incoming = initHashSet[string]()
  for row in catalog["stories"]:
    let id = row{"group"}.getStr() & " / " & row{"name"}.getStr()
    let kind = sourceStoryKind(row)
    if id in incoming or (identities.hasKey(id) and identities[id] != kind):
      raise newException(ValueError, "Ambiguous compiled story ID: " & id)
    incoming.incl(id)
  result = base
  result.componentVariants = sourceFixtures(manifest)
  for row in catalog{"stories"}:
    let kind = sourceStoryKind(row)
    let group = row{"group"}.getStr()
    let item = StoryItem(group: group, name: row{"name"}.getStr(), kind: kind)
    var found = -1
    for index, existing in result.storyGroups:
      if existing.name == group and existing.kind == kind: found = index
    if found < 0:
      result.storyGroups.add StoryGroup(name: group, kind: kind, expanded: true)
      found = result.storyGroups.high
    var duplicate = false
    for existing in result.storyGroups[found].items:
      if existing.name == item.name: duplicate = true
    if not duplicate: result.storyGroups[found].items.add item
  for index, variant in result.componentVariants:
    for stateIndex, state in variant.stateControls:
      for group in result.storyGroups:
        for itemIndex, item in group.items:
          if item.group == variant.component and item.name == variant.variantKey & " " & state.key:
            result.componentVariants[index].stateControls[stateIndex].story = StoryRef(
              group: item.group, name: item.name, kind: item.kind, index: itemIndex)
  let previous = base.previewHook
  result.previewHook = proc(story: StoryRef; platform: Platform): ProjectPreview =
    for row in catalog{"stories"}:
      if row{"group"}.getStr() == story.group and row{"name"}.getStr() == story.name and sourceStoryKind(row) == story.kind:
        var rendered = if previous != nil: previous(story, platform) else: ProjectPreview()
        rendered.status = ppsRendered
        rendered.story = story
        if rendered.title.len == 0: rendered.title = story.name
        rendered.documentHtml = if manifest{"editableStyleSources"} == nil:
          row{"documentHtml"}.getStr()
        else:
          sourceElementMarkup(row{"documentHtml"}.getStr(),
            sourceStoryIdentityPrefix(story.group & " / " & story.name)).html
        rendered.metadata.story = story
        for fixture in manifest{"fixtures"}:
          if fixture{"component"}.getStr() == story.group and
              fixture{"variant"}.getStr() & " " & fixture{"state"}.getStr() == story.name:
            rendered.metadata.sourceFile = fixture{"file"}.getStr()
            rendered.metadata.sourceLine = 1
            rendered.metadata.fixtureName = fixture{"schemaKey"}.getStr()
        return rendered
    if previous != nil: return previous(story, platform)
    ProjectPreview(status: ppsUnsupportedStory, story: story)
