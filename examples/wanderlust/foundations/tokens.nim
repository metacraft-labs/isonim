## Wanderlust — Design Tokens
##
## Semantic design tokens for the travel planning app.
## All visual properties reference these tokens, not raw values.

# ===========================================================================
# Color Palette
# ===========================================================================

const
  # Primary: warm coral/terracotta — evokes adventure and warmth
  colorPrimary* = "#E07A5F"         # Terracotta
  colorPrimaryLight* = "#F2A68B"
  colorPrimaryDark* = "#C45A3C"
  colorPrimarySubtle* = "#FDF0EC"

  # Secondary: deep teal — trust, depth, ocean
  colorSecondary* = "#3D7C8C"       # Teal
  colorSecondaryLight* = "#5BA3B5"
  colorSecondaryDark* = "#2A5A66"
  colorSecondarySubtle* = "#EDF5F7"

  # Accent: golden amber — sunlight, highlights, CTAs
  colorAccent* = "#F2CC8F"          # Amber
  colorAccentDark* = "#D4A654"
  colorAccentSubtle* = "#FDF6E8"

  # Neutral palette
  colorNeutral50* = "#FAFAF9"
  colorNeutral100* = "#F5F5F4"
  colorNeutral200* = "#E7E5E4"
  colorNeutral300* = "#D6D3D1"
  colorNeutral400* = "#A8A29E"
  colorNeutral500* = "#78716C"
  colorNeutral600* = "#57534E"
  colorNeutral700* = "#44403C"
  colorNeutral800* = "#292524"
  colorNeutral900* = "#1C1917"

  # Semantic colors
  colorSuccess* = "#4ADE80"
  colorWarning* = "#FBBF24"
  colorError* = "#F87171"
  colorInfo* = "#60A5FA"

  # Surface colors
  colorBgPrimary* = "#FFFFFF"
  colorBgSecondary* = "#FAFAF9"
  colorBgTertiary* = "#F5F5F4"
  colorBgOverlay* = "rgba(28, 25, 23, 0.6)"

  # Text colors
  colorTextPrimary* = "#1C1917"
  colorTextSecondary* = "#57534E"
  colorTextTertiary* = "#A8A29E"
  colorTextInverse* = "#FFFFFF"
  colorTextLink* = "#3D7C8C"

# ===========================================================================
# Typography Scale
# ===========================================================================

const
  fontFamilyDisplay* = "'Playfair Display', Georgia, serif"
  fontFamilyBody* = "'Inter', system-ui, -apple-system, sans-serif"
  fontFamilyMono* = "'JetBrains Mono', 'SF Mono', monospace"

  # Size scale (px)
  fontSizeXs* = "11"
  fontSizeSm* = "13"
  fontSizeMd* = "15"
  fontSizeLg* = "18"
  fontSizeXl* = "22"
  fontSize2xl* = "28"
  fontSize3xl* = "36"
  fontSize4xl* = "48"
  fontSize5xl* = "64"

  # Weight
  fontWeightNormal* = "400"
  fontWeightMedium* = "500"
  fontWeightSemibold* = "600"
  fontWeightBold* = "700"

  # Line height
  lineHeightTight* = "1.2"
  lineHeightNormal* = "1.5"
  lineHeightRelaxed* = "1.7"

# ===========================================================================
# Spacing Scale
# ===========================================================================

const
  space0* = "0"
  space1* = "4"     # 4px
  space2* = "8"     # 8px
  space3* = "12"    # 12px
  space4* = "16"    # 16px
  space5* = "20"    # 20px
  space6* = "24"    # 24px
  space8* = "32"    # 32px
  space10* = "40"   # 40px
  space12* = "48"   # 48px
  space16* = "64"   # 64px
  space20* = "80"   # 80px

# ===========================================================================
# Border Radius
# ===========================================================================

const
  radiusSm* = "4"
  radiusMd* = "8"
  radiusLg* = "12"
  radiusXl* = "16"
  radius2xl* = "24"
  radiusFull* = "9999"

# ===========================================================================
# Elevation (box-shadow)
# ===========================================================================

const
  elevationSm* = "0 1px 2px rgba(0,0,0,0.05)"
  elevationMd* = "0 4px 6px -1px rgba(0,0,0,0.1), 0 2px 4px -2px rgba(0,0,0,0.1)"
  elevationLg* = "0 10px 15px -3px rgba(0,0,0,0.1), 0 4px 6px -4px rgba(0,0,0,0.1)"
  elevationXl* = "0 20px 25px -5px rgba(0,0,0,0.1), 0 8px 10px -6px rgba(0,0,0,0.1)"

# ===========================================================================
# Motion
# ===========================================================================

const
  durationFast* = "0.1s"
  durationNormal* = "0.2s"
  durationSlow* = "0.3s"
  durationVerySlow* = "0.5s"

  easingDefault* = "cubic-bezier(0.4, 0, 0.2, 1)"
  easingIn* = "cubic-bezier(0.4, 0, 1, 1)"
  easingOut* = "cubic-bezier(0, 0, 0.2, 1)"
  easingBounce* = "cubic-bezier(0.34, 1.56, 0.64, 1)"
