## Phase G+1 — source-edit writeback for the section-based inspector.
##
## Phase A demolished the 12-sub-tab inspector and Phases B–H rebuilt
## the chrome as twelve ``section_*.nim`` widgets. The writeback did
## not come with it: not one section passed ``onChange`` to
## ``mountPropertyRow``, ``shell.nim``'s ``inspectorPropertyEditHandler``
## was never called, and typing a value in the mounted inspector was a
## silent no-op — no staging, no diagnostic, no refusal.
##
## This module is the missing half. It is deliberately a *transcription*
## of the decision ``component_edit.nim::renderPropertyInput`` already
## makes, not a second opinion about it. Two implementations that
## disagree about which source scope owns a property would disagree in
## exactly the cases nobody has a test for, so the scope-selection rule
## and the commit dispatch below are copied verbatim from that proc
## (``component_edit.nim`` ~1884-1935) and the correspondence is called
## out at each site. When that rule changes, both must change together;
## the old path is still mounted nowhere but is still the reference.
##
## Layering: this module imports ``viewmodels`` and ``choice_row`` but
## NOT ``property_row``, so ``property_row`` can import it for the
## wiring type without a cycle. It owns no view markup — it hands the
## row a thunk of choice chips, a commit closure, and two signals.
##
## Test fixture: ``tests/test_editor_viewmodels.nim`` §"inspector
## section writeback".

import std/options

import isonim/core/signals
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/choice_row

# --------------------------------------------------------------------------- #
#  Scope labelling.
#
#  ``sourceScopeAbbrev`` / ``sourceScopeRiskLabel`` are private `func`s in
#  ``component_edit.nim``. They are pure enum→string maps and importing
#  that 5000-line module to reach them would pull the whole legacy
#  inspector into every section. Transcribed instead, with the same
#  strings, so a chip in the new inspector reads identically to a chip
#  in the old one.
# --------------------------------------------------------------------------- #

func sourceScopeAbbrev*(kind: SourceScopeChoiceKind): string =
  case kind
  of sskLocalInstance: "Loc"
  of sskStoryFixture: "Fix"
  of sskComponentSchemaApi: "API"
  of sskSharedClass: "Cls"
  of sskComponentToken: "Tok"
  of sskSemanticToken: "Sem"
  of sskGlobalPrimitiveToken: "Prim"

func sourceScopeRiskLabel*(risk: SourceScopeRiskLevel): string =
  case risk
  of ssrNone: "none"
  of ssrLow: "low"
  of ssrMedium: "med"
  of ssrHigh: "high"

func sourceScopeApplyLabel*(kind: SourceScopeChoiceKind): string =
  ## The verb form used in the chip's ``aria-label``. Matches the old
  ## row's "Apply <label> source scope for <property>" phrasing, which
  ## is what ``e2e_style_manager_scope_choices_update_real_preview``
  ## resolves ("Apply local instance scope for padding").
  case kind
  of sskLocalInstance: "local instance"
  of sskStoryFixture: "story fixture"
  of sskComponentSchemaApi: "component schema"
  of sskSharedClass: "shared class"
  of sskComponentToken: "component token"
  of sskSemanticToken: "semantic token"
  of sskGlobalPrimitiveToken: "global primitive token"

# --------------------------------------------------------------------------- #
#  Property + scope resolution.
# --------------------------------------------------------------------------- #

proc inspectorProperty*(vm: EditorVM; property: string): Option[PropertyInfo] =
  ## The selected element's ``PropertyInfo`` for ``property``, or
  ## ``none`` when nothing is selected or the element does not expose
  ## it. The sections address properties by CSS name (the same string
  ## they already pass to ``inspectorBindingThunk``), so the lookup is
  ## by name rather than by index.
  let element = vm.inspector.selectedElement.val
  for prop in element.properties:
    if prop.name == property:
      return some(prop)
  none(PropertyInfo)

proc defaultScopeIndex*(choices: seq[SourceScopeChoice];
    prop: PropertyInfo): int =
  ## VERBATIM from ``renderPropertyInput`` (component_edit.nim ~1905):
  ##
  ##   var selectedScopeIndex = 0
  ##   for i in 0 ..< scopeChoices.len:
  ##     if scopeChoices[i].kind != sskLocalInstance and
  ##         scopeChoices[i].editable and
  ##         (prop.sharedCount > 0 or prop.tokenName.len > 0 or
  ##          prop.schemaKey.len > 0):
  ##       selectedScopeIndex = i
  ##       break
  ##
  ## Reads as: a property that is shared, token-backed or schema-owned
  ## defaults to the first editable non-local scope; everything else
  ## defaults to whatever is first (in practice the local instance).
  ##
  ## The original also counted ``editableScopeCount`` in the same loop
  ## and never read it; that dead local is the one thing not carried
  ## over. The rule itself is unchanged.
  result = 0
  for i in 0 ..< choices.len:
    if choices[i].kind != sskLocalInstance and choices[i].editable and
        (prop.sharedCount > 0 or prop.tokenName.len > 0 or
         prop.schemaKey.len > 0):
      return i

