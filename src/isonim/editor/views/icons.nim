## Inline SVG icon constants used by the right-sidebar top tab bar.
##
## This module exposes a registry of eight icon sets — the original
## *in-house* set designed in ``docs/icon-design/`` plus seven free
## third-party libraries. Each set defines the same three glyphs the
## tab bar consumes (wrench, robot/bot, plus). All glyphs use
## ``stroke="currentColor"`` / ``fill="currentColor"`` so the parent
## button's text colour drives the rendered ink — that lets the tab
## bar switch the icon between muted-grey (inactive) and accent-on-text
## (active) by setting a single ``color`` style on the button.
##
## The editor's live sidebar chrome uses the *in-house* set via the
## three backward-compatible aliases (``wrenchSvg``, ``robotSvg``,
## ``plusSvg``) at the bottom of this file. Story / preview surfaces
## that want to compare icon sets pick out the desired set by id via
## :proc:`iconSetById`.
##
## SVG markup is captured verbatim from the upstream sources. To
## iterate on the in-house glyphs, edit the corresponding file in
## ``docs/icon-design/`` and re-paste the body below. Do not "tune"
## the third-party SVGs — preserving them byte-for-byte is what lets
## reviewers verify the attribution matches the upstream library.
##
## Robot-substitute notes (libraries without a proper robot glyph):
##   * Heroicons:  uses ``cpu-chip`` (no robot in the outline set).
##   * Feather:    uses ``cpu``     (Feather is sparse; closest match).
##   * Bootstrap:  uses ``robot``   (Bootstrap *does* ship one).
##   * Tabler:     uses ``robot``   (Tabler ships one).
##   * Phosphor:   uses ``robot``   (Phosphor ships one).
##   * Material:   uses ``smart_toy`` (the canonical robot face).
##   * Lucide:     uses ``bot``     (Lucide ships one).
##
## Licenses are recorded per-set and summarised under
## ``LICENSES.md`` in this directory.

type
  IconSet* = object
    ## A bundle of the three glyphs the editor sidebar tab bar uses,
    ## paired with attribution metadata. Value type — cheap to copy.
    id*: string
      ## Stable lowercase identifier, e.g. ``"in-house"``, ``"lucide"``.
    label*: string
      ## Human-readable display name, e.g. ``"Lucide"``.
    license*: string
      ## SPDX-style identifier or short description of the upstream
      ## license. Used by the showcase story's legend.
    wrench*: string
      ## Full ``<svg>...</svg>`` markup for the wrench glyph.
    bot*: string
      ## Full ``<svg>...</svg>`` markup for the robot / AI glyph.
    plus*: string
      ## Full ``<svg>...</svg>`` markup for the plus glyph.

