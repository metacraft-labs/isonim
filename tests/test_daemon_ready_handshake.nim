## Real process/socket/descriptor regressions for the shared READY reader.
## No mock objects are used. ready_handshake_peer.py is an explicitly limited
## protocol fixture: it controls malformed lines, fragmentation, flood and EOF
## so reader ownership is deterministic. Real IsoNim startup, optional producer
## preparation and REST sessions are covered by their separate integration tests.
import std/[httpclient, os, osproc, posix, strutils, tempfiles, times, unittest, json]
import helpers/daemon_ready_handshake
const Peer = currentSourcePath().parentDir / "helpers" / "ready_handshake_peer.py"

proc startPeer(mode, state: string): Process =
  startProcess(findExe("python3"), args = @[Peer, mode, state], options = {poUsePath})

proc fetchPeer(port: int) =
  let client = newHttpClient(timeout = 1000)
  defer: client.close()
  check client.getContent("http://127.0.0.1:" & $port & "/health") == "ok"

suite "Owned READY stderr lifecycle":
  test "bound port parser rejects incomplete, malformed and out of range records":
    for invalid in ["", "READY", "READY 0", "READY 65536", "READY 12x", "READY -1", "READY +1", "READY 123 extra", "READY 99999999999999999999"]:
      check parseReadyPort(invalid) == -1
    check parseReadyPort("READY 1") == 1
    check parseReadyPort("READY 65535") == 65535

  test "malformed real records cannot satisfy a real listening socket handshake":
    let peer = startPeer("malformed", "unused")
    let reader = startStderrDrainer(peer)
    defer: closeAfterDrainer(peer, reader)
    let port = waitForReady(reader)
    check reader.preReadyLines == @["READY 0", "READY 65536", "READY 123junk", "READY -1", "READY +1"]
    fetchPeer(port)
    check peer.waitForExit(1000) == 0

  test "fragmented READY after a two MiB flood preserves all ordered lines and EOF":
    let peer = startPeer("flood", "unused")
    let reader = startStderrDrainer(peer)
    defer: closeAfterDrainer(peer, reader)
    check getFilePermissions(reader.capturePath) == {fpUserRead, fpUserWrite}
    let port = waitForReady(reader)
    check reader.preReadyLines.len == 5000
    for i, line in reader.preReadyLines:
      check line == "noise " & $i & " " & repeat('x', 400)
    fetchPeer(port)
    check peer.waitForExit(1000) == 0
    # Wait for actual final EOF bytes before checking the private file.
    let deadline = epochTime() + 1
    while not readFile(reader.capturePath).endsWith("tail after ready\n") and epochTime() < deadline:
      sleep(5)
    check readFile(reader.capturePath).endsWith("tail after ready\n")

  test "early EOF includes the exact final partial Unicode line and reaps the child":
    let peer = startPeer("eof", "unused")
    let reader = startStderrDrainer(peer)
    defer: closeAfterDrainer(peer, reader)
    var refused = false
    try: discard waitForReady(reader, 0.5)
    except IOError as error:
      refused = true
      check "last Unicode line λ without newline" in error.msg
    check refused
    check peer.waitForExit(1000) == 3

  test "repeated close joins readers before freeing Process resources":
    for iteration in 0 ..< 24:
      let peer = startPeer("normal", "unused")
      let reader = startStderrDrainer(peer)
      fetchPeer(waitForReady(reader))
      check peer.waitForExit(1000) == 0
      closeAfterDrainer(peer, reader)
      check reader.stopped
      check not fileExists(reader.capturePath)
      reader.shutdown()                 # Idempotent after joined release.

  test "orphan continuous writer cannot extend readiness timeout or reader teardown":
    let directory = createTempDir("isonim-stderr-test-", "")
    defer: removeDir(directory)
    let state = directory / "writer.pid"
    let peer = startPeer("flood_timeout", state)
    let reader = startStderrDrainer(peer)
    var descendant: int
    defer:
      if descendant > 0: discard kill(Pid(descendant), SIGKILL)
      closeAfterDrainer(peer, reader)
    let stateDeadline = epochTime() + 1
    while not fileExists(state) and epochTime() < stateDeadline: sleep(5)
    check fileExists(state)
    descendant = parseInt(readFile(state))
    let started = epochTime()
    var refused = false
    try: discard waitForReady(reader, 0.2)
    except IOError as error:
      refused = true
      check "within 0.2s" in error.msg
      check error.msg.len < 1024 * 1024 + 1024
    check refused
    check epochTime() - started < 1.0
    discard peer.waitForExit(1000)
    reader.shutdown()
    check reader.stopped
    check kill(Pid(descendant), 0) == 0 # Reader stopped while writer still held fd.

  test "later subprocesses inherit neither private spool nor duplicated stderr handles":
    let directory = createTempDir("isonim-stderr-inherit-", "")
    defer: removeDir(directory)
    let peer = startPeer("normal", "unused")
    let reader = startStderrDrainer(peer)
    defer: closeAfterDrainer(peer, reader)
    let port = waitForReady(reader)
    var pipeInfo, captureInfo: Stat
    check fstat(cint(peer.errorHandle), pipeInfo) == 0
    check stat(reader.capturePath, captureInfo) == 0
    let wanted = $(%* [[uint64(pipeInfo.st_dev), uint64(pipeInfo.st_ino)],
      [uint64(captureInfo.st_dev), uint64(captureInfo.st_ino)]])
    let output = directory / "inherited.json"
    let probe = startProcess(findExe("python3"), args = @[Peer,
      "descriptor_probe", output, wanted], options = {poUsePath})
    defer: probe.close()
    check probe.waitForExit(1000) == 0
    check parseJson(readFile(output)) == newJArray()
    fetchPeer(port)
    check peer.waitForExit(1000) == 0

  test "repeated real lifecycle restores the process descriptor count":
    proc descriptorCount(): int =
      let descriptorDirectory = when defined(linux): "/proc/self/fd" else: "/dev/fd"
      for kind, path in walkDir(descriptorDirectory): inc result
    let before = descriptorCount()
    for iteration in 0 ..< 16:
      let peer = startPeer("normal", "unused")
      let reader = startStderrDrainer(peer)
      fetchPeer(waitForReady(reader))
      check peer.waitForExit(1000) == 0
      closeAfterDrainer(peer, reader)
    check descriptorCount() == before
