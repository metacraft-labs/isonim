# Chat sidebar visual review brief

IsoNim is a website authoring editor. Review the actual compiled production chat
sidebar beside its website preview. Dark surfaces, compact semantic cards and
quiet metadata should leave the assistant response and requests easy to read.
Use CodeTracer agent activity and Harbor activity as semantic references.

## Required verification before aesthetics

Every full view has a story browser, visible Website preview, Assistant sidebar,
conversation controls and an anchored multiline Agent prompt composer. Wide is
1440×900 with a 420px sidebar; narrow is 1024×768 (production responsive rules
may constrain the configured 240px sidebar). Verify the specific elements below
before judging spacing, alignment, typography, semantic colors and readability.
A missing expected element is the first finding and a rating of at most 4/10.
Scroll content may exceed the viewport: inspect the DOM manifest and companion
captures rather than claiming clipped content is visually demonstrated.

## Canary scope

Only the complete actual production conversation scroll surface is captured for
conversation and plan at both sizes. It covers prose/code/thought versus plan
state rows. No pixels are masked and no content is hidden. Editor chrome,
composer and preview are outside this deliberately small determinism canary;
full-editor captures retain those surfaces and focus checks. Original full-frame
canary failures remain preserved and do not establish full-frame determinism.

## Expected elements per view

### View: empty

- Assistant introduction and suggested prompts
- No fabricated transcript entries
- Empty multiline composer and visible website preview

### View: conversation

- Distinct user request and assistant heading Hero refreshed
- List of rebuilt preview and retained primary action
- Visible Nim code and thinking card; composer focus retained

### View: tools

- Started create and build cards, successful capture and failed build cards. The REST tool enum exposes started/completed/failed; normalized common-interface waiting/running states have their own companion views.
- Failed compiler output distinct from assistant response
- Arguments expandable without pushing composer out of view

### View: plan

- Plan rows: completed Inspect the current hero, in progress Create the spacious variant, pending Check tablet layout
- Tool phase complete with actual token counts; it does not settle an active provider

### View: files

- File change stories/hero.nim and +4 / −2 lines
- File read theme/spacing.nim lines 8–20
- Before and After sections preserve both diff lines

### View: model-context

- Model Sonnet, 1260 input and 180 output tokens with provider_reported usage source
- Two named context files and total count 2
- Attributed authoring context

### View: workspace

- Workspace /workspace/website and local working copy
- Completed synchronization preview-sync with duration 240ms
- Host build completion and exit code 0

### View: delegation

- Layout-review sub-agent and its readable thought
- Delegation active/total 0/1
- Review requested for layout-review

### View: lifecycle

- Session start, waiting request question-hero, human resume and completed end
- Lifecycle labels remain separate from assistant text

### View: recovery

- Original latest-activity scroll position retains Agent restarted (Restart 2), Agent progress resumed (idle), and Session moved to another executor: authoring-host to preview-host, linux, flushed sequence 40.
- Provider throttling recovered, two retries and 1200ms waiting are mandatory in recovery-top at the same width.
- The first Provider access recovered heading/card is mandatory in recovery-top at the same width. Review both full frames; the first heading can be above this bottom viewport.

### View: recovery-top

- Top companion of recovery: the same five original events, real conversation scrollTop 0.
- Visible Provider access recovered heading, anthropic and Provider status 401.
- Visible Provider throttling recovered, Retry attempts 2 and Wait (ms) 1200.
- The paired recovery frame retains the later restart, idle recovery and executor migration evidence. Both wide/narrow pairs are required; no claim that all five cards fit in one frame.

### View: question

- Question Which hero spacing should I use?
- Comfortable and Compact options as readable choices, request question-hero
- This editor cannot answer this request.; no fake answer buttons

### View: login

- Provider login required and named provider/request
- Supported provider sign-in surface explanation; no credential contents or fake login link

### View: participants

- Website author joined as a human participant
- Source references show stories/hero.nim; no fake source-opening action

### View: error

- Visible error Build failed
- Last successful preview remains available
- Error is separate from assistant text

### View: long-content

