#!/usr/bin/env bash
#
# The falsifying mutations of the nginx fixture's browser tests
# (tests/browser/specs/rpc-over-nginx.spec.ts and
# request-context-generation.spec.ts).  Each mutant is built from a copy of
# the sources with one exact text replacement, served by the nginx fixture,
# and the spec's guarded tests must FAIL against it while its negative
# controls still pass.  Exits 0 when every mutant is caught.
#
#   sync-rpc       ngx-isonim runs the handler synchronously in nginx's
#                  content phase (nim_handle_rpc polls Nim's event loop
#                  until the handler is done): the concurrency test fails.
#   no-generation  the generated client without the context-generation
#                  check: the stale account and incarnation responses are
#                  applied.
#   no-navigation-generation
#                  staleReason (client_context.nim) without its navigation
#                  branch: the response whose navigation changed after its
#                  body was read is applied.
#   body-abort     rawFetch (rpc_client.nim) treating only an abort that
#                  rejects fetch() as a drop: an abort while the body is
#                  read reaches the caller as an exception.
#   canonical-first
#                  the manifest dispatch running the canonicalization hook
#                  before authentication: the generated
#                  pcAuthBeforeCanonical tests of tests/test_route_manifest.nim
#                  fail (a 301 with Location instead of 401/403).
#
# Needs what build_fixture.sh needs, and Playwright with a Chromium
# (PLAYWRIGHT_CHROMIUM_EXECUTABLE, or `chromium` on PATH).

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
NGX="${ISONIM_NGX_ISONIM_DIR:-${ROOT}/../ngx-isonim}"
WS="$(cd "${ROOT}/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/isonim-nginx-mutants.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
export PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium || true)}"

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

run_spec() {
  # run_spec <log> <grep> [env...]: runs the nginx-rpc project; returns
  # Playwright's exit code.
  local log="$1" grep="$2"
  shift 2
  (cd "${ROOT}/tests/browser" &&
    env "$@" npx playwright test --project=nginx-rpc --reporter=line \
      --grep "${grep}" >"${log}" 2>&1)
}

caught=0
missed=0

# --- sync-rpc -------------------------------------------------------------
mkdir -p "${WORK}/ngx"
cp -r "${NGX}/src" "${NGX}/scripts" "${NGX}/nim.cfg" "${WORK}/ngx/"
mutate "${WORK}/ngx/src/handler.nim" "      st.run()
" "      st.run()
      while not st.done: poll(20)
"
overrides=()
for input in nim-faststreams nim-stew isonim nim-everywhere; do
  overrides+=(--override-input "${input}" "path:${WS}/${input}")
done
(
  cd "${NGX}"
  NGX_ISONIM_PATHS="${WS}/nim-faststreams:${WS}/nim-stew:${ROOT}/src:${WS}/nim-everywhere/src" \
  NGX_ISONIM_NIMCACHE="${WORK}/ngx-nimcache" \
    nix develop "${overrides[@]}" --command bash "${WORK}/ngx/scripts/build-module.sh" \
      release "${WORK}/sync-rpc.so" "-d:ngxIsonimAppModule=${HERE}/fixture_app.nim" \
      -d:isonimRpcPrefix=/api/v1/rpc >"${WORK}/sync-rpc-build.log" 2>&1
) || { tail -30 "${WORK}/sync-rpc-build.log"; exit 1; }

if run_spec "${WORK}/sync-rpc.log" "concurrent request" \
    ISONIM_NGINX_MODULE="${WORK}/sync-rpc.so"; then
  echo "MISSED sync-rpc: the concurrency test passed against the mutant"
  missed=$((missed + 1))
else
  grep -q "1 failed" "${WORK}/sync-rpc.log" && grep -q "fastDone" "${WORK}/sync-rpc.log" ||
    { cat "${WORK}/sync-rpc.log"; exit 1; }
  echo "caught sync-rpc: the concurrency test failed at" \
    "$(grep -m1 -o 'expect(r\.[a-zA-Z]*)\.[a-zA-Z]*' "${WORK}/sync-rpc.log")"
  caught=$((caught + 1))
