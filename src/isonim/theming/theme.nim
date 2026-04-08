## Cross-platform theming for IsoNim renderers.
##
## Defines semantic design tokens (colors, spacing, typography, radii)
## that renderers map to platform-native properties. Three modes:
## - Native: platform defaults (no theme override)
## - Branded: identical appearance on all platforms
## - Adaptive: shared base with per-platform overrides

import std/tables

type
  ThemeMode* = enum
    tmNative     ## Use platform defaults (iOS blue, Material purple, etc.)
    tmBranded    ## Force identical appearance across platforms
    tmAdaptive   ## Shared base theme with per-platform overrides

  ColorToken* = object
    light*: string  ## Hex color for light mode (e.g. "#007AFF")
    dark*: string   ## Hex color for dark mode

  SpacingScale* = object
    xs*: float    ## 4
    sm*: float    ## 8
    md*: float    ## 16
    lg*: float    ## 24
    xl*: float    ## 32
    xxl*: float   ## 48

  TypographyStyle* = object
    size*: float       ## Font size in points/sp
    weight*: string    ## "normal", "medium", "semibold", "bold"
    letterSpacing*: float  ## Em units

  Typography* = object
    largeTitle*: TypographyStyle
    title*: TypographyStyle
    headline*: TypographyStyle
    body*: TypographyStyle
    callout*: TypographyStyle
    caption*: TypographyStyle
    footnote*: TypographyStyle

  BorderRadii* = object
    none*: float    ## 0
    sm*: float      ## 4
    md*: float      ## 8
    lg*: float      ## 12
    xl*: float      ## 16
    full*: float    ## 9999 (pill shape)

  Theme* = object
    name*: string
    mode*: ThemeMode

    # Colors
    primary*: ColorToken
    secondary*: ColorToken
    accent*: ColorToken
    background*: ColorToken
    surface*: ColorToken
    error*: ColorToken
    onPrimary*: ColorToken      ## Text/icon color on primary background
    onSecondary*: ColorToken
    onBackground*: ColorToken
    onSurface*: ColorToken
    onError*: ColorToken
    border*: ColorToken
    textPrimary*: ColorToken
    textSecondary*: ColorToken
    textDisabled*: ColorToken

    # Spacing
    spacing*: SpacingScale

    # Typography
    typography*: Typography

    # Radii
    radii*: BorderRadii

    # Platform overrides (only used in tmAdaptive mode)
    iosOverrides*: Table[string, string]   ## token name -> value override
    androidOverrides*: Table[string, string]

# ---------------------------------------------------------------------------
# Built-in themes
# ---------------------------------------------------------------------------

proc defaultSpacing*(): SpacingScale =
  SpacingScale(xs: 4, sm: 8, md: 16, lg: 24, xl: 32, xxl: 48)

proc defaultTypography*(): Typography =
  Typography(
    largeTitle: TypographyStyle(size: 34, weight: "bold", letterSpacing: 0),
    title: TypographyStyle(size: 28, weight: "bold", letterSpacing: 0),
    headline: TypographyStyle(size: 22, weight: "semibold", letterSpacing: 0),
    body: TypographyStyle(size: 17, weight: "normal", letterSpacing: 0),
    callout: TypographyStyle(size: 16, weight: "normal", letterSpacing: 0),
    caption: TypographyStyle(size: 12, weight: "normal", letterSpacing: 0),
    footnote: TypographyStyle(size: 13, weight: "normal", letterSpacing: 0),
  )

proc defaultRadii*(): BorderRadii =
  BorderRadii(none: 0, sm: 4, md: 8, lg: 12, xl: 16, full: 9999)

proc color*(light, dark: string): ColorToken =
  ColorToken(light: light, dark: dark)

proc color*(hex: string): ColorToken =
  ColorToken(light: hex, dark: hex)

proc nativeTheme*(): Theme =
  ## No theme -- let each platform use its defaults.
  Theme(name: "native", mode: tmNative)

proc isoTheme*(): Theme =
  ## IsoNim branded theme -- consistent across platforms.
  Theme(
    name: "iso",
    mode: tmBranded,
    primary: color("#6366F1", "#818CF8"),       # Indigo
    secondary: color("#8B5CF6", "#A78BFA"),     # Violet
    accent: color("#06B6D4", "#22D3EE"),        # Cyan
    background: color("#F8FAFC", "#0F172A"),    # Slate 50/900
    surface: color("#FFFFFF", "#1E293B"),        # White/Slate 800
    error: color("#EF4444", "#F87171"),          # Red
    onPrimary: color("#FFFFFF", "#FFFFFF"),
    onSecondary: color("#FFFFFF", "#FFFFFF"),
    onBackground: color("#0F172A", "#F8FAFC"),
    onSurface: color("#1E293B", "#F1F5F9"),
    onError: color("#FFFFFF", "#FFFFFF"),
    border: color("#E2E8F0", "#334155"),         # Slate 200/700
    textPrimary: color("#0F172A", "#F8FAFC"),
    textSecondary: color("#64748B", "#94A3B8"),  # Slate 500/400
    textDisabled: color("#CBD5E1", "#475569"),   # Slate 300/600
    spacing: defaultSpacing(),
    typography: defaultTypography(),
    radii: defaultRadii(),
  )