proc orderedScopeIndexes*(choices: seq[SourceScopeChoice];
    selectedIndex: int): seq[int] =
  ## VERBATIM from ``renderPropertyInput`` (component_edit.nim ~1943):
  ## local instance first, then shared class, then the selected scope
  ## if it is neither, then everything else in declaration order. The
  ## strip shows the head of this list and the overflow popup holds
  ## the tail, which is the spec's "common scopes remain visible,
  ## overflow lists less common or read-only scopes"
  ## (isonim-editor.md §"Edit Routing", ~1886).
  result = @[]
  for preferred in [sskLocalInstance, sskSharedClass]:
    for i in 0 ..< choices.len:
      if choices[i].kind == preferred and i notin result:
        result.add i
        break
  if selectedIndex >= 0 and selectedIndex notin result:
    result.add selectedIndex
  for i in 0 ..< choices.len:
    if i notin result:
      result.add i

# --------------------------------------------------------------------------- #
#  Commit.
# --------------------------------------------------------------------------- #

type
  PropertyCommitOutcome* = object
    ## The result of one row commit. ``ok`` is false for every refusal
    ## — a missing selection, a read-only workspace, an absent adapter,
    ## a non-editable scope, or a rejected value — and ``message`` is
    ## never empty when ``ok`` is false. The row renders ``message``
    ## inline; a refusal that reaches the user as blank UI is the
    ## defect this whole module exists to remove.
    ok*: bool
    message*: string
    scope*: SourceScopeChoiceKind
    committedValue*: string

func refusal(message: string; scope = sskLocalInstance): PropertyCommitOutcome =
  PropertyCommitOutcome(ok: false, message: message, scope: scope)

proc firstDiagnosticMessage(diagnostics: seq[PropertyEditDiagnostic];
    fallback: string): string =
  for d in diagnostics:
    if d.message.len > 0:
      return d.message
  fallback

proc commitInspectorValue*(vm: EditorVM; property, rawValue: string;
    scope: SourceScopeChoiceKind): PropertyCommitOutcome =
  ## Commit ``rawValue`` for ``property`` at ``scope``.
  ##
  ## The dispatch is VERBATIM from ``renderPropertyInput``'s
  ## ``commitScope`` (component_edit.nim ~1919):
  ##
  ##   let nextValue = normalizePrimitiveInputValue(propName, <input>)
  ##   if kind == sskLocalInstance:
  ##     vm.applyInspectorValue(propName, nextValue, pesLocal)
  ##   else:
  ##     discard vm.editSharedDesignProperty(propName, nextValue, kind)
  ##
  ## where ``applyInspectorValue`` (component_edit.nim:1625) is
  ## ``vm.editCssProperty(propName, normalizePrimitiveInputValue(...),
  ## scope, peoInspector)``. The normalisation is what turns ``6*4px``
  ## into ``24px`` — ``evalNumericExpression`` inside
  ## ``normalizePrimitiveInputValue`` is the expression parser, and it
  ## is reached here exactly as the old path reached it.
  ##
  ## What is NOT verbatim, and is the point of the exercise: the old
  ## path discarded both results. Every refusal below was already being
  ## computed and thrown away.
  let element = vm.inspector.selectedElement.val
  if element.tag.len == 0:
    return refusal("Select an element before editing " & property & ".", scope)

  let found = vm.inspectorProperty(property)
  if found.isNone:
    return refusal("The selected element does not expose " & property & ".",
      scope)

  # The permission gate, read before the edit rather than at Save.
  # `applyWorkspaceFileEdits` refuses a read-only workspace with this
  # exact sentence (viewmodels.nim:7731) but only once the user tries
  # to save, which is several interactions after the one that needs
  # the answer. Staging an edit that can never be written is itself a
  # silent failure, so the row says so at the keystroke.
  if not vm.workspacePermissions.val.writeSource:
    return refusal("This workspace is read-only for source changes.", scope)

  let normalized = normalizePrimitiveInputValue(property, rawValue)

  if scope == sskLocalInstance:
    let res = vm.editCssProperty(property, normalized, pesLocal, peoInspector)
    if res.status != pesAccepted:
      return refusal(firstDiagnosticMessage(res.diagnostics,
        "This edit to " & property & " was rejected."), scope)
  else:
    let res = vm.editSharedDesignProperty(property, normalized, scope)
    if res.status != pesAccepted:
      return refusal(firstDiagnosticMessage(res.diagnostics,
        "This scope has no source-backed writer in the project schema."),
        scope)

  # An accepted edit with no adapter is staged but unwritable. That is
  # a weaker condition than the two above — the journal is real and
  # Revert works — so it reports as a warning-shaped message rather
  # than as a rejection, but it still reports.
  if not vm.sourceAdapterReady.val:
    return PropertyCommitOutcome(ok: false,
      message: "Staged, but no source edit adapter is ready to write it.",
      scope: scope, committedValue: normalized)

  PropertyCommitOutcome(ok: true, message: "", scope: scope,
    committedValue: normalized)

