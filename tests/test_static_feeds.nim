## isonim/static/feeds on C and JS, without test doubles: the real writers,
## checked against published oracles (RFC 3986 §5.4's resolution examples,
## known calendar weekdays) and byte goldens. The goldens were parsed with
## an independent conforming XML parser (Python's expat-based ElementTree)
## when written, and the structural assertions below repeat what matters.
import std/[unittest, strutils]
import isonim/static/feeds

const base = "http://a/b/c/d;p?q"

proc sampleFeed(): Feed =
  Feed(title: "Notes & Sketches", subtitle: "A <small> notebook",
    siteUrl: "https://example.org/", feedUrl: "https://example.org/atom.xml",
    language: "en", authors: @[FeedPerson(name: "Ada", uri: "https://example.org/about/")],
    generator: "test", entries: @[
      FeedEntry(title: "Second", url: "https://example.org/posts/second/",
        published: "2020-02-02", updated: "2020-03-01",
        contentHtml: "<p>Two ]]> <a href=\"https://example.org/posts/first/\">x</a></p>",
        categories: @["nim", "a&b"]),
      FeedEntry(title: "First", url: "https://example.org/posts/first/",
        published: "2020-01-01T10:20:30+02:00", summary: "<p>One</p>",
        contentHtml: "<p>One, longer</p>")])

suite "feed URL resolution":
  test "RFC 3986 section 5.4.1 normal examples":
    for (reference, expected) in [
        ("g:h", "g:h"), ("g", "http://a/b/c/g"), ("./g", "http://a/b/c/g"),
        ("g/", "http://a/b/c/g/"), ("/g", "http://a/g"), ("//g", "http://g"),
        ("?y", "http://a/b/c/d;p?y"), ("g?y", "http://a/b/c/g?y"),
        ("#s", "http://a/b/c/d;p?q#s"), ("g#s", "http://a/b/c/g#s"),
        ("g?y#s", "http://a/b/c/g?y#s"), (";x", "http://a/b/c/;x"),
        ("g;x", "http://a/b/c/g;x"), ("g;x?y#s", "http://a/b/c/g;x?y#s"),
        (".", "http://a/b/c/"), ("./", "http://a/b/c/"), ("..", "http://a/b/"),
        ("../", "http://a/b/"), ("../g", "http://a/b/g"), ("../..", "http://a/"),
        ("../../", "http://a/"), ("../../g", "http://a/g")]:
      check resolveUrl(base, reference) == expected

  test "RFC 3986 section 5.4.2 abnormal examples":
    for (reference, expected) in [
        ("../../../g", "http://a/g"), ("../../../../g", "http://a/g"),
        ("/./g", "http://a/g"), ("/../g", "http://a/g"), ("g.", "http://a/b/c/g."),
        (".g", "http://a/b/c/.g"), ("g..", "http://a/b/c/g.."), ("..g", "http://a/b/c/..g"),
        ("./../g", "http://a/b/g"), ("./g/.", "http://a/b/c/g/"),
        ("g/./h", "http://a/b/c/g/h"), ("g/../h", "http://a/b/c/h"),
        ("g;x=1/./y", "http://a/b/c/g;x=1/y"), ("g;x=1/../y", "http://a/b/c/y"),
        ("g?y/./x", "http://a/b/c/g?y/./x"), ("g#s/../x", "http://a/b/c/g#s/../x")]:
      check resolveUrl(base, reference) == expected

  test "HTML references become absolute; everything else is byte for byte":
    let html = "<p class=\"a\">Text with href=\"/no\" <!-- <a href=\"/c\"> -->" &
      "<a href=\"/posts/x/#h\" title='/t'>l</a><img src='fig.svg' alt=\"/a\">" &
      "<img srcset=\"/a.png 1x, b.png 2x\" src=x.png><a HREF=#top>t</a>" &
      "<a href=\"https://other.example/y\">o</a><a href=\"mailto:a@b\">m</a></p>"
    check absoluteHtmlUrls(html, "https://example.org/posts/x/") ==
      "<p class=\"a\">Text with href=\"/no\" <!-- <a href=\"/c\"> -->" &
      "<a href=\"https://example.org/posts/x/#h\" title='/t'>l</a>" &
      "<img src='https://example.org/posts/x/fig.svg' alt=\"/a\">" &
      "<img srcset=\"https://example.org/a.png 1x, https://example.org/posts/x/b.png 2x\" " &
      "src=https://example.org/posts/x/x.png><a HREF=https://example.org/posts/x/#top>t</a>" &
      "<a href=\"https://other.example/y\">o</a><a href=\"mailto:a@b\">m</a></p>"
    # Positive control: unchanged input when nothing is relative.
    let absolute = "<a href=\"https://example.org/\">x</a>"
    check absoluteHtmlUrls(absolute, "https://example.org/a/") == absolute
    expect FeedError: discard absoluteHtmlUrls(html, "/relative/base/")

