## REV-M7 — ``GET /api/design-review/fetch-run`` tests.

import std/[json, unittest]

import helpers/design_review_http_fixture

suite "REV-M7 fetch-run API":

  test "test_api_fetch_run_returns_assembled_run":
    let f = startServeAndSeed()
    defer: f.shutdown()
    let cs = f.pg.connectionString
    let runId = seedRunInDb(cs, "render.assembled", "hAss")
    # Three captures + two agent reports.
    discard seedCaptureInDb(cs, runId, "p1/a:page#0@web",
                            "web", "tablet", "sha1", "/p/1", 100, 100)
    discard seedCaptureInDb(cs, runId, "p2/b:page#0@web",
                            "web", "tablet", "sha2", "/p/2", 100, 100)
    discard seedCaptureInDb(cs, runId, "p3/c:page#0@web",
                            "web", "tablet", "sha3", "/p/3", 100, 100)
    finishCapturesInDb(cs, runId)
    discard seedAgentReportInDb(cs, runId, "claude", "v1",
                                "/raw/1", "{}")
    discard seedAgentReportInDb(cs, runId, "gpt", "v1",
                                "/raw/2", "{}")
    let resp = httpGet(f,
        "/api/design-review/fetch-run?runId=" & runId)
    check resp.code == 200
    let body = parseJson(resp.body)
    check body.kind == JObject
    check body["run_id"].getStr == runId
    check body["brief_id"].getStr == "render.assembled"
    check body.hasKey("captures")
    check body["captures"].kind == JArray
    check body["captures"].len == 3
    check body.hasKey("reports")
    check body["reports"].kind == JArray
    check body["reports"].len == 2

  test "test_api_fetch_run_missing_id_400":
    let f = startServeAndSeed()
    defer: f.shutdown()
    let resp = httpGet(f, "/api/design-review/fetch-run")
    check resp.code == 400

  test "test_api_fetch_run_unknown_id_404":
    let f = startServeAndSeed()
    defer: f.shutdown()
    let resp = httpGet(f,
        "/api/design-review/fetch-run?runId=00000000-0000-0000-0000-000000000000")
    check resp.code == 404
