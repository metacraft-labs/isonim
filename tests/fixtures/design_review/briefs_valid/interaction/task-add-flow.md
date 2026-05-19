---
briefId: interaction.task-add-flow
schemaVersion: 1
kind: interaction
title: Task App — add-task interaction
coversPreviews:
  - storyRef: { group: "Task App", name: "Add Flow", kind: flow, index: 0 }
    backends: [web, tui]
captureViewports:
  - { width: 1080, height: 720, label: "tablet" }
reviewerSchemaVersion: 1
scoringDimensions:
  - { id: clarity,    label: "Action Clarity",   weight: 0.3, scale: { min: 1, max: 10 } }
  - { id: feedback,   label: "Visual Feedback",  weight: 0.4, scale: { min: 1, max: 10 } }
  - { id: keyboardAx, label: "Keyboard Access",  weight: 0.3, scale: { min: 1, max: 10 } }
---

# Task App — add-task interaction

Review the multi-step flow that goes from clicking "New Task" to seeing
the newly created entry in the list. Score clarity, feedback, and
keyboard accessibility independently.
