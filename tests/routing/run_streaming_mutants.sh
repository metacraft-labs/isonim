#!/usr/bin/env bash
#
# The falsifying mutations of tests/routing/t_manifest_streaming.nim
# (IFP-M30).  Each mutant is the nginx fixture's module built from a copy of
# src/ with exact text replacements; the test (built from this checkout)
# runs against it (ISONIM_NGINX_MODULE) and must FAIL, at the test named for
# the mutant.  Exits 0 when every mutant is caught.
#
#   headers-after-flush   the milestone's mutation: a streaming page's
#                         headers (content type, page headers, cache policy)
#                         applied after its first flush, when the response
#                         is already committed: the shell goes out without
#                         them.
#   hook-after-commit     serverHooks.pageHeaders run after the commit point
#                         instead of before it: the shell has no CSP.
#   override-after-commit setCachePolicy without the commit-point check: a
#                         change after the shell is accepted although the
#                         headers were sent with the old policy.
#   json-streamed         a streaming page's JSON variant streamed like its
#                         HTML (its stream not discarding).
#   bootstrap-without-nonce
#                         the hydration bootstrap written without the
#                         response's nonce: the CSP header's nonce is not
#                         the script's.
#   redirect-writes-shell a redirect before the commit point answered like
#                         a page: the dispatch writes the queued HTML, the
#                         page data and the tail.
#   redirect-without-policy
#                         a redirect before the commit point answered
#                         without the response's cache policy.
#   flush-on-redirect     page.flush() on a redirected response commits it
#                         instead of raising ValueError.
#   bad-request-is-500    RpcBadRequest before the commit point answered as
#                         an internal error (500) instead of 400.
#   custom-tail-ignored   the dispatch writes the default tail, whatever
#                         page.tail the handler set.
#
# The buffered-* mutants are of t_manifest_streaming_buffered.nim, the
# host without a writer (in-process): that test is built against a mutated
# copy of src/ and must fail at the test named for the mutant.  The same
# build of the unmutated src/ must pass first (the positive control of the
# build flags).
#
#   buffered-hook-without-writer
#                         serverHooks.pageHeaders skipped when the host
#                         provides no writer: the committed shell has no CSP.
#   buffered-not-committed
#                         the response left uncommitted at the first flush
#                         on such a host: its setters still work after it.
#
# Needs what tests/nginx/build_fixture.sh needs (the ngx-isonim sibling,
# nix); run inside the dev shell, as `just test-nginx` does.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/isonim-streaming-mutants.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

mutate() {
  # mutate <file> <original> <replacement> [<original> <replacement> ...]:
  # each original exactly once.
  python3 - "$@" <<'PY'
import sys
path, pairs = sys.argv[1], sys.argv[2:]
text = open(path).read()
for old, new in zip(pairs[0::2], pairs[1::2]):
    n = text.count(old)
    if n != 1:
        sys.exit(f"mutation of {path}: expected one occurrence, found {n}:\n{old}")
    text = text.replace(old, new)
open(path, "w").write(text)
PY
}

(cd "${ROOT}" && nim c --hints:off -d:isonimRpcPrefix=/api/v1/rpc \
  -o:"${WORK}/t_manifest_streaming" tests/routing/t_manifest_streaming.nim) \
  >"${WORK}/test-build.log" 2>&1 ||
  { tail -30 "${WORK}/test-build.log"; exit 1; }

caught=0
missed=0

# streaming_mutant <name> <failing test> <file under src/> <original> <replacement> [...]
streaming_mutant() {
  local name="$1" expect="$2" file="$3"
  shift 3
  rm -rf "${WORK}/${name}-src"
  cp -r "${ROOT}/src" "${WORK}/${name}-src"
  mutate "${WORK}/${name}-src/${file}" "$@"
  ISONIM_FIXTURE_SRC="${WORK}/${name}-src" ISONIM_FIXTURE_OUT="${WORK}/${name}" \
    bash "${ROOT}/tests/nginx/build_fixture.sh" --module-only >"${WORK}/${name}-build.log" 2>&1 ||
    { tail -30 "${WORK}/${name}-build.log"; exit 1; }
  if ISONIM_NGINX_MODULE="${WORK}/${name}/ngx_http_isonim_module.so" \
      "${WORK}/t_manifest_streaming" >"${WORK}/${name}.log" 2>&1; then
    echo "MISSED ${name}: t_manifest_streaming passed"
    missed=$((missed + 1))
  elif grep -qF "[FAILED] ${expect}" "${WORK}/${name}.log"; then
    echo "caught ${name}: [FAILED] ${expect}"
    caught=$((caught + 1))
  else
    echo "${name}: the test failed, but not at '${expect}':"
    cat "${WORK}/${name}.log"
    exit 1
  fi
  rm -rf "${WORK}/${name}-src" "${WORK}/${name}/.nimcache"
}

vacuity="vacuity guard: the shell arrives before the read, with the entry's policy and the hook's CSP; the rest, the page data and the bootstrap follow"

streaming_mutant headers-after-flush "${vacuity}" isonim/routing/route_dispatch.nim \
  "    page.commitHeaders()
    if ctx.bodyWriter.isNil:" \
  "    page.emit(flush = true)
    page.commitHeaders()
    if ctx.bodyWriter.isNil:"

