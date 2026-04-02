## isonim/accessibility.nim
##
## Accessibility helpers for IsoNim components.
## Thin wrappers around setAttribute for ARIA attributes.
## Provides discoverability and consistent API for accessible markup.
##
## Works with any RendererBackend (MockRenderer, browser DOM, etc.)
## since all helpers use the generic `setAttribute` call.

proc ariaLabel*[R, N](renderer: R; node: N; label: string) =
  ## Sets aria-label attribute on a node.
  renderer.setAttribute(node, "aria-label", label)

proc ariaChecked*[R, N](renderer: R; node: N; checked: bool) =
  ## Sets aria-checked attribute ("true" or "false").
  renderer.setAttribute(node, "aria-checked", if checked: "true" else: "false")

proc ariaHidden*[R, N](renderer: R; node: N; hidden: bool) =
  ## Sets aria-hidden attribute ("true" or "false").
  renderer.setAttribute(node, "aria-hidden", if hidden: "true" else: "false")

proc ariaExpanded*[R, N](renderer: R; node: N; expanded: bool) =
  ## Sets aria-expanded attribute ("true" or "false").
  renderer.setAttribute(node, "aria-expanded", if expanded: "true" else: "false")

proc ariaLive*[R, N](renderer: R; node: N; mode: string) =
  ## Sets aria-live attribute.
  ## mode: "polite", "assertive", or "off"
  renderer.setAttribute(node, "aria-live", mode)

proc ariaDescribedby*[R, N](renderer: R; node: N; id: string) =
  ## Sets aria-describedby attribute to reference another element by ID.
  renderer.setAttribute(node, "aria-describedby", id)

proc ariaLabelledby*[R, N](renderer: R; node: N; id: string) =
  ## Sets aria-labelledby attribute to reference another element by ID.
  renderer.setAttribute(node, "aria-labelledby", id)

proc role*[R, N](renderer: R; node: N; roleName: string) =
  ## Sets the role attribute on a node.
  renderer.setAttribute(node, "role", roleName)

proc srOnlyClass*(): string =
  ## Returns the CSS class name for visually hidden, screen-reader-only text.
  ## Use with: span(class = srOnlyClass()): text "3 items remaining"
  "sr-only"
