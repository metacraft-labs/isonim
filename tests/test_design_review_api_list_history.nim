## REV-M7 — ``GET /api/design-review/list-history`` tests.
##
## Boots the real ``isonim-review serve`` daemon against ``PgFixture``,
## seeds runs, queries the endpoint via ``std/httpclient``.  No mocks
## at the DB boundary or the transport.

import std/[algorithm, json, unittest]

import helpers/design_review_http_fixture

suite "REV-M7 list-history API":

  test "test_api_list_history_returns_runs_for_brief":
    let f = startServeAndSeed()
    defer: f.shutdown()
    let cs = f.pg.connectionString
    # Three runs for render.x and one for render.y.
    let r1 = seedRunInDb(cs, "render.x", "h1")
    let r2 = seedRunInDb(cs, "render.x", "h2")
    let r3 = seedRunInDb(cs, "render.x", "h3")
    discard seedRunInDb(cs, "render.y", "h4")
    check r1.len == 36
    check r2.len == 36
    check r3.len == 36
    let resp = httpGet(f, "/api/design-review/list-history?briefId=render.x")
    check resp.code == 200
    let body = parseJson(resp.body)
    check body.kind == JArray
    check body.len == 3
    # Most-recent-first ordering on started_at DESC.  The seed order
    # is r1, r2, r3 so the response array is [r3, r2, r1].
    let ids = @[
      body[0]["run_id"].getStr,
      body[1]["run_id"].getStr,
      body[2]["run_id"].getStr]
    check ids[0] == r3
    check ids[1] == r2
    check ids[2] == r1

  test "test_api_list_history_pagination":
    let f = startServeAndSeed()
    defer: f.shutdown()
    let cs = f.pg.connectionString
    var ids: seq[string] = @[]
    for i in 0 ..< 25:
      ids.add seedRunInDb(cs, "render.page", "h" & $i)
    # Sleep is unnecessary — started_at uses NOW() which monotonically
    # advances across these synchronous psql calls.
    let resp = httpGet(f, "/api/design-review/list-history" &
                       "?briefId=render.page&limit=10&offset=10")
    check resp.code == 200
    let body = parseJson(resp.body)
    check body.kind == JArray
    check body.len == 10
    # Expected: descending started_at → ids[14..5] (offset 10 from 25-
    # element descending list).  ids[24] is most recent; offset 10
    # skips ids[14..24], so we get ids[4..13] in descending order.
    let expectedDescending = block:
      var rev = ids
      rev.reverse()
      rev
    for i in 0 ..< 10:
      check body[i]["run_id"].getStr == expectedDescending[10 + i]

  test "test_api_list_history_missing_briefid_400":
    let f = startServeAndSeed()
    defer: f.shutdown()
    let resp = httpGet(f, "/api/design-review/list-history")
    check resp.code == 400
    let body = parseJson(resp.body)
    check body.hasKey("error")
