## Real string/stream DSL renderers. No renderer substitutes.
import std/[unittest, strutils]
import isonim/dsl/ui
import isonim/ssr/escape
import faststreams/outputs

suite "typed record directive":
  test "string and stream preserve explicit booleans without editable metadata":
    let page = ui:
      tdiv(record = true):
        input(record = false)
        textarea(record = true)
    let outStream = memoryOutput()
    uiWrite(outStream.s):
      tdiv(record = true):
        input(record = false)
        textarea(record = true)
    let streamed = outStream.s.getOutput(string)
    check streamed == page
    check page.count("data-isonim-record=\"true\"") == 2
    check page.count("data-isonim-record=\"false\"") == 1
    check not page.contains("data-isonim-style-bindings")
    check not page.contains(" record=")
