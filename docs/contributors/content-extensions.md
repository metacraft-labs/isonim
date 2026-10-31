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

`renderProseHtml` emits every fenced code block as `<pre tabindex="0">` and
wraps every table in a focusable, named region,
`<div class="table-scroll" role="region" tabindex="0" …>`
(`tableScrollClass`). A stylesheet can then let long lines and wide tables
scroll inside their own box (`overflow-x: auto`) without leaving them out of
reach of the keyboard: a scrolling box must be focusable (WCAG 2.2 SC 2.1.1;
axe-core's `scrollable-region-focusable`), and not every browser makes one
focusable by itself. Without script the renderer cannot tell which blocks
will overflow, so every one is focusable.

A region must have a name, and repeated regions on one page need different
names ([WAI-ARIA Authoring Practices, landmark regions](https://www.w3.org/WAI/ARIA/apg/practices/landmark-regions/);
axe-core's `landmark-unique`, which compares names case-insensitively).
The region is named as follows:

| The table                                    | Region attribute                       | Caption                                 |
| -------------------------------------------- | -------------------------------------- | --------------------------------------- |
| has a caption whose text is not yet a name   | `aria-labelledby="table_caption-<n>"`  | `<caption id="table_caption-<n>">…`     |
| has a caption whose text is already a name   | `aria-label="<caption text> (2)"`      | `<caption>…</caption>`                  |
| has no caption, follows a heading            | `aria-label="Table: <heading text>"`   | none                                    |
| has no caption, no heading before it         | `aria-label="Table"`                   | none                                    |

A name already used gets the next free ordinal, `(2)`, `(3)`, …. The
heading is the last one rendered before the table in the same document,
inside quotes and endnotes too (`tableRegionLabel` is the word `Table`).
Naming the captioned region through its visible `<caption>` is the
[pattern by Adrian Roselli](https://adrianroselli.com/2020/11/under-engineered-responsive-tables.html);
an uncaptioned region does not begin with its heading, so it is named with
`aria-label` rather than by pointing at the heading.

Captions are Pandoc's
[`table_captions`](https://pandoc.org/MANUAL.html#extension-table_captions)
syntax, also used by Quarto: a paragraph beginning `Table:`, `table:` or
`: ` directly above or below the table (blank lines between are allowed),
the marker removed. A caption above wins; otherwise a table takes the
caption paragraph after it, before a following table can claim it as its
own leading caption. The syntax is off unless the parse passes
`tableCaptions = true` (`parseMarkdownBlocks`, `parseMarkdownDoc`,
`parseMarkdownDocWithHooks`), because it gives such a paragraph a new
meaning: a consumer that renders tables itself and ignores
`Block.tableCaption` would drop that text.

Names and generated IDs are unique within a `ProsePageScope`. The
one-argument `renderProseHtml(doc)` uses a fresh scope, which is right for
a document that is a page of its own. When several renderings end up on one
page, such as the excerpts a listing page joins, render them all with one
scope, `renderProseHtml(doc, scope)`: names then never repeat and no
generated ID repeats another or an ID the parser assigned to a heading or
an endnote in any of them (`tableCaptionIdBase` uses an underscore, which
heading slugs never contain). `newProsePageScope(idPrefix)` prefixes every
generated ID, so two scopes whose output may meet on one page cannot
generate the same one. The heading a table is named after never carries
over from one document into the next.

The IDs the parser assigns (heading anchors, endnotes `fn-<n>`, references
`fnref-<n>`) are unique within one document only, so the same page showing
a second rendering of a document (a post's excerpt beside its content), or
several documents (a listing's excerpts), would repeat them. Pass each of
those renderings its own `anchorPrefix`:
`renderProseHtml(doc, scope, anchorPrefix = "excerpt.a_")` writes every
parser ID with that prefix and points the endnote references and back-links
at the prefixed IDs, so each rendering's notes link within itself, as
markdown-it-footnote's `env.docId` and Goldmark's `WithFootnoteIDPrefix`
do for footnotes. Authored links such as `[see](#setup)` are left as
written. A prefixed ID already used in the scope, or in the scope passed
as `avoid`, raises `ValueError`, since the caller gave two documents the
same prefix. `scope.reserve(other)` counts everything `other` used as used
in `scope` too, which builds one `avoid` scope out of several pages (every
post's content, for an excerpt a layout may print on any post's page).

An image written `![](src){decorative}` is decorative: the span's
`decorative` flag is set, the marker is consumed, and `renderProseHtml`
writes `alt=""` (`imageAlt(span)`). CommonMark cannot tell an empty alt text
from a missing one, so the marker records that the author meant it. Image
spans also carry their source `line` (in the `firstLine` coordinates), and
`proseImages(blocks)` lists every image of the prose subset in document
order, so a site builder can refuse `![](src)` without the marker and name
the file and line. `{decorative}` anywhere else stays text.

The static-site image pipeline (`isonim/static/assets`, `rewritePageImages`)
applies the HTML rules to built pages: an `<img>` without an `alt` attribute,
or with alt text of only whitespace, is an error, and `alt=""` is accepted.
Images inside the page's `<main>` element (`mainContentRange`; the whole
page when it has none) get `decoding="async"`, and every one after the first
`loading="lazy"`; images outside it, such as a header logo, are left as the
layout wrote them. An external image must be a `data:` URL or on an origin in
`ImageVariantConfig.remoteOrigins` (normalised by `parseWebOrigin` in
`isonim/static/urls`); anything else, including a protocol-relative URL, is
an error. `avifQuality` and `webpQuality` (1-100; 0 selects
`defaultAvifQuality` 50 and `defaultWebpQuality` 75) set the libvips encoder
quality and are part of each variant's cache key.

Math supports `$inline$`, `$$display$$` and fenced `math`. A single-dollar
opener must precede a non-space, and its closer must follow a non-space.
Unmatched delimiters stay literal. Escaped dollars and code spans/fences stay
literal; escaped dollars _inside_ TeX do not close the expression. TeX is
opaque inside strike and table syntax, including `$|x|$`. Explicit link
labels can contain math; destinations, titles and image alt text remain data.
Existing parsing calls without hooks preserve their earlier output, except
for table cells (below).

Table cells are inline content, as the
[GFM table extension](https://github.github.com/gfm/#tables-extension-)
specifies, whether or not maths is on: `Block.headerSpans` and
`Block.cellSpans` are filled for every table, so code spans, links,
autolinks and strikes in cells render, and links in cells are seen by
`visitInlineSpans`. A cell ends at every pipe not escaped with a backslash,
including one inside a code span or a link; `\|` is a literal pipe, also
inside a code span, and `Block.rows` holds the cell text with it unescaped.
With maths on, a formula keeps its pipes. (Before, cells were parsed only
with maths on, and without it `\|` split the cell, so turning maths on
changed every table of a site.)

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

Generated SVG has no `style` attributes, so it renders under a
Content-Security-Policy whose `style-src` omits `'unsafe-inline'` (a browser
applies a `style` attribute only with `'unsafe-inline'` or, by hash, with
`'unsafe-hashes'`; see [CSP Level 3](https://www.w3.org/TR/CSP3/#directive-style-src)).
The declarations the renderers write inline, and the semantic paints that must
beat the renderer's own palette classes, move into one `<style>` element
appended to the SVG root: the root's reserved variables under its ID, and each
distinct declaration list under a generated `isonim-diagram-s<n>` class. Those
rules repeat their class once more than the most class-heavy renderer
selector, so, like the attributes they replace, they win over every renderer
rule. Such a page allows the element by the hash of its text
(`'sha256-…'` in `style-src`). The validator refuses a `style` attribute, a
renderer class named `isonim-diagram-s<n>`, and a renderer selector with a
second ID, which no generated rule could outrank.

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
