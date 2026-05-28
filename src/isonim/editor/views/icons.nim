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
    ## A bundle of the glyphs the editor's chrome consumes, paired
    ## with attribution metadata. Value type — cheap to copy.
    ##
    ## The original three glyphs (``wrench`` / ``bot`` / ``plus``)
    ## drive the right-sidebar tab bar (set by EX-M14, expanded by
    ## the 2026-05-28 icon-coverage broadening commit).
    ##
    ## The status-bar and chrome-chip glyphs added in the 2026-05-28
    ## change cover three additional editor surfaces:
    ##   * status-bar sidebar toggles (``sidebarLeft`` / ``sidebarRight``);
    ##   * chrome Surface cluster (``preview`` / ``spec``);
    ##   * chrome Backend cluster (seven backend glyphs); and
    ##   * chrome Mode cluster (``modeView`` / ``modeComment`` /
    ##     ``modeEdit``).
    ##
    ## Where an upstream library does not ship the exact glyph name
    ## the set falls back to the closest match — substitutions are
    ## documented inline.
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

    # 2026-05-28 expansion — status-bar sidebar toggles.
    sidebarLeft*: string
      ## Status-bar glyph for the left-sidebar visibility toggle.
    sidebarRight*: string
      ## Status-bar glyph for the right-sidebar visibility toggle.

    # 2026-05-28 expansion — chrome Surface cluster.
    preview*: string
      ## Chrome Surface chip for the Preview surface (eye glyph).
    spec*: string
      ## Chrome Surface chip for the Spec surface (document glyph).

    # 2026-05-28 expansion — chrome Backend cluster.
    backendWeb*: string      ## Globe glyph.
    backendTui*: string      ## Terminal glyph.
    backendGpui*: string     ## Monitor / desktop glyph.
    backendFreya*: string    ## App-window glyph.
    backendCocoa*: string    ## Apple glyph (else command-key fallback).
    backendAndroid*: string  ## Android glyph (else smartphone fallback).
    backendIos*: string      ## Apple glyph (else smartphone fallback).

    # 2026-05-28 expansion — chrome Mode cluster.
    modeView*: string        ## Eye glyph.
    modeComment*: string     ## Message-square / chat-bubble glyph.
    modeEdit*: string        ## Pencil glyph.

