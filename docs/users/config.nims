# Sibling-repo path switching, mirroring ../../../isonim-docs/config.nims
# and ../../demos/config.nims. Toolchain and these repos are expected to
# come from the IsoNim dev shell (`nix develop ../isonim -c <cmd>` from
# isonim-docs; from here, `nix develop ../../.. -c <cmd>`) -- do not
# assume a global nim.
#
# `nim c`'s config-file lookup walks up from the *project* (entry) file's
# own directory, not from each imported file's -- so this file, not
# isonim-docs' own config.nims, is what's active when compiling anything
# rooted under this package (src/ or tests/), even though most of the
# actual code being compiled lives in the sibling isonim-docs repo. Every
# path isonim-docs' own config.nims sets up therefore has to be set up
# here too, adjusted for this package's extra directory depth
# (docs/users/ instead of the repo root).
import std/os

let root = currentSourcePath().parentDir()
let siblingRoot = root / "../../.." ## .../codetracer-ci-refactor/

switch("path", siblingRoot / "isonim/src")
switch("path", siblingRoot / "isonim-docs/src") ## the framework (isonim-docs), a PATH dependency
switch("path", siblingRoot / "codetracer-design-system/nim") ## the shared docs theme helper (metacraft_docs_theme)
switch("path", siblingRoot / "nim-everywhere/src")
switch("path", siblingRoot / "nim-faststreams")
switch("path", siblingRoot / "nim-stew")
switch("path", siblingRoot / "isonim/vendor/chronicles")
switch("path", siblingRoot / "isonim/vendor/serialization")
switch("path", siblingRoot / "isonim/vendor/json_serialization")
switch("define", "chronicles_sinks=textlines[stderr]")
switch("define", "chronicles_runtime_filtering=on")
switch("define", "chronicles_log_level=TRACE")
