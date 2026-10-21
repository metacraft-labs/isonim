Run `just lint-nondet` to check the framework and nim-everywhere, including the
scanner's real-file negative controls. Run `just test-strict-nondet` for the
native and JS compiler controls.

A site can reuse the same checker with all source roots in one invocation:

```sh
python3 ../isonim/tools/lint_nondet.py \
  --allowlist ../isonim/tools/nondet_allowlist.json \
  ../isonim/src ../nim-everywhere/src src
```

The allowlist uses exact `repository/src/path`, API, count and reason entries.
Adding a use, deleting an obsolete allowance's use, or omitting a reason fails.
Warnings for Worker, WebAssembly, BroadcastChannel and indexedDB remain visible
and cannot be suppressed by a fatal-API allowance. New site exceptions belong in
the same supplied allowlist and must identify their boundary and justification.

The scanner checks literal importjs/importc/emit payloads, emit fragment arrays,
and JavaScript lexical tokens, ignoring comments and ordinary strings. Git
ownership excludes ignored generated outputs and submodule trees; untracked
source is included. Without Git, it scans all files in the source roots. It
recognizes literal bracket members, but does not infer aliases, computed member
names, generated code or ordinary Nim variables later evaluated as JavaScript.

The existing native editor/iframe/preview adapter allowances are a bounded
inventory, not a claim that those adapters can be recorded and replayed. They
include computed-style and scroll geometry beyond the present rectangle seam.
New application code uses `isonim/core/nondet` instead.

Strict mode makes the legacy raw platform entry points compiler errors. The
Real backend and platform implementation explicitly delegate with
`RawBackendAccess`; this opt-in documents trust, rather than acting as a security
capability. Raw effect tags cannot prove effects through closure fields. Source
lint remains the enforcement for foreign calls.
