## Native full production shell Source controls. The shared fixture explicitly
## justifies MockRenderer and declared ownership metadata; no transport/source
## outcome is substituted. Full-shell MockRenderer JS compilation remains an
## unresolved canvas-bridge prerequisite, recorded separately, not skipped here.
import std/[unittest,options,tables,strutils,sequtils]
import isonim/core/[signals,computation,owner]
import isonim/testing/mock_dom
import isonim/editor/viewmodels
import isonim/editor/views/shell
import helpers/editor_source_scope_label_cases
proc mountNativeShell(r:MockRenderer;vm:EditorVM):MockNode =
  renderEditorShell[MockRenderer,MockNode](r,vm)
sourceScopeLabelCases(mountNativeShell)
