## Golden test: without `--variants`, `tools/tailwind-extract.mjs` emits
## exactly the JSON the pre-variants extractor emits for the same content.
##
## The pre-variants extractor is vendored verbatim as
## `tests/fixtures/tailwind-extract-900af96.mjs` (the tree's extractor before
## the variants mode was added). Both extractors run against one content set
## (`tests/fixtures/tailwind-golden/content.html`: plain, `sm:`, `md:`,
## `dark:` and `hover:` classes) in both of the extractor's paths:
##
## - auto-scan (no `--content`): Tailwind's non-minified output, where
##   `dark:`/`hover:` rules arrive as nested `@media`/`&:` blocks;
## - `--content` (explicit `@source`): Tailwind's minified output.
##
## The resulting `tailwind-styles.json` files are compared byte for byte.
##
## Both copies run from one scratch project root outside the checkout: the
## extractor treats `<its dir>/..` as the project root (the Tailwind CLI's
## cwd, and the auto-scan base), so sharing one root gives both runs the same
## content, including each other's source. `node_modules` is a symlink to the
## checkout's, so no install happens. Needs node and the checkout's
## `node_modules` (`just build-tailwind` provides them); no mocks.
import std/[os, osproc, strutils, unittest]

const testsDir = parentDir(currentSourcePath())
const repoRoot = parentDir(testsDir)

proc firstDiff(a, b: string): int =
  ## Offset of the first differing byte, or -1 when identical. Reported
  ## instead of the two JSON documents, which are too long to read in a
  ## failure message.
  for i in 0 ..< min(a.len, b.len):
    if a[i] != b[i]:
      return i
  if a.len != b.len: min(a.len, b.len) else: -1

proc extract(root, script, outDir: string; extra = ""): string =
  ## Runs one extractor copy from `root/tools/` and returns its JSON bytes.
  let (output, code) = execCmdEx("node " & quoteShell(root / "tools" / script) &
    " --out-dir " & quoteShell(outDir) & extra)
  doAssert code == 0, script & " failed:\n" & output
  readFile(outDir / "tailwind-styles.json")

suite "tailwind extractor: default output matches the pre-variants extractor":
  let scratch = getTempDir() / ("isonim-extract-golden-" &
    $getCurrentProcessId())
  let root = scratch / "project"
  removeDir(scratch)
  createDir(root / "tools")
  createDir(root / "content")
  createSymlink(repoRoot / "node_modules", root / "node_modules")
  copyFile(testsDir / "fixtures" / "tailwind-extract-900af96.mjs",
    root / "tools" / "extract-900af96.mjs")
  copyFile(repoRoot / "tools" / "tailwind-extract.mjs",
    root / "tools" / "extract-current.mjs")
  copyFile(testsDir / "fixtures" / "tailwind-golden" / "content.html",
    root / "content" / "content.html")

  test "auto-scan path (non-minified CSS) is byte-identical":
    let old = extract(root, "extract-900af96.mjs", scratch / "auto-old")
    let cur = extract(root, "extract-current.mjs", scratch / "auto-new")
    # The content set must actually reach the output, or the comparison
    # proves nothing about variant classes.
    for cls in ["\"p-4\"", "\"sm:p-2\"", "\"md:p-8\"", "\"dark:bg-gray-900\"",
        "\"hover:underline\""]:
      check cls in old
    check firstDiff(old, cur) == -1

  test "--content path (minified CSS) is byte-identical":
    let content = " --content " & quoteShell(root / "content" / "*.html")
    let old = extract(root, "extract-900af96.mjs", scratch / "content-old",
      content)
    let cur = extract(root, "extract-current.mjs", scratch / "content-new",
      content)
    for cls in ["\"p-4\"", "\"sm:p-2\"", "\"md:p-8\"", "\"dark:bg-gray-900\""]:
      check cls in old
    check firstDiff(old, cur) == -1

  test "variants mode differs from the default on the same content":
    # Control: the content set exercises the variant handling, so a
    # default mode that leaked variant behaviour would show up above.
    let def = readFile(scratch / "auto-new" / "tailwind-styles.json")
    let vars = extract(root, "extract-current.mjs", scratch / "auto-variants",
      " --variants sm,dark,hover,md")
    check "\"variant\"" in vars
    check "\"variant\"" notin def
    check vars != def

  removeDir(scratch)
