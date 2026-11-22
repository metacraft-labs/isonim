## A view generic over its renderer, in a module that imports no renderer:
## `test_dsl_stylesheet_classes` instantiates it with `FrameRenderer`, as a
## codetracer core instantiates its views, to show that the renderer's
## `classesStyledByStylesheet` is found where the view is instantiated.

import isonim/dsl/ui

proc overlayView*[R, N](r: R): N =
  ## Mirrors the Filesystem pane's error overlay: a static class carrying a
  ## Tailwind utility (`hidden`), beside a sibling so the subtree is also
  ## a template candidate.
  ui(r):
    tdiv(class = "pane"):
      tdiv(class = "pane-error-overlay hidden", role = "alert"):
        discard
      tdiv(class = "pane-list"):
        discard
