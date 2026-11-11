## isonim/routing/navigator.nim
##
## The target of client navigation: what `navigate` (navigate.nim) and the
## `Link` component call, and so what the typed route manifest's generated
## `<name>Navigate` and `<name>Link` helpers reach (manifest.nim).
##
## `createRouter` installs its router here, so an application that renders
## through IsoNim's `Router` needs nothing more. An application that renders
## its own pages (it matches the manifest's patterns itself and swaps an
## `Outlet`, with history.nim's `pushPath`) installs its own navigator with
## `setNavigator`, and the generated helpers then drive it, without the
## `Router` and its signals being compiled into the application.
##
## One navigator is active at a time: the last one installed (by
## `setNavigator` or by `createRouter`). Without one, a navigation does
## nothing.
##
## No dependency on the router, the DOM or the target: this module is a
## variable and its two accessors.

type
  Navigator* = proc (path: string; replace: bool) {.closure.}
    ## Shows `path` (a path with an optional query): pushes it onto the
    ## browser history, or replaces the current entry when `replace` is true,
    ## and renders the page.

var activeNavigator: Navigator

proc setNavigator*(navigator: Navigator) =
  ## Makes `navigator` the target of every client navigation (module doc);
  ## nil removes it.
  activeNavigator = navigator

proc currentNavigator*(): Navigator =
  ## The active navigator, nil when none is installed.
  activeNavigator
