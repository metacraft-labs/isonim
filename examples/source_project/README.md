# Source editor example

This consumer opts into IsoNim's native source bridge. Its `.isonim/source-project.json`
selects fixture schemas and a project-owned build command. The command compiles
`stories.nim` with Nim and renders its SSR UI into a catalog. The editor updates
only after that command returns a valid catalog. Ordinary agent edits are picked
up with `isonim editor build --command-id <id> --wait`.

The native worker keeps runtime state next to the manifest; it is not source
and is gitignored: `.isonim/catalog.json` (the published catalog),
`.isonim/source-transaction.json` (the rollback journal of an interrupted
transaction) and `.isonim/removal-receipts.json` (the line receipts of Reset /
Fill Delete removals not yet undone, so undo restores only what was removed).

`isonim editor create-story Card --variant default --state busy --command-id <id> --wait`
creates a persisted fixture. `capture-preview` returns the mounted iframe's HTML,
viewport, stable story ID and readiness; it does not return a PNG image.

Build and launch with `repro exec -- just source-editor-serve` from the IsoNim repo.
