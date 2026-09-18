## NH-M3 — ``test_uicomponent_native_arm_hashes_a_changed_body_differently``
##
## The gate that makes every other native-HMR hash assertion mean
## something. Until 2026-09-18 ``isonim/web/hmr_component.nim`` gated its
## whole macro body on ``defined(isonimHmr) and defined(js)``, so under
## ``nim c`` ``{.uiComponent.}`` was a transparent no-op and
## ``symBodyHash`` was never evaluated on native at all. NH-M2's four
## gates therefore fed the registry the hash literals a patched body
## *would have* produced. That fixture shape is defensible — a real
## Reprobuild patch replaces a body in place, so the slot keeps its
## ``file:line:col`` and gets a new hash, i.e. "one fixed loc, two hash
## strings" is exactly right — but it cannot test the one property that
## makes the hash load-bearing: **that a changed body produces a
## different hash.** Every NH-M3 verification entry turns on "when a
## slot's hash matches / differs".
##
## MOCK POLICY (workspace rule: every mock justified in the header).
## **No mocks, doubles, stubs or fakes of any kind.** The subject is the
## Nim compiler's ``symBodyHash`` as reached through the shipped
## ``{.uiComponent.}`` macro, and the only way to observe "two builds" is
## to perform two builds. This test writes a fixture, invokes the real
## ``nim`` from the pinned dev shell, runs the resulting program, and
## reads what it printed. Nothing is intercepted.
##
## NO SKIP ARMS. The one prerequisite — a ``nim`` on PATH — is checked
## and FAILS with a remedy if absent; it is never skipped, because a
## green run that compiled nothing is precisely the defect this file
## exists to rule out.
##
## ## The shape of the measurement
##
## Three fixture variants, at ONE path so the slot location is fixed:
##
## - ``A``  — body computes ``acc + i * 2``
## - ``B``  — the SAME file with one expression changed to ``i * 3``
## - ``A'`` — byte-identical to ``A``, built again from a cold nimcache
##
## Each is compiled for BOTH backends (``nim c`` and ``nim js``), giving
## six independent builds. Every build is forced (``-f``) into its OWN
## ``--nimcache`` directory: without that, ``A'`` could be served from
## ``A``'s cache and "identical bodies hash the same" would be a
## statement about the cache rather than about the compiler.
##
## ## What each block proves, and why it cannot pass for the wrong reason
##
## - **anti-vacuity** — all six hashes non-empty, and the three native
##   locations EQUAL (likewise the three web ones). Two empty strings are
##   equal for free, and a hash that changed because the slot MOVED would
##   say nothing about the body. Also asserts the dispatch was actually
##   rewritten (below), which is what distinguishes "the native arm ran"
##   from "the pragma was the old no-op".
## - **identical bodies → same hash** (``A`` vs ``A'``).
## - **changed body → different hash** (``A`` vs ``B``) — the claim.
## - **control arm** — the same pair built for ``-d:js``, where the web
##   arm has computed the hash since the beginning. It must reach the
##   same verdict, so a native/web divergence is visible instead of
##   silently tolerated. Measured on 2026-09-18: the two backends do not
##   merely agree on the verdict, they produce the IDENTICAL hash string
##   for the same body, so the control is asserted at that strength.
##
## ### The "dispatch was rewritten" check, and why it belongs here
##
## The fixture calls its own component with no ``HmrRoot`` started and
## prints whether that raised. Under the native arm the call reaches the
## generated dispatch, which reaches ``hmrInvokeSlot``, which raises
## "called with no active registry" — so ``dispatch=rewritten``. Under
## the pre-2026-09-18 no-op arm the call would land on the user's own
## body and return a node — ``dispatch=passthrough``. Without this the
## whole file could stay green against a macro that computed a hash and
## emitted nothing else.
##
## ## Falsifier (milestone-specified), measured 2026-09-18
##
## "Make the native arm hash the slot LOCATION rather than the body."
## Applied as a source mutation to ``hmr_component.nim``'s native arm
## (``let h = symBodyHash(implSym)`` → a digest of ``locStr``) and
## re-run. Outcome is recorded in the milestone's verification log. A
## location-keyed hash is the plausible wrong implementation, and a gate
## that only ever sees one body cannot discriminate it.

import std/[os, osproc, strutils, strformat, tables]
import unittest

# ---------------------------------------------------------------------------
# Fixture generation
# ---------------------------------------------------------------------------

