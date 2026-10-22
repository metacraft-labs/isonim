import isonim/dsl/ui
when defined(js):
  import isonim/web/web_renderer
  import isonim/rxcore
  let r = WebRenderer()
else:
  import isonim/ssr/escape
when defined(markerBypass):
  when defined(js):
    discard ui(r): input(`data-isonim-record` = "true")
  else:
    discard ui: input(`data-isonim-record` = "true")
else:
  when defined(js):
    discard ui(r): input(record = "true")
  else:
    discard ui: input(record = "true")