const
  # --- 1. In-house ----------------------------------------------------------
  # Original, hand-drawn glyphs from ``docs/icon-design/``. Tuned at
  # the canonical 18 px button-glyph size with 24 px and 48 px review
  # passes. The editor's live sidebar uses these.
  inhouseSet* = IconSet(
    id: "in-house",
    label: "In-house",
    license: "Original (hand-drawn); 2026-05-28 expansion glyphs derived from Lucide (ISC); GPUI/Freya/Android backend icons are original brand silhouettes (Zed Z mark; Freya fern leaf; Android Bugdroid — used per Google brand guidelines for Android platform identification)",
    wrench: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="M16.43 4.42a4.5 4.5 0 0 0-5.84 5.84L3.5 17.36a2 2 0 1 0 2.83 2.83l7.1-7.1a4.5 4.5 0 0 0 5.84-5.84l-2.46 2.46-2.83-2.83 2.45-2.46zM5.91 17.36l-.71.71.71-.71z"/></svg>""",
    bot: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v2.5"/><circle cx="12" cy="2.5" r="0.75" fill="currentColor" stroke="none"/><rect x="4.5" y="6" width="15" height="12" rx="2.5"/><circle cx="9" cy="12" r="1.25" fill="currentColor" stroke="none"/><circle cx="15" cy="12" r="1.25" fill="currentColor" stroke="none"/></svg>""",
    plus: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg>""",
    # In-house derivations of Lucide (ISC) glyphs — pragmatic copy +
    # attribution preserved in LICENSES.md and the ``license`` field
    # above. The in-house set is the editor's live default, so each
    # surface needs concrete artwork even when bespoke artwork hasn't
    # landed yet. When/if hand-drawn artwork replaces these the
    # comment + license field can be tightened.
    sidebarLeft: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><rect width="18" height="18" x="3" y="3" rx="2"/><path d="M9 3v18"/></svg>""",
    sidebarRight: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><rect width="18" height="18" x="3" y="3" rx="2"/><path d="M15 3v18"/></svg>""",
    preview: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/></svg>""",
    spec: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M14.5 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7.5L14.5 2z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/><line x1="10" y1="9" x2="8" y2="9"/></svg>""",
    backendWeb: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg>""",
    backendTui: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>""",
    # GPUI = Zed (Zed's GPUI is the framework). Use Zed's Z mark as
    # the canonical project identifier — monochrome silhouette so it
    # integrates with the chrome bar's currentColor styling. See
    # docs/icon-design/zed.svg for the source.
    backendGpui: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="M5 5h14v3.5L10 17h9v2H5v-3.5L14 7H5z"/></svg>""",
    # Freya's brand mark is a fern leaf. Stylised leaf silhouette with
    # a central vein. See docs/icon-design/freya.svg.
    backendFreya: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M5 19c0-7 5-13 14-15-2 9-8 14-14 15z"/><path d="M5 19 14 9"/></svg>""",
    # Cocoa = macOS native UI framework. The most recognisable macOS
    # identifier is a window with three traffic-light buttons (close /
    # minimize / maximize) in the top-left corner. See
    # docs/icon-design/cocoa.svg.
    backendCocoa: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="5" width="18" height="14" rx="2"/><line x1="3" y1="9" x2="21" y2="9"/><circle cx="5.8" cy="7" r="0.8" fill="currentColor" stroke="none"/><circle cx="8.2" cy="7" r="0.8" fill="currentColor" stroke="none"/><circle cx="10.6" cy="7" r="0.8" fill="currentColor" stroke="none"/></svg>""",
    # Android's Bugdroid silhouette. Google permits Bugdroid use for
    # identifying the Android platform. See docs/icon-design/bugdroid.svg.
    backendAndroid: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><g stroke="currentColor" stroke-width="1.6" stroke-linecap="round" fill="none"><line x1="7.5" y1="4.5" x2="8.8" y2="7"/><line x1="16.5" y1="4.5" x2="15.2" y2="7"/></g><path d="M5.5 9.2c0-1 .7-1.8 1.7-2 1.4-.4 3-.7 4.8-.7s3.4.3 4.8.7c1 .2 1.7 1 1.7 2v4.3H5.5z"/><rect x="6.3" y="14.3" width="11.4" height="6" rx="1.2"/></svg>""",
    # iOS — smartphone silhouette (Apple platform mobile). Distinct
    # from Cocoa's apple glyph so the two pills don't read identically.
    backendIos: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><rect x="7" y="3" width="10" height="18" rx="2"/><path d="M11 18h2"/></svg>""",
    modeView: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/></svg>""",
    modeComment: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>""",
    modeEdit: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z"/></svg>""")

  # --- 2. Lucide (ISC) ------------------------------------------------------
  # https://github.com/lucide-icons/lucide
  # Icons: ``wrench``, ``bot``, ``plus``. Stroke-based, 24x24, width 2.
  #
  # 2026-05-28 expansion icons (all stroke-based, 24x24, width 2):
  #   sidebarLeft   panel-left
  #   sidebarRight  panel-right
  #   preview       eye
  #   spec          file-text
  #   backendWeb    globe
  #   backendTui    terminal
  #   backendGpui   monitor
  #   backendFreya  app-window
  #   backendCocoa  apple (Lucide ships an apple glyph)
  #   backendAndroid smartphone (no android in Lucide; closest fit)
  #   backendIos    smartphone
  #   modeView      eye
  #   modeComment   message-square
  #   modeEdit      pencil
  lucideSet* = IconSet(
    id: "lucide",
    label: "Lucide",
    license: "ISC",
    wrench: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/></svg>""",
    bot: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 8V4H8"/><rect width="16" height="12" x="4" y="8" rx="2"/><path d="M2 14h2"/><path d="M20 14h2"/><path d="M15 13v2"/><path d="M9 13v2"/></svg>""",
    plus: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12h14"/><path d="M12 5v14"/></svg>""",
    sidebarLeft: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="18" height="18" x="3" y="3" rx="2"/><path d="M9 3v18"/></svg>""",
    sidebarRight: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="18" height="18" x="3" y="3" rx="2"/><path d="M15 3v18"/></svg>""",
    preview: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/></svg>""",
    spec: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14.5 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7.5L14.5 2z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/><line x1="10" y1="9" x2="8" y2="9"/></svg>""",
    backendWeb: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg>""",
    backendTui: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>""",
    backendGpui: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="3" width="20" height="14" rx="2" ry="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/></svg>""",
    backendFreya: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="4" width="20" height="16" rx="2"/><path d="M10 4v4"/><path d="M2 8h20"/><path d="M6 4v4"/></svg>""",
    backendCocoa: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20.94c1.5 0 2.75-.67 3.75-2 .83-1 1.5-2.42 2-4.21-1.66-.5-2.75-1.83-2.75-3.66 0-1.6.92-3 2.31-3.71-.91-1.66-2.4-2.66-4.31-2.66s-3.4 1-4.31 2.66c1.39.71 2.31 2.11 2.31 3.71 0 1.83-1.09 3.16-2.75 3.66.5 1.79 1.17 3.21 2 4.21 1 1.33 2.25 2 3.75 2"/><path d="M12 5c.5-1.5 2-2.5 4-2.5"/></svg>""",
    backendAndroid: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="2" width="14" height="20" rx="2" ry="2"/><line x1="12" y1="18" x2="12.01" y2="18"/></svg>""",
    backendIos: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20.94c1.5 0 2.75-.67 3.75-2 .83-1 1.5-2.42 2-4.21-1.66-.5-2.75-1.83-2.75-3.66 0-1.6.92-3 2.31-3.71-.91-1.66-2.4-2.66-4.31-2.66s-3.4 1-4.31 2.66c1.39.71 2.31 2.11 2.31 3.71 0 1.83-1.09 3.16-2.75 3.66.5 1.79 1.17 3.21 2 4.21 1 1.33 2.25 2 3.75 2"/><path d="M12 5c.5-1.5 2-2.5 4-2.5"/></svg>""",
    modeView: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/></svg>""",
    modeComment: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>""",
    modeEdit: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z"/></svg>""")

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
    plus: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4.5v15m7.5-7.5h-15"/></svg>""",
    # 2026-05-28 expansion. Substitutes documented inline because
    # Heroicons doesn't ship every glyph the spec names:
    #   sidebarLeft / sidebarRight: ``bars-3`` for left + a mirrored
    #     ``bars-3-bottom-right`` for right (Heroicons has no
    #     ``panel-*`` outline glyphs).
    #   preview / modeView: ``eye``.
    #   spec: ``document-text``.
    #   backendCocoa / backendIos: ``command-line`` — Heroicons has no
    #     ``apple`` glyph; the command-line glyph is the closest match
    #     in spirit.
    #   backendAndroid: ``device-phone-mobile`` (closest fit).
    #   modeComment: ``chat-bubble-left``.
    #   modeEdit: ``pencil``.
    sidebarLeft: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3.75 6.75h16.5M3.75 12h16.5m-16.5 5.25h16.5"/></svg>""",
    sidebarRight: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3.75 6.75h16.5M8.25 12h12m-7.5 5.25h7.5"/></svg>""",
    preview: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M2.036 12.322a1.012 1.012 0 0 1 0-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178Z"/><path d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"/></svg>""",
    spec: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M19.5 14.25v-2.625a3.375 3.375 0 0 0-3.375-3.375h-1.5A1.125 1.125 0 0 1 13.5 7.125v-1.5a3.375 3.375 0 0 0-3.375-3.375H8.25m2.25 0H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 0 0-9-9Z"/><path d="M9 12.75h6m-6 3h6m-6 3h6"/></svg>""",
    backendWeb: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 21a9.004 9.004 0 0 0 8.716-6.747M12 21a9.004 9.004 0 0 1-8.716-6.747M12 21c2.485 0 4.5-4.03 4.5-9S14.485 3 12 3m0 18c-2.485 0-4.5-4.03-4.5-9S9.515 3 12 3m0 0a8.997 8.997 0 0 1 7.843 4.582M12 3a8.997 8.997 0 0 0-7.843 4.582m15.686 0A11.953 11.953 0 0 1 12 10.5c-2.998 0-5.74-1.1-7.843-2.918m15.686 0A8.959 8.959 0 0 1 21 12c0 .778-.099 1.533-.284 2.253m0 0A17.919 17.919 0 0 1 12 16.5c-3.162 0-6.133-.815-8.716-2.247m0 0A9.015 9.015 0 0 1 3 12c0-1.605.42-3.113 1.157-4.418"/></svg>""",
    backendTui: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M6.75 7.5l3 2.25-3 2.25m4.5 0h3M2.25 12c0 5.385 4.365 9.75 9.75 9.75s9.75-4.365 9.75-9.75S17.385 2.25 12 2.25 2.25 6.615 2.25 12Z"/></svg>""",
    backendGpui: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M9 17.25v1.007a3 3 0 0 1-.879 2.122L7.5 21h9l-.621-.621A3 3 0 0 1 15 18.257V17.25m6-12V15a2.25 2.25 0 0 1-2.25 2.25H5.25A2.25 2.25 0 0 1 3 15V5.25m18 0A2.25 2.25 0 0 0 18.75 3H5.25A2.25 2.25 0 0 0 3 5.25m18 0V12a2.25 2.25 0 0 1-2.25 2.25H5.25A2.25 2.25 0 0 1 3 12V5.25"/></svg>""",
    backendFreya: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3.75 3.75v4.5m0-4.5h4.5m-4.5 0L9 9M3.75 20.25v-4.5m0 4.5h4.5m-4.5 0L9 15M20.25 3.75h-4.5m4.5 0v4.5m0-4.5L15 9m5.25 11.25h-4.5m4.5 0v-4.5m0 4.5L15 15"/></svg>""",
    backendCocoa: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M6.75 7.5l3 2.25-3 2.25m4.5 0h3m-9 8.25h13.5A2.25 2.25 0 0 0 21 18V6a2.25 2.25 0 0 0-2.25-2.25H5.25A2.25 2.25 0 0 0 3 6v12a2.25 2.25 0 0 0 2.25 2.25Z"/></svg>""",
    backendAndroid: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M10.5 1.5H8.25A2.25 2.25 0 0 0 6 3.75v16.5a2.25 2.25 0 0 0 2.25 2.25h7.5A2.25 2.25 0 0 0 18 20.25V3.75a2.25 2.25 0 0 0-2.25-2.25H13.5m-3 0V3h3V1.5m-3 0h3m-3 18.75h3"/></svg>""",
    backendIos: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M10.5 1.5H8.25A2.25 2.25 0 0 0 6 3.75v16.5a2.25 2.25 0 0 0 2.25 2.25h7.5A2.25 2.25 0 0 0 18 20.25V3.75a2.25 2.25 0 0 0-2.25-2.25H13.5m-3 0V3h3V1.5m-3 0h3m-3 18.75h3"/></svg>""",
    modeView: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M2.036 12.322a1.012 1.012 0 0 1 0-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178Z"/><path d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"/></svg>""",
    modeComment: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M7.5 8.25h9m-9 3H12m-9.75 1.51c0 1.6 1.123 2.994 2.707 3.227 1.087.16 2.185.283 3.293.369V21l4.184-4.183a1.14 1.14 0 0 1 .778-.332 48.294 48.294 0 0 0 5.83-.498c1.585-.233 2.708-1.626 2.708-3.228V6.741c0-1.602-1.123-2.995-2.707-3.228A48.394 48.394 0 0 0 12 3c-2.392 0-4.744.175-7.043.513C3.373 3.746 2.25 5.14 2.25 6.741v6.018Z"/></svg>""",
    modeEdit: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M16.862 4.487l1.687-1.688a1.875 1.875 0 1 1 2.652 2.652L6.832 19.82a4.5 4.5 0 0 1-1.897 1.13l-2.685.8.8-2.685a4.5 4.5 0 0 1 1.13-1.897L16.863 4.487Zm0 0L19.5 7.125"/></svg>""")

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
    plus: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>""",
    # 2026-05-28 expansion. Feather is intentionally sparse — its
    # ``sidebar`` glyph covers the left case, the right case mirrors
    # it via a flipped layout. No apple / android glyphs ship; we
    # substitute ``smartphone`` for both Cocoa+iOS+Android. ``edit-2``
    # covers the pencil case.
    sidebarLeft: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"/><line x1="9" y1="3" x2="9" y2="21"/></svg>""",
    sidebarRight: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"/><line x1="15" y1="3" x2="15" y2="21"/></svg>""",
    preview: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg>""",
    spec: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/><polyline points="10 9 9 9 8 9"/></svg>""",
    backendWeb: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg>""",
    backendTui: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>""",
    backendGpui: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="3" width="20" height="14" rx="2" ry="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/></svg>""",
    backendFreya: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"/><line x1="3" y1="9" x2="21" y2="9"/><line x1="9" y1="21" x2="9" y2="9"/></svg>""",
    backendCocoa: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="2" width="14" height="20" rx="2" ry="2"/><line x1="12" y1="18" x2="12.01" y2="18"/></svg>""",
    backendAndroid: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="2" width="14" height="20" rx="2" ry="2"/><line x1="12" y1="18" x2="12.01" y2="18"/></svg>""",
    backendIos: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="2" width="14" height="20" rx="2" ry="2"/><line x1="12" y1="18" x2="12.01" y2="18"/></svg>""",
    modeView: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg>""",
    modeComment: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>""",
    modeEdit: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17 3a2.828 2.828 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5L17 3z"/></svg>""")

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
    plus: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="100%" height="100%" fill="currentColor"><path d="M224,128a8,8,0,0,1-8,8H136v80a8,8,0,0,1-16,0V136H40a8,8,0,0,1,0-16h80V40a8,8,0,0,1,16,0v80h80A8,8,0,0,1,224,128Z"/></svg>""",
    # 2026-05-28 expansion. Phosphor ships ``android-logo``, ``apple-logo``,
    # ``terminal-window``, ``app-window``, ``monitor``, ``globe``, ``eye``,
    # ``file-text``, ``pencil-simple``, and ``chat-text``. We use the
    # ``sidebar-simple`` glyph in both orientations (the right variant is
    # the same glyph as a single-side panel marker).
    sidebarLeft: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="100%" height="100%" fill="currentColor"><path d="M216,40H40A16,16,0,0,0,24,56V200a16,16,0,0,0,16,16H216a16,16,0,0,0,16-16V56A16,16,0,0,0,216,40Zm0,16V200H88V56ZM40,200V56H72V200Z"/></svg>""",
    sidebarRight: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="100%" height="100%" fill="currentColor"><path d="M216,40H40A16,16,0,0,0,24,56V200a16,16,0,0,0,16,16H216a16,16,0,0,0,16-16V56A16,16,0,0,0,216,40ZM40,56H168V200H40Zm176,144H184V56h32Z"/></svg>""",
    preview: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="100%" height="100%" fill="currentColor"><path d="M247.31,124.76c-.35-.79-8.82-19.58-27.65-38.41C194.57,61.26,162.88,48,128,48S61.43,61.26,36.34,86.35C17.51,105.18,9,124,8.69,124.76a8,8,0,0,0,0,6.5c.35.79,8.82,19.57,27.65,38.4C61.43,194.74,93.12,208,128,208s66.57-13.26,91.66-38.34c18.83-18.83,27.3-37.61,27.65-38.4A8,8,0,0,0,247.31,124.76ZM128,192c-30.78,0-57.67-11.19-79.93-33.25A133.47,133.47,0,0,1,25,128,133.33,133.33,0,0,1,48.07,97.25C70.33,75.19,97.22,64,128,64s57.67,11.19,79.93,33.25A133.46,133.46,0,0,1,231.05,128C223.84,141.46,192.43,192,128,192Zm0-112a48,48,0,1,0,48,48A48.05,48.05,0,0,0,128,80Zm0,80a32,32,0,1,1,32-32A32,32,0,0,1,128,160Z"/></svg>""",
    spec: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="100%" height="100%" fill="currentColor"><path d="M213.66,82.34l-56-56A8,8,0,0,0,152,24H56A16,16,0,0,0,40,40V216a16,16,0,0,0,16,16H200a16,16,0,0,0,16-16V88A8,8,0,0,0,213.66,82.34ZM160,51.31,188.69,80H160ZM200,216H56V40h88V88a8,8,0,0,0,8,8h48V216Zm-40-88a8,8,0,0,1-8,8H88a8,8,0,0,1,0-16h64A8,8,0,0,1,160,128Zm0,32a8,8,0,0,1-8,8H88a8,8,0,0,1,0-16h64A8,8,0,0,1,160,160Z"/></svg>""",
    backendWeb: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="100%" height="100%" fill="currentColor"><path d="M128,24A104,104,0,1,0,232,128,104.12,104.12,0,0,0,128,24Zm88,104a87.61,87.61,0,0,1-3.33,24H174.16a157.44,157.44,0,0,0,0-48h38.51A87.61,87.61,0,0,1,216,128ZM102,168H154a115.11,115.11,0,0,1-26,45A115.27,115.27,0,0,1,102,168Zm-3.9-16a140.84,140.84,0,0,1,0-48h59.88a140.84,140.84,0,0,1,0,48ZM40,128a87.61,87.61,0,0,1,3.33-24H81.84a157.44,157.44,0,0,0,0,48H43.33A87.61,87.61,0,0,1,40,128ZM154,88H102a115.11,115.11,0,0,1,26-45A115.27,115.27,0,0,1,154,88Zm52.33,0H170.71a135.28,135.28,0,0,0-22.3-45.6A88.29,88.29,0,0,1,206.37,88ZM107.59,42.4A135.28,135.28,0,0,0,85.29,88H49.63A88.29,88.29,0,0,1,107.59,42.4ZM49.63,168H85.29a135.28,135.28,0,0,0,22.3,45.6A88.29,88.29,0,0,1,49.63,168Zm98.78,45.6a135.28,135.28,0,0,0,22.3-45.6h35.66A88.29,88.29,0,0,1,148.41,213.6Z"/></svg>""",
    backendTui: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="100%" height="100%" fill="currentColor"><path d="M216,40H40A16,16,0,0,0,24,56V200a16,16,0,0,0,16,16H216a16,16,0,0,0,16-16V56A16,16,0,0,0,216,40Zm0,16V80H40V56Zm0,144H40V96H216V200Zm-90.34-69.66a8,8,0,0,1,0,11.32l-24,24a8,8,0,0,1-11.32-11.32L108.69,136,90.34,117.66a8,8,0,0,1,11.32-11.32ZM168,176a8,8,0,0,1-8,8H128a8,8,0,0,1,0-16h32A8,8,0,0,1,168,176Z"/></svg>""",
    backendGpui: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="100%" height="100%" fill="currentColor"><path d="M208,32H48A16,16,0,0,0,32,48V176a16,16,0,0,0,16,16h72v16H88a8,8,0,0,0,0,16h80a8,8,0,0,0,0-16H136V192h72a16,16,0,0,0,16-16V48A16,16,0,0,0,208,32Zm0,144H48V48H208V176Z"/></svg>""",
    backendFreya: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="100%" height="100%" fill="currentColor"><path d="M216,40H40A16,16,0,0,0,24,56V200a16,16,0,0,0,16,16H216a16,16,0,0,0,16-16V56A16,16,0,0,0,216,40Zm0,16V88H40V56H216ZM40,200V104H216V200H40Z"/></svg>""",
    backendCocoa: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="100%" height="100%" fill="currentColor"><path d="M223.3,169.59a8.07,8.07,0,0,0-2.8-3.4c-12.34-8.31-19.51-21.69-19.51-33.91,0-15.49,9.74-29.83,25.85-37.45a8,8,0,0,0,3.85-10.78c-13.7-29-43.69-46.83-74.7-44.65a72.85,72.85,0,0,0-26.62,7.46,8,8,0,0,1-7.18-.05,72.5,72.5,0,0,0-32-7.83C49.43,38.51,16,72.55,16,114.83a121.1,121.1,0,0,0,12.85,53.62,158.34,158.34,0,0,0,32.79,45.4C73.95,225.4,86.78,232,99.41,232a55.32,55.32,0,0,0,16.22-2.58,40.92,40.92,0,0,1,24.74,0A55.21,55.21,0,0,0,156.59,232c12.63,0,25.46-6.59,37.77-19.34h0a39,39,0,0,0,2.93-3.41,158.69,158.69,0,0,0,26.66-39A8,8,0,0,0,223.3,169.59ZM182.85,201.6h0c-9.93,10.28-19.55,15-29.27,14.27a40.74,40.74,0,0,1-7.42-1.45,57,57,0,0,0-36.55,0,40.74,40.74,0,0,1-7.42,1.45c-9.7.69-19.34-4-29.28-14.27A143,143,0,0,1,42.83,160.91,105.16,105.16,0,0,1,32,114.83C32,81.38,57.84,54.5,90.62,54.5a56.39,56.39,0,0,1,24.94,6.08,24,24,0,0,0,21.65.14,57,57,0,0,1,20.86-5.86c20.66-1.5,40.69,8.71,53,26.51-17.3,11.46-27.49,29.34-27.49,48.91,0,15.83,8.31,31.83,22.5,43.81A142.45,142.45,0,0,1,182.85,201.6ZM128.42,24a8,8,0,0,1,7.16-8.75,40.06,40.06,0,0,1,43.6,35.78,8,8,0,0,1-7.16,8.75c-.27,0-.53,0-.79,0a8,8,0,0,1-8-7.2,24,24,0,0,0-26.16-21.43A8,8,0,0,1,128.42,24Z"/></svg>""",
    backendAndroid: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="100%" height="100%" fill="currentColor"><path d="M76,112a12,12,0,1,1-12-12A12,12,0,0,1,76,112Zm116-12a12,12,0,1,0,12,12A12,12,0,0,0,192,100Zm56,52A104,104,0,0,1,32,152V112a96,96,0,0,1,192,0v40a8,8,0,0,1,16,0v40ZM224,112a80,80,0,0,0-160,0v40a88,88,0,0,0,160,0V112Zm-46.34-72.7,12-20a8,8,0,1,0-13.72-8.23l-12.33,20.55a87.85,87.85,0,0,0-71.21,0L80.06,11.07A8,8,0,1,0,66.34,19.3l12,20A87.91,87.91,0,0,0,40,112a8,8,0,0,0,16,0,72,72,0,0,1,144,0,8,8,0,0,0,16,0A87.91,87.91,0,0,0,177.66,39.3Z"/></svg>""",
    backendIos: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="100%" height="100%" fill="currentColor"><path d="M223.3,169.59a8.07,8.07,0,0,0-2.8-3.4c-12.34-8.31-19.51-21.69-19.51-33.91,0-15.49,9.74-29.83,25.85-37.45a8,8,0,0,0,3.85-10.78c-13.7-29-43.69-46.83-74.7-44.65a72.85,72.85,0,0,0-26.62,7.46,8,8,0,0,1-7.18-.05,72.5,72.5,0,0,0-32-7.83C49.43,38.51,16,72.55,16,114.83a121.1,121.1,0,0,0,12.85,53.62,158.34,158.34,0,0,0,32.79,45.4C73.95,225.4,86.78,232,99.41,232a55.32,55.32,0,0,0,16.22-2.58,40.92,40.92,0,0,1,24.74,0A55.21,55.21,0,0,0,156.59,232c12.63,0,25.46-6.59,37.77-19.34h0a39,39,0,0,0,2.93-3.41,158.69,158.69,0,0,0,26.66-39A8,8,0,0,0,223.3,169.59Z"/></svg>""",
    modeView: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="100%" height="100%" fill="currentColor"><path d="M247.31,124.76c-.35-.79-8.82-19.58-27.65-38.41C194.57,61.26,162.88,48,128,48S61.43,61.26,36.34,86.35C17.51,105.18,9,124,8.69,124.76a8,8,0,0,0,0,6.5c.35.79,8.82,19.57,27.65,38.4C61.43,194.74,93.12,208,128,208s66.57-13.26,91.66-38.34c18.83-18.83,27.3-37.61,27.65-38.4A8,8,0,0,0,247.31,124.76ZM128,192c-30.78,0-57.67-11.19-79.93-33.25A133.47,133.47,0,0,1,25,128,133.33,133.33,0,0,1,48.07,97.25C70.33,75.19,97.22,64,128,64s57.67,11.19,79.93,33.25A133.46,133.46,0,0,1,231.05,128C223.84,141.46,192.43,192,128,192Zm0-112a48,48,0,1,0,48,48A48.05,48.05,0,0,0,128,80Zm0,80a32,32,0,1,1,32-32A32,32,0,0,1,128,160Z"/></svg>""",
    modeComment: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="100%" height="100%" fill="currentColor"><path d="M216,48H40A16,16,0,0,0,24,64V224a15.85,15.85,0,0,0,9.24,14.5A16.13,16.13,0,0,0,40,240a15.89,15.89,0,0,0,10.25-3.78l.09-.07L82.5,208H216a16,16,0,0,0,16-16V64A16,16,0,0,0,216,48ZM40,224h0ZM216,192H82.5a16,16,0,0,0-10.3,3.75l-.08.07L40,224V64H216V192Z"/></svg>""",
    modeEdit: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="100%" height="100%" fill="currentColor"><path d="M227.31,73.37,182.63,28.68a16,16,0,0,0-22.63,0L36.69,152A15.86,15.86,0,0,0,32,163.31V208a16,16,0,0,0,16,16H92.69A15.86,15.86,0,0,0,104,219.31L227.31,96a16,16,0,0,0,0-22.63ZM92.69,208H48V163.31l88-88L180.69,120ZM192,108.68,147.31,64l24-24L216,84.68Z"/></svg>""")

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
    plus: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M0 0h24v24H0z" fill="none" stroke="none"/><path d="M12 5l0 14"/><path d="M5 12l14 0"/></svg>""",
    # 2026-05-28 expansion. Tabler ships ``layout-sidebar`` and
    # ``layout-sidebar-right``, ``eye``, ``file-text``, ``world``,
    # ``terminal-2``, ``device-desktop``, ``app-window``,
    # ``brand-apple``, ``brand-android``, ``message``, ``pencil``.
    sidebarLeft: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M0 0h24v24H0z" fill="none" stroke="none"/><path d="M4 4m0 2a2 2 0 0 1 2 -2h12a2 2 0 0 1 2 2v12a2 2 0 0 1 -2 2h-12a2 2 0 0 1 -2 -2z"/><path d="M9 4l0 16"/></svg>""",
    sidebarRight: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M0 0h24v24H0z" fill="none" stroke="none"/><path d="M4 4m0 2a2 2 0 0 1 2 -2h12a2 2 0 0 1 2 2v12a2 2 0 0 1 -2 2h-12a2 2 0 0 1 -2 -2z"/><path d="M15 4l0 16"/></svg>""",
    preview: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M0 0h24v24H0z" fill="none" stroke="none"/><path d="M12 12m-2 0a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M22 12c-2.667 4.667 -6 7 -10 7s-7.333 -2.333 -10 -7c2.667 -4.667 6 -7 10 -7s7.333 2.333 10 7"/></svg>""",
    spec: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M0 0h24v24H0z" fill="none" stroke="none"/><path d="M14 3v4a1 1 0 0 0 1 1h4"/><path d="M17 21h-10a2 2 0 0 1 -2 -2v-14a2 2 0 0 1 2 -2h7l5 5v11a2 2 0 0 1 -2 2z"/><path d="M9 9l1 0"/><path d="M9 13l6 0"/><path d="M9 17l6 0"/></svg>""",
    backendWeb: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M0 0h24v24H0z" fill="none" stroke="none"/><path d="M3 12a9 9 0 1 0 18 0a9 9 0 0 0 -18 0"/><path d="M3.6 9h16.8"/><path d="M3.6 15h16.8"/><path d="M11.5 3a17 17 0 0 0 0 18"/><path d="M12.5 3a17 17 0 0 1 0 18"/></svg>""",
    backendTui: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M0 0h24v24H0z" fill="none" stroke="none"/><path d="M8 9l3 3l-3 3"/><path d="M13 15l3 0"/><path d="M3 4m0 2a2 2 0 0 1 2 -2h14a2 2 0 0 1 2 2v12a2 2 0 0 1 -2 2h-14a2 2 0 0 1 -2 -2z"/></svg>""",
    backendGpui: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M0 0h24v24H0z" fill="none" stroke="none"/><path d="M3 5a1 1 0 0 1 1 -1h16a1 1 0 0 1 1 1v10a1 1 0 0 1 -1 1h-16a1 1 0 0 1 -1 -1v-10z"/><path d="M7 20h10"/><path d="M9 16v4"/><path d="M15 16v4"/></svg>""",
    backendFreya: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M0 0h24v24H0z" fill="none" stroke="none"/><path d="M3 5a2 2 0 0 1 2 -2h14a2 2 0 0 1 2 2v14a2 2 0 0 1 -2 2h-14a2 2 0 0 1 -2 -2v-14z"/><path d="M6 8h.01"/><path d="M9 8h.01"/></svg>""",
    backendCocoa: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M0 0h24v24H0z" fill="none" stroke="none"/><path d="M9 7c-3 0 -4 3 -4 5.5c0 3 2 7.5 4 7.5c1.088 -.046 1.679 -.5 3 -.5c1.312 0 1.5 .5 3 .5s4 -3 4 -5c-.028 -.01 -2.472 -.403 -2.5 -3c-.019 -2.17 2.416 -2.954 2.5 -3c-1.023 -1.492 -2.951 -1.963 -3.5 -2c-1.433 -.111 -2.83 1 -3.5 1c-.68 0 -1.9 -1 -3 -1z"/><path d="M12 4a2 2 0 0 0 2 -2a2 2 0 0 0 -2 2"/></svg>""",
    backendAndroid: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M0 0h24v24H0z" fill="none" stroke="none"/><path d="M4 10l0 6"/><path d="M20 10l0 6"/><path d="M7 9h10v8a1 1 0 0 1 -1 1h-8a1 1 0 0 1 -1 -1v-8a5 5 0 0 1 10 0"/><path d="M8 3l1 2"/><path d="M16 3l-1 2"/><path d="M9 18l0 3"/><path d="M15 18l0 3"/></svg>""",
    backendIos: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M0 0h24v24H0z" fill="none" stroke="none"/><path d="M9 7c-3 0 -4 3 -4 5.5c0 3 2 7.5 4 7.5c1.088 -.046 1.679 -.5 3 -.5c1.312 0 1.5 .5 3 .5s4 -3 4 -5c-.028 -.01 -2.472 -.403 -2.5 -3c-.019 -2.17 2.416 -2.954 2.5 -3c-1.023 -1.492 -2.951 -1.963 -3.5 -2c-1.433 -.111 -2.83 1 -3.5 1c-.68 0 -1.9 -1 -3 -1z"/><path d="M12 4a2 2 0 0 0 2 -2a2 2 0 0 0 -2 2"/></svg>""",
    modeView: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M0 0h24v24H0z" fill="none" stroke="none"/><path d="M12 12m-2 0a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M22 12c-2.667 4.667 -6 7 -10 7s-7.333 -2.333 -10 -7c2.667 -4.667 6 -7 10 -7s7.333 2.333 10 7"/></svg>""",
    modeComment: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M0 0h24v24H0z" fill="none" stroke="none"/><path d="M8 9h8"/><path d="M8 13h6"/><path d="M14.5 18.5l-2.5 2.5l-3 -3h-3a3 3 0 0 1 -3 -3v-8a3 3 0 0 1 3 -3h12a3 3 0 0 1 3 3v8a3 3 0 0 1 -3 3h-3.5z"/></svg>""",
    modeEdit: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M0 0h24v24H0z" fill="none" stroke="none"/><path d="M4 20h4l10.5 -10.5a2.828 2.828 0 1 0 -4 -4l-10.5 10.5v4"/><path d="M13.5 6.5l4 4"/></svg>""")

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
    plus: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="100%" height="100%" fill="currentColor"><path d="M8 4a.5.5 0 0 1 .5.5v3h3a.5.5 0 0 1 0 1h-3v3a.5.5 0 0 1-1 0v-3h-3a.5.5 0 0 1 0-1h3v-3A.5.5 0 0 1 8 4"/></svg>""",
    # 2026-05-28 expansion. Bootstrap Icons ships ``layout-sidebar``,
    # ``layout-sidebar-reverse``, ``eye``, ``file-earmark-text``,
    # ``globe``, ``terminal``, ``display``, ``window``, ``apple``,
    # ``android2``, ``chat``, ``pencil``.
    sidebarLeft: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="100%" height="100%" fill="currentColor"><path d="M0 3.5A1.5 1.5 0 0 1 1.5 2h13A1.5 1.5 0 0 1 16 3.5v9a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 0 12.5zM1.5 3a.5.5 0 0 0-.5.5v9a.5.5 0 0 0 .5.5H4v-10zM5 13h9.5a.5.5 0 0 0 .5-.5v-9a.5.5 0 0 0-.5-.5H5z"/></svg>""",
    sidebarRight: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="100%" height="100%" fill="currentColor"><path d="M12 3v10h2.5a.5.5 0 0 0 .5-.5v-9a.5.5 0 0 0-.5-.5zm-1 0H1.5a.5.5 0 0 0-.5.5v9a.5.5 0 0 0 .5.5H11zM0 3.5A1.5 1.5 0 0 1 1.5 2h13A1.5 1.5 0 0 1 16 3.5v9a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 0 12.5z"/></svg>""",
    preview: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="100%" height="100%" fill="currentColor"><path d="M16 8s-3-5.5-8-5.5S0 8 0 8s3 5.5 8 5.5S16 8 16 8M1.173 8a13 13 0 0 1 1.66-2.043C4.12 4.668 5.88 3.5 8 3.5s3.879 1.168 5.168 2.457A13 13 0 0 1 14.828 8q-.086.13-.195.288c-.335.48-.83 1.12-1.465 1.755C11.879 11.332 10.119 12.5 8 12.5s-3.879-1.168-5.168-2.457A13 13 0 0 1 1.172 8z"/><path d="M8 5.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5M4.5 8a3.5 3.5 0 1 1 7 0 3.5 3.5 0 0 1-7 0"/></svg>""",
    spec: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="100%" height="100%" fill="currentColor"><path d="M5.5 7a.5.5 0 0 0 0 1h5a.5.5 0 0 0 0-1zM5 9.5a.5.5 0 0 1 .5-.5h5a.5.5 0 0 1 0 1h-5a.5.5 0 0 1-.5-.5m0 2a.5.5 0 0 1 .5-.5h2a.5.5 0 0 1 0 1h-2a.5.5 0 0 1-.5-.5"/><path d="M9.5 0H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V4.5zm0 1v2A1.5 1.5 0 0 0 11 4.5h2V14a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V2a1 1 0 0 1 1-1z"/></svg>""",
    backendWeb: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="100%" height="100%" fill="currentColor"><path d="M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8m7.5-6.923c-.67.204-1.335.82-1.887 1.855A8 8 0 0 0 5.145 4H7.5zM4.09 4a9.3 9.3 0 0 1 .64-1.539 7 7 0 0 1 .597-.933A7.03 7.03 0 0 0 1.255 4zm-.582 3.5c.03-.877.138-1.718.312-2.5H1.064a7 7 0 0 0-.581 2.5zm1.32-2.5a10.6 10.6 0 0 0-.338 2.5H7.5V5zm4.612 0H8.5v2.5h2.937a10.6 10.6 0 0 0-.338-2.5zM8.5 8.5V11h2.376c.183-.762.299-1.626.343-2.5zm-1 0H4.51c.045.874.16 1.738.343 2.5H7.5zm0 3.5H5.145c.182.49.395.94.636 1.342.547 1.024 1.207 1.643 1.886 1.866zm.5 2.064c.428-.255.83-.673 1.207-1.215.166-.279.32-.578.461-.85h-2.13c.14.272.295.571.46.85.378.542.78.96 1.208 1.215zm.5-2.064v3.208c.679-.223 1.34-.842 1.887-1.866q.39-.728.636-1.342zm2.92-1.5h2.43A6.95 6.95 0 0 0 14.86 8.5h-2.443c-.025.825-.122 1.654-.295 2.5zm.31-3.5c.03.846.123 1.66.295 2.5h2.39c.198-.787.295-1.625.295-2.5zm-1.05-1.5h-2.43A8 8 0 0 0 11.5 4.5c-.547-1.024-1.207-1.643-1.886-1.866V5H10c.456 0 .9-.043 1.32-.123.027.077.052.157.075.236A11 11 0 0 1 11.5 5z"/></svg>""",
    backendTui: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="100%" height="100%" fill="currentColor"><path d="M6 9a.5.5 0 0 1 .5.5v4a.5.5 0 0 1-1 0v-4A.5.5 0 0 1 6 9"/><path d="M14 1a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H2a2 2 0 0 1-2-2V3a2 2 0 0 1 2-2zM2 2a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V3a1 1 0 0 0-1-1z"/><path d="M3.146 6.146a.5.5 0 0 1 .708 0l2 2a.5.5 0 0 1 0 .708l-2 2a.5.5 0 0 1-.708-.708L4.793 8.5 3.146 6.854a.5.5 0 0 1 0-.708"/></svg>""",
    backendGpui: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="100%" height="100%" fill="currentColor"><path d="M0 4s0-2 2-2h12s2 0 2 2v6s0 2-2 2h-4q0 1 .25 1.5H11a.5.5 0 0 1 0 1H5a.5.5 0 0 1 0-1h.75Q6 13 6 12H2s-2 0-2-2zm1.398-.855a.76.76 0 0 0-.254.302A1.5 1.5 0 0 0 1.01 4.01L1 4.017V10c0 .337.13.516.265.642q.207.184.59.299c.387.103.8.139 1.245.111H13.1c.445.028.858-.008 1.245-.11q.382-.116.59-.3c.135-.126.265-.305.265-.642V4.017l-.01-.008a1.5 1.5 0 0 0-.135-.563.76.76 0 0 0-.254-.302C14.563 3.06 14.32 3 14 3H2c-.32 0-.563.06-.602.145"/></svg>""",
    backendFreya: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="100%" height="100%" fill="currentColor"><path d="M2.5 4a.5.5 0 1 0 0-1 .5.5 0 0 0 0 1m2-.5a.5.5 0 1 1-1 0 .5.5 0 0 1 1 0m1 .5a.5.5 0 1 0 0-1 .5.5 0 0 0 0 1"/><path d="M2 2a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V4a2 2 0 0 0-2-2zm13 2v1H1V4a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1M2 13a1 1 0 0 1-1-1V6h14v6a1 1 0 0 1-1 1z"/></svg>""",
    backendCocoa: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="100%" height="100%" fill="currentColor"><path d="M11.182.008C11.148-.03 9.923.023 8.857 1.18c-1.066 1.156-.902 2.482-.878 2.516s1.52.087 2.475-1.258.762-2.391.728-2.43m3.314 11.733c-.048-.096-2.325-1.234-2.113-3.422.212-2.189 1.675-2.789 1.698-2.854s-.597-.79-1.254-1.157a3.7 3.7 0 0 0-1.563-.434c-.108-.003-.483-.095-1.254.116-.508.139-1.653.589-1.968.607-.316.018-1.256-.522-2.267-.665-.647-.125-1.333.131-1.824.328-.49.196-1.422.754-2.074 2.237-.652 1.482-.311 3.83-.067 4.56s.625 1.924 1.273 2.796c.576.984 1.34 1.667 1.659 1.899s1.219.386 1.843.067c.502-.308 1.408-.485 1.766-.472.357.013 1.061.154 1.782.539.571.197 1.111.115 1.652-.105.541-.221 1.324-1.059 2.238-2.758q.52-1.185.473-1.282"/></svg>""",
    backendAndroid: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="100%" height="100%" fill="currentColor"><path d="M5 12.5a.5.5 0 0 1 .5.5v1.5a.5.5 0 0 1-1 0V13a.5.5 0 0 1 .5-.5m6 0a.5.5 0 0 1 .5.5v1.5a.5.5 0 0 1-1 0V13a.5.5 0 0 1 .5-.5M4.708 6.5a4.001 4.001 0 0 1 7.187.182l.156-.181a.495.495 0 1 1 .749.654l-.514.601a.5.5 0 0 1-.564.124 4 4 0 0 0-.404-.171l.054-.045a4.001 4.001 0 0 1-6.59.181l.156-.181a.495.495 0 0 0-.71-.687l-.514.601a.5.5 0 0 0-.075.18 5 5 0 1 1 .069 1.062z"/><path d="M11.246 4.5a.495.495 0 1 0-.711-.689l-.514.601a4 4 0 0 0-3.85-.001l-.514-.601a.495.495 0 1 0-.711.689l.157.182a4 4 0 1 0 5.987.001zM6 7.5a.5.5 0 1 1-1 0 .5.5 0 0 1 1 0m4.5.5a.5.5 0 1 0 0-1 .5.5 0 0 0 0 1"/></svg>""",
    backendIos: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="100%" height="100%" fill="currentColor"><path d="M11.182.008C11.148-.03 9.923.023 8.857 1.18c-1.066 1.156-.902 2.482-.878 2.516s1.52.087 2.475-1.258.762-2.391.728-2.43m3.314 11.733c-.048-.096-2.325-1.234-2.113-3.422.212-2.189 1.675-2.789 1.698-2.854s-.597-.79-1.254-1.157a3.7 3.7 0 0 0-1.563-.434c-.108-.003-.483-.095-1.254.116-.508.139-1.653.589-1.968.607-.316.018-1.256-.522-2.267-.665-.647-.125-1.333.131-1.824.328-.49.196-1.422.754-2.074 2.237-.652 1.482-.311 3.83-.067 4.56s.625 1.924 1.273 2.796c.576.984 1.34 1.667 1.659 1.899s1.219.386 1.843.067c.502-.308 1.408-.485 1.766-.472.357.013 1.061.154 1.782.539.571.197 1.111.115 1.652-.105.541-.221 1.324-1.059 2.238-2.758q.52-1.185.473-1.282"/></svg>""",
    modeView: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="100%" height="100%" fill="currentColor"><path d="M16 8s-3-5.5-8-5.5S0 8 0 8s3 5.5 8 5.5S16 8 16 8M1.173 8a13 13 0 0 1 1.66-2.043C4.12 4.668 5.88 3.5 8 3.5s3.879 1.168 5.168 2.457A13 13 0 0 1 14.828 8q-.086.13-.195.288c-.335.48-.83 1.12-1.465 1.755C11.879 11.332 10.119 12.5 8 12.5s-3.879-1.168-5.168-2.457A13 13 0 0 1 1.172 8z"/><path d="M8 5.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5M4.5 8a3.5 3.5 0 1 1 7 0 3.5 3.5 0 0 1-7 0"/></svg>""",
    modeComment: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="100%" height="100%" fill="currentColor"><path d="M2.678 11.894a1 1 0 0 1 .287.801 11 11 0 0 1-.398 2c1.395-.323 2.247-.697 2.634-.893a1 1 0 0 1 .71-.074A8 8 0 0 0 8 14c3.996 0 7-2.807 7-6s-3.004-6-7-6-7 2.808-7 6c0 1.468.617 2.83 1.678 3.894m-.493 3.905a22 22 0 0 1-.713.129c-.2.032-.352-.176-.273-.362a10 10 0 0 0 .244-.637l.003-.01c.248-.72.45-1.548.524-2.319C.743 11.37 0 9.76 0 8c0-3.866 3.582-7 8-7s8 3.134 8 7-3.582 7-8 7a9 9 0 0 1-2.347-.306c-.52.263-1.639.742-3.468 1.105"/></svg>""",
    modeEdit: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="100%" height="100%" fill="currentColor"><path d="M12.146.146a.5.5 0 0 1 .708 0l3 3a.5.5 0 0 1 0 .708l-10 10a.5.5 0 0 1-.168.11l-5 2a.5.5 0 0 1-.65-.65l2-5a.5.5 0 0 1 .11-.168zM11.207 2.5 13.5 4.793 14.793 3.5 12.5 1.207zm1.586 3L10.5 3.207 4 9.707V10h.5a.5.5 0 0 1 .5.5v.5h.5a.5.5 0 0 1 .5.5v.5h.293zm-9.761 5.175-.106.106-1.528 3.821 3.821-1.528.106-.106A.5.5 0 0 1 5 12.5V12h-.5a.5.5 0 0 1-.5-.5V11h-.5a.5.5 0 0 1-.468-.325"/></svg>""")

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
    plus: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6z"/></svg>""",
    # 2026-05-28 expansion. Material Symbols ships ``dock_to_left`` /
    # ``dock_to_right``, ``visibility``, ``description``, ``language``
    # for globe, ``terminal``, ``desktop_windows``, ``web_asset``,
    # ``smartphone`` (used for Cocoa/iOS/Android since Material doesn't
    # ship an apple/android logo), ``chat``, ``edit``.
    sidebarLeft: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm0 16H5V5h4v14z"/></svg>""",
    sidebarRight: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm0 16h-4V5h4v14z"/></svg>""",
    preview: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="M12 4.5C7 4.5 2.73 7.61 1 12c1.73 4.39 6 7.5 11 7.5s9.27-3.11 11-7.5c-1.73-4.39-6-7.5-11-7.5M12 17c-2.76 0-5-2.24-5-5s2.24-5 5-5 5 2.24 5 5-2.24 5-5 5m0-8c-1.66 0-3 1.34-3 3s1.34 3 3 3 3-1.34 3-3-1.34-3-3-3"/></svg>""",
    spec: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8zm-1 17H7v-2h6zm3-4H7v-2h9zm0-4H7V9h9zM13 9V3.5L18.5 9z"/></svg>""",
    backendWeb: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2M18.92 8h-2.95c-.32-1.25-.78-2.45-1.38-3.56 1.84.63 3.37 1.91 4.33 3.56M12 4.04c.83 1.2 1.48 2.53 1.91 3.96h-3.82c.43-1.43 1.08-2.76 1.91-3.96M4.26 14C4.1 13.36 4 12.69 4 12s.1-1.36.26-2h3.38c-.08.66-.14 1.32-.14 2s.06 1.34.14 2zm.82 2h2.95c.32 1.25.78 2.45 1.38 3.56-1.84-.63-3.37-1.9-4.33-3.56m2.95-8H5.08c.96-1.66 2.49-2.93 4.33-3.56C8.81 5.55 8.35 6.75 8.03 8M12 19.96c-.83-1.2-1.48-2.53-1.91-3.96h3.82c-.43 1.43-1.08 2.76-1.91 3.96M14.34 14H9.66c-.09-.66-.16-1.32-.16-2s.07-1.35.16-2h4.68c.09.65.16 1.32.16 2s-.07 1.34-.16 2m.25 5.56c.6-1.11 1.06-2.31 1.38-3.56h2.95a8.03 8.03 0 0 1-4.33 3.56M16.36 14c.08-.66.14-1.32.14-2s-.06-1.34-.14-2h3.38c.16.64.26 1.31.26 2s-.1 1.36-.26 2z"/></svg>""",
    backendTui: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="M20 4H4c-1.11 0-2 .89-2 2v12c0 1.1.89 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.11-.9-2-2-2m0 14H4V8h16zm-2-1h-6v-2h6zM7.5 17l-3.5-3.5 1.41-1.41L7.5 14.17l4.59-4.58 1.41 1.41z"/></svg>""",
    backendGpui: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="M21 2H3c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h7v2H8v2h8v-2h-2v-2h7c1.1 0 1.99-.9 1.99-2L23 4c0-1.1-.9-2-2-2m0 14H3V4h18z"/></svg>""",
    backendFreya: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="M19 4H5c-1.11 0-2 .9-2 2v12c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2V6c0-1.1-.89-2-2-2m0 14H5V8h14z"/></svg>""",
    backendCocoa: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="M17 1.01L7 1c-1.1 0-2 .9-2 2v18c0 1.1.9 2 2 2h10c1.1 0 2-.9 2-2V3c0-1.1-.9-1.99-2-1.99M17 19H7V5h10z"/></svg>""",
    backendAndroid: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="M17 1.01L7 1c-1.1 0-2 .9-2 2v18c0 1.1.9 2 2 2h10c1.1 0 2-.9 2-2V3c0-1.1-.9-1.99-2-1.99M17 19H7V5h10z"/></svg>""",
    backendIos: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="M17 1.01L7 1c-1.1 0-2 .9-2 2v18c0 1.1.9 2 2 2h10c1.1 0 2-.9 2-2V3c0-1.1-.9-1.99-2-1.99M17 19H7V5h10z"/></svg>""",
    modeView: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="M12 4.5C7 4.5 2.73 7.61 1 12c1.73 4.39 6 7.5 11 7.5s9.27-3.11 11-7.5c-1.73-4.39-6-7.5-11-7.5M12 17c-2.76 0-5-2.24-5-5s2.24-5 5-5 5 2.24 5 5-2.24 5-5 5m0-8c-1.66 0-3 1.34-3 3s1.34 3 3 3 3-1.34 3-3-1.34-3-3-3"/></svg>""",
    modeComment: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="M20 2H4c-1.1 0-1.99.9-1.99 2L2 22l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2"/></svg>""",
    modeEdit: """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75zM20.71 7.04a.996.996 0 0 0 0-1.41l-2.34-2.34a.996.996 0 0 0-1.41 0l-1.83 1.83 3.75 3.75z"/></svg>""")

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

  # History (capture-gallery) button — one-off, not part of the
  # swappable IconSet because the showcase story doesn't expose it.
  # Clock face with a counter-clockwise rewind arrow at the top-left.
  # See docs/icon-design/history.svg for the source.
  historySvg* = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/><path d="M12 7v5l3.5 2"/></svg>"""

  # ---------------------------------------------------------------
  # Selection-header quick-action SVGs (Phase B).
  #
  # These four icons live in the inspector's selection header — the
  # always-visible row above the section list that shows the
  # selected element's type plus a Code / Visibility / Duplicate /
  # More action cluster aligned to the right. They are chrome, NOT
  # part of the swappable ``IconSet`` (no showcase story exposes
  # them) — the spec pins their look so all icon sets render the
  # same selection header. See
  # ``Front-Ends/IsoNim/isonim-editor.md`` §"Selection header".
  # All four follow the established 24×24 viewBox, currentColor
  # stroke, 1.75 px stroke-width, round caps/joins family so they
  # read at the same weight as ``wrenchSvg`` / ``plusSvg`` etc.
  # ---------------------------------------------------------------

  selectionCodeSvg* = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><polyline points="8 6 3 12 8 18"/><polyline points="16 6 21 12 16 18"/><line x1="14" y1="4" x2="10" y2="20"/></svg>"""
    ## ``< / >`` brackets — "open source for selection" affordance.
    ## Two angle brackets framing a forward-slash. Hand-drawn so the
    ## stroke weight matches the rest of the in-house set.

  selectionVisibilitySvg* = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 3a9 9 0 0 0 0 18z" fill="currentColor"/></svg>"""
    ## Half-moon visibility icon. A full circle with the left half
    ## filled, which reads as "visibility toggled" — clearer than a
    ## bare eye glyph at 18 px and matches the Figma reference's
    ## ``◐`` chrome.

  selectionDuplicateSvg* = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="13" height="13" rx="2"/><rect x="8" y="8" width="13" height="13" rx="2"/><polyline points="17 19 20 22 23 19" transform="translate(-3 -3)"/></svg>"""
    ## Two overlapping rounded squares plus a small chevron — the
    ## "duplicate / variants" cluster from the Figma reference.

  selectionMoreSvg* = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor" stroke="none"><circle cx="8" cy="8" r="1.6"/><circle cx="16" cy="8" r="1.6"/><circle cx="8" cy="16" r="1.6"/><circle cx="16" cy="16" r="1.6"/></svg>"""
    ## 2×2 dots overflow glyph. Filled dots (rather than stroked
    ## circles) so it reads as a clear "more actions" affordance at
    ## the same visual weight as the other three icons.
