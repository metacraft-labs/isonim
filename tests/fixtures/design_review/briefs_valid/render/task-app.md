---
briefId: render.task-app
schemaVersion: 1
kind: render
title: Task App — cross-backend visual review
coversPreviews:
  - storyRef: { group: "Task App", name: "Inbox", kind: page, index: 0 }
    backends: [web, tui, gpui, freya, cocoa, android, ios]
  - storyRef: { group: "Task App", name: "Completed", kind: page, index: 0 }
    backends: [web, tui, gpui]
captureViewports:
  - { width: 1080, height: 720, label: "tablet" }
reviewerSchemaVersion: 1
scoringDimensions:
  - { id: chrome,    label: "Editor Chrome", weight: 0.4, scale: { min: 1, max: 10 } }
  - { id: rendering, label: "App Rendering", weight: 0.6, scale: { min: 1, max: 10 } }
relatedBriefs: [render.settings-app]
---

# Task App — cross-backend visual review

## What you're reviewing

The Task App preview rendered through every supported backend. Score the
rendering quality, the editor chrome, and how well the demo matches the
shared ViewModel.