streaming_mutant hook-after-commit "${vacuity}" isonim/routing/route_dispatch.nim \
  "  ctx.response.contentType = \"text/html; charset=utf-8\"
  let hook = serverHooks.pageHeaders
  if hook != nil:
    hook(ctx, page.spec.name)
  ctx.applyCachePolicy(ctx.responseCachePolicy)
  if page.spec.json" \
  "  ctx.response.contentType = \"text/html; charset=utf-8\"
  ctx.applyCachePolicy(ctx.responseCachePolicy)
  if page.spec.json" \
  "  page.emit(flush = true)

proc shell*" \
  "  page.emit(flush = true)
  let hook = serverHooks.pageHeaders
  if hook != nil:
    hook(ctx, page.spec.name)

proc shell*"

streaming_mutant override-after-commit \
  "after the shell: setCachePolicy is refused and reported, the headers are fixed" \
  isonim/server/context.nim \
  "    let committed = ctx.cachePolicyFixed or ctx.response.committed" \
  "    let committed = false"

streaming_mutant json-streamed "the JSON variant is answered whole, not streamed" \
  isonim/routing/route_dispatch.nim \
  "             discarding: ctx.pageVariant != pvHtml)" \
  "             discarding: false)"

streaming_mutant bootstrap-without-nonce "${vacuity}" isonim/routing/route_dispatch.nim \
  "generateHydrationScript(nonce = ctx.response.cspNonce)" \
  "generateHydrationScript()"

redirect="before the shell: a redirect has the entry's policy and no body; flushing it raises ValueError"

streaming_mutant redirect-writes-shell "${redirect}" isonim/routing/route_dispatch.nim \
  "  if ctx.response.isRedirect and not page.committed:" \
  "  if false:"

streaming_mutant redirect-without-policy "${redirect}" isonim/routing/route_dispatch.nim \
  "    page.pending.setLen(0)
    ctx.applyCachePolicy(ctx.responseCachePolicy)
    return" \
  "    page.pending.setLen(0)
    return"

streaming_mutant flush-on-redirect "${redirect}" isonim/routing/route_dispatch.nim \
  "    if ctx.response.isRedirect:
      raise newException(ValueError, \"the page redirected to \" &" \
  "    if false:
      raise newException(ValueError, \"the page redirected to \" &"

streaming_mutant bad-request-is-500 \
  "before the shell: RpcBadRequest is the 400, with none of the page" \
  isonim/routing/route_dispatch.nim \
  "  elif e of RpcBadRequest:" \
  "  elif false:"

streaming_mutant custom-tail-ignored \
  "a custom page.tail is written last, instead of the default" \
  isonim/routing/route_dispatch.nim \
  "  page.pending.add page.tail" \
  "  page.pending.add defaultPageTail"

# ---- the host without a writer (in-process) ----

WS="$(cd "${ROOT}/.." && pwd)"

# build_buffered <src> <out>: t_manifest_streaming_buffered.nim against
# <src> only (no config.nims: they would put this checkout's src/ first).
build_buffered() {
  nim c --hints:off --skipParentCfg --skipProjCfg \
    --nimcache:"$2.nimcache" -d:isonimRpcPrefix=/api/v1/rpc \
    --path:"$1" --path:"${WS}/nim-everywhere/src" \
    -o:"$2" "${ROOT}/tests/routing/t_manifest_streaming_buffered.nim" \
    >"$2-build.log" 2>&1 ||
    { tail -30 "$2-build.log"; exit 1; }
}

build_buffered "${ROOT}/src" "${WORK}/buffered-control"
if ! "${WORK}/buffered-control" >"${WORK}/buffered-control.log" 2>&1; then
  echo "t_manifest_streaming_buffered fails unmutated:"
  cat "${WORK}/buffered-control.log"
  exit 1
fi

# buffered_mutant <name> <failing test> <file under src/> <original> <replacement> [...]
buffered_mutant() {
  local name="$1" expect="$2" file="$3"
  shift 3
  rm -rf "${WORK}/${name}-src"
  cp -r "${ROOT}/src" "${WORK}/${name}-src"
  mutate "${WORK}/${name}-src/${file}" "$@"
  build_buffered "${WORK}/${name}-src" "${WORK}/${name}"
  if "${WORK}/${name}" >"${WORK}/${name}.log" 2>&1; then
    echo "MISSED ${name}: t_manifest_streaming_buffered passed"
    missed=$((missed + 1))
  elif grep -qF "[FAILED] ${expect}" "${WORK}/${name}.log"; then
    echo "caught ${name}: [FAILED] ${expect}"
    caught=$((caught + 1))
  else
    echo "${name}: the test failed, but not at '${expect}':"
    cat "${WORK}/${name}.log"
    exit 1
  fi
  rm -rf "${WORK}/${name}-src" "${WORK}/${name}.nimcache"
}

buffered_mutant buffered-hook-without-writer \
  "vacuity guard: the first flush commits a writerless response with the hook's headers; the rest, the page data and the bootstrap follow" \
  isonim/routing/route_dispatch.nim \
  "    hook(ctx, page.spec.name)" \
  "    if not ctx.bodyWriter.isNil:
      hook(ctx, page.spec.name)"

buffered_mutant buffered-not-committed \
  "after the shell: setCachePolicy is refused and reported, a header setter raises ResponseCommittedError" \
  isonim/routing/route_dispatch.nim \
  "      ctx.response.markCommitted()" \
  "      discard"

echo "streaming mutants caught: ${caught}, missed: ${missed}"
[ "${missed}" -eq 0 ]
