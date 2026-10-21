## Phase G — Source section body widget.
##
## Section catalogue (spec § "Section catalogue"):
##
##   * File path + line — "src/path.nim:42".
##   * Source scope (Local / Shared / Component schema / Theme token).
##   * Staged commit count (number of pending source edits).
##   * Ownership warnings — surface ``inspector.conflicts`` summary.

import std/[options, strutils]

import isonim/core/signals
import isonim/core/computation
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels

const
  textPrimary = "#ECEDF3"
  textSecondary = "#9CA0B0"
  textMuted = "#6B6F80"
  textDim = "#4A4D5C"
  warn = "#F59E0B"
  border = "#2A2C3A"

proc propertyScopeLabel(schema: DesignSystemSchema; element: ElementRef;
    prop: PropertyInfo): string =
  # An ownership edge identifies the owner even if its writer is unavailable or
  # its source is unstructured. Editability is a separate concern.
  if designSourceOwnershipIsAmbiguous(schema, element, prop): return "Unknown"
  var nativeLabel: string
  # Compiler-owned native mappings use the same complete declaration contract
  # as the row's scope choices. Reserved identities alone are not ownership.
  if prop.nativeSourceShared and prop.sourceFile.len > 0 and
      prop.authoredValue.len > 0:
    let token = prop.nativeSourceToken and prop.tokenName.len > 0 and
      prop.schemaKey.startsWith("tokens.native.")
    let shared = not prop.nativeSourceToken and
      prop.schemaKey.startsWith("classes.native.")
    if token or shared:
      let kind = if token: sskSemanticToken else: sskSharedClass
      for choice in sourceScopeChoices(schema, element, prop):
        if choice.kind == kind and choice.schemaKey == prop.schemaKey and
            choice.sourceFile == prop.sourceFile:
          nativeLabel = if token: "Theme token" else: "Shared"

  let mapped = resolveDesignSourceOwnership(schema, element, prop.name)
  if mapped.nodeKey.len > 0:
    if nativeLabel.len > 0:
      let file = if mapped.ownership.sourceSpan.file.len > 0:
        mapped.ownership.sourceSpan.file else: mapped.schemaNode.sourceSpan.file
      let matchingKind = if nativeLabel == "Shared":
        sourceScopeKindForNode(mapped.schemaNode.kind) == sskSharedClass
        else: sourceScopeKindForNode(mapped.schemaNode.kind) in {
          sskComponentToken, sskSemanticToken, sskGlobalPrimitiveToken}
      if mapped.nodeKey != prop.schemaKey or file != prop.sourceFile or not matchingKind:
        return "Unknown"
    # A fallback/class-list rewrite mechanism does not establish the domain of
    # its actual destination. Do not promote its incidental schema node to an
    # ownership assertion when that destination is not mapped separately.
    if mapped.planKind in {cspInlineStyleUpdate, cspTailwindClassReplacement}:
      return "Unknown"
    case sourceScopeKindForNode(mapped.schemaNode.kind)
    of sskLocalInstance, sskStoryFixture: return "Local"
    of sskComponentSchemaApi: return "Component schema"
    of sskSharedClass: return "Shared"
    of sskComponentToken, sskSemanticToken, sskGlobalPrimitiveToken:
      return "Theme token"

  if nativeLabel.len > 0: return nativeLabel
  if prop.origin == poThemeToken: return "Theme token"
  if not prop.nativeSourceShared and not prop.nativeSourceToken and
      prop.sourceFile.len > 0 and (prop.schemaKey.len == 0 or
        prop.schemaKey.startsWith("dom.")) and
      (prop.origin == poSetStyle or
        (prop.directStyleAllowed and prop.authoredValue.len > 0)):
    return "Local"
  "Unknown"

proc deriveScopeLabel(schema: DesignSystemSchema; element: ElementRef): string =
  # This row summarizes all exposed properties, rather than promoting one
  # guessed identity/count to a whole-element ownership assertion.
  var known: seq[string]
  var unknown = element.properties.len == 0
  for prop in element.properties:
    let label = propertyScopeLabel(schema, element, prop)
    if label == "Unknown": unknown = true
    elif label notin known: known.add label
  if unknown: "Unknown"
  elif known.len > 1: "Mixed"
  else: known[0]

