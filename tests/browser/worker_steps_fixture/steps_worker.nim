## steps_worker.nim
##
## The worker-steps fixture's worker chunk (steps.worker.js), served with
## `serveWorkerSteps`.

import isonim/web/worker
import steps_compile

serveWorkerSteps[StepsRequest, StepsResult, StepsRun](startSteps, stepSteps, finishSteps)
