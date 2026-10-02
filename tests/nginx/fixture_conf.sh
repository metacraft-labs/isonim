#!/usr/bin/env bash
#
# Prints the nginx configuration of the nginx fixture (README.md).
#
# Usage: fixture_conf.sh <prefix dir> <port> <module .so> <www dir> [daemon]
#   daemon: "on" (default) or "off" (foreground, for Playwright's webServer)
#
# ISONIM_FIXTURE_UPSTREAM_PORT, when set, adds /api/v1/slow-body: a proxy
# (unbuffered) to an HTTP server on that port of 127.0.0.1, which
# request-context-generation.spec.ts runs to send response headers and hold
# the body back.  Only that spec's slow-body test calls it.
#
# One worker process: every request of a test is served by the same worker,
# which is what makes "the worker was not blocked" observable.

set -euo pipefail
PREFIX="${1:?prefix}"
PORT="${2:?port}"
MODULE="${3:?module}"
WWW="${4:?www}"
DAEMON="${5:-on}"
UPSTREAM_PORT="${ISONIM_FIXTURE_UPSTREAM_PORT:-}"
SLOW_BODY=""
if [ -n "${UPSTREAM_PORT}" ]; then
  SLOW_BODY="location = /api/v1/slow-body {
      proxy_pass http://127.0.0.1:${UPSTREAM_PORT};
      proxy_buffering off;
    }"
fi

cat <<CONF
load_module ${MODULE};
daemon ${DAEMON};
worker_processes 1;
error_log ${PREFIX}/error.log info;
pid ${PREFIX}/nginx.pid;
events { worker_connections 1024; }
http {
  access_log off;
  client_body_temp_path ${PREFIX}/client_body;
  proxy_temp_path ${PREFIX}/proxy;
  fastcgi_temp_path ${PREFIX}/fastcgi;
  uwsgi_temp_path ${PREFIX}/uwsgi;
  scgi_temp_path ${PREFIX}/scgi;
  types { application/javascript js; text/html html; }
  server {
    listen 127.0.0.1:${PORT};
    location /static/ { alias ${WWW}/; }
    ${SLOW_BODY}
    location / {
      isonim_rpc on;
      isonim_rpc_app fixture;
      isonim_rpc_max_body_size 1100k;
      isonim_rpc_timeout 10s;
      client_max_body_size 8m;
    }
  }
}
CONF
