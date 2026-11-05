# Editor authoring scenarios

`editor-workflows.yaml` uses the official Rust Scenario-Format player. Its numbered
phases contain the model's decisions and actual `runCmd` commands. Phase files
choose a decision for each real prompt; barriers wait for real tool/render state.
Only model decisions and response text replace external inference. Tool output,
HTTP/SSE, dispatcher, source worker, filesystem, Nim compiler and catalog are real.

Run `just test-editor-scenarios-native`, `just test-editor-scenarios-stress` or
`just test-editor-scenarios-gui` with
`ISONIM_HARBOR_SCENARIO_PROVIDER` pointing to the official built Rust `mock-agent`.
Only an absent private Harbor checkout can skip. A present checkout with missing
provider, failed build or failed workflow fails. All three commands use private owned
launcher/Harbor/SQLite/provider instances and retain artifacts under
`/tmp/eac-m5-*/project/.scenario` (under Repro's temporary directory when applicable).
The `.scenario` directory is fixture execution state, separate from source and
catalog inputs. Placing it inside the bound project preserves Harbor's private
`/tmp`; no parent directory or global host temporary files are exposed. Source
non-mutation checks cover every project file outside this fixture directory.
Production launch handoffs use privately owned application data outside hidden
host `/tmp` and runtime IPC, and remain read-only to the isolated provider.

The four public scenario commands also handle a compiler checkout whose canonical
path lies under Linux `/tmp`. `editor_scenario_checkout.py` makes a genuine Git
snapshot outside private `/tmp`, copies the current authored edits and deletions,
retains real sibling/submodule dependencies and rebuilds with the same owning
recipe. Snapshot provenance and exit status are retained in an owned 0700
`~/.local/share/isonim-test-fixtures/harbor-checkout-*` directory, with 0600
manifests. User settings, credentials and private editor state are not copied.
The runner records generated Tailwind input hashes and does not regenerate them;
prepare them through the normal locked dependency/build mechanism first. It does
not change Harbor isolation or expose the compiler checkout as a writable project.

Every shared scenario terminal verifies the exact readable helper, CLI, role
prompt and official provider bytes, a readable bound sentinel and a host-existing
unbound `/tmp` sentinel that must remain hidden. Native, stress and GUI drivers
consume this actual terminal evidence. An additional stateful native resource
case poisons a resource hash and then names a bound file as the negative sentinel;
both actual commands must fail before CLI effects or a proof file are produced.

The original native suite is one stateful integration test, with named workflow outcomes;
the GUI runner records its own named outcomes. These are workflow checks, not
twelve independent unit tests. Each completed outcome is saved immediately, so a
later failure retains earlier evidence. Existing control/chat unit inventories
remain separate regression evidence.

The ownership stress suite is one additional integration test: 24 real streamed
turns and 1,536 authenticated HTTP state reads. YAML phase 17 holds the real
terminal at an observable barrier; each read verifies the production VM still
has an active turn after that turn's new streamed message. All turns retain the
same backend/provider kernel identity, then an acknowledged close reaps it.
These request and turn counts describe workload, not independent test cases.

| M5 workflow                           | YAML phase            | Native production host                                                                                         | Actual browser host                                                                                                                                                                                                                                                               |
| ------------------------------------- | --------------------- | -------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 create/compile/open/capture/reload  | 1, 2                  | Actual source/compiler/catalog; compiled SSR HTML capture; fresh VM loads persisted catalog                    | Mounted iframe navigation/HTML capture; separate PNG; actual page reload opens persisted story                                                                                                                                                                                    |
| 2 same-conversation second change     | 2                     | Same backend and provider kernel identity; actual second source compile/capture                                | Same session and actual provider kernel identity; mounted Followup story                                                                                                                                                                                                          |
| 3 streaming while composing           | 1, 14                 | Real incremental SSE and tools; next draft survives                                                            | Real text/tool stream, usable composer and retained next draft                                                                                                                                                                                                                    |
| 4 cancel capability then later prompt | 1, 2                  | Actual unsupported REST cancel 409 preserves active turn/provider; later prompt succeeds                       | Unsupported action unavailable; real 409; later prompt same session                                                                                                                                                                                                               |
| 5 compiler failure                    | 3                     | Real Nim type diagnostic; prior source/catalog/selection unchanged                                             | Visible diagnostic; prior mounted preview/source/catalog unchanged                                                                                                                                                                                                                |
| 6 independent chats                   | local host/UI actions | Independent drafts and exact retained history                                                                  | Actual tab clicks and independent draft/history state                                                                                                                                                                                                                             |
| 7 reconnect/stale targeting           | 9, 10                 | Actual lease expiry and authenticated same-instance renewal; same worker                                       | Browser offline through actual lease expiry, online same instance/provider; explicitly disconnected second instance credentials denied                                                                                                                                            |
| 8 mutation retry/conflict             | 7                     | Same command ID/result, one declaration; actual stale revision rejected                                        | Native coverage; no additional GUI claim                                                                                                                                                                                                                                          |
| 9 unsupported/denied                  | 8, 11                 | Actual CLI capability/permission rejection, unchanged source; revoked provider credential denied after closure | Native coverage; stale scope additionally covered by GUI workflow 7                                                                                                                                                                                                               |
| 10 keyboard/scroll/layout/focus       | 14                    | No keyboard, layout or DOM claim                                                                               | Enter/Shift+Enter/composition-event guard, actual transcript overflow/user scroll/Return to latest, narrow composer geometry and focus; wide/narrow normal header controls and single 44px scrollable preview chrome with keyboard menu/ESC/outside-click/resize                  |
| 11 first attempt guidance             | local host/UI actions | Dismissal state survives chat return                                                                           | Actual first Enter removes suggestions; actual tab return keeps them hidden                                                                                                                                                                                                       |
| 12 automatic/approval/rejection       | 4–6, 12–13, 15–16     | Real pending/approved/rejected navigation under shared policy                                                  | Actual CLI/RPC, visible approve/reject controls, automatic selection/focus/highlight; wide and narrow approvals switch between two real compiled button targets and change rendered highlight identity; pending and different-target rejection preserve selection/focus/highlight |

The native host is a thin real HTTP/SSE adapter configured on the production
EditorVM; the native BrowserAgentClient no-op is excluded. Browser-only claims
use actual mounted documents and input actions. Private scoped files contain only
the six production editor variables; credentials never enter YAML, public state,
tool arguments, prompt text or public artifacts. ACP terminals invoke the actual
production wrapper because terminal `args.env` does not inherit provider scope.
Linux slirp routing uses observed supported routes while keeping isolation.

Artifacts include actual host/browser logs, named outcomes, provider identities
and prompt traces, private Harbor SQLite event export, source diff and catalog,
compiler diagnostics, mounted HTML results and separately named PNGs. A screenshot
is retained evidence; automated checks do not constitute visual acceptance.

The fixture reads its own Harbor service's persisted ACP launch configuration,
matching the exact bound project and wrapper. It privately records the original
production handoff path. Every real terminal CLI command consumes that original
application-data file; native and GUI checks also verify its exact path, six-key
shape, scope equality and 0600/0700 modes inside the actual terminal. The fixture
copy is retained only for host-side authenticated observations. No additional
privileged environment key or host temporary mount is introduced.
