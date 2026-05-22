# Upgrading the editor's JS dependencies

This document is the canonical recipe for bumping the editor bundle's
yarn-managed JS dependencies (`@tiptap/core`, `@tiptap/starter-kit`,
`tiptap-markdown`, `@tiptap/pm`, `xterm`, and anything added later).

Background: the IsoNim editor's runtime JS is built by a content-
addressed Nix derivation at `isonim/nix/editor-vendor.nix`. The
derivation takes `isonim/package.json` + `isonim/yarn.lock` as inputs,
fetches the offline mirror via `fetchYarnDeps` (cached by the
`yarn.lock` content hash), and runs `esbuild` against
`isonim/nix/entry-tiptap.mjs` + `isonim/nix/entry-xterm.mjs` to produce
two UMD bundles. Each bundle attaches a single typed global
(`globalThis.TipTap`, `globalThis.TipTapStarterKit`,
`globalThis.TipTapMarkdown`, `globalThis.XtermTerminal`). The per-
library FFI modules under `isonim/src/isonim/editor/vendor/*.nim`
consume those globals via `{.importc, nodecl.}` + `{.importjs.}`.

The architectural pattern lives in
[`Editor-Topbar-Spec.milestones.org`](../../codetracer-specs/Front-Ends/IsoNim/Editor-Topbar-Spec.milestones.org)
under milestone TBAR-M5b.

## When to use this recipe

- A renovate / dependabot PR landed bumping a version in
  `package.json` / `yarn.lock`.
- A maintainer is bumping a dep by hand (e.g. tracking a TipTap
  security advisory).
- The `editor-vendor.nix` derivation suddenly fails to build with a
  hash-mismatch error like:
  ```
  hash mismatch in fixed-output derivation '/nix/store/...':
       specified: sha256-A/Flacyk8h4I3YnaiUTNGujmf/YDLIzOJoI/DJ8PB3k=
            got: sha256-NEW...
  ```

## The recipe

All steps run inside the `isonim` dev shell. Enter it via
`direnv exec ~/metacraft/isonim ...` or `cd ~/metacraft/isonim`.

### Step 1 — bump the version

Edit `isonim/package.json` and change the relevant version in
`dependencies`. For example:

```diff
-    "@tiptap/core": "^3.23.6",
+    "@tiptap/core": "^3.24.0",
```

Or for a security advisory you might pin exact:

```diff
-    "tiptap-markdown": "^0.8.10",
+    "tiptap-markdown": "0.8.11",
```

### Step 2 — refresh `yarn.lock`

From `isonim/`:

```sh
direnv exec ~/metacraft/isonim yarn install
```

This rewrites `isonim/yarn.lock`. Both `package.json` and `yarn.lock`
are committed.

### Step 3 — re-compute the offline-cache hash

The `editor-vendor.nix` derivation pins a `fetchYarnDeps` content
hash. Refresh it:

```sh
direnv exec ~/metacraft/isonim prefetch-yarn-deps yarn.lock
```

The command prints an SRI hash like:

```
sha256-NEW_HASH_HERE=
```

Open `isonim/nix/editor-vendor.nix` and replace the `hash` value in
the `offlineCache = fetchYarnDeps { ... }` block:

```diff
   offlineCache = fetchYarnDeps {
     yarnLock = ../yarn.lock;
-    hash = "sha256-A/Flacyk8h4I3YnaiUTNGujmf/YDLIzOJoI/DJ8PB3k=";
+    hash = "sha256-NEW_HASH_HERE=";
   };
```

### Step 4 — rebuild the bundle + verify

```sh
direnv exec ~/metacraft/isonim nix build .#editor-vendor
ls -la result/
# Should show:
#   tiptap.umd.js
#   xterm.umd.js
#   xterm.css
#   MANIFEST.txt
```

The bundle integrity test asserts the outputs are sane:

```sh
direnv exec ~/metacraft/isonim nim c -r tests/test_editor_vendor_dist_check.nim
```

If a bundle exceeds its per-library byte budget the test fails — that
is the gate, not a soft warning. Bundle budgets are documented in the
test itself (`tiptap.umd.js < 800 KB`, `xterm.umd.js < 300 KB`).

### Step 5 — rebuild the editor JS + smoke-test the live runtime

```sh
direnv exec ~/metacraft/isonim-examples just editor-build
```

The recipe pulls the new Nix-derivation output via
`nix build --print-out-paths` and `cp`s the bundles into
`isonim-examples/build/editor/vendor/`. The recipe does NOT invoke
`yarn` or `npm` directly.

Boot the editor server with the launchers and confirm the live page
still renders:

```sh
direnv exec ~/metacraft/isonim-examples just editor-serve-all
# browse to http://127.0.0.1:8091, click around, confirm
# Spec/View/Comment/Edit modes still work
```

### Step 6 — run the broader test suite