proc warmTheme*(): Theme =
  ## Warm-toned theme (orange/amber).
  Theme(
    name: "warm",
    mode: tmBranded,
    primary: color("#F59E0B", "#FBBF24"),       # Amber
    secondary: color("#EF4444", "#F87171"),     # Red
    accent: color("#10B981", "#34D399"),        # Emerald
    background: color("#FFFBEB", "#1C1917"),    # Amber 50/Stone 900
    surface: color("#FFFFFF", "#292524"),
    error: color("#DC2626", "#F87171"),
    onPrimary: color("#FFFFFF", "#000000"),
    onSecondary: color("#FFFFFF", "#FFFFFF"),
    onBackground: color("#1C1917", "#FAFAF9"),
    onSurface: color("#292524", "#F5F5F4"),
    onError: color("#FFFFFF", "#FFFFFF"),
    border: color("#FDE68A", "#44403C"),
    textPrimary: color("#1C1917", "#FAFAF9"),
    textSecondary: color("#78716C", "#A8A29E"),
    textDisabled: color("#D6D3D1", "#57534E"),
    spacing: defaultSpacing(),
    typography: defaultTypography(),
    radii: defaultRadii(),
  )

# ---------------------------------------------------------------------------
# Active theme management
# ---------------------------------------------------------------------------

var activeTheme*: Theme = nativeTheme()
var isDarkMode*: bool = false

proc setTheme*(theme: Theme) =
  activeTheme = theme

proc setDarkMode*(dark: bool) =
  isDarkMode = dark

proc resolveColor*(token: ColorToken): string =
  ## Resolve a color token to a hex string based on dark mode state.
  if isDarkMode: token.dark else: token.light

proc themeColor*(name: string): string =
  ## Look up a semantic color by name. Returns "" if native mode or not found.
  if activeTheme.mode == tmNative:
    return ""
  case name
  of "primary": resolveColor(activeTheme.primary)
  of "secondary": resolveColor(activeTheme.secondary)
  of "accent": resolveColor(activeTheme.accent)
  of "background": resolveColor(activeTheme.background)
  of "surface": resolveColor(activeTheme.surface)
  of "error": resolveColor(activeTheme.error)
  of "on-primary": resolveColor(activeTheme.onPrimary)
  of "on-secondary": resolveColor(activeTheme.onSecondary)
  of "on-background": resolveColor(activeTheme.onBackground)
  of "on-surface": resolveColor(activeTheme.onSurface)
  of "on-error": resolveColor(activeTheme.onError)
  of "border": resolveColor(activeTheme.border)
  of "text-primary": resolveColor(activeTheme.textPrimary)
  of "text-secondary": resolveColor(activeTheme.textSecondary)
  of "text-disabled": resolveColor(activeTheme.textDisabled)
  else: ""

proc themeSpacing*(size: string): float =
  ## Look up spacing by size name. Returns -1 if native mode.
  if activeTheme.mode == tmNative:
    return -1
  case size
  of "xs": activeTheme.spacing.xs
  of "sm": activeTheme.spacing.sm
  of "md": activeTheme.spacing.md
  of "lg": activeTheme.spacing.lg
  of "xl": activeTheme.spacing.xl
  of "xxl": activeTheme.spacing.xxl
  else: -1

proc themeRadius*(size: string): float =
  ## Look up border radius by size name. Returns -1 if native mode.
  if activeTheme.mode == tmNative:
    return -1
  case size
  of "none": activeTheme.radii.none
  of "sm": activeTheme.radii.sm
  of "md": activeTheme.radii.md
  of "lg": activeTheme.radii.lg
  of "xl": activeTheme.radii.xl
  of "full": activeTheme.radii.full
  else: -1

proc themeTypography*(style: string): TypographyStyle =
  ## Look up typography style by name.
  case style
  of "large-title", "largeTitle": activeTheme.typography.largeTitle
  of "title": activeTheme.typography.title
  of "headline": activeTheme.typography.headline
  of "body": activeTheme.typography.body
  of "callout": activeTheme.typography.callout
  of "caption": activeTheme.typography.caption
  of "footnote": activeTheme.typography.footnote
  else: activeTheme.typography.body
