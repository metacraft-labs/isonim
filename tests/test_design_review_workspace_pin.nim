## REV-M5 — workspace pin unit tests (replaces the retired
## ``repo manifest`` hash tests).
##
## Pure tests pin the canonical record format, the digest and the
## classification of stored values; the capture tests build a hermetic
## reprobuild workspace (``helpers/repro_workspace_fixture``) and pin it
## through ``repro`` exactly as capture does.

import std/[algorithm, os, sequtils, strutils, unittest]

import isonim/editor/design_review/workspace_pin

import helpers/repro_workspace_fixture

const ShaA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const ShaB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

proc sampleLock(): WorkspaceLock =
  WorkspaceLock(project: "demo", scope: ProjectScope,
    repos: @[
      LockedRepo(name: "repo-b", path: "b", remote: "org", revision: ShaA),
      LockedRepo(name: "repo-a", path: "a", remote: "org", revision: ShaB)],
    unmaterialized: @[
      UnmaterializedRepo(name: "z", path: "z", remote: "org",
                         reason: NoCheckoutReason)])

proc hammingHex(a, b: string): int =
  doAssert a.len == b.len
  for i in 0 ..< a.len:
    let x = parseHexInt($a[i]) xor parseHexInt($b[i])
    for bit in 0 ..< 4:
      if (x and (1 shl bit)) != 0: inc result

suite "REV-M5 workspace pin — format":

  test "test_sha256_matches_fips_180_vectors":
    check sha256Hex("") ==
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    check sha256Hex("abc") ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    check sha256Hex('a'.repeat(1_000_000)) ==
      "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"

  test "test_canonical_lock_is_the_reprobuild_record_shape":
    let toml = renderCanonicalLock(sampleLock())
    check toml == """schema = "reprobuild.workspace.lock.v1"

[lock]
project = "demo"

[[repo]]
name = "repo-a"
path = "a"
remote = "org"
revision = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

[[repo]]
name = "repo-b"
path = "b"
remote = "org"
revision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

[extensions]
pin_scope = "project"
unmaterialized_repos = [
  { name = "z", path = "z", remote = "org", reason = "no on-disk checkout" },
]
"""
    # Without unmaterialized repos the scope still closes the record.
    var full = sampleLock()
    full.unmaterialized = @[]
    check renderCanonicalLock(full).endsWith(
      "\n[extensions]\npin_scope = \"project\"\n")
    check renderCanonicalLock(parseCanonicalLock(
      renderCanonicalLock(full))) == renderCanonicalLock(full)

  test "test_canonical_lock_is_order_insensitive_and_round_trips":
    var shuffled = sampleLock()
    shuffled.repos.reverse()
    check renderCanonicalLock(shuffled) == renderCanonicalLock(sampleLock())
    let toml = renderCanonicalLock(sampleLock())
    check renderCanonicalLock(parseCanonicalLock(toml)) == toml
    # Names that are not filename-shaped survive the round trip.
    var odd = sampleLock()
    odd.repos[0].name = "stripe/sync-engine \"q\" \\ x"
    let oddToml = renderCanonicalLock(odd)
    check parseCanonicalLock(oddToml).repos.anyIt(it.name == odd.repos[0].name)

  test "test_parse_rejects_non_canonical_records":
    let toml = renderCanonicalLock(sampleLock())
    for bad in [toml.replace("\n", "\r\n"),
                toml.replace("name = \"repo-a\"", "name =  \"repo-a\""),
                toml & "\n",
                toml.replace("project = \"demo\"\n",
                             "project = \"demo\"\ncreated_at = \"x\"\n"),
                # no scope: a record that does not say what it covers
                toml.replace("pin_scope = \"project\"\n", ""),
                # entries out of canonical order
                toml.replace("\"repo-a\"", "\"tmp\"").replace(
                  "path = \"a\"", "path = \"c\"")]:
      expect WorkspacePinError:
        discard parseCanonicalLock(bad)

  test "test_pin_is_the_plain_sha256_the_database_check_computes":
    # Migration 011's CHECK recomputes the pin as
    #   'wslock-v1:sha256:' || encode(sha256(convert_to(lock_toml,'UTF8')),'hex')
    # i.e. lowercase-hex sha256 of the record's UTF-8 bytes, nothing else.
    # The expected value was computed outside Nim (Python hashlib over the
    # record text in the shape test above), so a pin that drifts from
    # what Postgres computes (CRLF, BOM, other prefix or case) fails here
    # without a database.
    check pinOf(renderCanonicalLock(sampleLock())) == WorkspacePinPrefix &
      "75a3d7fb37d248228812c830c18547ad0df8d62885b80bb00389f01fe0596021"

  test "test_pin_changes_when_any_revision_changes":
    let base = pinOf(renderCanonicalLock(sampleLock()))
    check base.startsWith(WorkspacePinPrefix)
    check base.len == WorkspacePinPrefix.len + 64
    var flipped = sampleLock()
    flipped.repos[0].revision = "cccccccccccccccccccccccccccccccccccccccc"
    let other = pinOf(renderCanonicalLock(flipped))
    check base != other
    check hammingHex(base[WorkspacePinPrefix.len .. ^1],
                     other[WorkspacePinPrefix.len .. ^1]) >= 80

  test "test_resolve_pin_rejects_a_record_that_does_not_hash_to_it":
    let toml = renderCanonicalLock(sampleLock())
    let pin = pinOf(toml)
    check resolvePin(pin, toml).repos.len == 2
    var other = sampleLock()
    other.project = "other"
    expect WorkspacePinError:
      discard resolvePin(pin, renderCanonicalLock(other))

  test "test_project_and_scope_are_part_of_the_pin":
    let base = pinOf(renderCanonicalLock(sampleLock()))
    var otherProject = sampleLock()
    otherProject.project = "codetracer"
    check pinOf(renderCanonicalLock(otherProject)) != base
    var otherScope = sampleLock()
    otherScope.scope = "workspace"
    check pinOf(renderCanonicalLock(otherScope)) != base

  test "test_classify_pin_recognises_every_stored_value_form":
    let pin = pinOf(renderCanonicalLock(sampleLock()))
    check classifyPin(pin) == pkWorkspaceLock
    check classifyPin("seeded:2026-01-01") == pkSeeded
    check isSeededManifestHash("seeded:x")
    # Rows written before migration 011: a bare repo-manifest sha256.
    let legacy = sha256Hex("<manifest/>")
    check classifyPin(legacy) == pkLegacyRepoManifest
    check classifyPin(legacy.toUpperAscii) == pkLegacyRepoManifest
    for other in ["local", "h", "test:fixture",
                  WorkspacePinPrefix & "xyz", WorkspacePinPrefix & legacy & "0"]:
      check classifyPin(other) == pkUnrecognised

