# Chat activity coverage boundaries

Authority: Agent Harbor `b40f6090`, public REST `SessionEvent` in
`crates/ah-rest-api-contract/src/types.rs` (34 variants). The domain enum differs.
All49 public frames are validated against the actual production Rust SessionEvent serde, with missing-required and invalid-enum controls. Synthetic public DTOs go through the real parser → nim-agents safe projection →
wire codec → shared reducer → full mounted production editor. This boundary
coverage does not emulate a server and does not prove infrastructure execution.
Official scenario integration remains `test-editor-scenarios-native`, stress and
GUI over real Harbor REST and its Rust mock-agent (persistent sessions, source,
compiler, mounted preview, CLI navigation/approval and close/reap).

| Public discriminator          | Named view                            | Deterministic boundary                         | Official REST scenario                                       |
| ----------------------------- | ------------------------------------- | ---------------------------------------------- | ------------------------------------------------------------ |
| agent_question                | question                              | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| anti_halting_resume_confirmed | recovery                              | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| context_files                 | model-context                         | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| context_injection             | model-context                         | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| delegation                    | delegation                            | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| diff                          | files                                 | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| dispatcher_restarted          | recovery                              | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| error                         | error                                 | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| file_edit                     | files                                 | Full typed projection + mounted production GUI | Existing persistent authoring scenario                       |
| file_read                     | files                                 | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| fleet_fence                   | workspace                             | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| fleet_host                    | workspace                             | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| link_spans                    | participants                          | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| llm_request                   | model-context                         | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| log                           | conversation, long-content, completed | Full typed projection + mounted production GUI | Existing persistent authoring scenario                       |
| login_required                | login                                 | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| orchestration                 | delegation                            | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| participant                   | participants                          | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| plan                          | plan                                  | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| proxy_credential_rotated      | recovery                              | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| proxy_rate_limit_absorbed     | recovery                              | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| session_awaiting_input        | lifecycle, question, login            | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| session_ended                 | lifecycle                             | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| session_leadership_migrated   | recovery                              | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| session_resumed               | lifecycle                             | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| session_started               | lifecycle                             | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| status                        | error                                 | Full typed projection + mounted production GUI | Existing persistent authoring scenario                       |
| sub_agent                     | delegation                            | Full typed projection + mounted production GUI | DTO boundary only; no official infrastructure emission claim |
| thought                       | conversation, completed               | Full typed projection + mounted production GUI | Existing persistent authoring scenario                       |
| tool_result                   | tools                                 | Full typed projection + mounted production GUI | Existing persistent authoring scenario                       |
| tool_use                      | tools, long-content                   | Full typed projection + mounted production GUI | Existing persistent authoring scenario                       |
| turn_complete                 | plan, completed                       | Full typed projection + mounted production GUI | Existing persistent authoring scenario                       |
| user_input                    | conversation                          | Full typed projection + mounted production GUI | Existing persistent authoring scenario                       |
| workspace                     | workspace                             | Full typed projection + mounted production GUI | Existing persistent authoring scenario                       |

## Existing behavioral integration retained

Actual first-send suggestion removal, rejected-send draft preservation, tab
separation, streaming selection/scrollback, cancel availability, CLI/RPC
navigation, approval/rejection/stale targets, source/preview focus and highlight
remain in the original headless and full GUI suites. They are not replaced by
these visual fixtures. The named wide/narrow companions below retain the same
production boundaries; their independent acceptance is recorded separately.
These captures remain deterministic VM/DOM boundary evidence; original genuine
REST and control GUI suites remain independently mandatory.

## Question delivery investigation

At Harbor `b40f60901a2a438b24ff1df4c7d74b4320c425ab`, the normal editor
REST session uses `agent.acp_stdio_launch_command`. The actual launch chain is:

- `ah-rest-server/src/executor.rs:3214–3248` forwards structured events from
  the inner ACP launcher and passes `--acp-agent-cmd`.
- `ah-tui/src/acp_client.rs:2744–2779` creates `TuiAcpSession`.
- `ah-agents/src/tui_session.rs:269–274` wraps `AcpAgentSession`.
- `ah-agents/src/acp_session.rs:2935–2998` handles ACP permissions directly,
  selecting an offered allow option. Qwen question requests choose the first
  label (`2228–2294`); Grok custom questions also auto-answer (`3000–3058`).
- `ah-rest-server/src/handlers/running_agent.rs:220–245,314–343` only records
  non-prompt input/permission envelopes and returns `accepted:true`; it does not
  invoke the provider's pending request handler. An HTTP acknowledgment cannot
  prove park, selected-answer delivery, or resume.

