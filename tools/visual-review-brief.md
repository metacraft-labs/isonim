# Visual Review Brief — IsoNim Editor

## What You're Reviewing

The IsoNim Editor is an AI-powered visual component editor, combining:
- **Storybook-like** component browser (sidebar with story hierarchy)
- **Figma-like** inspector panel (properties, styles, layout)
- **AI agent chat** for natural-language component editing

It is built with IsoNim itself (dogfooding the framework).

## Design Goals

- **Dark theme** — professional tool aesthetic similar to VS Code, Figma, or Storybook dark mode
- **Three-panel layout** — left sidebar (story browser), center preview pane, right inspector panel
- Panels should feel balanced — no panel should visually dominate unless contextually appropriate
- Clean, minimal chrome — content should breathe, not feel cramped
- Consistent spacing rhythm (multiples of 4px or 8px)
- Clear typography hierarchy: headings > labels > body > metadata
- Subtle borders/dividers between panels — not heavy lines

## Color Expectations

- Background: dark grays (#1a1a2e range for main, slightly lighter for panels)
- Text: white/light gray for primary, muted gray for secondary
- Accent: a single vibrant accent color for selected states, active tabs, interactive elements
- Hover/focus states should be visible but subtle

## What to Evaluate

For each screenshot, assess and report on:

1. **Alignment** — Are elements properly aligned? Consistent left edges, centered content, grid adherence?
2. **Spacing** — Consistent padding/margins? Nothing too cramped or too loose?
3. **Color harmony** — Does the palette feel cohesive? Any jarring colors?
4. **Typography** — Clear hierarchy? Readable sizes? Consistent font weights?
5. **Visual weight** — Is the layout balanced? Does the eye flow naturally?
6. **Professional polish** — Does it look like a shipping product or a prototype? What's the gap?
7. **Responsive behavior** (if multiple sizes) — Do panels collapse/adapt sensibly at smaller viewports?

## How to Report

- Keep your report under 200 words
- Lead with overall impression (1 sentence)
- List specific issues as bullet points with location (e.g., "sidebar header: 24px gap above title feels excessive")
- End with 1-2 highest-priority fixes
- Be direct and specific — "the inspector tabs look cramped" is better than "spacing could be improved"
