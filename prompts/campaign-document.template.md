# Campaign Document Template

> This file is the template the **AI Assistant** writes a new
> campaign document from when a design campaign is launched. The
> Campaign Orchestrator reads the resulting document at the start
> of every turn — the YAML frontmatter is its operating contract,
> and the `## Current state` + `## History` sections are its
> working memory across turns.
>
> Save new campaign documents at
> `<project-repo>/campaigns/<campaignId>.md`.
>
> Commentary blocks below each section explain what goes there and
> who is responsible for maintaining it. **Delete the commentary
> when you copy the template into a real campaign doc** — the
> orchestrator parses the live file directly and doesn't need the
> meta-narrative.

---

```yaml
---
campaignId: <slug> # lowercase-kebab-case, unique per project
schemaVersion: 1 # bump when this frontmatter grammar changes
briefRefs: # one or more briefIds from briefs/*/*.md frontmatter
  - render.task-app
targetScore: 9.0 # per-cell target on the brief's overall score
scopeBackends: # subset of the brief's coversPreviews[*].backends
  - web
  - tui
  - gpui
  - freya
  - cocoa
  - android
  - ios
captureViewports: # optional override of the brief's captureViewports
  - { width: 1920, height: 1080, label: "wide" }
maxIterations: 30 # hard cap; the orchestrator escalates on hit
status: pending # pending | active | converged | escalated | stopped
startedAt: null # ISO 8601 UTC; orchestrator fills on first turn
finishedAt: null # ISO 8601 UTC; set on terminal status
iteration: 0 # bumped by the orchestrator each turn
reviewerPromptVersion: review-prompt@v3 # current reviewer prompt version
notesToOrchestrator: |
  # Optional. One free-form paragraph the orchestrator reads on every
  # turn alongside the brief. Use this to scope attention ("focus on
  # web first"), to fold in a hypothesis ("recurring stretched-aspect
  # is probably the resampler"), or to set non-default discipline
  # ("commit only after every two verified fixes, not after each").
---
```

> **Frontmatter ownership.** The AI Assistant authors the initial
> frontmatter. The Orchestrator owns `status`, `startedAt`,
> `finishedAt`, `iteration`, and `reviewerPromptVersion`
> thereafter. The user (via the Assistant's `campaign edit-doc`
> command) owns `briefRefs`, `targetScore`, `scopeBackends`,
> `captureViewports`, `maxIterations`, and `notesToOrchestrator`.
> The Orchestrator re-reads on every turn and respects edits.

---

# <Campaign title — short, human-readable>

> One sentence. "Converge render.task-app to 9.0/10 across all seven
> backends with focus on the android stretched-aspect regression."
> If the user can't summarise the campaign in one sentence, the
> scope is probably too broad — split it.

## Objectives

> Plain-language bullets. What the user wants out of this campaign.
> Three bullets max; this is not a project plan. Keep operational
> details out (those go in `## Scope` and the frontmatter).
>
> Example:
>
> - Get every cell of `render.task-app` to >= 9.0 overall.
> - Resolve the recurring `stretched-aspect` defect on android once
>   and for all (rooted in the launcher, not the CSS).
> - Tighten typography hierarchy on TUI so the active filter chip
>   reads as the IsoNim brand indigo, not as a desaturated blue.

- ...

## Scope

> What the campaign covers and what it deliberately does **not**
> cover. The frontmatter's `briefRefs` and `scopeBackends` are the
> authoritative machine-readable scope; this section is the
> human-readable supplement, especially for explicit non-goals.
>
> Example:
>
> - **In scope**: `render.task-app` cross-backend convergence
>   (7 backends), at the brief's `captureViewports` defaults.
> - **Out of scope**: `render.settings-app` (separate campaign);
>   `interaction.task-app` flows (separate brief, future
>   campaign); editor chrome polish on the sidebar (chrome
>   campaign is a separate brief kind).
> - **Out of scope decisions**: do not refactor the four-layer
>   architecture of `task_app/` during this campaign — the goal is
>   visual convergence within the existing structure, not a
>   layering rework.

- In scope: ...
- Out of scope: ...
- Out of scope decisions: ...

## Success criteria

> The numeric and qualitative gates that turn `status: active` into
> `status: converged`. The Orchestrator checks these every turn.
>
> Default success criteria (delete and customise if needed):

- Every preview × backend cell reaches `parsed_scores.overall.
score >= targetScore` in the most recent run.
- No `severity: blocker` defects remain in any preview's
  `parsed_scores.previews.<id>.defects[]`.
- No regression vs. the previous two consecutive rounds — i.e. no
  cell's score drops by more than 0.2 between consecutive runs
  without a new defect explaining the drop.

