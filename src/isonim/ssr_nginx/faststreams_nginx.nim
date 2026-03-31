## isonim/ssr_nginx/faststreams_nginx.nim
##
## nginx OutputStreamVTable backend using faststreams.
## Allows streaming SSR output directly through nginx's buffer chain.
##
## This module re-exports nginx_stream which provides the OutputStream
## backed by nginx buffers. The "faststreams" name is kept for historical
## reasons; the actual implementation uses the OutputStream abstraction
## from isonim/ssr/stream.

import isonim/ssr_nginx/nginx_stream
export nginx_stream