fi
# Control: the same module passes the typed round trip.
run_spec "${WORK}/sync-rpc-control.log" "typed results" \
  ISONIM_NGINX_MODULE="${WORK}/sync-rpc.so" ||
  { echo "the sync-rpc mutant fails even the round trip:"; cat "${WORK}/sync-rpc-control.log"; exit 1; }

# --- no-generation --------------------------------------------------------
cp -r "${ROOT}/src" "${WORK}/isonim-src"
mutate "${WORK}/isonim-src/isonim/server/rpc_client.nim" \
  "  if reason.len > 0 or status == -1:" "  if status == -1:"
ISONIM_FIXTURE_SRC="${WORK}/isonim-src" ISONIM_FIXTURE_OUT="${WORK}/no-generation" \
  bash "${HERE}/build_fixture.sh" --client-only >"${WORK}/no-generation-build.log" 2>&1 ||
  { tail -30 "${WORK}/no-generation-build.log"; exit 1; }

if run_spec "${WORK}/no-generation.log" "reaches the client and is dropped" \
    ISONIM_FIXTURE_WWW="${WORK}/no-generation/www"; then
  echo "MISSED no-generation: the stale responses were dropped anyway"
  missed=$((missed + 1))
else
  grep -q "2 failed" "${WORK}/no-generation.log" || { cat "${WORK}/no-generation.log"; exit 1; }
  echo "caught no-generation: account and incarnation cases failed (stale responses applied)"
  caught=$((caught + 1))
fi
run_spec "${WORK}/no-generation-control.log" "negative control" \
  ISONIM_FIXTURE_WWW="${WORK}/no-generation/www" ||
  { echo "the no-generation mutant fails the negative controls:"; cat "${WORK}/no-generation-control.log"; exit 1; }

client_mutant() {
  # client_mutant <name> <file under src/> <original> <replacement>: builds
  # the fixture's browser client from a mutated copy of src/ into
  # ${WORK}/<name>/www.
  local name="$1"
  rm -rf "${WORK}/${name}-src"
  cp -r "${ROOT}/src" "${WORK}/${name}-src"
  mutate "${WORK}/${name}-src/$2" "$3" "$4"
  ISONIM_FIXTURE_SRC="${WORK}/${name}-src" ISONIM_FIXTURE_OUT="${WORK}/${name}" \
    bash "${HERE}/build_fixture.sh" --client-only >"${WORK}/${name}-build.log" 2>&1 ||
    { tail -30 "${WORK}/${name}-build.log"; exit 1; }
}

# --- no-navigation-generation ----------------------------------------------
client_mutant no-navigation-generation isonim/routing/client_context.nim \
  "    if scope == csNavigation and
        captured.navigationGeneration != ctxState.navigationGeneration:
      return \"navigation\"
" ""
if run_spec "${WORK}/no-navigation-generation.log" "after the body is read" \
    ISONIM_FIXTURE_WWW="${WORK}/no-navigation-generation/www"; then
  echo "MISSED no-navigation-generation: the stale response was dropped anyway"
  missed=$((missed + 1))
else
  grep -q "1 failed" "${WORK}/no-navigation-generation.log" ||
    { cat "${WORK}/no-navigation-generation.log"; exit 1; }
  echo "caught no-navigation-generation: the response whose navigation changed" \
    "after its body was read was applied"
  caught=$((caught + 1))
fi
# Control: the abort still drops what it reaches, and fresh responses apply.
run_spec "${WORK}/no-navigation-generation-control.log" \
  "aborted and dropped|while the body is read|negative control" \
  ISONIM_FIXTURE_WWW="${WORK}/no-navigation-generation/www" ||
  { echo "the no-navigation-generation mutant fails its controls:"
    cat "${WORK}/no-navigation-generation-control.log"; exit 1; }

