## Accepted colour writeback through the actual consumer production adapter.
## No adapter callback, source storage, patch/write operation or compiler is mocked.
## A private authored Nim stylesheet uses the public token schema that the existing
## metacraftBackOfficeEditAdapter owns. The real shared colour popup edits the
## inline-variable draft; the actual inline Save journals a foundation edit; the
## production transaction/adapter writes the real file, and Nim compiles/runs it.
## MockRenderer substitutes only the DOM to drive renderer-neutral control events;
## actual geometry/focus/refusal is covered separately by the full mounted GUI.
## This optional-sibling test fails when explicitly requested without its consumer;
## the default popup suite remains usable without the private metacraft-web repo.
import std/[os, osproc, tempfiles, strutils, tables, unittest, options]
import isonim/core/[signals, computation, owner]
import isonim/editor
import isonim/editor/views/widgets/[color_popover, variable_inline_editor]
import isonim/testing/mock_dom
import backoffice_editor/workspace

proc find(node: MockNode; attr, value: string): MockNode =
  if node == nil: return nil
  if node.attributes.getOrDefault(attr) == value: return node
  for child in node.children:
    result = find(child, attr, value)
    if result != nil: return

suite "colour popup through a real production source adapter":
  test "draft, Save and production transaction write compiler-readable source":
    let directory = createTempDir("isonim-color-source-", "", getEnv("ISONIM_POPUP_ARTIFACTS", getTempDir()))
    echo "Private source/compiler artifacts: ", directory
    let relative = "packages/metacraft-design/src/metacraft_design/tokens.nim"
    let file = directory / relative
    createDir(parentDir(file))
    let original = "const colorCss* = \"\"\"\n:root {\n  --mcl-color-primary: #2563EB;\n}\n\"\"\"\necho colorCss\n"
    writeFile(file, original)
    var product = metacraftBackOfficeEditorWorkspace()
    product.editAdapter = metacraftBackOfficeEditAdapter(directory)
    product.sourceAdapterReady = true
    createRoot(proc(dispose: proc()) =
      let beforeCompiled = execCmdEx(quoteShell(findExe("nim")) & " c -r --hints:off --out:" & quoteShell(directory / "compiled-before") & " " & quoteShell(file))
      writeFile(directory / "compiler-before.log", beforeCompiled.output)
      check beforeCompiled.exitCode == 0
      check beforeCompiled.output.contains("--mcl-color-primary: #2563EB;")
      let vm = createEditorVM(product)
      let inlineState = createVariableInlineEditorState()
      openVariableInlineEditorWithRect(vm, inlineState, "color.primary", 0, 0, 20, 20)
      let renderer = MockRenderer()
      let host = renderer.createElement("div")
      discard mountVariableInlineEditor(renderer, host, vm, inlineState)
      host.find("data-variable-inline-editor-picker", "true").fireEvent("click")
      for color in ["#FFFFFF", "#3B82F6", "#22C55E"]:
        host.find("data-color-popover-swatch", color).fireEvent("click")
        check renderer.inputValue(host.find("data-color-popover-input", "true")) == color
      host.find("data-color-popover-apply", "true").fireEvent("click")
      check inlineState.draftValue.val == "#22C55E"
      check readFile(file) == original
      host.find("data-variable-inline-editor-save", "true").fireEvent("click")
      check not inlineState.open.val
      let result = vm.applyWorkspaceFileEdits()
      check result.ok
      check result.patches.len == 1
      writeFile(directory / "source-before.nim", original)
      writeFile(directory / "source-after.nim", readFile(file))
      check readFile(file).contains("--mcl-color-primary: #22C55E;")
      check not readFile(file).contains("--mcl-color-primary: #2563EB;")
      let compiled = execCmdEx(quoteShell(findExe("nim")) & " c -r --hints:off --out:" & quoteShell(directory / "compiled-tokens") & " " & quoteShell(file))
      writeFile(directory / "compiler.log", compiled.output)
      check compiled.exitCode == 0
      check compiled.output.contains("--mcl-color-primary: #22C55E;")
      dispose())
