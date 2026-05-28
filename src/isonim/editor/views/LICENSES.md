# Icon Set Licenses

This directory's `icons.nim` ships an eight-set icon registry. The
in-house set is original work; the other seven are third-party
libraries with the licenses listed below. Each set's `IconSet.license`
field records the same SPDX identifier so the showcase story's legend
can display attribution at runtime.

| Set              | License    | Upstream source                             |
| ---------------- | ---------- | ------------------------------------------- |
| In-house         | Original   | `docs/icon-design/` (this repository)       |
| Lucide           | ISC        | <https://github.com/lucide-icons/lucide>    |
| Heroicons        | MIT        | <https://github.com/tailwindlabs/heroicons> |
| Feather          | MIT        | <https://github.com/feathericons/feather>   |
| Phosphor         | MIT        | <https://github.com/phosphor-icons/web>     |
| Tabler Icons     | MIT        | <https://github.com/tabler/tabler-icons>    |
| Bootstrap Icons  | MIT        | <https://github.com/twbs/icons>             |
| Material Symbols | Apache-2.0 | <https://fonts.google.com/icons>            |

## Robot-substitute notes

Three libraries do not ship a "robot" glyph; the registry substitutes
the closest match and records the choice in the `icons.nim` header:

- **Heroicons** — uses `cpu-chip` (no robot in the outline set).
- **Feather** — uses `cpu` (Feather is sparse; closest match).
- **Material Symbols** — uses `smart_toy` (Material's canonical robot
  face; closest match by intent).

The other four libraries (Lucide, Phosphor, Tabler, Bootstrap) all
ship a proper `bot` / `robot` glyph, used as-is.

## Verbatim-paste rule

The third-party SVG markup is captured byte-for-byte from each
upstream library. Do not "tune" the paths — preserving the upstream
shapes is what lets reviewers verify attribution. Each set's
`viewBox` is normalised to `0 0 24 24` _except_ Bootstrap, which uses
its native `0 0 16 16`; both render correctly inside `width="100%"
height="100%"` containers because the SVG renderer scales to the
container box.

All glyphs use `stroke="currentColor"` / `fill="currentColor"` so the
parent button's text color drives the rendered ink — that's what lets
the tab bar switch between muted-grey (inactive) and accent-on-text
(active) by setting a single `color` style on the button.
