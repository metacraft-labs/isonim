#!/usr/bin/env bash
#
# Runs the nginx fixture in the foreground on a port (Playwright's
# webServer for the nginx-rpc project).
#
# Usage: serve_fixture.sh <port>
#
# The module, the nginx binary and the static files come from
# build/nginx-fixture (just build-nginx-fixture); ISONIM_NGINX_MODULE and
# ISONIM_FIXTURE_WWW override the module and the static files (the
# falsifying mutations of run_mutants.sh).

set -euo pipefail
PORT="${1:?port}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
BUILD="${ROOT}/build/nginx-fixture"
# shellcheck source=/dev/null
source "${BUILD}/env.sh"
MODULE="${ISONIM_NGINX_MODULE:-${BUILD}/ngx_http_isonim_module.so}"
WWW="${ISONIM_FIXTURE_WWW:-${BUILD}/www}"
PREFIX="$(mktemp -d "${TMPDIR:-/tmp}/isonim-nginx-fixture.XXXXXX")"
mkdir -p "${PREFIX}"/{client_body,proxy,fastcgi,uwsgi,scgi}
# The slow-body upstream of request-context-generation.spec.ts listens on
# the next port.
ISONIM_FIXTURE_UPSTREAM_PORT="$((PORT + 1))" \
  bash "${HERE}/fixture_conf.sh" "${PREFIX}" "${PORT}" "${MODULE}" "${WWW}" off \
  >"${PREFIX}/nginx.conf"
echo "nginx fixture on port ${PORT}, prefix ${PREFIX}, module ${MODULE}" >&2
exec "${NGINX_BIN}" -c "${PREFIX}/nginx.conf" -p "${PREFIX}" -e "${PREFIX}/error.log"
