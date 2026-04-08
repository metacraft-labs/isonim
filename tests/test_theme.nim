## Tests for the cross-platform theming system.

import unittest
import isonim/theming/theme

suite "Theme - Native mode":
  setup:
    setTheme(nativeTheme())
    setDarkMode(false)

  test "nativeTheme returns tmNative mode":
    check activeTheme.mode == tmNative

  test "themeColor returns empty string in native mode":
    check themeColor("primary") == ""
    check themeColor("background") == ""

  test "themeSpacing returns -1 in native mode":
    check themeSpacing("md") == -1

  test "themeRadius returns -1 in native mode":
    check themeRadius("lg") == -1

suite "Theme - Branded mode (isoTheme)":
  setup:
    setTheme(isoTheme())
    setDarkMode(false)

  test "themeColor primary returns light color":
    check themeColor("primary") == "#6366F1"

  test "themeColor secondary returns light color":
    check themeColor("secondary") == "#8B5CF6"

  test "themeColor background returns light color":
    check themeColor("background") == "#F8FAFC"

  test "themeColor unknown returns empty string":
    check themeColor("nonexistent") == ""

  test "spacing lookup md":
    check themeSpacing("md") == 16

  test "spacing lookup xs":
    check themeSpacing("xs") == 4

  test "spacing lookup xxl":
    check themeSpacing("xxl") == 48

  test "spacing unknown returns -1":
    check themeSpacing("nonexistent") == -1

  test "radius lookup lg":
    check themeRadius("lg") == 12

  test "radius lookup full":
    check themeRadius("full") == 9999

  test "radius unknown returns -1":
    check themeRadius("nonexistent") == -1

  test "typography body":
    let body = themeTypography("body")
    check body.size == 17
    check body.weight == "normal"

  test "typography headline":
    let hl = themeTypography("headline")
    check hl.size == 22
    check hl.weight == "semibold"

  test "typography large-title alias":
    let lt = themeTypography("large-title")
    check lt.size == 34

suite "Theme - Dark mode":
  setup:
    setTheme(isoTheme())
    setDarkMode(true)

  teardown:
    setDarkMode(false)

  test "dark mode primary returns dark color":
    check themeColor("primary") == "#818CF8"

  test "dark mode background returns dark color":
    check themeColor("background") == "#0F172A"

  test "dark mode on-primary":
    check themeColor("on-primary") == "#FFFFFF"

  test "resolveColor picks dark":
    let token = color("#AAAAAA", "#BBBBBB")
    check resolveColor(token) == "#BBBBBB"

suite "Theme - Warm theme":
  setup:
    setTheme(warmTheme())
    setDarkMode(false)

  test "warmTheme has different primary than isoTheme":
    check themeColor("primary") == "#F59E0B"
    check themeColor("primary") != "#6366F1"

  test "warmTheme accent":
    check themeColor("accent") == "#10B981"

suite "Theme - Reset to native":
  test "reset to native clears overrides":
    setTheme(isoTheme())
    setDarkMode(false)
    check themeColor("primary") == "#6366F1"
    setTheme(nativeTheme())
    check themeColor("primary") == ""
    check themeSpacing("md") == -1
    check themeRadius("lg") == -1

suite "Theme - Color token helper":
  test "color with single hex uses same for light and dark":
    let c = color("#FF0000")
    check c.light == "#FF0000"
    check c.dark == "#FF0000"

  test "color with two hex values":
    let c = color("#AAAAAA", "#BBBBBB")
    check c.light == "#AAAAAA"
    check c.dark == "#BBBBBB"
