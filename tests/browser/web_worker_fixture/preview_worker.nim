## preview_worker.nim
##
## The web-worker fixture's worker chunk: built to preview.worker.js by
## `tools/isonim-bundle.mjs build --kind worker` (just build-web-worker-fixture).

import isonim/web/worker
import preview_compile

serveWorker(compilePreview)
