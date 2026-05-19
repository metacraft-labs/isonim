## REV-M8 — ``GET /api/design-review/list-layouts`` tests.

import std/[json, unittest]

import helpers/design_review_http_fixture

proc seedUserLayout(f: ServeFixture; briefId, user, name: string): string =
  let body = "{\"briefId\":\"" & briefId & "\",\"scope\":\"user\"," &
             "\"ownerUserId\":\"" & user & "\",\"name\":\"" & name &
             "\",\"layout\":{\"version\":1,\"entries\":[]}," &
             "\"expectedVersion\":null}"
  let r = httpPost(f, "/api/design-review/save-layout", body)
  doAssert r.code == 200, "seed failed: code=" & $r.code & " body=" & r.body
  parseJson(r.body)["layout_id"].getStr

proc seedAndPromote(f: ServeFixture; briefId, user, name: string): string =
  let l = seedUserLayout(f, briefId, user, name)
  let body = "{\"layoutId\":\"" & l & "\",\"actor\":\"" & user & "\"}"
  let r = httpPost(f, "/api/design-review/promote-layout", body)
  doAssert r.code == 200, "promote failed"
  parseJson(r.body)["layout_id"].getStr

suite "REV-M8 list-layouts API":

  test "test_list_layouts_visibility_rules":
    let f = startServeAndSeed()
    defer: f.shutdown()
    # User A saves user-scope layout L1; user A promotes L1 → workspace L2.
    let l1 = seedUserLayout(f, "render.x", "alice", "private")
    let l2 = seedAndPromote(f, "render.x", "alice", "shared")
    discard l1
    discard l2
    # Bob has his own (alice cannot see).
    discard seedUserLayout(f, "render.x", "bob", "bob-only")
    # alice → 4 rows: L1, the shared row alice promoted, the source of
    # the shared row, AND the workspace row.  Actually: alice sees
    # L1 (user, owner=alice), seed (user, owner=alice for promote),
    # promoted (workspace, owner=NULL).  Bob's user-scope is NOT visible.
    let aRsp = httpGet(f,
      "/api/design-review/list-layouts?briefId=render.x&userId=alice")
    check aRsp.code == 200
    let aArr = parseJson(aRsp.body)
    var aliceUserCount = 0
    var workspaceCount = 0
    for row in aArr:
      let scope = row["scope"].getStr
      if scope == "workspace":
        inc workspaceCount
      elif scope == "user":
        check row["owner_user_id"].getStr == "alice"
        inc aliceUserCount
    check workspaceCount >= 1
    check aliceUserCount == 2  # L1 + the source of L2
    # bob → workspace rows only (alice's user-scope rows hidden).
    let bRsp = httpGet(f,
      "/api/design-review/list-layouts?briefId=render.x&userId=bob")
    check bRsp.code == 200
    let bArr = parseJson(bRsp.body)
    var bobUserCount = 0
    var bobWorkspaceCount = 0
    for row in bArr:
      let scope = row["scope"].getStr
      if scope == "workspace": inc bobWorkspaceCount
      elif scope == "user":
        check row["owner_user_id"].getStr == "bob"
        inc bobUserCount
    check bobWorkspaceCount >= 1
    check bobUserCount == 1  # bob's own user-scope row

  test "test_list_layouts_missing_briefid_400":
    let f = startServeAndSeed()
    defer: f.shutdown()
    let r = httpGet(f, "/api/design-review/list-layouts")
    check r.code == 400

  test "test_list_layouts_empty_brief_returns_empty_array":
    let f = startServeAndSeed()
    defer: f.shutdown()
    let r = httpGet(f, "/api/design-review/list-layouts?briefId=render.empty")
    check r.code == 200
    let arr = parseJson(r.body)
    check arr.kind == JArray
    check arr.len == 0

  test "test_list_layouts_workspace_only_when_no_user":
    let f = startServeAndSeed()
    defer: f.shutdown()
    discard seedUserLayout(f, "render.y", "alice", "private")
    discard seedAndPromote(f, "render.y", "bob", "shared")
    # No userId param → workspace rows only.
    let r = httpGet(f, "/api/design-review/list-layouts?briefId=render.y")
    check r.code == 200
    let arr = parseJson(r.body)
    for row in arr:
      check row["scope"].getStr == "workspace"
