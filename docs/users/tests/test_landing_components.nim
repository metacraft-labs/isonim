## ../isonim/docs/users -- M3 verification (C-target only).
##
## Proves the WebFlow-equivalent landing and the FAQ page are authored on
## the M2 content components (hero / card grids / native `<details>` FAQ
## accordion) and the M1 need-help chrome, rendered through this site's own
## real `content/` dir and `renderRoute` shell -- the same path `just build`
## takes. Also pins the M3 framework prev/next fix: the pagination now
## renders AFTER `.docs-main`, not inside the nav region above the H1.

import std/[unittest, os, strutils]
import ../src/ssr

const repoRoot = currentSourcePath().parentDir().parentDir()
const contentDir = repoRoot / "content"

suite "IsoNim docs site -- M3 landing + FAQ components (Tier 3, C-target)":
  test "the home renders the WebFlow-equivalent landing: hero + Start-here/Popular card grids + need-help":
    let (status, html) = renderRoute("/", contentDir)
    check status == 200

    # Hero: H1 + subtitle + a primary and a secondary action button.
    check html.contains("class=\"docs-md-hero\"")
    check html.contains("class=\"docs-md-hero-title\"")
    check html.contains("class=\"docs-md-hero-subtitle\"")
    check html.contains("class=\"docs-md-button\" href=\"/getting-started\"")
    check html.contains("class=\"docs-md-button docs-md-button-secondary\"")

    # Two card grids (Start here + Popular articles) = 3 + 6 real cards, each
    # linking a real in-site route.
    check html.contains("class=\"docs-md-card-grid\"")
    check html.count("class=\"docs-md-card\"") == 9
    check html.contains("class=\"docs-md-card\" href=\"/guide/install-setup\"")
    check html.contains("class=\"docs-md-card\" href=\"/editor/overview\"")

    # Regression guard: card/button hrefs are resolved routes, never the raw
    # `.md` content paths (which the component directives do NOT rewrite).
    check not html.contains("getting-started.md")
    check not html.contains("install-setup.md")

    # The M1 "Need some help?" chrome block is present.
    check html.contains("class=\"docs-need-help\"")

    # M6 (framework): a landing (its body carries a `:::hero`) renders the
    # wider content column and DROPS the prev/next pager -- a landing is not
    # part of a linear article sequence, and the WebFlow home has none.
    check html.contains("class=\"docs-main docs-main--wide\"")
    check not html.contains("docs-nav-adjacent")

  test "the FAQ page renders a native <details>/<summary> accordion of real Q&A":
    let (status, html) = renderRoute("/faq", contentDir)
    check status == 200
    check html.contains("<h1 class=\"docs-md-title\">FAQ</h1>")
    check html.contains("class=\"docs-md-faq\"")
    # Every accordion item is a native, JS-free <details> disclosure.
    check html.count("<details class=\"docs-md-faq-item\">") >= 5
    check html.contains("<summary class=\"docs-md-faq-question\">What is IsoNim?</summary>")

  test "prev/next pagination renders AFTER the main content (M3 framework fix), not in the nav region":
    let (status, html) = renderRoute("/guide/install-setup", contentDir)
    check status == 200
    let mainClose = html.find("</main>")
    let adjacent = html.find("docs-nav-adjacent")
    check mainClose >= 0
    check adjacent >= 0
    # The pagination `<nav>` sits below `.docs-main`, so its only occurrence is
    # after the main region closes -- never above the H1 inside the nav column.
    check adjacent > mainClose
    check html.count("docs-nav-adjacent") == 1
    # M6 (framework): a normal article (no hero) keeps the narrow content column
    # -- the `.docs-main--wide` landing modifier is never added here.
    check not html.contains("docs-main--wide")
