## Pure metadata checked on C and JS, without test doubles.
import std/[unittest, strutils, json, algorithm]
import isonim/static/[sitemap, head, buildinfo, robots, urls]
suite "static metadata boundaries":
  test "calendar and timezone components must be valid":
    for date in ["2026-02-31", "2026-02-29", "2026-04-31", "2026-10-21T12:00+99:99"]:
      check not isW3cDatetime(date)
  test "JSON encodes every control byte":
    for n in 0..31:
      let quoted = jsonLdString($char(n))
      check char(n) notin quoted
  test "tree hash orders sha256sum lines by path":
    let files = @[("a", "Z"), ("z", "A")]
    let listing = sha256Hex("Z") & "  a\n" & sha256Hex("A") & "  z\n"
    check treeHashOf(files) == "sha256-" & sha256Hex(listing)

  test "JSON parse round trips controls in metadata and JSON-LD":
    var data = "</script>\"\\雪"
    for n in 0..31: data.add char(n)
    check parseJson(jsonLdString(data)).getStr == data
    let record = SiteBuildInfo(generator: data, sourceRevision: data,
      components: @[BuildComponent(name: data, revision: data)], outputHash: data)
    let decoded = parseJson(renderBuildJson(record))
    check decoded["generator"].getStr == data
    check decoded["sourceRevision"].getStr == data
    check decoded["components"][0]["name"].getStr == data
    check decoded["components"][0]["revision"].getStr == data
    check decoded["outputHash"].getStr == data
    check "</script>" notin renderBuildJson(record)
  test "calendar boundaries and zone ranges":
    for date in ["1900-02-29", "0000-01-01", "2026-10-21T12:00+24:00", "2026-10-21T12:00+00:60"]:
      check not isW3cDatetime(date)
    for date in ["2000-02-29", "2024-02-29", "2026-02-28", "2026-04-30", "2026-10-21T12:00-23:59"]:
      check isW3cDatetime(date)
  test "independent path-sorted tree hash golden":
    # Python hashlib.sha256 over sha256(content) + '  ' + path + '\n',
    # in path order a then z. Digest order deliberately differs.
    let files = @[("a", "Z"), ("z", "A")]
    check treeHashOf(files) == "sha256-f6ba91820b2aaec30fc9258782e3c735fa400462d27395f859ad079ada681f36"
    check treeHashOf(files.reversed) == "sha256-f6ba91820b2aaec30fc9258782e3c735fa400462d27395f859ad079ada681f36"
  test "sitemap and robots bytes and injection rejection":
    check renderSitemap([sitemapEntry("https://example.org", "/a&b", "2024-02-29")]).contains(
      "<loc>https://example.org/a&amp;b</loc><lastmod>2024-02-29</lastmod>")
    check renderRobots("/sitemap.xml") == "User-agent: *\nAllow: /\nSitemap: /sitemap.xml\n"
    check renderRobots([RobotsGroup(userAgent: "ExampleBot", disallow: @["/drafts/"])]).contains(
      "User-agent: ExampleBot\nDisallow: /drafts/\n")
    expect ValueError:
      discard renderRobots([RobotsGroup(userAgent: "*", disallow: @["/a\nAllow: /"])])

  test "tree listings cannot inject a second file through a newline in a name":
    let ordinary = @[("a", "A"), ("b", "B")]
    let injected = "a\n" & sha256Hex("B") & "  b"
    check treeHashOf(ordinary) != treeHashOf(@[(injected, "A")])
  test "exceptional names use sha256sum escaping and its leading marker":
    # Generated independently with GNU sha256sum plus Python hashlib.
    check treeHashOf(@[("a\nb", "A")]) == "sha256-de626d4829e81448ef67dd2adef6fbfa9cd875a44715f8a8ee7a22b2d023c6c5"
    check treeHashOf(@[("a\\b", "A")]) == "sha256-3a9e38cf3ecd3532353d78792266a2c1f7dca21c9a6eafccd158e9a0167d52f8"
    check treeHashOf(@[("a\rb", "A")]) == "sha256-7dcb921bf1704bf0b60cb37331b0797997fb64b5f348f479cbe2e7f167bdbf9a"

  test "W3C datetime seconds stop at 59, including fractional seconds":
    # NOTE-datetime defines ss as 00 through 59. The earlier positive
    # leap-second vector was incorrect for this explicitly adopted profile.
    for zone in ["Z", "+02:00", "-05:00"]:
      for fraction in ["", ".5"]:
        let good = "2026-10-21T23:59:59" & fraction & zone
        let bad = "2026-10-21T23:59:60" & fraction & zone
        check isW3cDatetime(good)
        check renderSitemap([SitemapEntry(loc: "/", lastmod: good)]).contains(good)
        check not isW3cDatetime(bad)
        expect SitemapError:
          discard renderSitemap([SitemapEntry(loc: "/", lastmod: bad)])

suite "web origins":
  test "webOrigin serialises http(s) origins and refuses everything else":
    # RFC 6454 §6.2: lower-case scheme and host, the default port left out.
    check webOrigin("https://cdn.example.net/a/b.png?x#y") == "https://cdn.example.net"
    check webOrigin("HTTPS://CDN.Example.NET:443/a.png") == "https://cdn.example.net"
    check webOrigin("http://example.org:80") == "http://example.org"
    check webOrigin("http://example.org:8080/x") == "http://example.org:8080"
    check webOrigin("https://example.org.:8443") == "https://example.org:8443"
    check webOrigin("https://[2001:db8::1]:444/x") == "https://[2001:db8::1]:444"
    for other in ["/assets/a.png", "a.png", "//cdn.example.net/a.png", "data:image/png;base64,AA",
        "ftp://example.org/a.png", "https://user@example.org/a.png", "https:///a.png",
        "https://exa_mple.org/", "https://example.org:0/", "https://example.org:65536/",
        "https://example.org:8x/", "https://-example.org/", "https://[zz]/", ""]:
      check webOrigin(other) == ""

  test "parseWebOrigin accepts an origin with at most a trailing slash":
    check parseWebOrigin("https://CDN.example.net/") == "https://cdn.example.net"
    check parseWebOrigin("http://localhost:4000") == "http://localhost:4000"
    for bad in ["https://cdn.example.net/images", "https://cdn.example.net?x", "https://cdn.example.net#x",
        "cdn.example.net", "//cdn.example.net", "ftp://cdn.example.net", "https://a@cdn.example.net", ""]:
      expect ValueError: discard parseWebOrigin(bad)
