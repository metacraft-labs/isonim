# Docs theme ↔ brand-token divergences

**Purpose.** The CodeTracer docs site uses its own docs-specific design (ported from the
WebFlow reference `codetracer-docs-review`). That design is an independent lineage from
the canonical Metacraft brand tokens in the `codetracer-design-system` repo
(`brand → alias → mapped`). This document enumerates every point where the two disagree,
so the authors of both designs can decide whether more alignment is desired.

**Current stance (per operator decision).** The docs theme follows the WebFlow docs design
faithfully (structure, layout, spacing, radii, canvas, *and* brand identity — fonts/accent).
Divergences below are recorded, not yet reconciled. Nothing here is "wrong" — it is a
deliberate docs-specific look pending a joint design decision.

**Sources**
- Docs design: `codetracer-docs-review/69cfa7efe94af49e84c7ba44/css/codetracer-docs.shared.*.css`
  (hand-authored CodeTracer layer, lines ~3954–4105).
- Brand tokens: `codetracer-design-system/{brand,alias,mapped}/*.json` (W3C DTCG).

---

## Divergences (need a design decision)

| # | Dimension | Docs design (WebFlow) | Brand token (design-system) | Notes for the authors |
|---|-----------|-----------------------|-----------------------------|-----------------------|
| ① | UI / body font | **Geist** (variable, self-hosted) | `type.fontFamily.ui-primary` = **Space Grotesk** | The docs mockup uses Geist; the brand mandates Space Grotesk. Both are geometric sans. Decision: keep Geist for docs, or adopt Space Grotesk for brand consistency? |
| ② | Code / mono font | browser default **`monospace`** | `type.fontFamily.code-primary` = **Space Mono** (Fira Mono also shipped) | Docs mockup left code font unspecified. Brand has Space/Fira Mono. Adopting a real mono is a strict improvement; which one? |
| ③ | Accent / link color | **blue `#4168cc`** (link text is actually near-black `#111`, blue used sparingly) | `colors.action.primary` = brand.600 **indigo `#4f46e5`** (dark: brand.400 `#818cf8`) | Neither matches CodeTracer's logo red `#ff3300` (reserved for the mark). Docs blue vs brand indigo is a visible identity choice. |
| ④ | Page canvas (light) | **warm off-white `#f0eeea`** | closest `graphite.50 #ececeb` (no exact token) | The warm canvas is a deliberate WebFlow choice with no brand-token equivalent. Keep warm, or snap to a neutral token? |
| ④' | Page canvas (dark) | `#161719` | `neutral.950 #161616` (near-match) | ~3 units off; could snap to `#161616` with no visible change. |

## Near-matches (aligned enough; noted for completeness)

| Dimension | Docs design | Brand token | Status |
|-----------|-------------|-------------|--------|
| Focus ring | `#3b82f6` | `colors.ui.border.focus` = blue.500 `#3b82f6` | **exact match** |
| Admonition palette (note/tip/important/warning/caution) | blue/green/violet/amber/red `.500`+`.50` | same hexes in `brand.json` primitives | **exact match** — the docs admonitions already *are* the brand palette; all five severities render distinctly as of M3 |
| Body text | `#111` / dark `#dfe0e4` | `neutral.1000 #101010` / dark `neutral.150` | near-match, keep |
| Muted text | `#7e7e7e` / `#a8aab1` | `neutral.300 #919191` / `neutral.250` | near-match, keep |
| Borders/dividers | `#e5e7eb` / `#3c4046` | `divider.subtle` (neutral.700) | close, keep docs values |
| Spacing / radii / line-height | bespoke WebFlow scale (§ theme) | `alias.padding` / `alias.border-radius` | docs scale is structural design; keep |
| Theme mechanism | `[data-theme="dark"]` + `prefers-color-scheme` | (n/a) | identical to isonim-docs's own; ports 1:1 |

---

