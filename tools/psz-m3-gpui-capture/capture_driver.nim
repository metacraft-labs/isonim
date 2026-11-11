## Captures the editor's GPUI page preview from inside GuiAssert's headless
## sway. It starts the sway session, runs drive.mjs in it (the editor page
## opens in a chromium window that sway shows), and takes the screen at each
## handover request, writing binary PPMs:
##   fit-shown.ppm / fit-hidden.ppm         Fit (the default zoom)
##   actual-shown.ppm / actual-hidden.ppm   100%
##   actual-wide-shown.ppm / ...            100% opened by the URL
## "hidden" is the same screen with the streamed canvas hidden by drive.mjs.
## The measured page state is written by drive.mjs as <state>.json.
##
## Build (from the GuiAssert dev shell, see README.md):
##   nim c -d:release --path:<GuiAssert>/src -o:capture_driver capture_driver.nim
##
## Environment: PSZ_M3_GPUI_FRAMES (output and sync dir), PSZ_M3_URL,
## NODE, CHROMIUM, PSZ_M3_DRIVE (drive.mjs), PSZ_M3_STATES, PSZ_M3_OUTPUT
## (the sway output, "W,H"), PSZ_M3_WINDOW (the chromium window, "W,H").
import std/[os, osproc, strutils, times]
import gui_assert/desktop_env
import gui_assert/desktop_env/sway

proc need(name: string): string =
  result = getEnv(name)
  if result.len == 0: quit("capture_driver: " & name & " is not set", 2)

let syncDir = need("PSZ_M3_GPUI_FRAMES")
let node = need("NODE")
let driveScript = need("PSZ_M3_DRIVE")
createDir(syncDir)

proc writePpm(img: RgbImage; path: string) =
  var s = "P6\n" & $img.width & " " & $img.height & "\n255\n"
  s.setLen(s.len + img.data.len)
  let off = s.len - img.data.len
  for i, b in img.data: s[off + i] = char(b)
  writeFile(path, s)

proc chromeWindow(t: SwayTarget): EnvWindow =
  ## The editor's window: the one chromium opened for the page.
  for w in t.windows():
    echo "  toplevel app_id=", w.appId.escape, " title=", w.title.escape, " rect=", w.rect.w, "x", w.rect.h
    if w.rect.w > 0 and w.rect.h > 0: return w
  raise newException(CatchableError, "no chromium window")

let outputSize = getEnv("PSZ_M3_OUTPUT", "1920,1200").split(",")
let states = getEnv("PSZ_M3_STATES", "fit,actual").split(",")
let t = newSwayTarget(parseInt(outputSize[0]), parseInt(outputSize[1]))
t.start()
var status = 0
try:
  let p = t.spawn(@[node, driveScript],
    extraEnv = [("SYNC_DIR", syncDir), ("PSZ_M3_URL", need("PSZ_M3_URL")),
                ("CHROMIUM", need("CHROMIUM")), ("PSZ_M3_STATES", states.join(",")),
                ("PSZ_M3_WINDOW", getEnv("PSZ_M3_WINDOW", "1920,1200"))])
  let deadline = epochTime() + 600
  proc finishedOrFailed(): bool =
    fileExists(syncDir / "finished") or fileExists(syncDir / "failed")
  t.waitUntil("the editor page to be ready", proc(): bool =
    fileExists(syncDir / "ready") or finishedOrFailed(),
    timeout = initDuration(seconds = 600))
  if not fileExists(syncDir / "ready"):
    raise newException(CatchableError, "drive.mjs: " & readFile(syncDir / "failed"))

  var names: seq[string]
  for s in states:
    names.add s & "-shown"
    names.add s & "-hidden"
  for name in names:
    t.waitUntil("the " & name & " request", proc(): bool =
      fileExists(syncDir / ("request-" & name)) or finishedOrFailed(),
      timeout = initDuration(seconds = 600))
    if not fileExists(syncDir / ("request-" & name)):
      break
    let rect = t.chromeWindow().rect
    let img = t.captureSettled(rect, agree = 3, intervalMs = 400,
      timeout = initDuration(seconds = 120))
    img.writePpm(syncDir / (name & ".ppm"))
    echo name, ": window ", rect.w, "x", rect.h, ", capture ", img.width, "x", img.height
    writeFile(syncDir / ("ack-" & name), "")
  t.waitUntil("drive.mjs to finish", proc(): bool = finishedOrFailed(),
    timeout = initDuration(seconds = 300))
  if fileExists(syncDir / "failed"):
    raise newException(CatchableError, "drive.mjs: " & readFile(syncDir / "failed"))
  discard p.waitForExit(10000)
except CatchableError as e:
  echo "capture_driver: FAILED: ", e.msg
  status = 1
finally:
  t.stop()
quit(status)
