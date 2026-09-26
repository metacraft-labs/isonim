## The workspace facts the editor-compliance check reads (D6, D7).
##
## `tools/check_editor_compliance.py` answers D1-D5 from a rendered page and
## the project's token files. D6 (is what you declared reachable?) and D7 (does
## the edit contract cohere?) are questions about the **workspace declaration**,
## which is Nim, so something has to hand them over as data. This module is
## that something.
##
## **Why a JSON manifest rather than parsing the Nim.** A heuristic scan of
## `storyGroups()` for `skFoundation` would be wrong the first time a project
## built its groups in a loop, which is the normal way to build them — grip
## builds four of its five that way. The declaration is only reliably known by
## the program that makes it.
##
## **Why this module imports `isonim/editor/types` and nothing else.** So that
## a project can emit the manifest without compiling the editor. `newEditorWorkspace`
## lives in `isonim/editor/workspace`, which transitively pulls the
## streaming-preview runtime and its native adapters; grip's own `workspace.nim`
## documents why it keeps that import out, and a compliance check that needed
## the whole editor stack to run would not run in seconds. A project that CAN
## compile the editor should prefer `compliance_manifest_workspace.nim`, which
## takes the real `EditorWorkspace` and cannot be lied to.
##
## **The manifest is not a production artifact.** Nothing reads it at runtime;
## it is written by a small emitter beside the project's other emitters and
## consumed by the check.

import std/[json, sets]
import isonim/editor/types

const ComplianceManifestVersion* = 1
  ## Bumped when a field changes meaning. The Python side refuses a version it
  ## does not know rather than reading a field that has moved, because a check
  ## that silently misreads its input is worse than one that does not run.

func storyRefJson(story: StoryRef): JsonNode =
  %*{"group": story.group, "name": story.name, "kind": $story.kind,
     "index": story.index}

func storyItemJson(item: StoryItem): JsonNode =
  %*{"name": item.name, "kind": $item.kind, "group": item.group}

func storyGroupJson(group: StoryGroup): JsonNode =
  var items = newJArray()
  for item in group.items:
    items.add storyItemJson(item)
  %*{"name": group.name, "kind": $group.kind, "expanded": group.expanded,
     "items": items}

func tokenJson(token: FoundationTokenEntry): JsonNode =
  ## Deliberately partial. The check needs to know a token EXISTS, what domain
  ## it is in and where it is declared; it reads values, contrast and aliases
  ## from the DTCG files, which are the source of truth for them. Serialising
  ## them here would create a second copy that could disagree with the first.
  %*{"key": token.key, "kind": $token.kind,
     "sourceFile": token.sourceFile, "sourceLine": token.sourceLine,
     "schemaKey": token.schemaKey}

func propertyJson(property: ComponentPropertyDefinition): JsonNode =
  %*{"name": property.name, "kind": $property.kind,
     "schemaKey": property.schemaKey,
     "sourceFile": property.sourceFile, "sourceLine": property.sourceLine,
     "hasDocumentation": property.documentation.len > 0,
     "hasUsageGuidance": property.usageGuidance.len > 0}

func variantJson(variant: ComponentVariantDefinition): JsonNode =
  var properties = newJArray()
  for property in variant.properties:
    properties.add propertyJson(property)
  %*{"component": variant.component, "variantKey": variant.variantKey,
     "story": storyRefJson(variant.story),
     "fixtureName": variant.fixtureName,
     "properties": properties}

func schemaJson(entry: WorkspaceEditableSchemaEntry): JsonNode =
  %*{"key": entry.key, "kind": $entry.kind, "file": entry.file,
     "path": entry.path, "property": entry.property}

func permissionsJson(permissions: EditorWorkspacePermissions): JsonNode =
  %*{"readSource": permissions.readSource,
     "writeSource": permissions.writeSource,
     "createStory": permissions.createStory,
     "createVariant": permissions.createVariant,
     "duplicate": permissions.duplicate,
     "delete": permissions.delete}

proc complianceManifest*(
    id, title: string;
    storyGroups: seq[StoryGroup];
    foundationTokens: seq[FoundationTokenEntry] = @[];
    componentVariants: seq[ComponentVariantDefinition] = @[];
    schema: seq[WorkspaceEditableSchemaEntry] = @[];
    permissions = EditorWorkspacePermissions();
    hasEditAdapter = false;
    platform = pbWeb;
    allowedPlatforms: set[PreviewBackend] = {}): JsonNode =
  ## Build the manifest from a workspace's PIECES.
  ##
  ## `hasEditAdapter` is the one fact this form cannot verify, because the
  ## adapter is not among the pieces. A project should pass
  ## `myEditAdapter().isNil == false` — calling the same proc its mount passes
  ## — rather than a hand-written literal, so that the claim and the thing it
  ## claims about cannot drift. `compliance_manifest_workspace.nim` removes the
  ## question entirely for projects that can compile the editor.
  var groups = newJArray()
  for group in storyGroups:
    groups.add storyGroupJson(group)
  var tokens = newJArray()
  for token in foundationTokens:
    tokens.add tokenJson(token)
  var variants = newJArray()
  for variant in componentVariants:
    variants.add variantJson(variant)
  var entries = newJArray()
  for entry in schema:
    entries.add schemaJson(entry)
  var platforms = newJArray()
  for backend in allowedPlatforms:
    platforms.add %($backend)

  %*{
    "schemaVersion": ComplianceManifestVersion,
    "id": id,
    "title": title,
    "storyGroups": groups,
    "foundationTokens": tokens,
    "componentVariants": variants,
    "schema": entries,
    "permissions": permissionsJson(permissions),
    "hasEditAdapter": hasEditAdapter,
    "platform": $platform,
    "allowedPlatforms": platforms,
  }
