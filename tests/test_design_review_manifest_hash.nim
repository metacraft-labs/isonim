## REV-M5 — manifest hash unit tests.
##
## We exercise the public ``captureManifestHashOfBytes`` helper to
## avoid coupling these unit tests to a working ``repo`` binary.
## The orchestration in ``captureManifestHash`` is the same code
## path tested by the e2e suite once a real ``repo`` workspace is
## materialised.

import std/[strutils, unittest]

import isonim/editor/design_review/manifest_hash

const sampleXmlA = """<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <!-- some comment -->
  <project name="repo-b" path="b" revision="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"/>
  <project name="repo-a" path="a" revision="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"/>
</manifest>
"""

# Same content but with reordered projects + extra whitespace + a comment.
# The normalisation must squash this back to the same canonical bytes.
const sampleXmlAVariant = """<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <project name="repo-a"   path="a" revision="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"/>
  <!--    different comment    -->
  <project   name="repo-b"   revision="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"     path="b"/>
</manifest>
"""

# Same shape but with one revision flipped — must produce a wildly
# different hash (sha256 avalanche).
const sampleXmlAFlipped = """<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <project name="repo-a" path="a" revision="cccccccccccccccccccccccccccccccccccccccc"/>
  <project name="repo-b" path="b" revision="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"/>
</manifest>
"""

proc hammingHex(a, b: string): int =
  ## Hamming distance (in bits) between two equal-length hex digests.
  doAssert a.len == b.len
  result = 0
  for i in 0 ..< a.len:
    let x = parseHexInt($a[i]) xor parseHexInt($b[i])
    for bit in 0 ..< 4:
      if (x and (1 shl bit)) != 0:
        inc result

suite "REV-M5 manifest hash":

  test "test_manifest_hash_stable_across_repeated_invocations":
    let baseline = captureManifestHashOfBytes(sampleXmlA)
    check baseline.len == 64
    # 100 repeat calls must agree byte-for-byte.
    for _ in 0 ..< 100:
      check captureManifestHashOfBytes(sampleXmlA) == baseline

    # Reordering projects + comment + whitespace must also produce
    # the same hash — the normaliser is the contract.
    check captureManifestHashOfBytes(sampleXmlAVariant) == baseline

  test "test_manifest_hash_changes_when_pin_changes":
    let baseline = captureManifestHashOfBytes(sampleXmlA)
    let flipped  = captureManifestHashOfBytes(sampleXmlAFlipped)
    check baseline != flipped
    # sha256 avalanche: at least 120 of 256 bits should differ when a
    # single attribute changes.
    check hammingHex(baseline, flipped) >= 120
