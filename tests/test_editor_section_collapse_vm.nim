## Phase C (2026-05-28) — section-collapse ViewModel tests.
##
## Exercises the inspector's collapsible-section machinery introduced
## by the editor-sidebar redesign:
##
##   * ``createEditorVM`` seeds the spec-mandated default open set
##     (Position / Layout / Appearance / Fill).
##   * ``toggleSectionExpanded`` adds a previously-collapsed section
##     to the set and removes a previously-open one.
##   * ``serializeExpandedSections`` / ``parseExpandedSections``
##     round-trip through the slug payload used by the localStorage
##     hydration.
##   * Unknown slugs in a serialized payload are silently dropped
##     (forwards-compat).
##   * ``applyExpandedSectionsFromStorage`` ignores an empty payload
##     (so a missing storage key keeps the default in place).

import std/[unittest, options, sequtils]

import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import isonim/editor/types
import isonim/editor/viewmodels

suite "Editor inspector section collapse (Phase C)":

  test "default_expandedSections_is_position_layout_appearance_fill":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      let expanded = vm.inspector.expandedSections.val
      # The spec's "Section catalogue" defaults Position / Layout /
      # Appearance / Fill open with Stroke / Effects / Export
      # collapsed. ``createInspectorVM`` seeds exactly that set so
      # the first-open editor reads the way the spec describes.
      check expanded.len == 4
      check isPosition in expanded
      check isLayout in expanded
      check isAppearance in expanded
      check isFill in expanded
      check isStroke notin expanded
      check isEffects notin expanded
      check isExport notin expanded
      check isTypography notin expanded
      check isSelectionColors notin expanded
      check isSource notin expanded
      check isComponentProps notin expanded
      check isState notin expanded
      dispose()

  test "toggleSectionExpanded_isPosition_removes_from_set":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      check isPosition in vm.inspector.expandedSections.val
      vm.inspector.toggleSectionExpanded(isPosition)
      check isPosition notin vm.inspector.expandedSections.val
      # The other defaults stay put — the toggle is per-section.
      check isLayout in vm.inspector.expandedSections.val
      check isAppearance in vm.inspector.expandedSections.val
      check isFill in vm.inspector.expandedSections.val
      dispose()

  test "toggleSectionExpanded_isStroke_adds_to_set":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      check isStroke notin vm.inspector.expandedSections.val
      vm.inspector.toggleSectionExpanded(isStroke)
      check isStroke in vm.inspector.expandedSections.val
      # Toggling Stroke does not disturb the four defaults.
      check isPosition in vm.inspector.expandedSections.val
      check isLayout in vm.inspector.expandedSections.val
      check isAppearance in vm.inspector.expandedSections.val
      check isFill in vm.inspector.expandedSections.val
      # And toggling it again flips it back off.
      vm.inspector.toggleSectionExpanded(isStroke)
      check isStroke notin vm.inspector.expandedSections.val
      dispose()

  test "serialize_and_parse_round_trip_through_storage_payload":
    let expanded = @[isPosition, isLayout, isAppearance, isFill]
    let payload = serializeExpandedSections(expanded)
    check payload == "position,layout,appearance,fill"
    check parseExpandedSections(payload) == expanded

  test "parseExpandedSections_drops_unknown_slugs":
    # A future editor build may persist a slug this build doesn't
    # know about. The parse drops the unknown entry and keeps the
    # rest so the hydration is forwards-compatible.
    let payload = "position,unicorn,fill, ,effects"
    let parsed = parseExpandedSections(payload)
    check parsed == @[isPosition, isFill, isEffects]

  test "parseExpandedSections_skips_duplicates_and_empty_entries":
    let payload = "position,position,, layout ,layout"
    let parsed = parseExpandedSections(payload)
    check parsed == @[isPosition, isLayout]

  test "applyExpandedSectionsFromStorage_empty_payload_keeps_default":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      let before = vm.inspector.expandedSections.val
      vm.inspector.applyExpandedSectionsFromStorage("")
      check vm.inspector.expandedSections.val == before
      dispose()

  test "applyExpandedSectionsFromStorage_replaces_with_payload":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.inspector.applyExpandedSectionsFromStorage(
        "stroke,effects,source")
      let after = vm.inspector.expandedSections.val
      check after == @[isStroke, isEffects, isSource]
      # The default four are gone — the storage payload is the
      # authoritative state once hydration runs.
      check isPosition notin after
      check isLayout notin after
      check isAppearance notin after
      check isFill notin after
      dispose()

  test "slug_round_trip_covers_all_catalogue_sections":
    # Every section in the catalogue maps to a slug and back. The
    # round-trip property pins the inspectorSectionToSlug ↔
    # inspectorSectionFromSlugOpt pairing — a Phase G addition
    # (new section in the catalogue) MUST extend the helpers
    # symmetrically or this test fails.
    const catalogueSections = [
      isPosition, isLayout, isAppearance, isFill, isStroke,
      isEffects, isTypography, isSelectionColors, isSource,
      isComponentProps, isState, isExport
    ]
    for section in catalogueSections:
      let slug = inspectorSectionToSlug(section)
      let roundTrip = inspectorSectionFromSlugOpt(slug)
      check roundTrip.isSome
      check roundTrip.get == section

  test "inspectorSectionFromSlugOpt_returns_none_for_unknown":
    check inspectorSectionFromSlugOpt("unicorn").isNone
    check inspectorSectionFromSlugOpt("").isNone
    check inspectorSectionFromSlugOpt("Position").isNone  # case-sensitive
