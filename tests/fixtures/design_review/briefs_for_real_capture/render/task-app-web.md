---
briefId: render.task-app-web
schemaVersion: 1
kind: render
title: Task App — web backend only (real-launcher capture)
coversPreviews:
  - storyRef: { group: "Task App", name: "Inbox", kind: page, index: 0 }
    backends: [web]
captureViewports:
  - { width: 800, height: 600, label: "default" }
reviewerSchemaVersion: 1
scoringDimensions:
  - { id: rendering, label: "App Rendering", weight: 1.0, scale: { min: 1, max: 10 } }
---

# Task App — web backend only

Minimal single-backend brief used by the REV-M5 follow-up
end-to-end test (`e2e_design_review_capture_web_real_bridge.nim`).
The test spawns the real `isonim-examples-web` launcher binary and
asserts that the captured PNG is a non-trivial RGBA image — not the
flat fallback gradient.
