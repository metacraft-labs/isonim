## REV-M8 — ``POST /api/design-review/promote-layout`` tests.

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

suite "REV-M8 promote-layout API":

  test "test_save_gallery_layout_workspace_promotion":
    let f = startServeAndSeed()
    defer: f.shutdown()
    let layoutId = seedUserLayout(f, "render.x", "alice", "foo")
    let promote = httpPost(f, "/api/design-review/promote-layout",
      "{\"layoutId\":\"" & layoutId & "\",\"actor\":\"alice\"}")
    check promote.code == 200
    let body = parseJson(promote.body)
    check body.hasKey("layout_id")
    check body["layout_id"].getStr != layoutId  # new row
    # The promoted (workspace) row must have scope=workspace, owner=NULL,
    # name and layout identical to the source.
    let cur = body["current"]
    check cur["scope"].getStr == "workspace"
    check cur["owner_user_id"].kind == JNull
    check cur["name"].getStr == "foo"
    # Source row (user-scope) is left untouched — list_layouts as alice
    # must still return BOTH the user-scope and the new workspace row.
    let ls = httpGet(f,
      "/api/design-review/list-layouts?briefId=render.x&userId=alice")
    check ls.code == 200
    let arr = parseJson(ls.body)
    check arr.kind == JArray
    check arr.len == 2

  test "test_promote_layout_404_when_layout_missing":
    let f = startServeAndSeed()
    defer: f.shutdown()
    let r = httpPost(f, "/api/design-review/promote-layout",
      "{\"layoutId\":\"00000000-0000-0000-0000-000000000000\",\"actor\":\"alice\"}")
    check r.code == 404

  test "test_promote_layout_400_when_layout_id_not_uuid":
    let f = startServeAndSeed()
    defer: f.shutdown()
    let r = httpPost(f, "/api/design-review/promote-layout",
      "{\"layoutId\":\"not-a-uuid\",\"actor\":\"alice\"}")
    check r.code == 400

  test "test_promote_layout_400_when_actor_missing":
    let f = startServeAndSeed()
    defer: f.shutdown()
    let layoutId = seedUserLayout(f, "render.x", "alice", "foo")
    let r = httpPost(f, "/api/design-review/promote-layout",
      "{\"layoutId\":\"" & layoutId & "\"}")
    check r.code == 400
