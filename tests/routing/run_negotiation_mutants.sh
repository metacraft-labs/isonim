#!/usr/bin/env bash
#
# The falsifying mutations of tests/routing/t_manifest_negotiation.nim
# (IFP-M26).  Each mutant is the nginx fixture's module built from a copy of
# src/ with one exact text replacement; the test (built from this checkout)
# runs against it (ISONIM_NGINX_MODULE) and must FAIL, at the test named for
# the mutant.  Exits 0 when every mutant is caught.
#
#   override-overwritten  the entry's cache headers written after the
#                         per-response policy on the hook's redirect (the
#                         dispatch before IFP-M26): the no-store redirect
#                         carries private, no-cache, must-revalidate.
#   weaker-accepted       setCachePolicy without the strictness check: the
#                         handler relaxes a response the hook made no-store.
#   strictness-vs-entry   setCachePolicy comparing with the entry's policy
#                         instead of the response's current one: the same.
#   undeclared-accepted   setCachePolicy without the declared-policy check:
#                         a handler gets a policy its entry does not declare.
#   refusal-unreported    setCachePolicy refusing without telling
#                         serverHooks.onCachePolicyRefused.
#   json-always           a page with a JSON variant answering JSON to every
#                         request: the vacuity guard (the HTML request
#                         answers the page's HTML) fails.
#   any-without-entry-policy
#                         the `any` dispatch (runAny) without
#                         beginCachePolicy: its response is no-store
#                         whatever the entry declares, and every
#                         setCachePolicy from its handler is refused.
#
# Needs what tests/nginx/build_fixture.sh needs (the ngx-isonim sibling,
# nix); run inside the dev shell, as `just test-nginx` does.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/isonim-negotiation-mutants.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

mutate() {
  # mutate <file> <original> <replacement>: exactly one occurrence.
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
n = text.count(old)
if n != 1:
    sys.exit(f"mutation of {path}: expected one occurrence, found {n}")
open(path, "w").write(text.replace(old, new))
PY
}

(cd "${ROOT}" && nim c --hints:off -d:isonimRpcPrefix=/api/v1/rpc \
  -o:"${WORK}/t_manifest_negotiation" tests/routing/t_manifest_negotiation.nim) \
  >"${WORK}/test-build.log" 2>&1 ||
  { tail -30 "${WORK}/test-build.log"; exit 1; }

caught=0
missed=0

# negotiation_mutant <name> <file under src/> <original> <replacement> <failing test>
negotiation_mutant() {
  local name="$1" file="$2" old="$3" new="$4" expect="$5"
  rm -rf "${WORK}/${name}-src"
  cp -r "${ROOT}/src" "${WORK}/${name}-src"
  mutate "${WORK}/${name}-src/${file}" "${old}" "${new}"
  ISONIM_FIXTURE_SRC="${WORK}/${name}-src" ISONIM_FIXTURE_OUT="${WORK}/${name}" \
    bash "${ROOT}/tests/nginx/build_fixture.sh" --module-only >"${WORK}/${name}-build.log" 2>&1 ||
    { tail -30 "${WORK}/${name}-build.log"; exit 1; }
  if ISONIM_NGINX_MODULE="${WORK}/${name}/ngx_http_isonim_module.so" \
      "${WORK}/t_manifest_negotiation" >"${WORK}/${name}.log" 2>&1; then
    echo "MISSED ${name}: t_manifest_negotiation passed"
    missed=$((missed + 1))
  elif grep -qF "[FAILED] ${expect}" "${WORK}/${name}.log"; then
    echo "caught ${name}: [FAILED] ${expect}"
    caught=$((caught + 1))
  else
    echo "${name}: the test failed, but not at '${expect}':"
    cat "${WORK}/${name}.log"
    exit 1
  fi
}

negotiation_mutant override-overwritten isonim/routing/route_dispatch.nim \
  "    ctx.applyCachePolicy(ctx.responseCachePolicy)
    ctx.response.redirect(" \
  "    ctx.applyCachePolicy(ctx.responseCachePolicy)
    ctx.applyCachePolicy(spec.cache)
    ctx.response.redirect(" \
  "the two redirects carry their policies' headers"

negotiation_mutant weaker-accepted isonim/server/context.nim \
  "if isAtLeastAsStrict(policy, ctx.cachePolicy) and policy in ctx.cacheChoices:" \
  "if policy in ctx.cacheChoices:" \
  "negative control: a weaker or undeclared override is refused and reported"

negotiation_mutant strictness-vs-entry isonim/server/context.nim \
  "if isAtLeastAsStrict(policy, ctx.cachePolicy) and policy in ctx.cacheChoices:" \
  "if isAtLeastAsStrict(policy, ctx.cacheChoices[0]) and policy in ctx.cacheChoices:" \
  "negative control: a weaker or undeclared override is refused and reported"

negotiation_mutant undeclared-accepted isonim/server/context.nim \
  "if isAtLeastAsStrict(policy, ctx.cachePolicy) and policy in ctx.cacheChoices:" \
  "if isAtLeastAsStrict(policy, ctx.cachePolicy):" \
  "negative control: a weaker or undeclared override is refused and reported"

negotiation_mutant refusal-unreported isonim/server/context.nim \
  "      report(ctx, policy, ctx.cachePolicy)" \
  "      discard" \
  "negative control: a weaker or undeclared override is refused and reported"

negotiation_mutant json-always isonim/routing/route_dispatch.nim \
  "    if ctx.pageVariant != pvHtml:" \
  "    if spec.json:" \
  "vacuity guard: the HTML request answers the page's HTML with its data"

negotiation_mutant any-without-entry-policy isonim/routing/route_dispatch.nim \
  "  ctx.beginCachePolicy(spec.cache, spec.cacheOverrides)
  if not await ctx.enforcePolicies(spec.name, spec.auth, spec.csrf, formToken):
    return
  let before = ctx.response.snapshot()
  try:
    await handler(ctx)" \
  "  if not await ctx.enforcePolicies(spec.name, spec.auth, spec.csrf, formToken):
    return
  let before = ctx.response.snapshot()
  try:
    await handler(ctx)" \
  "an any entry answers with its own policy and its declared overrides"

echo "negotiation mutants caught: ${caught}, missed: ${missed}"
[ "${missed}" -eq 0 ]