`Session::await_question`/`Session::deliver` exist for native PTY paths. The
separate `RestAcpClient` blocking registry and durable asynchronous feedback
have different controllers and semantics. Neither proves correlated question
answering on this ACP editor route. `AgentQuestion` scenario notifications are
not a held RPC. No transport migration, answer API, busy-state bypass or Harbor
source repair is introduced by this campaign. All four public question modes
(free_form, single_choice, multi_choice, confirmation) retain actual prompt,
request, mode and offered choice labels, with plain unavailable-answer copy and
no fabricated actions. Generic busy-prompt rejection remains intact. Native
park/answer/resume is not claimed as supported or tested by these captures.

Public REST tool status is started/completed/failed. Companion tool-waiting and
tool-running views use normalized common AgentEvent data (not public REST DTOs).
Their production codec/reducer/rendering boundary is explicit. The thought-settled
view verifies genuine typed completion settles an earlier streamed thought.

### Contract and visible-frame evidence

The fixture is exported by actual b40 `SessionEvent` deserialize/serialize; every supplied field must survive the roundtrip identically, with required-field and enum negative controls. Separate injected unknown/private fields test safe editor projection and are not producer fixture data. Per-event captures assert their card heading lies inside the actual conversation viewport. The event-log-bottom companion exposes the end of the long code block; grouped views may need their named event-\* companions to inspect earlier cards.

## Behavioral scene matrix

All companions run the production mounted editor. Request injection replaces
external transport timing and explicitly owns the local host connection state.
Native/executed-JS and mounted negative controls prove disconnected approval is
rejected before any application. Shared command validation, revision checks, approval
resolution, DOM focus/highlight/selection and chat reducer remain real. Source
authoring/compiler/CLI/REST execution remains in the original official suites.

| Views (wide and narrow)                                                      | Production boundary                                                                                                              | Original integration coverage                                                                   |
| ---------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| navigation-pending / approved / rejected / stale / auto                      | Shared admission, actual preference checkbox and approval buttons, real story selection; stale approval after a changed viewport | Native control plus genuine REST scenario/control GUI                                           |
| focus-auto / selection-highlight-auto / highlight-auto                       | Installed DOM focus/selection/highlight adapters, real preview document and inspector IDs                                        | Genuine control GUI and official scenario GUI                                                   |
| chat-first-send / send-failed / draft-streaming                              | Actual composer send, rejected admission, suggestion dismissal, retained draft, active-turn send guard                           | Native/executed-JS chat and original mounted GUI                                                |
| chat-independent-first / second                                              | Actual new-chat/switch commands, independent drafts/transcripts and placeholder state                                            | Original mounted GUI and official scenario GUI                                                  |
| chat-scroll-back / latest / selection-streaming                              | Actual scroll handler/latest button and browser Range selection across production streamed updates                               | Original mounted GUI                                                                            |
| question-free-form / multi-choice / confirmation and question(single-choice) | Valid public DTO → safe projection → codec → reducer → real view; no unavailable response controls                               | Native/executed-JS all-mode assertion plus mounted capture; no park/resume infrastructure claim |

The grouped recovery scene has a required recovery-top companion at both widths. Both views reuse the same five original events. The top frame demonstrates Provider access recovered and provider throttling; the original latest-activity frame retains restart, idle recovery and executor migration. The full inventory preserves all original 146 keys and adds these two full-frame keys (148 total). Both views use the same preview, published-scene, frame and composer guards; actual visible heading/fact bounds are recorded and checked.

The grouped long-content scene also requires a long-content-top full-frame companion at both widths, using the same original log/tool DTO list and real top scrolling. Assistant and the entire wrapped six-repeat identifier are visible at the top; the original latest-activity frame retains final Nim code and isonim inspect started. The exact inventory retains the original 148 keys including recovery-top and adds these two (150 total). Normal preview, published-scene, advancing-frame, composer and PNG/hash guards remain mandatory.

The additive expanded-code scene uses the unchanged original long-content log/tool DTOs. Real Enter/Space/click open the production native dialog; Close/Escape return to its source button. The independent full-text/language/viewport/larger-area oracle binds all twelve ordered literal code lines to their nonempty visible DOM ranges and rejects duplicated/omitted line evidence, and rejects an actually removed source Expand control and changed expanded text before restoring each. Both new full frames explicitly show the modal reading state and intentional background occlusion; the original 150 views and their preview/composer expectations remain required.

The additive tool-code-details scene uses the independently authored shared code-reading public tool_use/tool_result DTOs through the actual safe projection/reducer. Full Details is genuinely opened and scrolled to its output tail; complete Nim tail and second sh fence, associated ordinal/language control and its real keyboard reader/return are guarded. Actual removal of the Details control is rejected by the same capture guard and restored exactly at both widths. The existing 152 keys, original DTOs/behavior events/thresholds/deadlines remain unchanged; this view adds only two full frames (154 total). The new fixture SHA is separately bound in current lineage.
