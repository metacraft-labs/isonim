## Inline SVG icon constants used by the right-sidebar top tab bar.
##
## The three icons (wrench, robot, plus) were designed in
## ``docs/icon-design/`` and tuned at the canonical 18 px button-glyph
## size with 24 px and 48 px review passes. They use
## ``stroke="currentColor"`` / ``fill="currentColor"`` so the parent
## button's text color drives the rendered ink — that lets the tab bar
## switch the icon between muted-grey (inactive) and accent-on-text
## (active) by setting a single ``color`` style on the button.
##
## SVG bodies are kept verbatim from the design files; do not edit them
## here. To iterate on a glyph, edit the corresponding file in
## ``docs/icon-design/`` and re-paste the body below.

const
  wrenchSvg* = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="currentColor"><path d="M16.43 4.42a4.5 4.5 0 0 0-5.84 5.84L3.5 17.36a2 2 0 1 0 2.83 2.83l7.1-7.1a4.5 4.5 0 0 0 5.84-5.84l-2.46 2.46-2.83-2.83 2.45-2.46zM5.91 17.36l-.71.71.71-.71z"/></svg>"""

  robotSvg* = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v2.5"/><circle cx="12" cy="2.5" r="0.75" fill="currentColor" stroke="none"/><rect x="4.5" y="6" width="15" height="12" rx="2.5"/><circle cx="9" cy="12" r="1.25" fill="currentColor" stroke="none"/><circle cx="15" cy="12" r="1.25" fill="currentColor" stroke="none"/></svg>"""

  plusSvg* = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg>"""