# --------------------------------------------------------------------------- #
#  Row wiring — what a section hands to ``mountPropertyRow``.
# --------------------------------------------------------------------------- #

type
  InspectorRowWiring* = object
    ## One property row's connection to the source-edit pipeline.
    ## Built once per row by ``inspectorRowWiring`` and splatted into
    ## ``PropertyRowConfig`` by the row constructors. A zeroed value
    ## (``cssProperty == ""``) leaves the row exactly as it behaved
    ## before Phase G+1, which is what the widget's own test fixture
    ## and any non-inspector caller get.
    cssProperty*: string
    scopeSelected*: Signal[SourceScopeChoiceKind]
    commitMessage*: Signal[string]
    commitRejected*: Signal[int]
      ## Bumped every time a commit is REFUSED. The row snapshots this
      ## counter around its call to `commit` and, when it advances, puts its
      ## own control back the way it was. Without it a refused edit left the
      ## typed value sitting in the field: the panel said 42, the element was
      ## still 34, and the only thing saying so was a one-line message the
      ## eye slides past. A control that keeps a value the system rejected is
      ## lying about the document.
    scopeOptions*: proc(): seq[CompactChoiceOption]
    commit*: proc(value: string)

proc inspectorRowWiring*(vm: EditorVM; property: string): InspectorRowWiring =
  ## Wire one row to ``property``.
  ##
  ## ``scopeSelected`` seeds lazily: the scope choices depend on the
  ## selected element, which changes under the row, so the thunk
  ## recomputes ``defaultScopeIndex`` on every read and only honours a
  ## user's explicit pick while it stays applicable. That mirrors the
  ## old row, which recomputed the whole strip each time the inspector
  ## re-rendered a property.
  let capturedProperty = property
  let selected = createSignal(sskLocalInstance)
  let userPicked = createSignal(false)
  let message = createSignal("")
  let rejected = createSignal(0)

  proc currentChoices(): seq[SourceScopeChoice] =
    let found = vm.inspectorProperty(capturedProperty)
    if found.isNone: return @[]
    vm.sourceScopeChoices(found.get)

  proc effectiveScope(): SourceScopeChoiceKind =
    let choices = currentChoices()
    if choices.len == 0:
      return sskLocalInstance
    if userPicked.val:
      for choice in choices:
        if choice.kind == selected.val:
          return selected.val
    let found = vm.inspectorProperty(capturedProperty)
    if found.isNone:
      return sskLocalInstance
    let idx = defaultScopeIndex(choices, found.get)
    if idx >= 0 and idx < choices.len: choices[idx].kind else: sskLocalInstance

  proc commit(value: string) =
    let outcome = commitInspectorValue(vm, capturedProperty, value,
      effectiveScope())
    message.val = outcome.message
    if not outcome.ok:
      rejected.val = rejected.val + 1

  proc scopeOptions(): seq[CompactChoiceOption] =
    let choices = currentChoices()
    if choices.len == 0:
      return @[]
    let active = effectiveScope()
    var selectedIndex = -1
    for i in 0 ..< choices.len:
      if choices[i].kind == active:
        selectedIndex = i
        break
    result = @[]
    for i in orderedScopeIndexes(choices, selectedIndex):
      let choice = choices[i]
      let kind = choice.kind
      let editable = choice.editable
      let label = choice.label
      let risk = choice.riskLevel.sourceScopeRiskLabel()
      result.add CompactChoiceOption(
        label: label & " " & risk,
        shortLabel: kind.sourceScopeAbbrev(),
        # Same phrasing as the old row so a caller (or a test) that
        # knows one knows the other.
        ariaLabel: "Apply " & kind.sourceScopeApplyLabel() &
          " scope for " & capturedProperty,
        selected: i == selectedIndex,
        enabled: editable,
        dataAttrs: @[("data-source-scope-editable",
          if editable: "true" else: "false"),
          ("data-source-scope-kind", $kind)],
        onChoose: (proc() =
          if editable:
            selected.val = kind
            userPicked.val = true
            message.val = ""
          else:
            # A non-editable scope is not silently inert. The old row
            # made the chip unclickable and said nothing; saying why
            # costs one line and is the difference between "this
            # control is broken" and "this scope is read-only".
            message.val =
              if choice.reason.len > 0: choice.reason
              else: "This scope has no source-backed writer in the " &
                "project schema."))

  InspectorRowWiring(
    cssProperty: capturedProperty,
    scopeSelected: selected,
    commitMessage: message,
    commitRejected: rejected,
    scopeOptions: scopeOptions,
    commit: commit)
