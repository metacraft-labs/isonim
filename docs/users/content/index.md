# Welcome to isonim-docs

isonim-docs is a documentation-site framework built on top of IsoNim, the
isomorphic reactive UI framework for Nim. This page is the M0 proof-of-life
route: it is loaded from a real file in content/, rendered through the same
docs shell component under SSR (nim c) and in the browser (nim js), and its
exact title and body text are asserted by the MockRenderer, SSR, and
JS-mount test tiers alike.