const
  thisDir = currentSourcePath().parentDir
  # ONE path for every variant. The slot key is `file:line:col`, so a
  # per-variant path or a temp-dir name would move the location and the
  # anti-vacuity check ("the locations are EQUAL") would be the thing
  # failing instead of the thing guarding.
  fixturePath = thisDir / "uicomponentprobefixture.nim"

  # The template. `@@STEP@@` is the ONE expression that varies. Note the
  # component's `proc` header sits at a fixed line: everything that
  # differs between variants is strictly inside the body, which is
  # exactly what a Reprobuild patch does to a function.
  fixtureTemplate = """## GENERATED by tests/test_uicomponent_native_arm.nim — DO NOT EDIT, DO NOT COMMIT.
##
## Deliberately identical source for both backends, so the two arms'
## `symBodyHash` values are comparable. The component body is pure Nim
## (no renderer call) for the same reason: `symBodyHash` is transitive,
## so a backend-specific helper inside the body would make the two
## backends disagree for a reason that has nothing to do with the edit
## under test.
{.warning[UnusedImport]: off.}

when not defined(isonimHmr):
  {.error: "the uiComponent probe fixture requires -d:isonimHmr".}

when defined(js):
  import std/jsffi
  import isonim/web/dom_api

import isonim/web/hmr_component

type
  ProbeNode* = ref object
    label*: string
    tally*: int

proc probeComponent(): ProbeNode {.uiComponent.} =
  var acc = 0
  for i in 0 ..< 4:
    acc = acc + i * @@STEP@@
  ProbeNode(label: "probe", tally: acc)

when defined(js):
  echo "backend=js"
else:
  echo "backend=c"
echo "loc=", probeComponentLoc
echo "hash=", probeComponentHash

# Reaching the component with no HmrRoot started must land in the
# generated dispatch (which raises), not in the user's body. See the
# header of the test that generates this file.
#
# The result is `discard`ed rather than inspected because the two arms
# give the dispatch different return types: the native arm uses the
# component's own (`ProbeNode`), while the web arm's zero-arg path has
# always hardcoded `Node`. That asymmetry is pre-existing web behaviour
# and is harmless for real web components, which all return `Node`; it
# is called out here so a reader does not mistake the `discard` for
# laziness.
try:
  discard probeComponent()
  echo "dispatch=passthrough"
except CatchableError, Defect:
  echo "dispatch=rewritten"
"""

type
  Probe = object
    backend: string
    loc: string
    hash: string
    dispatch: string

proc writeFixture(step: string) =
  writeFile(fixturePath, fixtureTemplate.replace("@@STEP@@", step))

proc parseProbe(output: string): Probe =
  for rawLine in output.splitLines():
    let line = rawLine.strip()
    if line.startsWith("backend="): result.backend = line["backend=".len .. ^1]
    elif line.startsWith("loc="): result.loc = line["loc=".len .. ^1]
    elif line.startsWith("hash="): result.hash = line["hash=".len .. ^1]
    elif line.startsWith("dispatch="): result.dispatch = line["dispatch=".len .. ^1]

proc buildAndRun(nimExe, backend, label: string): Probe =
  ## One independent build. `-f` plus a per-label `--nimcache` is what
  ## makes the `A` / `A'` pair two builds rather than one build read
  ## twice.
  let cache = thisDir / "_build" / ("uicomponentprobe-" & label)
  removeDir(cache)
  createDir(cache)
  let args = @[backend, "-r", "-f", "--hints:off", "--verbosity:0",
               "-d:isonimHmr", "--nimcache:" & cache, fixturePath]
  let (output, exitCode) = execCmdEx(
    quoteShellCommand(@[nimExe] & args), workingDir = thisDir)
  if exitCode != 0:
    raise newException(OSError,
      &"`nim {backend}` of the uiComponent probe fixture failed (rc " &
      &"{exitCode}) for variant '{label}'.\n" &
      "This is a FAILURE, not a reason to skip: the whole gate is about " &
      "what the compiler computes, so a build that did not happen has " &
      "nothing to assert on.\n--- output ---\n" & output)
  result = parseProbe(output)
  if result.hash.len == 0 or result.loc.len == 0:
    raise newException(ValueError,
      &"the probe fixture ran for variant '{label}' ({backend}) but " &
      "printed no `loc=`/`hash=` line. The {.uiComponent.} macro must " &
      "emit `<Name>Loc` and `<Name>Hash` consts on both arms.\n" &
      "--- output ---\n" & output)

# ---------------------------------------------------------------------------
# Measure once, assert many times.
# ---------------------------------------------------------------------------

