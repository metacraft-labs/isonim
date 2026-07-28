## ../isonim/docs/users -- this site's own `DocsConfig` + completeness
## matrix (M1 corrective deliverable 4: lifted wholesale from the
## framework's staging module, isonim-docs' now-removed `src/docs_site.nim`,
## once this consumer package existed to hold it).

import core/config
import core/completeness

proc isonimDocsConfig*(): DocsConfig =
  ## metacraft-theme M2 deliverable 4: CodeTracer branding for the
  ## Metacraft-internal docs build. `stylesheetHref` is kept unchanged so
  ## the SSG hash/purge pipeline (and its non-dangling guarantee) is
  ## untouched; the CodeTracer look is delivered by the token layer +
  ## `assets/style.css`, not by pointing at a different stylesheet.
  DocsConfig(
    siteTitle: "IsoNim",
    siteDescription: "Documentation for IsoNim -- the isomorphic reactive UI framework for Nim.",
    defaultRoute: "/",
    stylesheetHref: "/assets/style.css",
    # Published to GitHub project Pages (metacraft-labs.github.io/isonim), so the
    # site is served under the `/isonim` subpath: `baseUrl` carries it for
    # absolute canonical/sitemap URLs, and `basePath` prefixes every internal
    # root-relative URL the SSG emits (see isonim-docs `core/base_path`).
    baseUrl: "https://metacraft-labs.github.io/isonim",
    basePath: "/isonim",
    # The Metacraft docs THEME (Geist/accent/canvas token layer + assets/style.css)
    # is retained as the shared internal doc-site look; only the site IDENTITY is
    # IsoNim's. No `siteLogo`: the header renders the plain `.docs-title` text
    # ("IsoNim") -- IsoNim ships no wordmark here, and the CodeTracer mark must
    # not brand the framework's own docs. `footerHtml` fills the `.docs-footer`.
    footerHtml: "Built by <a href=\"https://github.com/metacraft-labs\">metacraft-labs</a> — 2026",
    # metacraft-theme-parity M1: the WebFlow-parity chrome, delivered through the
    # framework's optional default-off hooks (see isonim-docs
    # `core/config.DocsConfig` + `shell.nim`). Each is content-agnostic in the
    # framework; the CodeTracer-specific values live here in the consumer.
    #
    # Gap B (header nav buttons, WebFlow `.ct-nav-btn`). The FAQ button now
    # targets the real in-site `/faq` page authored in M3 (WebFlow points its
    # own FAQ nav button at the internal faq.html); Support stays external
    # (there is no in-site support page).
    headerLinks: @[
      (label: "Support", href: "https://github.com/metacraft-labs/isonim/issues"),
      (label: "FAQ", href: "/faq"),
    ],
    # Gap C (sidebar social links, WebFlow `.link-with-icon`) -- the vendored
    # `icon__github.svg` mark under `static/img/` (copied to `public/assets/img/`
    # by `build.nim`). Points at IsoNim's own repo; the CodeTracer Twitter is
    # dropped (IsoNim has no separate social handle).
    sidebarLinks: @[
      (label: "Github", href: "https://github.com/metacraft-labs/isonim",
       icon: "/assets/img/icon__github.svg"),
    ],
    # Gap C (toggle placement): render the theme toggle as a pill at the bottom
    # of the sidebar (WebFlow `.theme-switch`) instead of in the header.
    sidebarThemeToggle: true,
    # Content-page header parity: the page title becomes the big content `<h1>`
    # at the top of `.docs-main` (and drops out of the header), matching WebFlow.
    pageTitleInContent: true,
    # The WebFlow "Need some help?" block above the footer.
    needHelp: (heading: "Need some help?", links: @[
      (label: "Contact our support", href: "https://github.com/metacraft-labs/isonim/issues",
       icon: "/assets/img/icon__support.svg"),
      (label: "Frequently asked questions", href: "/faq",
       icon: "/assets/img/icon__faq.svg"),
    ]),
  )

proc isonimCompletenessMatrix*(): seq[CompletenessRequirement] =
  ## The M4 deliverable-2 topic list, each bound to the real route this
  ## site actually serves that topic's documentation at.
  @[
    CompletenessRequirement(topic: "install-setup", deliverableText: "install/setup",
      routePath: "/guide/install-setup",
      requiredHeadings: @["Prerequisites", "Sibling dev shell"], minWordCount: 80),
    CompletenessRequirement(topic: "reactive-core", deliverableText: "reactive core",
      routePath: "/guide/signals-effects",
      requiredHeadings: @["Creating a signal", "Reacting with effects"], minWordCount: 80),
    CompletenessRequirement(topic: "dsl-components", deliverableText: "DSL and components",
      routePath: "/guide/dsl",
      requiredHeadings: @["Basic elements", "Components"], minWordCount: 80),
    CompletenessRequirement(topic: "routing-ssr", deliverableText: "routing/SSR",
      routePath: "/guide/ssr-basics",
      requiredHeadings: @["renderRoute", "Route matching"], minWordCount: 80),
    CompletenessRequirement(topic: "testing-strategy", deliverableText: "testing strategy",
      routePath: "/guide/testing-strategy",
      requiredHeadings: @["Three tiers", "MockRenderer"], minWordCount: 80),
    CompletenessRequirement(topic: "editor-workspace-model", deliverableText: "editor workspace model",
      routePath: "/editor/workspace",
      requiredHeadings: @["EditorWorkspace", "Building a workspace"], minWordCount: 80),
    CompletenessRequirement(topic: "editor-browser-mount-contract", deliverableText: "browser mount contract",
      routePath: "/editor/browser-mount",
      requiredHeadings: @["mountEditor", "DOM contract"], minWordCount: 80),
    CompletenessRequirement(topic: "editor-consumer-integration", deliverableText: "consumer integration guides",
      routePath: "/editor/integration",
      requiredHeadings: @["Importing", "Project-owned data"], minWordCount: 80),
  ]
