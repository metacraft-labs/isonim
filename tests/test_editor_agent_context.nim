import unittest
import std/sequtils
import std/strutils
import nim_acp
import isonim/editor/agent_context
import isonim/editor/types

suite "editor ACP context mapping":
  test "editor_agent_prompt_builds_acp_content_blocks":
    let story = StoryRef(group: "Button", name: "Primary", kind: skComponent, index: 2)
    let element = ElementRef(
      tag: "button",
      sourceFile: "/tmp/Button.nim",
      sourceLine: 12,
      properties: @[PropertyInfo(name: "padding", value: "12px", originDetail: "class:p-3")])
    let edits = @[EditRecord(file: "/tmp/Button.nim", line: 12, property: "padding",
      oldValue: "8px", newValue: "12px")]

    let blocks = editorContextToAcpContentBlocks(story, element, edits, "Make it roomier")
    check blocks.len >= 5
    check blocks[0].kind == cbText
    check blocks[0].text == "Make it roomier"
    check blocks[1].text == "story: Button/Primary"
    check blocks.anyIt(it.kind == cbResource and it.uri.contains("Button.nim#L12"))
