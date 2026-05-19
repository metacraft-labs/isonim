---
reviewerSchemaVersion: 1
briefId: render.settings-app
runId: 00000000-0000-0000-0000-000000000000
agentName: canned
agentVersion: rev-m10-acceptance
manifestHash: 0000000000000000000000000000000000000000000000000000000000000000
capturedAt: 2026-05-19T12:00:00Z
overall:
  score: 7.6
  status: pass
previews:
  "Settings App %2F Pages/Preferences:page#0@web":
    scores: { chrome: 8, rendering: 8 }
    status: pass
    defects: []
  "Settings App %2F Pages/Preferences:page#0@tui":
    scores: { chrome: 8, rendering: 7 }
    status: pass
    defects: []
  "Settings App %2F Pages/Preferences:page#0@gpui":
    scores: { chrome: 8, rendering: 7 }
    status: pass
    defects: []
  "Settings App %2F Pages/Preferences:page#0@freya":
    scores: { chrome: 8, rendering: 7 }
    status: pass
    defects: []
  "Settings App %2F Pages/Preferences:page#0@cocoa":
    scores: { chrome: 8, rendering: 8 }
    status: pass
    defects: []
  "Settings App %2F Pages/Preferences:page#0@android":
    scores: { chrome: 8, rendering: 7 }
    status: pass
    defects: []
  "Settings App %2F Pages/Preferences:page#0@ios":
    scores: { chrome: 8, rendering: 8 }
    status: pass
    defects: []
notes: |
  REV-M10 acceptance run — canned reviewer output covering all 7
  backends declared by the migrated render.settings-app brief.
---

# Settings App — Acceptance Run Notes

Canned reviewer output produced by REV-M10's acceptance gate. The
real per-backend reviewer is run via `agentBackend: claudeCode` in
follow-up work; this file exists so the pipeline's
`run-review` path can be exercised end-to-end without depending on
a live LLM.
