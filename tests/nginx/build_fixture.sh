#!/usr/bin/env bash
#
# Builds the nginx fixture (README.md) into build/nginx-fixture:
#
#   ngx_http_isonim_module.so  ngx-isonim (the sibling checkout) with
#                              fixture_app.nim compiled in
#   www/client.js              the browser client (fixture_client.nim)
#   www/hydrate.js             the hydration client (hydration_client.nim)
#   env.sh                     NGINX_BIN: the --with-compat nginx the module
#                              is built for
#
# Usage: build_fixture.sh [--module-only | --client-only] [extra nim args]
#
# The module is built by ngx-isonim's own scripts/build-module.sh inside
# ngx-isonim's dev shell (which provides that nginx and its configured
# headers), against THIS checkout's src/.  Environment:
#   ISONIM_NGX_ISONIM_DIR  the ngx-isonim checkout (default ../ngx-isonim)
#   ISONIM_FIXTURE_OUT     output directory (default build/nginx-fixture)
#   ISONIM_FIXTURE_SRC     the isonim src/ to build against (default
#                          this checkout's; run_mutants.sh points it at a
#                          mutated copy)

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
NGX="${ISONIM_NGX_ISONIM_DIR:-${ROOT}/../ngx-isonim}"
OUT="${ISONIM_FIXTURE_OUT:-${ROOT}/build/nginx-fixture}"
SRC="${ISONIM_FIXTURE_SRC:-${ROOT}/src}"
WS="$(cd "${ROOT}/.." && pwd)"
PREFIX_DEFINE="-d:isonimRpcPrefix=/api/v1/rpc"

what="all"
case "${1:-}" in
--module-only) what="module"; shift ;;
--client-only) what="client"; shift ;;
esac

if [ ! -x "${NGX}/scripts/build-module.sh" ]; then
  echo "build_fixture.sh: no ngx-isonim checkout at ${NGX}" \
    "(set ISONIM_NGX_ISONIM_DIR)" >&2
  exit 2
fi
mkdir -p "${OUT}/www"

if [ "${what}" != "client" ]; then
  # ngx-isonim's dev shell, with the workspace siblings as its flake inputs
  # (as its .envrc does), so nothing is fetched.
  overrides=()
  for input in nim-faststreams nim-stew isonim nim-everywhere; do
    overrides+=(--override-input "${input}" "path:${WS}/${input}")
  done
  (
    cd "${NGX}"
    NGX_ISONIM_PATHS="${WS}/nim-faststreams:${WS}/nim-stew:${SRC}:${WS}/nim-everywhere/src" \
    NGX_ISONIM_NIMCACHE="${OUT}/.nimcache" \
      nix develop "${overrides[@]}" --command bash -c '
        set -euo pipefail
        scripts/build-module.sh release "$1" "-d:ngxIsonimAppModule=$2" "${@:4}"
        echo "NGINX_BIN=$(command -v nginx)" >"$3"
      ' build "${OUT}/ngx_http_isonim_module.so" "${HERE}/fixture_app.nim" \
        "${OUT}/env.sh" "${PREFIX_DEFINE}" "$@"
  )
fi

if [ "${what}" != "module" ]; then
  # Only the paths given here (no config.nims), so that ISONIM_FIXTURE_SRC
  # really is the isonim the client is built from.
  nim js --hints:off --skipParentCfg --skipProjCfg \
    --nimcache:"${OUT}/.nimcache-js" "${PREFIX_DEFINE}" \
    --path:"${SRC}" --path:"${WS}/nim-everywhere/src" "$@" \
    -o:"${OUT}/www/client.js" "${HERE}/fixture_client.nim"
  nim js --hints:off --skipParentCfg --skipProjCfg \
    --nimcache:"${OUT}/.nimcache-js-hydrate" \
    --path:"${SRC}" --path:"${WS}/nim-everywhere/src" "$@" \
    -o:"${OUT}/www/hydrate.js" "${HERE}/hydration_client.nim"
fi