const
  # --- 1. In-house ----------------------------------------------------------
  # Original, hand-drawn glyphs from ``docs/icon-design/``. Tuned at
  # the canonical 18 px button-glyph size with 24 px and 48 px review
  # passes. The editor's live sidebar uses these.
  inhouseSet* = IconSet(
    id: "in-house",
    label: "In-house",
    license: "Original (hand-drawn)",
    wrench: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="M16.43 4.42a4.5 4.5 0 0 0-5.84 5.84L3.5 17.36a2 2 0 1 0 2.83 2.83l7.1-7.1a4.5 4.5 0 0 0 5.84-5.84l-2.46 2.46-2.83-2.83 2.45-2.46zM5.91 17.36l-.71.71.71-.71z"/></svg>""",
    bot: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v2.5"/><circle cx="12" cy="2.5" r="0.75" fill="currentColor" stroke="none"/><rect x="4.5" y="6" width="15" height="12" rx="2.5"/><circle cx="9" cy="12" r="1.25" fill="currentColor" stroke="none"/><circle cx="15" cy="12" r="1.25" fill="currentColor" stroke="none"/></svg>""",
    plus: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg>""")

  # --- 2. Lucide (ISC) ------------------------------------------------------
  # https://github.com/lucide-icons/lucide
  # Icons: ``wrench``, ``bot``, ``plus``. Stroke-based, 24x24, width 2.
  lucideSet* = IconSet(
    id: "lucide",
    label: "Lucide",
    license: "ISC",
    wrench: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/></svg>""",
    bot: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 8V4H8"/><rect width="16" height="12" x="4" y="8" rx="2"/><path d="M2 14h2"/><path d="M20 14h2"/><path d="M15 13v2"/><path d="M9 13v2"/></svg>""",
    plus: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12h14"/><path d="M12 5v14"/></svg>""")

  # --- 3. Heroicons (MIT) ---------------------------------------------------
  # https://github.com/tailwindlabs/heroicons (24px outline variant).
  # Icons: ``wrench-screwdriver`` (wrench), ``cpu-chip`` (robot
  # substitute — Heroicons has no robot glyph), ``plus``. Stroke-based,
  # 24x24, width 1.5.
  heroiconsSet* = IconSet(
    id: "heroicons",
    label: "Heroicons",
    license: "MIT",
    wrench: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M11.42 15.17 17.25 21A2.652 2.652 0 0 0 21 17.25l-5.877-5.877M11.42 15.17l2.496-3.03c.317-.384.74-.626 1.208-.766M11.42 15.17l-4.655 5.653a2.548 2.548 0 1 1-3.586-3.586l6.837-5.63m5.108-.233c.55-.164 1.163-.188 1.743-.14a4.5 4.5 0 0 0 4.486-6.336l-3.276 3.277a3.004 3.004 0 0 1-2.25-2.25l3.276-3.276a4.5 4.5 0 0 0-6.336 4.486c.091 1.076-.071 2.264-.904 2.95l-.102.085m-1.745 1.437L5.909 7.5H4.5L2.25 3.75l1.5-1.5L7.5 4.5v1.409l4.26 4.26m-1.745 1.437 1.745-1.437m6.615 8.206L15.75 15.75M4.867 19.125h.008v.008h-.008v-.008Z"/></svg>""",
    bot: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M8.25 3v1.5M4.5 8.25H3m18 0h-1.5M4.5 12H3m18 0h-1.5m-15 3.75H3m18 0h-1.5M8.25 19.5V21M12 3v1.5m0 15V21m3.75-18v1.5m0 15V21m-9-1.5h10.5a2.25 2.25 0 0 0 2.25-2.25V6.75a2.25 2.25 0 0 0-2.25-2.25H6.75A2.25 2.25 0 0 0 4.5 6.75v10.5a2.25 2.25 0 0 0 2.25 2.25Zm.75-12h9v9h-9v-9Z"/></svg>""",
    plus: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4.5v15m7.5-7.5h-15"/></svg>""")

  # --- 4. Feather (MIT) -----------------------------------------------------
  # https://github.com/feathericons/feather
  # Icons: ``tool`` (closest to wrench in Feather's sparse set),
  # ``cpu`` (robot substitute — Feather has no robot glyph), ``plus``.
  # Stroke-based, 24x24, width 2.
  featherSet* = IconSet(
    id: "feather",
    label: "Feather",
    license: "MIT",
    wrench: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.121 2.121 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/></svg>""",
    bot: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="4" width="16" height="16" rx="2" ry="2"/><rect x="9" y="9" width="6" height="6"/><line x1="9" y1="1" x2="9" y2="4"/><line x1="15" y1="1" x2="15" y2="4"/><line x1="9" y1="20" x2="9" y2="23"/><line x1="15" y1="20" x2="15" y2="23"/><line x1="20" y1="9" x2="23" y2="9"/><line x1="20" y1="14" x2="23" y2="14"/><line x1="1" y1="9" x2="4" y2="9"/><line x1="1" y1="14" x2="4" y2="14"/></svg>""",
    plus: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>""")

  # --- 5. Phosphor (MIT) ----------------------------------------------------
  # https://github.com/phosphor-icons/web (regular weight, 256x256
  # viewbox normalised to 24x24).
  # Icons: ``wrench``, ``robot``, ``plus``. Fill-based, 256-grid.
  phosphorSet* = IconSet(
    id: "phosphor",
    label: "Phosphor",
    license: "MIT",
    wrench: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="100%" height="100%" fill="currentColor"><path d="M226.76,69a8,8,0,0,0-12.84-2.88l-40.3,37.19-17.23-3.7-3.7-17.23,37.19-40.3A8,8,0,0,0,187,29.24,72,72,0,0,0,88,96,72.34,72.34,0,0,0,94,124.94L33.79,177c-.15.12-.29.26-.43.39a32,32,0,0,0,45.26,45.26c.13-.13.27-.28.39-.42L130.06,162A72,72,0,0,0,226.76,69ZM160,168a72.07,72.07,0,0,1-15.94-1.79,8,8,0,0,0-7.55,2.13L82.78,219.51a16,16,0,1,1-22.27-22.28L113.65,143.5a8,8,0,0,0,2.13-7.55,56,56,0,1,1,68.74,40.59A56.32,56.32,0,0,1,160,168Z"/></svg>""",
    bot: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="100%" height="100%" fill="currentColor"><path d="M200,48H136V16a8,8,0,0,0-16,0V48H56A32,32,0,0,0,24,80V192a32,32,0,0,0,32,32H200a32,32,0,0,0,32-32V80A32,32,0,0,0,200,48Zm16,144a16,16,0,0,1-16,16H56a16,16,0,0,1-16-16V80A16,16,0,0,1,56,64H200a16,16,0,0,1,16,16Zm-52-56H92a28,28,0,0,0,0,56h72a28,28,0,0,0,0-56Zm-28,16v24H120V152ZM80,164a12,12,0,0,1,12-12h12v24H92A12,12,0,0,1,80,164Zm84,12H152V152h12a12,12,0,0,1,0,24ZM72,108a12,12,0,1,1,12,12A12,12,0,0,1,72,108Zm88,0a12,12,0,1,1,12,12A12,12,0,0,1,160,108Z"/></svg>""",
    plus: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="100%" height="100%" fill="currentColor"><path d="M224,128a8,8,0,0,1-8,8H136v80a8,8,0,0,1-16,0V136H40a8,8,0,0,1,0-16h80V40a8,8,0,0,1,16,0v80h80A8,8,0,0,1,224,128Z"/></svg>""")

  # --- 6. Tabler Icons (MIT) ------------------------------------------------
  # https://github.com/tabler/tabler-icons (outline variant).
  # Icons: ``tool`` (wrench-like), ``robot``, ``plus``. Stroke-based,
  # 24x24, width 2, square caps/joins.
  tablerSet* = IconSet(
    id: "tabler",
    label: "Tabler Icons",
    license: "MIT",
    wrench: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M0 0h24v24H0z" fill="none" stroke="none"/><path d="M7 10h3v-3l-3.5 -3.5a6 6 0 0 1 8 8l6 6a2 2 0 0 1 -3 3l-6 -6a6 6 0 0 1 -8 -8l3.5 3.5"/></svg>""",
    bot: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M0 0h24v24H0z" fill="none" stroke="none"/><path d="M6 5h12a3 3 0 0 1 3 3v8a3 3 0 0 1 -3 3h-12a3 3 0 0 1 -3 -3v-8a3 3 0 0 1 3 -3z"/><path d="M9 16c1 .667 2 1 3 1s2 -.333 3 -1"/><path d="M9 7l-1 -4"/><path d="M15 7l1 -4"/><path d="M9 12v-1"/><path d="M15 12v-1"/></svg>""",
    plus: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M0 0h24v24H0z" fill="none" stroke="none"/><path d="M12 5l0 14"/><path d="M5 12l14 0"/></svg>""")

  # --- 7. Bootstrap Icons (MIT) ---------------------------------------------
  # https://github.com/twbs/icons
  # Icons: ``wrench``, ``robot``, ``plus``. Fill-based, native 16x16
  # viewbox (preserved). Bootstrap *does* ship a robot glyph.
  bootstrapSet* = IconSet(
    id: "bootstrap",
    label: "Bootstrap Icons",
    license: "MIT",
    wrench: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="100%" height="100%" fill="currentColor"><path d="M.102 2.223A3.004 3.004 0 0 0 3.78 5.897l6.341 6.252A3.003 3.003 0 0 0 13 16a3 3 0 1 0-.851-5.878L5.897 3.781A3.004 3.004 0 0 0 2.223.1l2.141 2.142L4 4l-1.757.364zm13.37 9.019.528.026.287.445.445.287.026.529L15 13l-.242.471-.026.529-.445.287-.287.445-.529.026L13 15l-.471-.242-.529-.026-.287-.445-.445-.287-.026-.529L11 13l.242-.471.026-.529.445-.287.287-.445.529-.026L13 11z"/></svg>""",
    bot: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="100%" height="100%" fill="currentColor"><path d="M6 12.5a.5.5 0 0 1 .5-.5h3a.5.5 0 0 1 0 1h-3a.5.5 0 0 1-.5-.5M3 8.062C3 6.76 4.235 5.765 5.53 5.886a26.6 26.6 0 0 0 4.94 0C11.765 5.765 13 6.76 13 8.062v1.157a.93.93 0 0 1-.765.935c-.845.147-2.34.346-4.235.346s-3.39-.2-4.235-.346A.93.93 0 0 1 3 9.219zm4.542-.827a.25.25 0 0 0-.217.068l-.92.9a25 25 0 0 1-1.871-.183.25.25 0 0 0-.068.495c.55.076 1.232.149 2.02.193a.25.25 0 0 0 .189-.071l.754-.736.847 1.71a.25.25 0 0 0 .404.062l.932-.97a25 25 0 0 0 1.922-.188.25.25 0 0 0-.068-.495c-.538.074-1.207.145-1.98.189a.25.25 0 0 0-.166.076l-.754.785-.842-1.7a.25.25 0 0 0-.182-.135"/><path d="M8.5 1.866a1 1 0 1 0-1 0V3h-2A4.5 4.5 0 0 0 1 7.5V8a1 1 0 0 0-1 1v2a1 1 0 0 0 1 1v1a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-1a1 1 0 0 0 1-1V9a1 1 0 0 0-1-1v-.5A4.5 4.5 0 0 0 10.5 3h-2zM14 7.5V13a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V7.5A3.5 3.5 0 0 1 5.5 4h5A3.5 3.5 0 0 1 14 7.5"/></svg>""",
    plus: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="100%" height="100%" fill="currentColor"><path d="M8 4a.5.5 0 0 1 .5.5v3h3a.5.5 0 0 1 0 1h-3v3a.5.5 0 0 1-1 0v-3h-3a.5.5 0 0 1 0-1h3v-3A.5.5 0 0 1 8 4"/></svg>""")

  # --- 8. Material Symbols (Apache-2.0) -------------------------------------
  # https://fonts.google.com/icons (outlined variant, 24x24 viewbox).
  # Icons: ``build`` (closest to wrench), ``smart_toy`` (the canonical
  # robot face), ``add``. Fill-based, 24x24.
  materialSet* = IconSet(
    id: "material",
    label: "Material Symbols",
    license: "Apache-2.0",
    wrench: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="m22.7 19-9.1-9.1c.9-2.3.4-5-1.5-6.9-2-2-5-2.4-7.4-1.3L9 6 6 9 1.6 4.7C.4 7.1.9 10.1 2.9 12.1c1.9 1.9 4.6 2.4 6.9 1.5l9.1 9.1c.4.4 1 .4 1.4 0l2.3-2.3c.5-.4.5-1.1.1-1.4z"/></svg>""",
    bot: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="M20 9V7c0-1.1-.9-2-2-2h-3c0-1.66-1.34-3-3-3S9 3.34 9 5H6c-1.1 0-2 .9-2 2v2c-1.66 0-3 1.34-3 3s1.34 3 3 3v4c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2v-4c1.66 0 3-1.34 3-3s-1.34-3-3-3M7.5 11.5c0-.83.67-1.5 1.5-1.5s1.5.67 1.5 1.5S9.83 13 9 13s-1.5-.67-1.5-1.5M16 17H8v-2h8zm-1-4c-.83 0-1.5-.67-1.5-1.5S14.17 10 15 10s1.5.67 1.5 1.5S15.83 13 15 13"/></svg>""",
    plus: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6z"/></svg>""")

  iconSets*: array[8, IconSet] = [
    inhouseSet,
    lucideSet,
    heroiconsSet,
    featherSet,
    phosphorSet,
    tablerSet,
    bootstrapSet,
    materialSet]
    ## The full registry, exposed for stories / preview surfaces to
    ## iterate over. Order is stable: in-house first (used by the live
    ## editor chrome), then the seven third-party libraries in
    ## roughly popularity order. New sets append at the end.

proc iconSetById*(id: string): IconSet =
  ## Look up an icon set by its stable id. Falls back to the in-house
  ## set when the id is unknown — that's the same default the live
  ## editor chrome already uses.
  for s in iconSets:
    if s.id == id:
      return s
  inhouseSet

proc currentIconSet*(): IconSet =
  ## Return the icon set the live editor chrome currently renders.
  ## EX-M14 ships the in-house set everywhere; the showcase story is
  ## preview-only and does not flip a global preference. A future
  ## settings entry could swap this proc to read a signal — the call
  ## sites in ``shell.nim`` are intentionally indirected through the
  ## three backward-compat aliases below so a future swap is one edit.
  inhouseSet

# ----------------------------------------------------------------------------
# Backward-compatible aliases.
#
# The live editor's right-sidebar shell (`views/shell.nim`) uses these
# three constants directly. They resolve to the in-house set so the
# refactor is a no-op for the running editor. Do not remove them —
# they are the keep-shell.nim-untouched contract.
# ----------------------------------------------------------------------------

const
  wrenchSvg* = inhouseSet.wrench
  robotSvg*  = inhouseSet.bot
  plusSvg*   = inhouseSet.plus
