---
briefId: render.mismatched-kind
schemaVersion: 1
kind: interaction
title: Brief in render/ directory but says kind=interaction
coversPreviews:
  - storyRef: { group: "Task App", name: "Inbox", kind: page, index: 0 }
    backends: [web]
captureViewports:
  - { width: 1080, height: 720, label: "tablet" }
reviewerSchemaVersion: 1
scoringDimensions:
  - { id: chrome, label: "Editor Chrome", weight: 1.0, scale: { min: 1, max: 10 } }
---

# Mismatched kind

This brief lives under `render/` but declares `kind: interaction`.
