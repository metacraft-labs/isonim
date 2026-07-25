## ../isonim/docs/users -- this site's own `DocsConfig` + completeness
## matrix (M1 corrective deliverable 4: lifted wholesale from the
## framework's staging module, isonim-docs' now-removed `src/docs_site.nim`,
## once this consumer package existed to hold it).

import core/config
import core/completeness

proc isonimDocsConfig*(): DocsConfig =
  DocsConfig(
    siteTitle: "IsoNim Docs",
    siteDescription: "Documentation for the IsoNim isomorphic reactive web framework.",
    defaultRoute: "/",
    stylesheetHref: "/assets/style.css",
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