proc mountSectionSource*[R, E](r: R; parent: E; vm: EditorVM) =
  ## Mount the Source section body. The section is read-only for
  ## Phase G — it surfaces the four metadata rows the spec calls out
  ## (file:line, scope, staged commits, ownership warnings).
  var fileLineEl: E
  var scopeEl: E
  var stagedEl: E
  var ownershipEl: E

  let body = ui(r):
    tdiv(`data-source-section-body` = "true",
         display = "flex", flex_direction = "column",
         gap = "8px", padding = "4px 0"):
      # File path + line row.
      tdiv(`data-source-row` = "file",
            display = "flex", flex_direction = "row",
            align_items = "center", gap = "6px",
            font_size = "11px"):
        span(color = textMuted, min_width = "60px"): text "File"
        span(ref = fileLineEl,
              `data-source-file-line` = "true",
              color = textPrimary,
              font_family = "monospace",
              overflow = "hidden",
              text_overflow = "ellipsis",
              white_space = "nowrap",
              flex = "1"):
          text "—"
      # Scope row.
      tdiv(`data-source-row` = "scope",
            display = "flex", flex_direction = "row",
            align_items = "center", gap = "6px",
            font_size = "11px"):
        span(color = textMuted, min_width = "60px"): text "Scope"
        span(ref = scopeEl,
              `data-source-scope` = "true",
              color = textSecondary):
          text "Local"
      # Staged commits row.
      tdiv(`data-source-row` = "staged",
            display = "flex", flex_direction = "row",
            align_items = "center", gap = "6px",
            font_size = "11px"):
        span(color = textMuted, min_width = "60px"): text "Staged"
        span(ref = stagedEl,
              `data-source-staged-count` = "true",
              color = textSecondary):
          text "0"
      # Ownership warnings row — kept always-present so the data
      # attribute is queryable by tests even when empty.
      tdiv(`data-source-row` = "ownership",
            display = "flex", flex_direction = "column", gap = "4px",
            border = "1px solid " & border, border_radius = "4px",
            padding = "6px 8px", background_color = "#0F172A",
            font_size = "11px"):
        span(color = textDim, font_size = "10px",
              text_transform = "uppercase", letter_spacing = "0.4px"):
          text "Ownership"
        span(ref = ownershipEl,
              `data-source-ownership` = "true",
              color = textSecondary):
          text "No conflicts"
  r.appendChild(parent, body)

  # Shared edits need their ownership and affected uses visible before a
  # commit. Keep this source-aware summary beside the source scope rather
  # than resurrecting the removed tabbed inspector.
  let impact = ui(r):
    tdiv(`data-design-system-impact` = "true",
         `aria-label` = "Shared design-system editors",
         display = "flex", flex_direction = "column", gap = "6px",
         padding = "6px 0", font_size = "11px", color = textSecondary,
         overflow_wrap = "anywhere")
  r.appendChild(parent, impact)
  createRenderEffect proc() =
    var editors: seq[SharedDesignPropertyEditor]
    let schema = vm.designSystemSchema.val
    for candidate in vm.sharedDesignPropertyEditors():
      # Unmapped hypothetical scopes are not affected uses. Their refusal
      # remains on the row; the impact panel lists actual declared owners.
      for node in schema.nodes:
        if node.key == candidate.sourceScope.schemaKey:
          editors.add candidate
          break
    let previews = vm.sharedDesignCommitPreviews()
    r.setAttribute(impact, "data-shared-design-editor-count", $editors.len)
    r.setAttribute(impact, "data-shared-design-commit-preview-count", $previews.len)
    r.clearChildren(impact)
    for editor in editors:
      let description = editor.property & " | " & sharedDesignCategoryLabel(editor.category) &
        " | " & editor.sourceScope.label & " | " & editor.sourceScope.schemaKey &
        " | " & $editor.sourceScope.usageCount & " mapped uses"
      let row = ui(r):
        tdiv(): text description
      r.appendChild(impact, row)
    for preview in previews:
      let property = preview.property
      let detail = preview.property & " | " & sourceScopeChoiceLabel(preview.sourceScope) &
        "\n" & preview.sourceDiff & "\nAffected components: " &
        preview.affectedComponents.join(", ") & "\n" & preview.previewStateLabel &
        "\nRegeneration: " & (if preview.regenerationRequired: "required" else: "not required")
      let row = ui(r):
        tdiv(`data-shared-design-commit-preview` = property,
             white_space = "pre-wrap", overflow_wrap = "anywhere"):
          text detail
      r.appendChild(impact, row)

  createRenderEffect proc() =
    let el = vm.inspector.selectedElement.val
    if vm.inspector.hasElement.val:
      let label =
        if el.sourceFile.len > 0 and el.sourceLine > 0:
          el.sourceFile & ":" & $el.sourceLine
        elif el.sourceFile.len > 0: el.sourceFile
        else: "—"
      r.setTextContent(fileLineEl, label)
      r.setTextContent(scopeEl, deriveScopeLabel(vm.designSystemSchema.val, el))
    else:
      r.setTextContent(fileLineEl, "—")
      r.setTextContent(scopeEl, "—")

  createRenderEffect proc() =
    let staged = vm.inspector.pendingSourceEdits.val.len
    r.setTextContent(stagedEl, $staged)

  createRenderEffect proc() =
    let conflicts = vm.inspector.conflicts.val
    if conflicts.len == 0:
      r.setTextContent(ownershipEl, "No conflicts")
      r.setAttribute(ownershipEl, "data-source-ownership-warning", "false")
      r.setStyle(ownershipEl, "color", textSecondary)
    else:
      r.setTextContent(ownershipEl,
        $conflicts.len & " conflict(s)")
      r.setAttribute(ownershipEl, "data-source-ownership-warning", "true")
      r.setStyle(ownershipEl, "color", warn)