## How this doc is meant to be used
1. The docs theme ships with the **Docs design** column values (WebFlow-faithful).
2. Each token in the docs theme is tagged with its brand-token counterpart (or "docs-specific,
   no token") so a future alignment pass is mechanical.
3. When the design authors decide on ①–④, update the docs token layer and prune the resolved
   rows here. Rows in "Near-matches" can be snapped to the brand token at any time with no
   visible change if strict token-sourcing is later required.

---

## Implemented binding (M2 docs token layer)

The docs token layer (`src/theme_tokens.nim`, emitted by the M1
`emitTokensCss`) binds each `--docs-*` variable either as a docs-specific
**literal** (`bkLiteral`) or by **token** (`bkToken`, resolved against
`codetracer-design-system/{brand,alias,mapped}/*.json`). This is the
mechanical tag the "How this doc is meant to be used" section calls for.

| `--docs-*` variable | Light / dark value | Binding | Brand-token counterpart |
|---------------------|--------------------|---------|-------------------------|
| `--docs-font-sans` | Geist stack | **literal** (①) | `type.fontFamily.ui-primary` = Space Grotesk |
| `--docs-font-mono` | monospace stack | **literal** (②) | `type.fontFamily.code-primary` = Space Mono |
| `--docs-bg` | `#f0eeea` / `#161719` | **literal** (④, ④') | none / `neutral.950 #161616` (near) |
| `--docs-bg-raised` | `#E7E5E1` / `#31343a` | **literal** | warm hover, docs-specific |
| `--docs-fg` | `#111` / `#dfe0e4` | **literal** | `neutral.1000` / `neutral.150` (near) |
| `--docs-fg-muted` | `#7e7e7e` / `#a8aab1` | **literal** | `neutral.300` / `neutral.250` (near) |
| `--docs-border` | `#e5e7eb` / `#3c4046` | **literal** | `divider.subtle` (near) |
| `--docs-accent`, `--docs-link` | `#4168cc` / `#88a4f2` | **literal** (③) | `colors.action.primary` = indigo `#4f46e5` |
| `--docs-focus-ring` | `#3b82f6` | **token** `colors.blue.500` | exact match |
| `--docs-admonition-note-border` | `#3b82f6` | **token** `colors.blue.500` | exact match |
| `--docs-admonition-tip-border` | `#22c55e` | **token** `colors.green.500` | exact match |
| `--docs-admonition-warning-border` | `#f59e0b` | **token** `colors.amber.500` | exact match |
| `--docs-admonition-danger-border` | `#ef4444` | **token** `colors.red.500` | exact match |
| `--docs-admonition-important-border` (M3) | `#8b5cf6` | **token** `colors.violet.500` | exact match |
| `--docs-admonition-caution-border` (M3) | `#ef4444` | **token** `colors.red.500` | exact match (WebFlow `caution` = red, now its own severity) |
| `--docs-admonition-*-bg` | tint / rgba tint | **literal** | brand `*.50` primitives (light); dark tints docs-specific |
| `--docs-code-*`, `--docs-tok-*`, `--docs-api-*`, radii/spacing/sizes | see `theme_tokens.nim` | **literal** | structural / no WebFlow spec |

**Notes.**
- The five brand-primitive **border** colours are bound by token precisely
  because they already match the design system (see "Near-matches"); a
  future alignment pass need only flip the divergent literals (①②③④).
- The admonition **backgrounds** stay literals: their light tints match the
  brand `*.50` primitives, but the dark tints are translucent `rgba(...)`
  overlays with no single brand-token equivalent, and a `Binding` is
  all-token or all-literal (no per-side mix).
- **Gap A** (logo) — RESOLVED in M3. The framework's optional `siteLogo`/
  `logoHref` `DocsConfig` hooks now render the vendored CodeTracer mark as a
  real `<img class="docs-logo">` in `.docs-header` (linked home), replacing the
  M2 `.docs-title::before` background-image stopgap. `.docs-logo` styling +
  dark-mode `filter: invert(1)` live in the consumer stylesheet.
- **Gap B** (header nav-links) — RESOLVED in metacraft-theme-parity M1. The
  framework's optional `headerLinks: seq[{label, href}]` `DocsConfig` hook now
  renders the WebFlow `.ct-nav-btn` row (Support/FAQ) as a `.docs-header-nav`
  group at the right of `.docs-header`. Content-agnostic in the framework
  (empty ⇒ nothing, header byte-for-byte pre-M1); the CodeTracer button
  set + `.docs-header-nav-btn` pill styling live in the consumer.
- **Gap C** (sidebar social icons + toggle placement) — RESOLVED in
  metacraft-theme-parity M1. Two optional framework hooks: `sidebarLinks:
  seq[{label, href, icon}]` renders the WebFlow `.link-with-icon` external
  items (Github/Twitter, with the vendored `icon__github.svg`/
  `icon__twitter.svg` marks under `static/img/`) at the bottom of
  `.docs-nav-sidebar`; `sidebarThemeToggle: bool` moves the single
  `#docs-theme-toggle` out of the header into a bottom-of-sidebar pill
  (WebFlow `.theme-switch`). Both default off (byte-for-byte pre-M1); the
  `.docs-sidebar-extras` / `.docs-theme-switch-wrap` styling is consumer-side.
  The black Github/Twitter marks invert in dark mode (like the logo); the
  blue need-help icons do not.
- **Content-page header/footer parity** — ADDED in metacraft-theme-parity M1.
  Optional framework hooks: `pageTitleInContent: bool` renders the page title
  as an `<h1 class="docs-md-title">` at the top of `.docs-main` and drops it
  from the header (WebFlow's big content H1); `lastUpdated`/`showLastUpdated`
  add the "Last updated <date>" `.docs-md-meta` line under it (left off in this
  consumer — no per-page date source yet); and `needHelp: {heading, links}`
  renders the WebFlow "Need some help?" `.docs-need-help` block above the
  footer. All default off ⇒ byte-for-byte pre-M1.
- **Gap D** (the book's `important`/`caution` severities) — RESOLVED in M3.
  The framework markdown renderer now has first-class `important` (violet) and
  `caution` (red) admonition kinds, so `:::important` / `:::caution` parse and
  render their own `.docs-md-admonition-important` / `-caution` classes. The
  consumer binds `--docs-admonition-important-border` → `colors.violet.500`
  (exact brand primitive) and `--docs-admonition-caution-border` →
  `colors.red.500`. WebFlow `caution` is now its OWN severity (red) instead of
  borrowing `danger`, and `important` renders distinctly (violet) — no more
  lossy remap.
- **Gap F** (footer) — RESOLVED in M3. The framework's optional `footerHtml`
  hook fills the previously-empty `.docs-footer` with the WebFlow attribution
  line ("Built by metacraft-labs — 2026"). SSR-string hook (raw HTML has no
  generic-renderer node form); the consumer is a static SSG build, so this is
  the delivery path.
- **Asset delivery deviation.** The design-port spec calls for vendoring the
  Geist woff2 / logo / glyph under `assets/` referenced as `url(/assets/...)`.
  The framework SSG hash pipeline content-hashes+renames *and removes* every
  file under `assets/` but does **not** rewrite CSS `url()` refs, so a font
  shipped there would dangle at runtime. To keep both the `url(/assets/...)`
  authoring convention **and** a working (non-dangling) reference, the
  binaries live in `static/` and `src/build.nim` copies them verbatim into
  `public/assets/` *after* the hash pass. Net effect: real files at the
  exact unhashed `/assets/...` paths the stylesheet points at.

- **Landing hero H1 vs the framework content H1 (M3).** `pageTitleInContent`
  renders the page title as a `.docs-md-title` H1 at the top of `.docs-main` on
  every page (WebFlow's `.content-title` H1). The home ALSO opens with a
  `:::hero`, which brings its own H1 + subtitle + button group — the WebFlow home
  puts exactly that in `.content-title`. To avoid a duplicate big heading on the
  landing, the consumer stylesheet drops the framework's `.docs-md-title` (and
  its meta line) on the one page that carries a hero, keyed purely on the hero
  component's presence (`.docs-main:has(.docs-md-hero) > .docs-md-title`), so
  ordinary article pages keep their content H1 unchanged.
- **Home product video — OMITTED (M3).** The WebFlow home embeds a CodeTracer
  Noir demo video (a YouTube/embedly iframe) between the Overview and the
  "Start here" cards. This consumer documents IsoNim / isonim-docs, for which no
  real product video exists, so the embed is deliberately omitted rather than
  faking a CodeTracer video or shipping an empty placeholder box. Everything
  else in the WebFlow home layout (hero, Overview prose, Start-here + Popular
  card grids, need-help) is reproduced.

_Maintained alongside the docs theme in `isonim/docs/users/`. Last updated by the
M3 landing + FAQ build (WebFlow-equivalent home, FAQ accordion, prev/next fix);
see the design-port spec for exact CSS line references and per-component mapping._
