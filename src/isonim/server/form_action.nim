## isonim/server/form_action.nim
##
## Form-encoded bodies and progressive-enhancement forms.
##
## An `{.action.}` server function and a progressive route manifest entry
## accept `application/x-www-form-urlencoded` bodies, so a plain HTML form
## reaches them without JavaScript; the server answers such a submission
## with `303 See Other` (redirect-after-POST, rpc.nim and the route
## manifest).  `formHtml` renders the form: its `action`, its `method` and
## the `_csrf` field carrying the request's CSRF token.

when not defined(js):
  import std/[json, tables, strutils]
  import request, context

  proc decodeUrlComponent*(s: string): string =
    ## Decodes a form name or value: `+` is a space and `%XX` a byte; a `%`
    ## that does not start a valid escape is kept as is.
    decodeFormComponent(s)

  proc parseFormData*(body: string): Table[string, string] =
    ## Parses an application/x-www-form-urlencoded body.  For a repeated
    ## name the last value wins.
    ## "title=Hello+World&body=Content" -> {"title": "Hello World", "body": "Content"}
    result = initTable[string, string]()
    for (k, v) in parseQuery(body):
      result[k] = v

  proc formToJson*(formData: Table[string, string]): JsonNode =
    ## A JSON object of the form's fields, each a string.
    result = newJObject()
    for key, val in formData:
      result[key] = newJString(val)

  proc formBodyToJson*(body: string): JsonNode =
    ## Parses a form body to a JSON object of strings.
    formToJson(parseFormData(body))

  proc escapeHtmlAttr(s: string): string =
    s.multiReplace(("&", "&amp;"), ("\"", "&quot;"), ("<", "&lt;"),
                   (">", "&gt;"))

  proc formHtml*(ctx: RequestContext; action: string; inner: string;
                 attrs = ""): string =
    ## A `<form method="post">` to `action` carrying the CSRF token of
    ## this request (the session's, else the anonymous one, issuing the
    ## anonymous CSRF cookie if needed) in a hidden `_csrf` field.
    ## `inner` is the form's HTML; `attrs` extra attributes, verbatim.
    "<form action=\"" & escapeHtmlAttr(action) & "\" method=\"post\"" &
      (if attrs.len > 0: " " & attrs else: "") & ">" &
      "<input type=\"hidden\" name=\"" & csrfFieldName & "\" value=\"" &
      escapeHtmlAttr(ctx.csrfTokenFor()) & "\">" & inner & "</form>"
