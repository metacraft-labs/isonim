---
kind: reference
title: Build-time content extensions
---

# Build-time math and diagrams

The optional `isonim/content/ext/math` and `isonim/content/ext/diagrams`
modules render Markdown through KaTeX, D2 and Graphviz. They run in native
site builders. The parser, validated fragments and prose rendering also work
on the JavaScript backend, so a browser can display already-built content
without downloading any renderer or math font.

Pass explicit executable paths; there is no PATH lookup or silent skip.
The default library and development shell do not require these tools. The
optional shell uses the existing Nix lock and sets `ISONIM_KATEX`, `ISONIM_D2`
and `ISONIM_DOT`:

```sh
repro exec -- nix develop .#content-tools --command nim c -r tests/test_content_math.nim
repro exec -- nix develop .#content-tools --command nim c -r tests/test_content_diagrams.nim
repro exec -- repro build --variant contentTools=true test-content-tools
repro exec -- repro build --variant contentTools=true test-content-tools-mutation
```

Pure parser and fragment tests belong to the normal C/JS `test-content`
target. Tool tests are registered only with `contentTools=true`; requesting
an absent target is an error, never a successful skipped test.

| API                                                                           | Contract                                                         |
| ----------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| `mathHooks(katexPath)`                                                        | A `ParseHooks` value using an explicit KaTeX executable.         |
| `diagramHooks(DiagramConfig)`                                                 | Hooks using explicit `d2Path`, `dotPath`, and `cacheDir`.        |
| `parseMarkdownDocWithHooks(hooks, body, sourceRelPath = path, firstLine = n)` | Shared document parsing with source coordinates.                 |
| `renderProseHtml(doc)`                                                        | Semantic HTML including validated fragments.                     |
| `renderMath(tex, display, katexPath, location)`                               | Direct native math rendering with source diagnostics.            |
| `renderDiagram(language, source, config, location, occurrence)`               | Cached native SVG rendering with a stable optional instance key. |

`firstLine` accounts for front matter or other text removed by the caller.
Errors name the opening delimiter/fence in that coordinate system, including
nested quotes, tabs, notes, captions, lists and directive bodies. A pre-parse
transform owns the coordinates of the text it returns. An unconfigured tool
fails when its syntax is used; a document without that syntax needs no tool.

Math supports `$inline$`, `$$display$$` and fenced `math`. A single-dollar
opener must precede a non-space, and its closer must follow a non-space.
Unmatched delimiters stay literal. Escaped dollars and code spans/fences stay
literal; escaped dollars _inside_ TeX do not close the expression. TeX is
opaque inside strike and table syntax, including `$|x|$`. Explicit link
labels can contain math; destinations, titles and image alt text remain data.
Existing parsing calls without hooks preserve their earlier output.

The pinned KaTeX CLI uses `--format mathml`, default error throwing
and its default disabled trust option. The adapter removes only the outer
HTML wrapper and TeX annotation. It validates the presentation tree against
[the MathML Core vocabulary](https://www.w3.org/TR/mathml-core/): identifiers,
numbers, operators, text, rows, spaces, fractions, radicals, scripts, limits,
`mstyle`, padding/phantoms and Core table structure. Supported attributes are
explicitly listed in `mathFragment`; `mathvariant` accepts only `normal`.

This is a qualified subset, not every KaTeX feature: `\cancel` (`menclose`),
bold/double-struck `mathvariant` values, and KaTeX matrices/alignment using
legacy table spacing/alignment attributes fail with their source location.
The adapter preserves supported `mstyle` semantics and never drops an
unsupported presentation attribute to make a formula appear to work. See the
[KaTeX CLI](https://katex.org/docs/cli) for its error and display options.

Fenced `d2` and `dot` become inline SVG. Theme colors are inherited from a
containing element using `--diagram-fill`, `--diagram-background`,
`--diagram-foreground` and `--diagram-stroke`. Fallbacks use system `Canvas`
and `currentColor`, so no external stylesheet is required. Themes can set
these variables for their own light/dark palette. Generated SVG defines only
the reserved `--diagram-mask-visible:white` and `--diagram-mask-hidden:black`
variables itself: they preserve luminance clipping and must not be themed.
Author colors map to these semantic roles; shape geometry, labels, gradients,
markers, masks and local references remain SVG.

The adapters qualify the pinned D2 with its fixed Dagre/theme options, and Graphviz's [`svg_inline` output](https://graphviz.org/docs/outputs/svg/).
The supported output is passive, self-contained SVG: no scripts, events,
foreign HTML, images, external links/resources, CSS escapes or advanced
selectors. Simple type/class/ID compound selectors and descendants, listed
presentation properties, local fragment URLs (quoted or unquoted) and embedded
WOFF fonts are supported. Unsupported output fails. This bounded tool-output
validator is not a general sanitizer for arbitrary untrusted content.

The cache hashes source, backend, executable path/content and normalization
version. Nix paths identify the pinned tool closure; mutable custom launchers
must change their own bytes/path when their dependencies change. Cache entries
carry a payload checksum and are revalidated, including paints/references.
Corruption fails visibly; failed renders never publish a cache entry. Writes
use an atomic rename. Warm and independent cold caches produce identical bytes.

IDs are namespaced by source path and opening-fence line. A direct
`renderDiagram` caller embedding the same location repeatedly supplies distinct
stable `occurrence` keys. Reusing a key denotes the same instance and produces
the same bytes; there is no global counter. D2 imports and external files are
outside this standalone source/cache contract. Import tokens, including absolute
imports, are refused before cache lookup. Quote or escape literal at-signs in
labels; quoted/escaped text and comments are kept literal. The source guard recognizes repeated-symbol block
delimiters; mixed-symbol delimiters are refused.

`ContentFragment` is opaque. `mathFragment` and `diagramFragment` validate
before constructing it; arbitrary strings and authored raw HTML do not become
trusted output. Site builders still apply their usual script policy to the
complete exported document.
