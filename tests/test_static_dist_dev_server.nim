## Tests for the shared static-site live-reload dev server
## (`isonim/server/static_dist_dev_server`). Covers the RFC 6455 primitives
## against the spec's own vectors, the text-frame encoder's length prefixes,
## and the injected live-reload client placement.

import std/[unittest, strutils, os, tempfiles, tables, times]
import isonim/server/static_dist_dev_server

suite "static_dist_dev_server — RFC 6455 primitives":
  test "wsAcceptKey matches the RFC 6455 §1.3 worked example":
    # From RFC 6455 §1.3: client key "dGhlIHNhbXBsZSBub25jZQ==" must produce
    # accept "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=".
    check wsAcceptKey("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

  test "encodeWsTextFrame — short payload (<=125) uses 1-byte length":
    let f = encodeWsTextFrame("reload")
    check f[0] == chr(0x81)          # FIN + text opcode
    check f[1] == chr(6)             # length, no mask bit
    check f[2 .. ^1] == "reload"

  test "encodeWsTextFrame — 126..65535 payload uses 2-byte extended length":
    let payload = "x".repeat(200)
    let f = encodeWsTextFrame(payload)
    check f[0] == chr(0x81)
    check f[1] == chr(126)           # 16-bit extended length marker
    let len16 = (f[2].ord shl 8) or f[3].ord
    check len16 == 200
    check f[4 .. ^1] == payload

  test "encodeWsTextFrame — >65535 payload uses 8-byte extended length":
    let payload = "y".repeat(70000)
    let f = encodeWsTextFrame(payload)
    check f[0] == chr(0x81)
    check f[1] == chr(127)           # 64-bit extended length marker
    var n = 0
    for i in 2 .. 9: n = (n shl 8) or f[i].ord
    check n == 70000
    check f[10 .. ^1] == payload

  test "wsHandshakeResponse is a well-formed 101 upgrade":
    let r = wsHandshakeResponse("dGhlIHNhbXBsZSBub25jZQ==")
    check r.startsWith("HTTP/1.1 101 Switching Protocols\r\n")
    check "Upgrade: websocket\r\n" in r
    check "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" in r
    check r.endsWith("\r\n\r\n")

suite "static_dist_dev_server — injected browser bytes":
  test "injectLiveReload inserts the client before </body>":
    let html = "<html><body><h1>hi</h1></body></html>"
    let rendered = injectLiveReload(html, defaultLiveReloadPath)
    let bodyIdx = rendered.find("</body>")
    let scriptIdx = rendered.find("<script>")
    check scriptIdx >= 0
    check scriptIdx < bodyIdx          # script sits before the closing tag
    check defaultLiveReloadPath in rendered # the WS path is wired in

  test "injectLiveReload appends when there is no </body>":
    let rendered = injectLiveReload("<h1>fragment</h1>", "/ws")
    check rendered.startsWith("<h1>fragment</h1>")
    check "<script>" in rendered
    check "/ws" in rendered

  test "renderErrorOverlay carries the site name and escapes the message":
    let overlay = renderErrorOverlay("boom <tag> & more", "My Site")
    check "My Site" in overlay
    check "Static export failed" in overlay
    check "&lt;tag&gt;" in overlay      # message HTML-escaped
    check "&amp;" in overlay
    check "<script>" in overlay         # overlay keeps the live-reload client

suite "static_dist_dev_server — config constructor":
  test "newStaticDistDevServer applies the documented defaults":
    let s = newStaticDistDevServer(
      rebuildCommand = @["nim", "c", "src/static_export.nim"])
    check s.distDir == "dist"
    check s.watchRoots == @["src"]
    check s.liveReloadPath == defaultLiveReloadPath
    check s.reloadMessage == defaultReloadMessage
    check s.siteName == "isonim site"
    check ".nim" in s.watchExts

suite "static_dist_dev_server — source watcher":
  # Real files in a fresh temporary directory; no test doubles.
  test "a file root is watched on its own and an empty extension list watches every file":
    let root = createTempDir("isonim-watch-", "")
    defer: removeDir(root)
    createDir(root / "content")
    createDir(root / "out")
    writeFile(root / "site.toml", "title = 1\n")
    writeFile(root / "content/post.md", "a\n")
    writeFile(root / "content/_headers", "/*\n")
    writeFile(root / "out/index.html", "generated\n")
    let s = newStaticDistDevServer(rebuildCommand = @["true"],
      watchRoots = @[root / "site.toml", root / "content", root / "missing"],
      watchExts = @[])
    let first = s.snapshotSources()
    check first.len == 3
    check (root / "site.toml") in first
    check (root / "content/_headers") in first   # no extension, still watched
    check (root / "out/index.html") notin first  # not under a watch root
    # A re-timed file root and a newly created root are both changes.
    setLastModificationTime(root / "site.toml", fromUnix(1_000_000))
    let second = s.snapshotSources()
    check changed(first, second)
    check not changed(second, s.snapshotSources())
    createDir(root / "missing")
    writeFile(root / "missing/new.txt", "x\n")
    check changed(second, s.snapshotSources())

  test "a non-empty extension list still filters directories and file roots":
    let root = createTempDir("isonim-watch-", "")
    defer: removeDir(root)
    writeFile(root / "notes.md", "a\n")
    writeFile(root / "page.nim", "discard\n")
    let s = newStaticDistDevServer(rebuildCommand = @["true"],
      watchRoots = @[root, root / "notes.md"], watchExts = @[".nim"])
    let snapshot = s.snapshotSources()
    check snapshot.len == 1
    check (root / "page.nim") in snapshot