let nimExe = findExe("nim")
if nimExe.len == 0:
  raise newException(OSError,
    "`nim` is not on PATH. This gate compiles its fixture twice per " &
    "backend and cannot run without a compiler. Run it inside the " &
    "repo dev shell: `direnv exec <isonim> nim c -r " &
    "tests/test_uicomponent_native_arm.nim`.")

var probes: Table[string, Probe]
for (label, step) in {"A": "2", "B": "3", "Aprime": "2"}:
  writeFixture(step)
  probes["c-" & label] = buildAndRun(nimExe, "c", "c-" & label)
  probes["js-" & label] = buildAndRun(nimExe, "js", "js-" & label)

# Leave the tree as the fixture-free state it was found in. The generated
# file is gitignored, but a stale copy at a path inside `tests/` is the
# kind of thing a later `find tests -name 'test_*.nim'` sweep or a
# `just test-c` addition trips over.
removeFile(fixturePath)

let
  cA = probes["c-A"]
  cB = probes["c-B"]
  cAp = probes["c-Aprime"]
  jA = probes["js-A"]
  jB = probes["js-B"]
  jAp = probes["js-Aprime"]

suite "NH-M3: {.uiComponent.} native arm computes symBodyHash":

  test "anti-vacuity: hashes are non-empty and the location is fixed":
    # Two empty strings are equal for free; a hash that moved because the
    # SLOT moved would prove nothing about the body.
    for p in probes.values:
      check p.hash.len > 0
      check p.loc.len > 0
      # `symBodyHash` returns a `__`-prefixed digest. A bare non-empty
      # check would also accept a macro that emitted the proc's name.
      check p.hash.startsWith("__")
      check p.hash != p.loc
      # The location is the slot key and must name the fixture and a
      # `line:col` inside it — not, say, the macro's own module.
      check p.loc.startsWith(fixturePath & ":")
      let tail = p.loc[(fixturePath.len + 1) .. ^1].split(':')
      check tail.len == 2
      check tail[0].allCharsInSet({'0' .. '9'})
      check tail[1].allCharsInSet({'0' .. '9'})

    # EQUAL locations across the three native builds, and across the
    # three web builds. Asserted before any hash comparison below.
    check cA.loc == cB.loc
    check cA.loc == cAp.loc
    check jA.loc == jB.loc
    check jA.loc == jAp.loc

    # Each build really ran on the backend it was asked for.
    check cA.backend == "c"
    check cB.backend == "c"
    check cAp.backend == "c"
    check jA.backend == "js"
    check jB.backend == "js"
    check jAp.backend == "js"

  test "anti-vacuity: the native pragma is no longer a transparent no-op":
    # Under the pre-2026-09-18 arm this reads `passthrough`, because the
    # macro returned the user's proc unchanged. Everything else in this
    # file could be green against a macro that computed a hash and
    # emitted no dispatch and no registration.
    check cA.dispatch == "rewritten"
    check cB.dispatch == "rewritten"
    check cAp.dispatch == "rewritten"

    # NATIVE ONLY, and the asymmetry is a property of the two arms
    # rather than an omission. The web arm registers its factory from a
    # TOP-LEVEL statement, so by the time the fixture calls its
    # component the slot exists and the dispatch succeeds — measured
    # 2026-09-18: `dispatch=passthrough` on both `js` builds. The native
    # arm cannot register at module init (there is no registry until
    # `HmrRoot.start()`), so an un-started call raises, which is what
    # makes this observation discriminating there and only there.
    check jA.dispatch == "passthrough"
    check jB.dispatch == "passthrough"

  test "native: two builds of an IDENTICAL body produce the SAME hash":
    check cA.hash == cAp.hash

  test "native: two builds whose BODY differs by one expression produce DIFFERENT hashes":
    # The claim. Same file, same path, same `file:line:col` (asserted
    # above); one expression changed inside the body.
    check cA.hash != cB.hash

  test "control arm: the web arm reaches the same verdict on the same pair":
    # The web arm has computed this hash since the pragma shipped, so it
    # is the reference. A native/web divergence must be visible here
    # rather than silently tolerated.
    check jA.hash == jAp.hash
    check jA.hash != jB.hash

  test "control arm: native and web agree on the hash STRING, per variant":
    # Measured 2026-09-18: `symBodyHash` over a body whose transitive
    # closure is pure Nim is backend-independent, so the control can be
    # asserted at string strength rather than only at verdict strength.
    # If this ever goes red while the four blocks above stay green, the
    # two arms have started hashing different things — which is the
    # divergence the milestone asked to be made visible, not a reason to
    # weaken this check.
    check cA.hash == jA.hash
    check cB.hash == jB.hash
    check cAp.hash == jAp.hash
