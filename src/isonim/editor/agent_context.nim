## Editor-owned mapping from IsoNim context into ACP prompt content blocks.

import std/strutils
import nim_acp
import isonim/editor/types

proc storyToAcpContentBlocks*(story: StoryRef): seq[ContentBlock] =
  if story.group.len == 0 and story.name.len == 0:
    return @[]
  @[
    textBlock("story: " & story.group & "/" & story.name),
    textBlock("storyKind: " & $story.kind),
    textBlock("storyIndex: " & $story.index)
  ]

proc elementToAcpContentBlocks*(element: ElementRef): seq[ContentBlock] =
  if element.tag.len == 0:
    return @[]
  result.add textBlock("selectedElement: " & element.tag)
  if element.sourceFile.len > 0:
    result.add resourceBlock("file://" & element.sourceFile & "#L" & $element.sourceLine, "text/x-nim")
  for prop in element.properties:
    result.add textBlock("property: " & prop.name & "=" & prop.value & " origin=" & prop.originDetail)

proc editJournalToAcpContentBlocks*(edits: seq[EditRecord]): seq[ContentBlock] =
  if edits.len == 0:
    return @[]
  var lines: seq[string] = @["editJournal:"]
  for edit in edits:
    lines.add "- " & edit.file & ":" & $edit.line & " " & edit.property &
      " " & edit.oldValue & " -> " & edit.newValue
  @[textBlock(lines.join("\n"))]

proc sourceMapToAcpContentBlocks*(entries: seq[AgentSourceMapEntry]): seq[
    ContentBlock] =
  if entries.len == 0:
    return @[]
  var lines: seq[string] = @["sourceMap:"]
  for entry in entries:
    lines.add "- " & entry.elementTag & "." & entry.property & " -> " &
      entry.file & ":" & $entry.line & " origin=" & entry.originDetail &
      " schema=" & entry.schemaKey
  @[textBlock(lines.join("\n"))]

proc designSystemSchemaToAcpContentBlocks*(
    entries: seq[AgentDesignSystemSchemaEntry]): seq[ContentBlock] =
  if entries.len == 0:
    return @[]
  var lines: seq[string] = @["designSystemSchema:"]
  for entry in entries:
    lines.add "- " & entry.key & " kind=" & entry.kind & " file=" &
      entry.file & " path=" & entry.path & " property=" & entry.property
  @[textBlock(lines.join("\n"))]

proc diagnosticsToAcpContentBlocks*(
    diagnostics: seq[AgentDiagnosticSnapshot]): seq[ContentBlock] =
  if diagnostics.len == 0:
    return @[]
  var lines: seq[string] = @["diagnostics:"]
  for diagnostic in diagnostics:
    lines.add "- " & diagnostic.source & " " & diagnostic.severity & " " &
      diagnostic.category & " " & diagnostic.file & ":" & $diagnostic.line &
      " " & diagnostic.property & " " & diagnostic.message
  @[textBlock(lines.join("\n"))]

proc fileDiffsToAcpContentBlocks*(diffs: seq[AgentFileDiff]): seq[ContentBlock] =
  if diffs.len == 0:
    return @[]
  var lines: seq[string] = @["currentFileDiffs:"]
  for diff in diffs:
    lines.add "- " & diff.file & " " & diff.summary
  result.add textBlock(lines.join("\n"))
  for diff in diffs:
    if diff.file.len > 0:
      result.add resourceBlock("file://" & diff.file & "#pending-diff",
        "text/plain")

proc editorPromptContextToAcpContentBlocks*(context: AgentPromptContext;
    userPrompt: string): seq[ContentBlock] =
  if userPrompt.strip.len > 0:
    result.add textBlock(userPrompt.strip)
  result.add storyToAcpContentBlocks(context.selectedStory)
  result.add elementToAcpContentBlocks(context.selectedElement)
  result.add sourceMapToAcpContentBlocks(context.sourceMap)
  result.add editJournalToAcpContentBlocks(context.accumulatedEdits)
  result.add designSystemSchemaToAcpContentBlocks(context.designSystemSchema)
  result.add diagnosticsToAcpContentBlocks(context.diagnostics)
  result.add fileDiffsToAcpContentBlocks(context.currentFileDiffs)

proc editorContextToAcpContentBlocks*(story: StoryRef; element: ElementRef;
    edits: seq[EditRecord]; userPrompt: string): seq[ContentBlock] =
  var sourceMap: seq[AgentSourceMapEntry] = @[]
  for prop in element.properties:
    sourceMap.add AgentSourceMapEntry(
      elementTag: element.tag,
      property: prop.name,
      file: prop.sourceFile,
      line: prop.sourceLine,
      originDetail: prop.originDetail,
      schemaKey: prop.schemaKey,
      tokenName: prop.tokenName,
      variantKey: prop.variantKey)
  editorPromptContextToAcpContentBlocks(AgentPromptContext(
    selectedStory: story,
    selectedElement: element,
    accumulatedEdits: edits,
    sourceMap: sourceMap,
    platform: pfWeb), userPrompt)
