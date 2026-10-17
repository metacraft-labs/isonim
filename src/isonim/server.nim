## isonim/server — Server functions.
##
## Re-exports the `{.server.}` / `{.action.}` pragmas, the request context
## and policies, the RPC registry and dispatch (C) or the `fetch` client
## (JS), form helpers and `createServerResource`.
##
## Inside ngx-isonim, which builds with `-d:asyncBackend=nginx`, import
## `isonim/server/[pragma, rpc]` instead: `createServerResource` builds on
## `isonim/core/resource`, which needs an asyncdispatch or chronos backend.

import isonim/server/[pragma, rpc, context, policy, form_action, data_loading]
export pragma, rpc, context, policy, form_action, data_loading