- Original latest-activity frame: final Nim line `setStyle(hero, "padding", "32px") # line 11` and isonim inspect started are visible.
- The paired long-content-top frame demonstrates the Assistant heading and entire wrapped long identifier. Both full-frame width pairs are mandatory; the original narrow frame does not claim offscreen prose is visible.
- Multiline Nim code remains readable and expandable; no horizontal page overflow or leaked PRIVATE_CAMPAIGN_SECRET.

### View: long-content-top

- Same original log/tool events as long-content, genuine conversation scrollTop 0.
- Visible Assistant heading and Long source identifiers remain readable:.
- The full responsiveHeroWithSharedSpacingAndAccessiblePrimaryAction identifier repeated six times wraps across multiple lines, all visibly inside the conversation viewport.
- The paired original long-content frame retains final code and tool evidence. No claim that the entire long response fits in one frame.

### View: completed

- Assistant result and settled thought
- Actual terminal end_turn and usage counts
- Composer remains anchored and focused

### View: event-user_input

- The admitted You message Improve the hero spacing. appears exactly once; the typed acknowledgement adds no second card.

### View: event-log

- In the conversation area below the user request, a card headed Assistant.
- Long source identifiers remain readable: begins the wrapped prose. The Nim code continues below the visible frame; inspect event-log-bottom for its final lines.

### View: event-thought

- In the conversation area below the user request, a card headed Thinking.
- Verified the mounted preview. under Thinking; streaming state until genuine terminal event.

### View: event-tool_use

- In the conversation area below the user request, a card headed isonim inspect.
- Started status on isonim inspect; expandable sanitized arguments; private token never appears.

### View: event-tool_result

- In the conversation area below the user request, a card headed isonim build.
- Failed status on isonim build; visible stories/hero.nim:42 compiler diagnostic and Exit code 1.

### View: event-plan

- In the conversation area below the user request, a card headed Plan.
- Three rows under Plan: completed Inspect the current hero; in progress Create the spacious variant; pending Check tablet layout.

### View: event-turn_complete

- In the conversation area below the user request, a card headed Turn complete.
- Stop reason end_turn; Input tokens 1260; Output tokens 180.

### View: event-file_edit

- In the conversation area below the user request, a card headed File change · stories/hero.nim.
- File stories/hero.nim, Changes +4 / −2 lines, and Use shared spacing and preserve the title.

### View: event-file_read

- In the conversation area below the user request, a card headed File read.
- File theme/spacing.nim, From line 8, To line 20.

### View: event-diff

- In the conversation area below the user request, a card headed Diff · stories/hero.nim.
- File stories/hero.nim with labeled Before and After values on separate lines; 16px/8px before, 32px/16px after.

### View: event-llm_request

- In the conversation area below the user request, a card headed Model request.
- Under Model request: Model Sonnet; Input tokens 1260; Output tokens 180; Usage source provider_reported; Messages 6; Tool calls true.

### View: event-context_files

- In the conversation area below the user request, a card headed Context files.
- Event added and Files in context 2 with separate File rows for stories/hero.nim and theme/spacing.nim.

### View: event-context_injection

- In the conversation area below the user request, a card headed Session context.
- Tag attribution with Website author requested a spacious hero.

### View: event-workspace

- In the conversation area below the user request, a card headed Workspace ready.
- Workspace /workspace/website and Working copy local.

### View: event-fleet_fence

- In the conversation area below the user request, a card headed Workspace synchronization.
- Event fence_complete; Synchronization preview-sync; Duration (ms) 240.

### View: event-fleet_host

- In the conversation area below the user request, a card headed Host execution.
- Event host_complete; Host preview-host; Os linux; Command isonim build; Exit code 0; Stream stdout; compiled preview output.

### View: event-sub_agent

- In the conversation area below the user request, a card headed Sub-agent.
- Agent layout-review; Parent session website-session; Event thought; Checking the tablet hero layout.

### View: event-delegation

- In the conversation area below the user request, a card headed Delegation.
- Event completed; Active agents 0; Total agents 1; Layout review completed.

### View: event-orchestration

- In the conversation area below the user request, a card headed Orchestration.
- Event review_requested; Target session layout-review; Review the selected hero story.

### View: event-session_started

- In the conversation area below the user request, a card headed Session started.
- The explicit Session started lifecycle heading; no invented model usage or process details.

