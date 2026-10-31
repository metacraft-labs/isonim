## Export the copied GRIP project's actual public story registry and SSR previews.
## No catalog HTML, story list or compiler result is substituted by this fixture.
import std/json
import isonim/editor/types
import editor/workspace

var stories = newJArray()
for group in gripStoryGroups():
  for index, item in group.items:
    let story = StoryRef(group: group.name, name: item.name,
      kind: item.kind, index: index)
    let preview = gripPreviewHook(story, pbWeb)
    doAssert preview.status == ppsRendered
    stories.add(%* {"group": group.name, "name": item.name,
      "kind": (if item.kind == skPage: "page" else: "component"),
      "documentHtml": preview.documentHtml})
echo $(%* {"stories": stories})
