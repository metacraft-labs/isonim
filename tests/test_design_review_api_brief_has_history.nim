## REV-M7 — ``GET /api/design-review/brief-has-history`` tests.

import std/[json, unittest]

import helpers/design_review_http_fixture

suite "REV-M7 brief-has-history API":

  test "test_api_brief_has_history_empty":
    let f = startServeAndSeed()
    defer: f.shutdown()
    let resp = httpGet(f,
        "/api/design-review/brief-has-history?briefId=render.empty")
    check resp.code == 200
    let body = parseJson(resp.body)
    check body["hasHistory"].getBool == false
    check body["runCount"].getInt == 0

  test "test_api_brief_has_history_populated":
    let f = startServeAndSeed()
    defer: f.shutdown()
    let cs = f.pg.connectionString
    for i in 0 ..< 5:
      discard seedRunInDb(cs, "render.populated", "h" & $i)
    let resp = httpGet(f,
        "/api/design-review/brief-has-history?briefId=render.populated")
    check resp.code == 200
    let body = parseJson(resp.body)
    check body["hasHistory"].getBool == true
    check body["runCount"].getInt == 5

  test "test_api_brief_has_history_missing_id_400":
    let f = startServeAndSeed()
    defer: f.shutdown()
    let resp = httpGet(f, "/api/design-review/brief-has-history")
    check resp.code == 400
