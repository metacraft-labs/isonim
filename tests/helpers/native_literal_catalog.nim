## Consumer-owned catalog adapter for the declared real native literal fixture.
## Rendering and CSS come from the fixture's actual public workspace API;
## this module only serializes its outputs into the source bridge's catalog.
import std/[json, strutils]
import isonim/editor/types
import editor/workspace
import components/styles

func kindName(kind: StoryKind): string =
  case kind
  of skPage: "page"
  of skComponent: "component"
  of skPattern: "pattern"
  of skFoundation: "foundation"
  of skFlow: "flow"
  of skGuideline: "guideline"
  of skVectorSymbol: "vector-symbol"

var rows = newJArray()
for group in gripStoryGroups():
  for index, item in group.items:
    let story = StoryRef(group: item.group, name: item.name,
      kind: item.kind, index: index)
    let preview = gripPreviewHook(story, pbWeb)
    doAssert preview.status == ppsRendered
    doAssert preview.documentHtml.len > 0
    # The producer may declare only constants the actual page embeds.
    doAssert designTokens in preview.documentHtml
    doAssert structureCss in preview.documentHtml
    rows.add %*{"group": story.group, "name": story.name,
      "kind": kindName(story.kind), "documentHtml": preview.documentHtml,
      "sourceFile": preview.metadata.sourceFile,
      "sourceLine": preview.metadata.sourceLine,
      "editableStylesheets": [
        {"file": "src/components/styles.nim", "const": "designTokens"},
        {"file": "src/components/styles.nim", "const": "structureCss"}]}
doAssert rows.len > 0
echo $(%*{"workspace": GripEditorId, "title": GripEditorTitle, "stories": rows})