# --- body-abort --------------------------------------------------------------
client_mutant body-abort isonim/server/rpc_client.nim \
  '  `result` = fetch(`url`, init)
    .then(function (r) {
      return r.text().then(function (t) { return {status: r.status, text: t}; });
    })
    .catch(function (e) {' \
  '  `result` = fetch(`url`, init)
    .then(function (r) {
      return r.text().then(function (t) { return {status: r.status, text: t}; });
    }, function (e) {'
if run_spec "${WORK}/body-abort.log" "while the body is read" \
    ISONIM_FIXTURE_WWW="${WORK}/body-abort/www"; then
  echo "MISSED body-abort: the abort during the body read was dropped anyway"
  missed=$((missed + 1))
else
  grep -q "1 failed" "${WORK}/body-abort.log" && grep -q "AbortError" "${WORK}/body-abort.log" ||
    { cat "${WORK}/body-abort.log"; exit 1; }
  echo "caught body-abort: the abort during the body read surfaced as an AbortError"
  caught=$((caught + 1))
fi
run_spec "${WORK}/body-abort-control.log" "aborted and dropped|negative control" \
  ISONIM_FIXTURE_WWW="${WORK}/body-abort/www" ||
  { echo "the body-abort mutant fails its controls:"; cat "${WORK}/body-abort-control.log"; exit 1; }

# --- canonical-first ---------------------------------------------------------
# The module (server) from a mutated isonim: the canonicalization hook runs
# before authentication.  The route-manifest test, built as `just test-nginx`
# builds it, runs against it.
rm -rf "${WORK}/canonical-first-src"
cp -r "${ROOT}/src" "${WORK}/canonical-first-src"
mutate "${WORK}/canonical-first-src/isonim/routing/route_dispatch.nim" \
  "  if not await ctx.enforcePolicies(spec.name, spec.auth, spec.csrf, formToken):
    return
  if not await ctx.canonicalStage(spec):
    return
" "  if not await ctx.canonicalStage(spec):
    return
  if not await ctx.enforcePolicies(spec.name, spec.auth, spec.csrf, formToken):
    return
"
ISONIM_FIXTURE_SRC="${WORK}/canonical-first-src" ISONIM_FIXTURE_OUT="${WORK}/canonical-first" \
  bash "${HERE}/build_fixture.sh" --module-only >"${WORK}/canonical-first-build.log" 2>&1 ||
  { tail -30 "${WORK}/canonical-first-build.log"; exit 1; }
(cd "${ROOT}" && nim c --hints:off -d:isonimRpcPrefix=/api/v1/rpc \
  -o:"${WORK}/test_route_manifest" tests/test_route_manifest.nim) \
  >"${WORK}/canonical-first-test-build.log" 2>&1 ||
  { tail -30 "${WORK}/canonical-first-test-build.log"; exit 1; }
if ISONIM_NGINX_MODULE="${WORK}/canonical-first/ngx_http_isonim_module.so" \
    "${WORK}/test_route_manifest" >"${WORK}/canonical-first.log" 2>&1; then
  echo "MISSED canonical-first: the generated policy tests passed"
  missed=$((missed + 1))
else
  grep -q "pcAuthBeforeCanonical" "${WORK}/canonical-first.log" ||
    { cat "${WORK}/canonical-first.log"; exit 1; }
  # Only the canonicalized entry may fail (its pcAuth/pcRole requests are the
  # same requests and fail with it).
  if grep "expected status" "${WORK}/canonical-first.log" | grep -vq "^ *rTopic "; then
    echo "canonical-first: policy tests of entries other than rTopic failed:"
    cat "${WORK}/canonical-first.log"; exit 1
  fi
  echo "caught canonical-first:" \
    "$(grep -c 'pcAuthBeforeCanonical' "${WORK}/canonical-first.log") pcAuthBeforeCanonical failures"
  caught=$((caught + 1))
fi

echo "mutants caught: ${caught}, missed: ${missed}"
[ "${missed}" -eq 0 ]
