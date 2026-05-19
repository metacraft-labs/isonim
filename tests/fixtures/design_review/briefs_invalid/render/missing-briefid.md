---
schemaVersion: 1
kind: render
title: No briefId here
coversPreviews:
  - storyRef: { group: "Task App", name: "Inbox", kind: page, index: 0 }
    backends: [web]
captureViewports:
  - { width: 1080, height: 720, label: "tablet" }
reviewerSchemaVersion: 1
scoringDimensions:
  - { id: chrome, label: "Editor Chrome", weight: 1.0, scale: { min: 1, max: 10 } }
---

# Missing briefId

This brief is missing the required `briefId` field.
