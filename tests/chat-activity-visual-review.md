# Chat sidebar review brief

Review full mounted editor screenshots from `test_editor_chat_activity_gui.mjs`.
Each named view is captured with sidebar widths 240 and 420 pixels at a
1440×900 viewport. The producer writes `results.json` beside the screenshots.
Every capture first verifies its required text is inside the transcript viewport,
after actual rendering and width layout settle. These are M4 design evidence; the complete event campaign is tracked in EAC-M7.

## Common mandatory elements

- The central website preview and its primary action remain usable.
- Conversation content wraps inside the sidebar with no page overflow.
- The multiline composer, send control, session status and close control remain
  reachable at the bottom. Sending is disabled during a running turn.
- Navigation approval preference is legible. Existing editor chrome remains
  aligned; tool details are secondary to message content.
- Text has readable contrast and spacing, and controls have visible focus.
- No credential values, account names or synthetic usage metrics are shown.

## Views and expected elements

| View | Mandatory visible content | Design checks |
| --- | --- | --- |
| empty | Design-system invitation, suggested prompts, empty composer | Inviting hierarchy; suggestions wrap without crowding preview |
| streaming | Human multiline turn, assistant heading/list/code, retained next draft | Distinct speakers; readable text and code; disabled send |
| tool-heavy | Compile story failure, expanded arguments and initial diagnostic output | Failure is obvious; arguments/output readable and wrapped; companion activity-details supplies diff/plan/model evidence |
| activity-details | Expanded source diff, plan steps and reported model with 120 input / 30 output tokens | Supported fields visibly disclosed at both widths; complementary to expanded tool output |
| waiting | Agent question “Which variant?” | Question stands out; no fabricated response action; expanded unavailable-action explanation visibly readable |
| error | Source build failure text and retained draft | Exactly one failure readable in viewport; retained draft and close recovery control visible |
| long-history | Review diagnostics and sub-agent result near latest output | Composer anchored; scrolling belongs to transcript, not page |

Review each view at both widths. Report concrete P1/P2 issues with screenshot
name, affected element and a suggested correction. Do not accept a broken layout
by treating the screenshot itself as its new baseline.
