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

proc editorContextToAcpContentBlocks*(story: StoryRef; element: ElementRef;
    edits: seq[EditRecord]; userPrompt: string): seq[ContentBlock] =
  if userPrompt.strip.len > 0:
    result.add textBlock(userPrompt.strip)
  result.add storyToAcpContentBlocks(story)
  result.add elementToAcpContentBlocks(element)
  result.add editJournalToAcpContentBlocks(edits)
