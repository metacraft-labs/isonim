## REV-M8 — ``POST /api/design-review/save-layout`` tests.
##
## All assertions run against the real ``isonim-review serve`` daemon
## spawned by the http fixture (which in turn boots ``PgFixture`` →
## userspace Postgres).  No mocks at the DB or HTTP boundary.

import std/[json, unittest, osproc, strutils]

import helpers/design_review_http_fixture

suite "REV-M8 save-layout API":

  test "test_save_gallery_layout_user_scope_default":
    let f = startServeAndSeed()
    defer: f.shutdown()
    let bodyJson = """
      {"briefId": "render.task-app",
       "scope": "user",
       "ownerUserId": "alice",
       "name": "default",
       "layout": {"version":1,"entries":[]},
       "expectedVersion": null}
    """
    let resp = httpPost(f, "/api/design-review/save-layout", bodyJson)
    check resp.code == 200
    let body = parseJson(resp.body)
    check body["version"].getInt == 1
    check body["scope"].getStr == "user"
    check body["owner_user_id"].getStr == "alice"
    check body["name"].getStr == "default"
    check body.hasKey("layout_id")

  test "test_save_gallery_layout_optimistic_concurrency_rejects_stale":
    let f = startServeAndSeed()
    defer: f.shutdown()
    # v1: INSERT.
    let r1 = httpPost(f, "/api/design-review/save-layout", """
      {"briefId":"render.x","scope":"user","ownerUserId":"alice",
       "name":"foo","layout":{"v":1},"expectedVersion":null}
    """)
    check r1.code == 200
    let layoutId = parseJson(r1.body)["layout_id"].getStr
    # v2: UPDATE with expectedVersion=1.
    let r2 = httpPost(f, "/api/design-review/save-layout", """
      {"briefId":"render.x","scope":"user","ownerUserId":"alice",
       "name":"foo","layout":{"v":2},"expectedVersion":1,
       "layoutId":"""" & layoutId & """"}
    """)
    check r2.code == 200
    check parseJson(r2.body)["version"].getInt == 2
    # v3: stale expectedVersion=1 — must 409.
    let r3 = httpPost(f, "/api/design-review/save-layout", """
      {"briefId":"render.x","scope":"user","ownerUserId":"alice",
       "name":"foo","layout":{"v":3},"expectedVersion":1,
       "layoutId":"""" & layoutId & """"}
    """)
    check r3.code == 409
    let conflictBody = parseJson(r3.body)
    check conflictBody["error"].getStr == "layout_version_conflict"
    check conflictBody.hasKey("current")
    # current row must surface the current version (2), not the stale 1.
    check conflictBody["current"]["version"].getInt == 2

  test "test_save_gallery_layout_jsonb_round_trips_unchanged":
    let f = startServeAndSeed()
    defer: f.shutdown()
    # Use a JSON object with annotations + filters + viewMode shape.
    let layoutJsonInput = """{"viewMode":"compact","annotations":[{"id":"a1","text":"hi"}],"filters":{"backends":["web","ios"]}}"""
    let saveBody = """{"briefId":"render.x","scope":"user","ownerUserId":"alice","name":"complex","layout":""" & layoutJsonInput & ""","expectedVersion":null}"""
    let r1 = httpPost(f, "/api/design-review/save-layout", saveBody)
    check r1.code == 200
    let returned = parseJson(r1.body)["layout"]
    # All keys preserved.
    check returned["viewMode"].getStr == "compact"
    check returned["annotations"].len == 1
    check returned["annotations"][0]["id"].getStr == "a1"
    check returned["filters"]["backends"].len == 2

  test "test_save_gallery_layout_missing_fields_400":
    let f = startServeAndSeed()
    defer: f.shutdown()
    let r = httpPost(f, "/api/design-review/save-layout",
                     """{"scope":"user","name":"x","layout":{}}""")
    check r.code == 400

  test "test_save_gallery_layout_concurrency_one_wins":
    let f = startServeAndSeed()
    defer: f.shutdown()
    let r1 = httpPost(f, "/api/design-review/save-layout", """
      {"briefId":"render.x","scope":"user","ownerUserId":"alice",
       "name":"foo","layout":{"v":1},"expectedVersion":null}
    """)
    check r1.code == 200
    let layoutId = parseJson(r1.body)["layout_id"].getStr
    # Two concurrent POSTs both targeting expectedVersion=1.  We
    # serialise them via the script: one must succeed, the other
    # must 409 (the routine guards via FOR UPDATE).
    let body = """{"briefId":"render.x","scope":"user","ownerUserId":"alice",
                  "name":"foo","layout":{"v":99},"expectedVersion":1,
                  "layoutId":"""" & layoutId & """"}"""
    let a = httpPost(f, "/api/design-review/save-layout", body)
    let b = httpPost(f, "/api/design-review/save-layout", body)
    var oneOk = false
    var oneConflict = false
    if a.code == 200: oneOk = true
    elif a.code == 409: oneConflict = true
    if b.code == 200:
      check oneOk == false  # only one 200
      oneOk = true
    elif b.code == 409:
      oneConflict = true
    check oneOk
    check oneConflict