### View: event-session_awaiting_input

- In the conversation area below the user request, a card headed Waiting for input.
- Request login-provider under Waiting for input, followed by the visible notice “Waiting for input. This editor cannot respond to this request.” outside closed Details. No response control is offered.

### View: event-session_resumed

- In the conversation area below the user request, a card headed Session resumed.
- Deliverer human below the Session resumed heading.

### View: event-session_ended

- In the conversation area below the user request, a card headed Session ended.
- Outcome completed below the Session ended heading.

### View: event-proxy_credential_rotated

- In the conversation area below the user request, a card headed Provider access recovered.
- Provider anthropic and Provider status 401; account identity/private marker must be absent.

### View: event-proxy_rate_limit_absorbed

- In the conversation area below the user request, a card headed Provider throttling recovered.
- Retry attempts 2 and Wait (ms) 1200.

### View: event-dispatcher_restarted

- In the conversation area below the user request, a card headed Agent restarted.
- Restart 2.

### View: event-anti_halting_resume_confirmed

- In the conversation area below the user request, a card headed Agent progress resumed.
- Recovered stall idle.

### View: event-session_leadership_migrated

- In the conversation area below the user request, a card headed Session moved to another executor.
- Previous executor authoring-host; Current executor preview-host; Operating system linux; Flushed sequence 40.

### View: event-agent_question

- In the conversation area below the user request, a card headed Agent question.
- Question Which hero spacing should I use? followed by request question-hero and choices Comfortable and Compact.
- Question answering is explicitly unavailable in this candidate; no fake answer buttons.

### View: event-login_required

- In the conversation area below the user request, a card headed Provider login required.
- Provider anthropic and Request login-provider; an explanation of the supported provider sign-in surface, without a fabricated link.

### View: event-participant

- In the conversation area below the user request, a card headed Participant activity.
- Participant Website author; Event owner; Presence joined.

### View: event-link_spans

- In the conversation area below the user request, a card headed Source references.
- File stories/hero.nim under Source references; no unsupported open-file button.

### View: event-status

- In the conversation area below the user request, a card headed Session with running status.
- The running connection transition has no invented assistant prose or provider usage.

### View: event-error

- In the conversation area below the user request, a card headed Error.
- Build failed. The last successful preview is still available. as error text.

### View: tool-waiting

- Below the user request, a tool card isonim build with pending badge.
- Arguments show story Hero when expanded. This is normalized common-interface state coverage, not a Rust public REST pending enum.

### View: tool-running

- Below the user request, a tool card isonim build with running badge.
- Composer remains focused and anchored. This is normalized common-interface state coverage, not a Rust public REST running enum.

### View: thought-settled

- Thinking card Verified the compiled hero preview. with completed badge after actual typed completion.
- No unsettled streaming label remains on that thought.

## Review protocol

Report under 250 words: `Expected elements: present / missing ...`; then precise
findings with view/size/location, severity P1/P2/P3, evidence and proposed fix.
Assess contrast, focus, overflow, grouping, compactness, readable file/diff/model
information and truthful actions. An adversarial pass should try long data,
failed/waiting states and narrow layouts. Ratings summarize findings; they do
not replace zero unresolved P1/P2 and the final human quality review.

First baseline is a candidate awaiting human acceptance. Never automatically
approve images or ratchet thresholds. Complete typed DTO presentation coverage
is not a claim that the official Rust mock produces every infrastructure event.

## Visible frame and long transcript companion

Per-event views scroll to the top and assert the actual card heading lies inside the conversation viewport. Long content can continue below that viewport; event-log-bottom scrolls the same actual assistant card to its bottom to expose the final fenced code. Review both captures at each width. Grouped views can contain earlier cards above the viewport; their event-* companions show each event individually.

### event-log-bottom

- Final fenced Nim code is visible in the conversation viewport.
- The heading may be above the viewport; event-log provides its companion top view.
- Focused composer and usable website preview remain in the full editor frame.

## Reproducible artifacts and acceptance records

`just test-editor-chat-visual OUTPUT` builds through the existing owning entries,
then runs the pinned canaries, full captures and tooling guard tests. The driver
writes `OUTPUT/corpus/review.html`, `findings-ledger.json`,
`perceptual-gates.json` and the expected-elements detection control. The gallery
uses `chat-visual-expected.json`; it contains safe scripted UI fixtures only.
Independent screenshot detection of the control remains a separate review gate.