suite "feed dates":
  test "RFC 822 weekdays and zones match the calendar":
    check rfc822Date("2020-01-01") == "Wed, 01 Jan 2020 00:00:00 +0000"
    check rfc822Date("2000-02-29") == "Tue, 29 Feb 2000 00:00:00 +0000"
    check rfc822Date("1970-01-01T00:00Z") == "Thu, 01 Jan 1970 00:00:00 +0000"
    check rfc822Date("2026-10-25T13:14:15.75-03:30") == "Sun, 25 Oct 2026 13:14:15 -0330"
    check rfc3339Date("2020-01-01") == "2020-01-01T00:00:00Z"
    check rfc3339Date("2020-01-01T10:20+02:00") == "2020-01-01T10:20:00+02:00"
    check rfc3339Date("2020-01-01T10:20:30.5Z") == "2020-01-01T10:20:30.5Z"
    for bad in ["2020-02-30", "2020-01-01T10:20", "01/01/2020", ""]:
      expect FeedError: discard rfc822Date(bad)

suite "feed writers":
  test "Atom golden bytes and structure":
    let atom = renderAtom(sampleFeed())
    check atom == """<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xml:lang="en">
  <title>Notes &amp; Sketches</title>
  <subtitle>A &lt;small&gt; notebook</subtitle>
  <link rel="alternate" type="text/html" href="https://example.org/"/>
  <link rel="self" type="application/atom+xml" href="https://example.org/atom.xml"/>
  <id>https://example.org/atom.xml</id>
  <updated>2020-03-01T00:00:00Z</updated>
  <author><name>Ada</name><uri>https://example.org/about/</uri></author>
  <generator>test</generator>
  <entry>
    <title>Second</title>
    <link rel="alternate" type="text/html" href="https://example.org/posts/second/"/>
    <id>https://example.org/posts/second/</id>
    <published>2020-02-02T00:00:00Z</published>
    <updated>2020-03-01T00:00:00Z</updated>
    <category term="nim"/>
    <category term="a&amp;b"/>
    <content type="html">&lt;p&gt;Two ]]&gt; &lt;a href=&quot;https://example.org/posts/first/&quot;&gt;x&lt;/a&gt;&lt;/p&gt;</content>
  </entry>
  <entry>
    <title>First</title>
    <link rel="alternate" type="text/html" href="https://example.org/posts/first/"/>
    <id>https://example.org/posts/first/</id>
    <published>2020-01-01T10:20:30+02:00</published>
    <updated>2020-01-01T10:20:30+02:00</updated>
    <summary type="html">&lt;p&gt;One&lt;/p&gt;</summary>
    <content type="html">&lt;p&gt;One, longer&lt;/p&gt;</content>
  </entry>
</feed>
"""

  test "RSS golden bytes and structure":
    let rss = renderRss(sampleFeed())
    check rss == """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" xmlns:content="http://purl.org/rss/1.0/modules/content/">
<channel>
  <title>Notes &amp; Sketches</title>
  <link>https://example.org/</link>
  <description>A &lt;small&gt; notebook</description>
  <atom:link rel="self" type="application/rss+xml" href="https://example.org/atom.xml"/>
  <language>en</language>
  <lastBuildDate>Sun, 01 Mar 2020 00:00:00 +0000</lastBuildDate>
  <generator>test</generator>
  <item>
    <title>Second</title>
    <link>https://example.org/posts/second/</link>
    <guid isPermaLink="true">https://example.org/posts/second/</guid>
    <pubDate>Sun, 02 Feb 2020 00:00:00 +0000</pubDate>
    <category>nim</category>
    <category>a&amp;b</category>
    <description>&lt;p&gt;Two ]]&gt; &lt;a href=&quot;https://example.org/posts/first/&quot;&gt;x&lt;/a&gt;&lt;/p&gt;</description>
    <content:encoded>&lt;p&gt;Two ]]&gt; &lt;a href=&quot;https://example.org/posts/first/&quot;&gt;x&lt;/a&gt;&lt;/p&gt;</content:encoded>
  </item>
  <item>
    <title>First</title>
    <link>https://example.org/posts/first/</link>
    <guid isPermaLink="true">https://example.org/posts/first/</guid>
    <pubDate>Wed, 01 Jan 2020 10:20:30 +0200</pubDate>
    <description>&lt;p&gt;One&lt;/p&gt;</description>
    <content:encoded>&lt;p&gt;One, longer&lt;/p&gt;</content:encoded>
  </item>
</channel>
</rss>
"""
    # Entries keep the caller's order; reversing the input reverses the items.
    var reversedFeed = sampleFeed()
    reversedFeed.entries = @[reversedFeed.entries[1], reversedFeed.entries[0]]
    let reversedRss = renderRss(reversedFeed)
    check reversedRss.find("<title>First</title>") < reversedRss.find("<title>Second</title>")

  test "invalid feeds are refused instead of written":
    var feed = sampleFeed()
    feed.entries[0].url = "/posts/second/"
    expect FeedError: discard renderAtom(feed)
    expect FeedError: discard renderRss(feed)
    feed = sampleFeed()
    feed.feedUrl = "atom.xml"
    expect FeedError: discard renderRss(feed)
    feed = sampleFeed()
    feed.entries[1].published = "2020-13-01"
    expect FeedError: discard renderAtom(feed)
    feed = sampleFeed()
    feed.entries[0].title = ""
    expect FeedError: discard renderRss(feed)
    feed = sampleFeed()
    feed.entries[0].contentHtml = "form\ffeed"
    expect FeedError: discard renderAtom(feed)
    # Atom needs an author somewhere (RFC 4287 section 4.1.1)...
    feed = sampleFeed()
    feed.authors = @[]
    expect FeedError: discard renderAtom(feed)
    # ...and an entry-level author satisfies it.
    for entry in feed.entries.mitems: entry.authors = @[FeedPerson(name: "Bo")]
    check renderAtom(feed).count("<author><name>Bo</name></author>") == 2
    # An empty feed has no newest entry to date it.
    feed = sampleFeed()
    feed.entries = @[]
    expect FeedError: discard renderAtom(feed)
    feed.updated = "2020-01-01"
    check renderAtom(feed).contains("<updated>2020-01-01T00:00:00Z</updated>")

  test "discovery links escape their attributes":
    check feedLinkHtml("https://example.org/a.xml?x=1&y=2", atomMediaType, "A \"feed\"") ==
      "<link rel=\"alternate\" type=\"application/atom+xml\" title=\"A &quot;feed&quot;\" " &
      "href=\"https://example.org/a.xml?x=1&amp;y=2\" />"
    check isAbsoluteHttpUrl("https://example.org")
    for bad in ["https:/x", "ftp://example.org/", "//example.org/", "https://", "https:// x/"]:
      check not isAbsoluteHttpUrl(bad)
