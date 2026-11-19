## DSL fixtures built twice by `test_dsl_templates.nim`: once in a module where the renderer
## creates static subtrees from templates, once (`template_plain.nim`) where it does not. Included,
## not imported, so each module's `ui` blocks see that module's renderer procs.

proc staticCard(r: MockRenderer): MockNode =
  ui(r):
    tdiv(class = "card p-4 rounded", `data-kind` = "info", width = "120px"):
      h2: text "Title"
      p(class = "muted"):
        text "Body "
        strong: text "bold"
      br
      span: text "end"

proc dynamicRow(r: MockRenderer; index: Signal[int]; label: Signal[string];
                tone: Signal[string]): MockNode =
  ui(r):
    tdiv(class = "row", `data-tone` = tone.val, background_color = tone.val, opacity = "0.5"):
      span(class = "idx"): text $index.val
      text label.val

proc withHandlers(r: MockRenderer; clicks: Signal[int]; held: var MockNode): MockNode =
  ui(r):
    tdiv(class = "toolbar"):
      button(class = "inc", onclick = proc() = clicks.val = clicks.val + 1, ref = held):
        text "+"
      span: text "clicks: " & $clicks.val

proc mixed(r: MockRenderer; items: seq[string]): MockNode =
  ui(r):
    ul(class = "list"):
      for item in items:
        let shown = item
        li(class = "item"):
          span: text shown
