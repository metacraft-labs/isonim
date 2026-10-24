## Real sandboxed consumer of the optional map loader and the DSL. The default
## map is genuinely absent in the immutable source input. A nonempty explicit
## map is a separate input control; the Nix check also requires a denied-target
## link to fail through the original read. No compiler or renderer doubles.
import isonim/dsl/[ui, tailwind]
import isonim/ssr/escape

static:
  when defined(expectedMap):
    doAssert hasTailwindStyles
    doAssert expandTailwindClassesCompileTime("sandbox-color") ==
      @[("color", "#123456")]
  else:
    doAssert not hasTailwindStyles

let html = ui:
  tdiv(class = "custom-class"):
    text "Hello"
doAssert html == "<div class=\"custom-class\">Hello</div>"
echo html
