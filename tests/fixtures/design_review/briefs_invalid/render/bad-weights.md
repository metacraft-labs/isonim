---
briefId: render.bad-weights
schemaVersion: 1
kind: render
title: Bad scoring weights
coversPreviews:
  - storyRef: { group: "Task App", name: "Inbox", kind: page, index: 0 }
    backends: [web]
captureViewports:
  - { width: 1080, height: 720, label: "tablet" }
reviewerSchemaVersion: 1
scoringDimensions:
  - { id: a, label: "Alpha", weight: 0.4, scale: { min: 1, max: 10 } }
  - { id: b, label: "Beta",  weight: 0.55, scale: { min: 1, max: 10 } }
---

# Bad weights

Weights sum to 0.95, not 1.0.
