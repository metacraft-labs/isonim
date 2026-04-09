## isonim/dsl/tailwind.nim
##
## Compile-time Tailwind CSS utility class parser.
## Expands Tailwind class names to (CSS-property, value) pairs that can be
## emitted as setStyle calls by the buildHtml macro.
##
## This enables the same Tailwind utility classes to work on all platforms:
## - Web: classes are passed through to the browser CSS engine
## - Native (iOS/Android/Freya): classes are expanded to setStyle calls
##
## Supports a practical subset of Tailwind v3 utilities.

import std/[strutils, tables, macros]

# ===========================================================================
# Tailwind color palette (subset — the most commonly used shades)
# ===========================================================================

const tailwindColors* = {
  # Gray
  "gray-50": "#F9FAFB", "gray-100": "#F3F4F6", "gray-200": "#E5E7EB",
  "gray-300": "#D1D5DB", "gray-400": "#9CA3AF", "gray-500": "#6B7280",
  "gray-600": "#4B5563", "gray-700": "#374151", "gray-800": "#1F2937",
  "gray-900": "#111827", "gray-950": "#030712",
  # Slate
  "slate-50": "#F8FAFC", "slate-100": "#F1F5F9", "slate-200": "#E2E8F0",
  "slate-300": "#CBD5E1", "slate-400": "#94A3B8", "slate-500": "#64748B",
  "slate-600": "#475569", "slate-700": "#334155", "slate-800": "#1E293B",
  "slate-900": "#0F172A", "slate-950": "#020617",
  # Red
  "red-50": "#FEF2F2", "red-100": "#FEE2E2", "red-200": "#FECACA",
  "red-300": "#FCA5A5", "red-400": "#F87171", "red-500": "#EF4444",
  "red-600": "#DC2626", "red-700": "#B91C1C", "red-800": "#991B1B",
  "red-900": "#7F1D1D", "red-950": "#450A0A",
  # Orange
  "orange-500": "#F97316", "orange-600": "#EA580C",
  # Amber
  "amber-500": "#F59E0B", "amber-600": "#D97706",
  # Yellow
  "yellow-500": "#EAB308",
  # Green
  "green-50": "#F0FDF4", "green-100": "#DCFCE7", "green-200": "#BBF7D0",
  "green-300": "#86EFAC", "green-400": "#4ADE80", "green-500": "#22C55E",
  "green-600": "#16A34A", "green-700": "#15803D", "green-800": "#166534",
  "green-900": "#14532D",
  # Blue
  "blue-50": "#EFF6FF", "blue-100": "#DBEAFE", "blue-200": "#BFDBFE",
  "blue-300": "#93C5FD", "blue-400": "#60A5FA", "blue-500": "#3B82F6",
  "blue-600": "#2563EB", "blue-700": "#1D4ED8", "blue-800": "#1E40AF",
  "blue-900": "#1E3A8A",
  # Indigo
  "indigo-50": "#EEF2FF", "indigo-100": "#E0E7FF", "indigo-200": "#C7D2FE",
  "indigo-300": "#A5B4FC", "indigo-400": "#818CF8", "indigo-500": "#6366F1",
  "indigo-600": "#4F46E5", "indigo-700": "#4338CA", "indigo-800": "#3730A3",
  "indigo-900": "#312E81",
  # Violet
  "violet-50": "#F5F3FF", "violet-100": "#EDE9FE", "violet-200": "#DDD6FE",
  "violet-300": "#C4B5FD", "violet-400": "#A78BFA", "violet-500": "#8B5CF6",
  "violet-600": "#7C3AED", "violet-700": "#6D28D9", "violet-800": "#5B21B6",
  "violet-900": "#4C1D95",
  # Purple
  "purple-500": "#A855F7", "purple-600": "#9333EA",
  # Pink
  "pink-500": "#EC4899", "pink-600": "#DB2777",
  # Cyan
  "cyan-500": "#06B6D4", "cyan-600": "#0891B2",
  # Teal
  "teal-500": "#14B8A6", "teal-600": "#0D9488",
  # Named
  "white": "#FFFFFF", "black": "#000000", "transparent": "transparent",
}.toTable

