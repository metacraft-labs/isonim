## isonim/server/data_loading.nim
##
## Combines server functions with createResource for declarative data fetching.
##
## On C target (SSR): the server function executes synchronously, so the
## resource resolves immediately (state == rsReady) before the shell is rendered.
##
## On JS target (browser): the server function is an RPC stub, so
## createResource wraps it with loading/error states that integrate
## with Suspense boundaries.
##
## Usage:
##   proc getUser(id: int): User {.server.} =
##     db.query("SELECT * FROM users WHERE id = ?", id)
##
##   let user = createServerResource(proc(): User = getUser(42))
##   # SSR: user.state == rsReady, user.val is populated
##   # Browser: user.state == rsPending until RPC completes

import ../core/resource

proc createServerResource*[T](
    serverFn: proc(): T;
    initialValue: T = default(T)): Resource[T] =
  ## Creates a resource that fetches data via a server function.
  ##
  ## On C (SSR): calls the server function directly (synchronous).
  ## The resource is immediately in rsReady state, so renderToString
  ## produces HTML with the data already populated -- no Suspense needed.
  ##
  ## On JS (browser): the server function is already an RPC stub,
  ## so createResource wraps it with loading/error states. The resource
  ## starts as rsPending and transitions to rsReady when the RPC completes.
  createResource(serverFn, initialValue)

proc createServerResource*[S, T](
    source: proc(): S;
    serverFn: proc(s: S): T;
    initialValue: T = default(T)): Resource[T] =
  ## Creates a resource that refetches via a server function when the
  ## source signal changes.
  ##
  ## On C (SSR): the server function runs synchronously for the initial
  ## source value, producing an immediately-ready resource.
  ##
  ## On JS (browser): the resource refetches (via RPC) whenever the
  ## source value changes, with proper loading/error state tracking.
  createResource(source, serverFn, initialValue)
