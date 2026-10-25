# Task-app browser cost baseline

This standalone benchmark measures real SSR, hydration and DOM dispatch with a
MessageChannel task settlement after every event. It includes synchronous
handlers and their microtasks, plus identical scheduler overhead in both arms.
It excludes rendering, future timers, upload completion and browser automation
round trips. It does not implement or qualify an active recording adapter.

Use the ordinary development shell, real generated Tailwind map and existing
Playwright installation. No toolchain update is needed. Build from published
Git archives, excluding all unfinished working-copy changes:

```sh
nix develop --command python3 tools/build_task_overhead.py \
  --output build/task-overhead \
  --candidate HEAD \
  --nim-everywhere /absolute/workspace/nim-everywhere/src \
  --tailwind-map /absolute/real-generated/tailwind-styles.json
nix develop --command node --test tests/test_task_overhead.mjs
nix develop --command node tests/test_task_overhead_inputs.mjs \
  build/task-overhead /absolute/isonim/tests/browser/node_modules/playwright/index.mjs
nix develop --command node tools/task_overhead.mjs \
  build/task-overhead build/task-overhead/receipt.json \
  /absolute/isonim/tests/browser/node_modules/playwright/index.mjs
```

The output directory must not already exist. Every failed/noisy browser attempt
retains its receipt; use a new receipt name for another attempt. Keep every
attempt when reporting results. The baseline is fixed at
`df230a07a493993fa7306970bc00f21e7d24968f`; fixture bytes must match exactly.
Both builds use the one installed compiler and default library, identical
release flags and identical appended observation of the fixture's real handler
counter. No CSS is served. The real generated Tailwind metadata is shared and
hashed; it is not a substitute renderer.

Sampling and thresholds are exported as the immutable `protocol` in
`tools/task_overhead.mjs`:30 baseline/baseline calibration pairs,30
baseline/candidate pairs, alternating order,1000 cycles of43 real handlers,
three100-cycle warmups per page. The entire batch is timed inside Chromium;
the output is a batched per-event estimate, not individual event percentiles.
The empirically calibrated95th-percentile noise band must stay below1µs/event.
The candidate's95% paired bootstrap interval must fit wholly inside that band.
No outlier removal, adaptive counts or candidate-driven noise widening occurs.

Actual synchronous slowdown must fail both the noise gate and the predeclared
10µs incremental recording budget. A missing real handler, zero events and
invalid clock must also fail. Missing browser/artifacts or changed artifact
bytes fail without skipping. Chromium executable and engine hashes, source
commits/trees, fixture/library/compiler hashes, every sample, clock quantum and
host load are recorded in JSON. A coarse clock is amortized over43000 verified
events; zero elapsed time is never accepted.

An ordinary/default comparison is labeled accordingly. Recordable dormant and
activated recording remain separate pending gates until real adapters exist.
Their event-boundary/checkpoint counts and decoded records must be asserted;
any adapter boundary work scheduled later must extend measured settlement.
Draining/asserting uploads outside timing does not claim upload latency is
included. Preserve the historical ordinary-bundle byte-identity test unchanged.

For independent harness self-tests after a noisy run, a fourth positional
argument may name an earlier valid calibration receipt with identical protocol
and artifact provenance. This runs only bounded slowdown/input controls; the
receipt explicitly says `controls-only-no-performance-qualification`, records
the reference receipt hash and has no calibration or comparison samples.
It cannot establish current default or dormant performance qualification.

The build records the actual nim-everywhere owner commit, dirty state and every
source-file hash, plus generated style-map bytes, before and after each archived
build. Any change refuses the comparison. No dependency source is copied.
Receipts are exclusively created before reading inputs; failed attempts retain
failure data and concurrent attempts cannot overwrite an existing owner.

Real-browser controls add50µs inside the registered application callback,
preserving its receiver/arguments and original invocation. A separate callback
control queues that work as a microtask and checks completion after settlement.
Both must exceed both unchanged gates with the same43 registrations and actual
calls. Empty/truncated SSR captures must fail the explicit44-node identity check.