# ===========================================================================
# Tailwind spacing scale (rem → px at default 16px base)
# ===========================================================================

const spacingScale* = {
  "0": "0", "0.5": "2", "1": "4", "1.5": "6", "2": "8", "2.5": "10",
  "3": "12", "3.5": "14", "4": "16", "5": "20", "6": "24", "7": "28",
  "8": "32", "9": "36", "10": "40", "11": "44", "12": "48",
  "14": "56", "16": "64", "20": "80", "24": "96",
  "28": "112", "32": "128", "36": "144", "40": "160",
  "44": "176", "48": "192", "52": "208", "56": "224",
  "60": "240", "64": "256", "72": "288", "80": "320", "96": "384",
  "px": "1", "full": "100%", "auto": "auto",
}.toTable

# ===========================================================================
# Font size scale
# ===========================================================================

const fontSizes* = {
  "xs": "12", "sm": "14", "base": "16", "lg": "18", "xl": "20",
  "2xl": "24", "3xl": "30", "4xl": "36", "5xl": "48", "6xl": "60",
  "7xl": "72", "8xl": "96", "9xl": "128",
}.toTable

# ===========================================================================
# Border radius scale
# ===========================================================================

const radiusScale* = {
  "none": "0", "sm": "2", "": "4", "md": "6", "lg": "8", "xl": "12",
  "2xl": "16", "3xl": "24", "full": "9999",
}.toTable

# ===========================================================================
# Opacity scale
# ===========================================================================

const opacityScale* = {
  "0": "0", "5": "0.05", "10": "0.1", "15": "0.15", "20": "0.2",
  "25": "0.25", "30": "0.3", "35": "0.35", "40": "0.4", "45": "0.45",
  "50": "0.5", "55": "0.55", "60": "0.6", "65": "0.65", "70": "0.7",
  "75": "0.75", "80": "0.8", "85": "0.85", "90": "0.9", "95": "0.95",
  "100": "1",
}.toTable

# ===========================================================================
# Core parser: Tailwind class → seq[(property, value)]
# ===========================================================================

proc lookupColor(name: string): string =
  if name in tailwindColors: tailwindColors[name]
  elif name.startsWith("#"): name  # raw hex passthrough
  else: ""

proc lookupSpacing(s: string): string =
  if s in spacingScale: spacingScale[s]
  elif s.allCharsInSet({'0'..'9', '.'}): s  # arbitrary numeric
  else: ""