For a compatible targeted update, run `python3 tools/chat-visual-campaign.py
--output OUTPUT --view VIEW --size SIZE`. It requires a complete current corpus
and preserves untouched entries and keyed findings. Changed capture source,
assets, scene definitions or runtime require full regeneration. Full regeneration
cleans stale owned review outputs, archives the prior ledger and invalidates prior
review status; it does not discard recorded findings.

The comparator validates the full required inventory and PNG/runtime lineage
before comparison. Without `--baseline`, it writes a pending-human report and
exits 2. An accepted baseline must carry `humanAcceptance` with decision
`accepted`, a named `reviewer`, timezone-bearing ISO `reviewedAt`, review
`evidence`, the sorted complete `reviewedViews` (`view/size`), integer
`unresolvedP1P2: 0`, and `manifestSha256`. That hash is SHA256 of the manifest
without `humanAcceptance`, serialized with sorted keys and compact JSON
separators. This binds the actual review to the exact manifest. Creating this
record requires the human quality review; neither driver nor comparator creates
it, and test-only acceptance records cannot authorize a real campaign.

### View: question-free-form

- Agent question with What should the hero say?
- Visible free_form mode and request question-free-form
- This editor cannot answer this request.; no answer, checkbox or confirmation actions

### View: question-multi-choice

- Agent question with Which layouts should I preview?
- Visible multi_choice mode and request question-multi-choice
- This editor cannot answer this request.; no answer, checkbox or confirmation actions
- Readable Desktop choice
- Readable Tablet choice

### View: question-confirmation

- Agent question with May I replace the hero image?
- Visible confirmation mode and request question-confirmation
- This editor cannot answer this request.; no answer, checkbox or confirmation actions

### View: navigation-pending

- Checked Approve agent navigation preference
- Pending open-story request with Approve and Reject controls
- Home remains in the preview until approval


### View: navigation-approved

- Applied open-story history row without pending controls
- Details is selected in the real story browser
- Website preview remains visible


### View: navigation-rejected

- Rejected open-story history row without pending controls
- Home remains selected; no navigation was applied
- Approval preference remains enabled


### View: navigation-stale

- Failed request history after a real user viewport change
- Home remains selected after the stale approval
- No pending approval controls remain


### View: navigation-auto

- Unchecked Approve agent navigation preference
- Applied open-story history row and Details selected
- No approval controls are shown


### View: focus-auto

- Applied focus sidebar-search history row
- Sidebar search holds actual keyboard focus
- Website preview and composer remain visible


### View: selection-highlight-auto

- Applied select primary history row
- Primary action in the preview has a visible highlight and actual focus
- Selected element is primary in production inspector state


### View: highlight-auto

- Applied highlight secondary history row
- Secondary action in the preview has a visible highlight
- Selection stays unchanged; highlighting does not imply selection


### View: chat-first-send

- One actual user message Improve the hero spacing.
- Introduction and suggested prompt chips are gone
- Composer is empty after accepted send


### View: chat-send-failed

- Retry this website request. remains in the composer
- Suggested prompt chips and introduction are gone after attempted send
- No fabricated successful assistant response


### View: chat-draft-streaming

- Streaming assistant Website update is visible
- Next website change. remains in the composer
- Send is disabled during the unresolved turn


### View: chat-independent-first

- First conversation has its actual user and assistant content
- First conversation draft remains in its composer
- Suggested prompts do not return to this sent conversation


### View: chat-independent-second

- Second independent conversation shows its own draft
- Second conversation retains introduction and suggested prompts
- No first-conversation transcript appears


### View: chat-scroll-back

- Earlier assistant History 0 remains at the top of scrollback
- New output · Return to latest control is visible
- Draft stays intact and streaming does not force a jump


### View: chat-scroll-latest

- Latest assistant Newest website activity is visible
- Return to latest indicator has disappeared
- Composer draft remains intact


### View: chat-selection-streaming

- Selected heading Website update remains selected after another chunk
- Streaming continuation is visible
- Composer and website preview remain visible