> Optional additional criteria (delete bullets that don't apply):

- All previously-recurring defect IDs (those that appeared in 3+
  rounds before this campaign) are absent for at least two
  consecutive rounds.
- The reviewer prompt version is unchanged for the final two
  rounds — i.e. convergence is not the result of late
  recalibration.

## Current state

> **Maintained by the Orchestrator.** At the start of every turn,
> the Orchestrator updates this section to reflect the latest
> review's outcome and the focus for the next dispatch. The user
> reads this to see "where are we right now". The user may also
> edit this section to inject a focus hint (see § _AI Assistant &
> Design Campaigns_ in `isonim-editor.md` for the protocol).
>
> Shape (replace with live values):

```
Iteration:        4 / 30
Last review:      run 0192f3a6-..., agent_reports row 0192f4b1-...
                  agentVersion: review-prompt@v3
                  capturedAt:   2026-05-19T11:32:04Z

Scores by cell (overall, weighted):
  Task App/Inbox:page#0@web      9.1  ✓ converged
  Task App/Inbox:page#0@tui      8.4  ⚠ below target (typography)
  Task App/Inbox:page#0@gpui     8.9  ⚠ below target by 0.1
  Task App/Inbox:page#0@freya    9.0  ✓ converged
  Task App/Inbox:page#0@cocoa    9.2  ✓ converged
  Task App/Inbox:page#0@android  6.0  ✗ blocker (stretched-aspect, recurring)
  Task App/Inbox:page#0@ios      8.3  ⚠ below target by 0.7

Open defects (blocker first):
  - stretched-aspect@android         (blocker; recurring round 2..4)
  - typography-muddy@tui             (warn; new this round)
  - alignment-drift-add-btn@ios      (warn; new this round)
  - gpui-chip-radius-flat@gpui       (nit; deferred)

Focus for next turn:
  ROOT-CAUSE INVESTIGATION on stretched-aspect@android.
  Hypothesis carried from injects: nearest-neighbour resample in
  isonim-android/src/host_loop.nim around the capture path.
  Investigation deliverable: deterministic reproducer + file:line
  evidence; DO NOT implement the fix in the investigation turn.
```

## History

> **Maintained by the Orchestrator.** Append-only, reverse-
> chronological (newest on top). One block per turn. Captures the
> durable narrative of the campaign — what was tried, what worked,
> what didn't, what the orchestrator learned.
>
> The Orchestrator also writes machine-readable
> `design_review.campaign_events` rows for the same actions; this
> section is the human-readable mirror.
>
> Shape per entry:

```
### Turn 4 — 2026-05-19T11:42:18Z

Decision:    D2 (recurring defect → investigation, not another fix)
Defect:      stretched-aspect@android (3rd consecutive occurrence)
Action:      Dispatched investigation sub-agent
Outcome:     Root cause confirmed: Bitmap.createScaledBitmap with
             filter=false in isonim-android/src/host_loop.nim:347.
             Deterministic reproducer: tests/test_android_capture_
             aspect.nim, currently failing.
Next turn:   Dispatch fix sub-agent against the confirmed root cause.

### Turn 3 — 2026-05-19T11:31:55Z

Decision:    D6 (new blocker; fix highest-priority)
Defect:      stretched-aspect@android (2nd consecutive — should have
             been D2, see correction below)
Action:      Dispatched fix sub-agent against
             isonim-examples/task_app/android/leaves.nim
Outcome:     Sub-agent edited the row container's class to
             aspect-square; re-capture still showed defect.
Commit:      none — fix not verified clean
Correction:  Orchestrator misclassified this turn — should have
             treated as D2 because the defect appeared in rounds 2
             and 3. Promoted to turn-4 investigation.

### Turn 2 — 2026-05-19T11:21:10Z
...
```

## Notes to the next campaign (optional)

> Filled in only when `status` transitions to `converged`,
> `escalated`, or `stopped`. Lessons that didn't make it into
> persistent memory but the next campaign on a related surface
> should know about.
>
> Example:
>
> - The android launcher's resampling path is now BILINEAR by
>   default (commit `abc123`). Any future campaign that touches
>   android capture should be aware: nearest-neighbour comes back
>   only if the flag at `host_loop.nim:347` is flipped.
> - The reviewer prompt was bumped from `v3` to `v4` on iteration
>   12 to require explicit per-Render-Quality-dimension annotation.
>   The bump made scores 0.3 stricter on average — recalibrate
>   expectations on campaigns inheriting the prompt.

---

> **End of template.** When the orchestrator parses this file, it
> stops at the last frontmatter-or-section boundary; trailing
> commentary like this paragraph is ignored. But to keep the file
> tidy, delete the meta-commentary blocks when copying the
> template into a real campaign doc.
