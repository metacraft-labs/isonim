## No mocks: production markup tokenizer and compiler identity insertion run on
## exact byte buffers, including browser raw-text and malformed-attribute cases.
import std/[unittest, strutils, tables, sets]
import isonim/editor/html_classes

suite "Compiled source markup identities":
  test "preserves original bytes, raw text and existing class semantics":
    let markup = """<!DOCTYPE html PUBLIC "quoted > identity"><html><head>
<style>.card::before{content:"<div class='fake'>雪 >"}</style>
<script><!--<script>const x="</script><div class='fake'>";</script>--></script>
</head><body><!-- <p class='fake'> --><DIV CLASS="card&#32;primary" title="a > b">雪 &amp; λ</DIV>
<input class='field' /><span =class='fake' class='actual' CLASS='duplicate'>café</span>
<template><div class='inert'>hidden</div></template><textarea><b class='fake'>text</b></textarea>
<button data-isonim-element-id="authored-id" class="card">Go</button></body></html>"""
    let originalClasses = htmlClassNames(markup)
    check originalClasses == @["card", "primary", "field", "actual"]
    let compiled = sourceElementMarkup(markup, "compiled-story")
    check compiled.elements.len == 5
    var restored = compiled.html
    for element in compiled.elements:
      if element.id != "authored-id":
        restored = restored.replace(" data-isonim-element-id=\"" & element.id & "\"", "")
    check restored == markup
    check htmlClassNames(compiled.html) == originalClasses
    check sourceElementMarkup(compiled.html, "compiled-story").html == compiled.html
    var ids = initHashSet[string]()
    for element in compiled.elements:
      check element.id notin ids
      ids.incl element.id
    check compiled.elements[0].attributes["class"] == "card primary"
    check compiled.elements[2].attributes["class"] == "actual"
    let changed = sourceElementMarkup(markup.replace("content:", "width: 123px;content:"), "compiled-story")
    for index, element in compiled.elements:
      check changed.elements[index].id == element.id

  test "rejects invalid producer prefixes and duplicate authored identities":
    expect ValueError:
      discard sourceElementMarkup("<div></div>", "bad\"prefix")
    expect ValueError:
      discard sourceElementMarkup("<div data-isonim-element-id='same'></div><b data-isonim-element-id='same'></b>", "story")
    check sourceElementMarkup("<div title='incomplete", "story").html == "<div title='incomplete"