suite "REV-M5 workspace pin — capture":

  test "test_pin_is_stable_for_one_workspace_state":
    let ws = newReproWorkspace("pin_stable", ["repo-a", "repo-b"])
    defer: ws.cleanup()
    let first = captureWorkspacePin(ws.root)
    check classifyPin(first.pin) == pkWorkspaceLock
    check first.pin == pinOf(first.lockToml)
    check first.lockRecord == ""   # no record store in this workspace
    let lock = parseCanonicalLock(first.lockToml)
    check lock.project == ws.project
    check lock.repos.mapIt(it.path) == @["repo-a", "repo-b"]
    check lock.repos[0].revision == ws.headSha("repo-a")
    check lock.repos[1].revision == ws.headSha("repo-b")
    check lock.repos[0].remote == "repo-a-origin"
    check captureWorkspacePin(ws.root).pin == first.pin

  test "test_pin_differs_between_workspace_states":
    let ws = newReproWorkspace("pin_states", ["repo-a", "repo-b"])
    defer: ws.cleanup()
    let before = ws.headSha("repo-b")
    let pinA = captureWorkspacePin(ws.root)
    discard ws.commitAndPublish("repo-b", "move on", [("b.txt", "b\n")])
    let pinB = captureWorkspacePin(ws.root)
    check pinA.pin != pinB.pin
    check pinA.lockToml != pinB.lockToml
    # Back at the first state (detached at the published commit): the
    # same state yields the same pin again.
    discard git(["checkout", "-q", before], ws.repoDir("repo-b"))
    check captureWorkspacePin(ws.root).pin == pinA.pin

  test "test_pin_records_declared_but_absent_checkouts":
    let ws = newReproWorkspace("pin_absent", ["repo-a", "repo-b"])
    defer: ws.cleanup()
    removeDir(ws.repoDir("repo-b"))
    let lock = parseCanonicalLock(captureWorkspacePin(ws.root).lockToml)
    check lock.repos.mapIt(it.path) == @["repo-a"]
    check lock.unmaterialized.len == 1
    check lock.unmaterialized[0].path == "repo-b"
    check lock.unmaterialized[0].reason == NoCheckoutReason

  test "test_pin_refuses_states_it_must_not_describe":
    let ws = newReproWorkspace("pin_refuse", ["repo-a"])
    defer: ws.cleanup()
    writeFile(ws.repoDir("repo-a") / "README.md", "dirty\n")
    expect WorkspacePinError:
      discard captureWorkspacePin(ws.root)
    discard git(["checkout", "--", "README.md"], ws.repoDir("repo-a"))
    discard ws.commit("repo-a", "unpushed", [("u.txt", "u\n")])
    expect WorkspacePinError:
      discard captureWorkspacePin(ws.root)

  test "test_pin_covers_only_its_project":
    let ws = newReproWorkspace("pin_scope", ["repo-a"],
                               otherProject = "unrelated",
                               otherRepos = ["repo-z"])
    defer: ws.cleanup()
    let before = captureWorkspacePin(ws.root, ws.project)
    # An unpublished, dirty repo in the other project neither blocks the
    # pin nor changes it.
    discard ws.commit("repo-z", "local only", [("z.txt", "z\n")])
    writeFile(ws.repoDir("repo-z") / "README.md", "dirty\n")
    let pin = captureWorkspacePin(ws.root, ws.project)
    check pin.pin == before.pin
    let lock = parseCanonicalLock(pin.lockToml)
    check lock.project == ws.project
    check lock.scope == ProjectScope
    check lock.repos.mapIt(it.path) == @["repo-a"]
    check lock.unmaterialized.len == 0
    # The other project is pinned under its own name, and refused there.
    expect WorkspacePinError:
      discard captureWorkspacePin(ws.root, "unrelated")

  test "test_pin_names_the_published_reprobuild_record_and_matches_it":
    # Declared out of path order: reprobuild writes ``[[repo]]`` blocks in
    # declaration order, the pin in canonical (path) order.
    let ws = newReproWorkspace("pin_record", ["repo-b", "repo-a"])
    defer: ws.cleanup()
    ws.addRecordStore()
    discard ws.lockAndPublish()
    let pin = captureWorkspacePin(ws.root)
    let sha = ws.headSha("repo-a")
    # repro keys the record by its trigger repo; either repo may be it.
    check pin.lockRecord in [ws.project & "/repo-a@" & sha,
                             ws.project & "/repo-b@" & ws.headSha("repo-b")]
    # The pin is the reprobuild record minus provenance keys, with its
    # ``[[repo]]`` blocks in canonical order.  Nothing else is dropped:
    # every other line of the record must reappear verbatim.
    let parts = pin.lockRecord.split({'/', '@'})
    let recordPath = ws.recordStore / "locks" / parts[0] / parts[1] /
                     (parts[2] & ".toml")
    var stripped: seq[string]
    for line in readFile(recordPath).replace("\r\n", "\n").splitLines:
      if line.startsWith("created_at = ") or line.startsWith("created_by = ") or
         line.startsWith("workspace_branch = ") or line.startsWith("branch = "):
        continue
      stripped.add line
    proc sortedRepoBlocks(text: string): string =
      let chunks = text.strip().split("\n\n[[repo]]\n")
      var blocks = chunks[1 .. ^1]
      for b in blocks.mitems: b = b.strip()
      blocks.sort()
      chunks[0].strip() & "\n\n[[repo]]\n" & blocks.join("\n\n[[repo]]\n")
    let repoPart = pin.lockToml[0 ..< pin.lockToml.find("\n[extensions]")]
    check sortedRepoBlocks(stripped.join("\n")) == repoPart.strip()
    # Not vacuous: reprobuild's own order differs from the canonical one.
    check stripped.join("\n").strip() != repoPart.strip()
    # The record is advisory: identical state, identical pin.
    check pin.pin == captureWorkspacePin(ws.root).pin
    # Once the workspace moves past the record it is no longer named.
    discard ws.commitAndPublish("repo-a", "past the lock", [("p.txt", "p\n")])
    check captureWorkspacePin(ws.root).lockRecord == ""