proc parseTailwindClass*(cls: string): seq[tuple[prop, val: string]] =
  ## Parse a single Tailwind utility class into CSS property/value pairs.
  ## Returns empty seq for unrecognized classes.

  # --- Display ---
  case cls
  of "flex": return @[("display", "flex")]
  of "hidden": return @[("display", "none")]
  of "block": return @[("display", "flex")]  # flex on native
  of "inline": return @[("display", "flex")]
  else: discard

  # --- Flex direction ---
  case cls
  of "flex-row": return @[("flex-direction", "row")]
  of "flex-col": return @[("flex-direction", "column")]
  of "flex-row-reverse": return @[("flex-direction", "row-reverse")]
  of "flex-col-reverse": return @[("flex-direction", "column-reverse")]
  of "flex-wrap": return @[("flex-wrap", "wrap")]
  of "flex-nowrap": return @[("flex-wrap", "nowrap")]
  else: discard

  # --- Flex grow/shrink ---
  case cls
  of "flex-1": return @[("flex", "1")]
  of "flex-auto": return @[("flex-grow", "1"), ("flex-shrink", "1")]
  of "flex-none": return @[("flex-grow", "0"), ("flex-shrink", "0")]
  of "grow": return @[("flex-grow", "1")]
  of "grow-0": return @[("flex-grow", "0")]
  of "shrink": return @[("flex-shrink", "1")]
  of "shrink-0": return @[("flex-shrink", "0")]
  else: discard

  # --- Alignment ---
  case cls
  of "items-start": return @[("align-items", "flex-start")]
  of "items-center": return @[("align-items", "center")]
  of "items-end": return @[("align-items", "flex-end")]
  of "items-stretch": return @[("align-items", "stretch")]
  of "items-baseline": return @[("align-items", "baseline")]
  of "justify-start": return @[("justify-content", "flex-start")]
  of "justify-center": return @[("justify-content", "center")]
  of "justify-end": return @[("justify-content", "flex-end")]
  of "justify-between": return @[("justify-content", "space-between")]
  of "justify-around": return @[("justify-content", "space-around")]
  of "justify-evenly": return @[("justify-content", "space-evenly")]
  of "self-auto": return @[("align-self", "auto")]
  of "self-start": return @[("align-self", "flex-start")]
  of "self-center": return @[("align-self", "center")]
  of "self-end": return @[("align-self", "flex-end")]
  of "self-stretch": return @[("align-self", "stretch")]
  else: discard

  # --- Text alignment ---
  case cls
  of "text-left": return @[("text-align", "left")]
  of "text-center": return @[("text-align", "center")]
  of "text-right": return @[("text-align", "right")]
  of "text-justify": return @[("text-align", "justified")]
  else: discard

  # --- Font weight ---
  case cls
  of "font-thin": return @[("font-weight", "100")]
  of "font-light": return @[("font-weight", "300")]
  of "font-normal": return @[("font-weight", "normal")]
  of "font-medium": return @[("font-weight", "500")]
  of "font-semibold": return @[("font-weight", "600")]
  of "font-bold": return @[("font-weight", "bold")]
  of "font-extrabold": return @[("font-weight", "800")]
  of "font-black": return @[("font-weight", "900")]
  else: discard

  # --- Position ---
  case cls
  of "relative": return @[("position", "relative")]
  of "absolute": return @[("position", "absolute")]
  else: discard

  # --- Prefix-based utilities ---

  # Padding: p-*, px-*, py-*, pt-*, pr-*, pb-*, pl-*
  if cls.startsWith("p-"):
    let v = lookupSpacing(cls[2..^1])
    if v.len > 0: return @[("padding", v)]
  if cls.startsWith("px-"):
    let v = lookupSpacing(cls[3..^1])
    if v.len > 0: return @[("padding-left", v), ("padding-right", v)]
  if cls.startsWith("py-"):
    let v = lookupSpacing(cls[3..^1])
    if v.len > 0: return @[("padding-top", v), ("padding-bottom", v)]
  if cls.startsWith("pt-"):
    let v = lookupSpacing(cls[3..^1])
    if v.len > 0: return @[("padding-top", v)]
  if cls.startsWith("pr-"):
    let v = lookupSpacing(cls[3..^1])
    if v.len > 0: return @[("padding-right", v)]
  if cls.startsWith("pb-"):
    let v = lookupSpacing(cls[3..^1])
    if v.len > 0: return @[("padding-bottom", v)]
  if cls.startsWith("pl-"):
    let v = lookupSpacing(cls[3..^1])
    if v.len > 0: return @[("padding-left", v)]

  # Margin: m-*, mx-*, my-*, mt-*, etc.
  if cls.startsWith("m-"):
    let v = lookupSpacing(cls[2..^1])
    if v.len > 0: return @[("margin", v)]
  if cls.startsWith("mx-"):
    let v = lookupSpacing(cls[3..^1])
    if v.len > 0: return @[("margin-left", v), ("margin-right", v)]
  if cls.startsWith("my-"):
    let v = lookupSpacing(cls[3..^1])
    if v.len > 0: return @[("margin-top", v), ("margin-bottom", v)]
  if cls.startsWith("mt-"):
    let v = lookupSpacing(cls[3..^1])
    if v.len > 0: return @[("margin-top", v)]
  if cls.startsWith("mr-"):
    let v = lookupSpacing(cls[3..^1])
    if v.len > 0: return @[("margin-right", v)]
  if cls.startsWith("mb-"):
    let v = lookupSpacing(cls[3..^1])
    if v.len > 0: return @[("margin-bottom", v)]
  if cls.startsWith("ml-"):
    let v = lookupSpacing(cls[3..^1])
    if v.len > 0: return @[("margin-left", v)]

  # Gap
  if cls.startsWith("gap-"):
    let v = lookupSpacing(cls[4..^1])
    if v.len > 0: return @[("gap", v)]

  # Width/Height
  if cls.startsWith("w-"):
    let v = lookupSpacing(cls[2..^1])
    if v.len > 0: return @[("width", v)]
  if cls.startsWith("h-"):
    let v = lookupSpacing(cls[2..^1])
    if v.len > 0: return @[("height", v)]
  if cls.startsWith("min-w-"):
    let v = lookupSpacing(cls[6..^1])
    if v.len > 0: return @[("min-width", v)]
  if cls.startsWith("min-h-"):
    let v = lookupSpacing(cls[6..^1])
    if v.len > 0: return @[("min-height", v)]
  if cls.startsWith("max-w-"):
    let v = lookupSpacing(cls[6..^1])
    if v.len > 0: return @[("max-width", v)]
  if cls.startsWith("max-h-"):
    let v = lookupSpacing(cls[6..^1])
    if v.len > 0: return @[("max-height", v)]

  # Background color: bg-*
  if cls.startsWith("bg-"):
    let color = lookupColor(cls[3..^1])
    if color.len > 0: return @[("background-color", color)]

  # Text color: text-* (but not text-left/center/right/justify)
  if cls.startsWith("text-") and cls notin [
      "text-left", "text-center", "text-right", "text-justify"]:
    let suffix = cls[5..^1]
    # Check if it's a font size
    if suffix in fontSizes:
      return @[("font-size", fontSizes[suffix])]
    # Otherwise it's a color
    let color = lookupColor(suffix)
    if color.len > 0: return @[("color", color)]

  # Border color: border-*
  if cls == "border":
    return @[("border-width", "1")]
  if cls.startsWith("border-"):
    let suffix = cls[7..^1]
    # Check if it's a width
    if suffix in ["0", "2", "4", "8"]:
      return @[("border-width", suffix)]
    # Otherwise color
    let color = lookupColor(suffix)
    if color.len > 0: return @[("border-color", color)]

  # Border radius: rounded, rounded-*
  if cls == "rounded":
    return @[("border-radius", radiusScale[""])]
  if cls.startsWith("rounded-"):
    let suffix = cls[8..^1]
    if suffix in radiusScale:
      return @[("border-radius", radiusScale[suffix])]

  # Opacity
  if cls.startsWith("opacity-"):
    let suffix = cls[8..^1]
    if suffix in opacityScale:
      return @[("opacity", opacityScale[suffix])]

  # Unrecognized
  return @[]

proc expandTailwindClasses*(classStr: string): seq[tuple[prop, val: string]] =
  ## Parse a space-separated Tailwind class string and expand all utilities
  ## to CSS property/value pairs. Unrecognized classes are silently skipped.
  for cls in classStr.splitWhitespace():
    let styles = parseTailwindClass(cls)
    result.add(styles)

# ===========================================================================
# Compile-time API for the DSL macro
# ===========================================================================

proc expandTailwindClassesCompileTime*(classStr: string): seq[tuple[prop, val: string]]
    {.compileTime.} =
  ## Compile-time version for use inside macros.
  for cls in classStr.splitWhitespace():
    let styles = parseTailwindClass(cls)
    result.add(styles)