```sh
direnv exec ~/metacraft/isonim nim c -r tests/test_editor_spec_pane_vm.nim
direnv exec ~/metacraft/isonim nim c -r tests/test_editor_spec_pane_edit_vm.nim
direnv exec ~/metacraft/isonim nim c -r tests/test_editor_spec_comment_vm.nim
cd ~/metacraft/isonim/tests/browser && node --test e2e_editor_spec_pane_view_mode.mjs
cd ~/metacraft/isonim/tests/browser && node --test e2e_editor_spec_edit_mode.mjs
cd ~/metacraft/isonim/tests/browser && node --test e2e_editor_spec_comment_to_chat.mjs
```

If a TipTap behaviour changed in the new version (e.g. an extension
removed a method the FFI module imported, or the markdown serializer
output format shifted), one of these tests will catch it. Fix the
binding in the relevant `isonim/src/isonim/editor/vendor/*.nim` and
re-run.

### Step 7 — commit

Three files always change together on a dep bump:

```sh
cd ~/metacraft/isonim
git add package.json yarn.lock nix/editor-vendor.nix
git commit -m "Bump @tiptap/core to 3.24.0

[describe what changed + why + any breaking-change notes]"
```

## Adding a brand-new dependency

When the editor needs a new JS library (e.g. a code-editor widget,
syntax highlighter, etc.):

1. `yarn add <package>` from `isonim/` (regenerates yarn.lock).
2. Refresh the offline-cache hash (step 3 above).
3. Add an entry-script next to the existing
   `isonim/nix/entry-tiptap.mjs` + `entry-xterm.mjs`. Each entry
   imports the npm package and assigns it to a `globalThis.<Name>`.
4. Extend `isonim/nix/esbuild.config.mjs` to bundle the new entry —
   list it alongside the existing ones; the config produces one UMD
   per entry.
5. Write a new FFI module at
   `isonim/src/isonim/editor/vendor/<library>.nim` exposing the
   global as `{.importc, nodecl.}` + the library's API as
   `{.importjs.}` typed procs. NO `{.emit.}` blocks.
6. Add the new `<script>` tag to `isonim-examples/editor/index.html`
   loading `vendor/<library>.umd.js` before the editor bundle.
7. Update `tests/test_editor_vendor_dist_check.nim` to assert the
   new bundle exists with a sensible per-library byte budget.
8. Rebuild + run all the verification commands above.

## Troubleshooting

### Hash mismatch on `nix build .#editor-vendor`

You bumped `yarn.lock` but forgot step 3. Re-run
`prefetch-yarn-deps yarn.lock` and paste the new hash into
`nix/editor-vendor.nix`.

### `prefetch-yarn-deps` not found

The dev shell needs to be entered (the binary is on `PATH` only
inside the Nix dev shell, not in the host shell). Use
`direnv exec ~/metacraft/isonim prefetch-yarn-deps yarn.lock`.

### `just editor-build` fails with "vendor/<file> not found"

`nix build .#editor-vendor` either failed or produced a different
output set than the recipe expects. Run the `nix build` command
manually + check the contents of `result/`.

### Bundle exceeds its byte budget

The `tests/test_editor_vendor_dist_check.nim` test asserts hard
budgets. If a dep bump exceeds them:

- Confirm the bundle's content is what you expected
  (`du -h result/*.js`).
- If the budget is reasonable to relax (e.g. TipTap upstream added a
  new mandatory extension), update the budget in the test file and
  document the increase in the commit message.
- If the budget shouldn't be relaxed (e.g. a transitive dep is
  pulling in a large polyfill we don't need), figure out which dep
  is responsible and either pin the smaller version or extract just
  the part we need.

### TipTap markdown round-trip lost a structure

If the e2e browser test `e2e_editor_spec_edit_mode.mjs` fails
asserting that typed `**bold**` produces a `<strong>` tag after a
TipTap version bump, the upstream tiptap-markdown extension may
have changed its parse behaviour. Read the upstream changelog;
the fix is usually a `configure({ ... })` option on the markdown
extension exposed via
`isonim/src/isonim/editor/vendor/tiptap_markdown.nim`.

## Related files

- `isonim/package.json` + `isonim/yarn.lock`
- `isonim/nix/editor-vendor.nix`
- `isonim/nix/{entry-tiptap,entry-xterm,esbuild.config}.mjs`
- `isonim/src/isonim/editor/vendor/{tiptap,tiptap_starter_kit,tiptap_markdown,xterm}.nim`
- `isonim/tests/test_editor_vendor_dist_check.nim`
- `isonim-examples/Justfile` (the `editor-build` recipe)
- `isonim-examples/editor/index.html` (loads the UMDs)
- TBAR-M5b in
  `codetracer-specs/Front-Ends/IsoNim/Editor-Topbar-Spec.milestones.org`
