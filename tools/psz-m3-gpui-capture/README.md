# PSZ-M3 GPUI page-preview capture

Captures the editor's GPUI page preview as the screen shows it, for the
streamed-zoom test (`tests/test_editor_preview_streamed_zoom.nim`). The test
reads the captures and checks the frame's size and content, so the frames must
come from the real stack: the editor page, the editor server, the daemon and
the GPUI launcher. Nothing here draws a frame itself.

## What it captures

| State | URL zoom | Window (`PSZ_M3_WINDOW`) | Writes |
| --- | --- | --- | --- |
| `fit` | `zoom=fit` (default) | 1920,1200 | `fit-shown.ppm`, `fit-hidden.ppm`, `fit.json` |
| `actual` | 100% by the zoom control | 1920,1200 | `actual-shown.ppm`, `actual-hidden.ppm`, `actual.json` |
| `actual-wide` | `zoom=100` | 2550,900 | `actual-wide-shown.ppm`, `actual-wide-hidden.ppm`, `actual-wide.json` |

"Shown" is the screen with the streamed canvas. "Hidden" is the same screen with
the canvas hidden and the frame's own background set to magenta, so the painted
frame is the box where the two differ. `<state>.json` is the page state drive.mjs
measured: the preview area, the scale and the canvas size.

## What must be running

1. **The editor bundle and daemon**, from the isonim checkout:
   `just editor-build` and `just isonim-review-build`.
2. **The editor server**, which serves the bundle, proxies the daemon's API and
   forwards `/bridge/gpui` to the launcher on 127.0.0.1:8103:

   ```sh
   ISONIM_REVIEW_BACKEND_BIN_DIR=<dir holding isonim-examples-gpui> \
     python3 tools/editor_server.py --directory build/editor \
       --project-root examples/wanderlust --daemon-binary build/bin/isonim-review \
       --port 18691 --bind 127.0.0.1
   ```

3. **The GPUI launcher**, on the bridge port the server forwards to. The daemon
   does not start it for the streamed page, so start it by hand, as the
   `editor-serve-all` recipe does:

   ```sh
   isonim-examples-gpui --port 8103 --demo task
   ```

   Build it in isonim-examples with `just build-backends` (or the `nim c` line
   for `editor/backends/gpui.nim` there). It needs the Rust GPUI shim
   (`libgpui_nim_shim.so`) and libwebp on `LD_LIBRARY_PATH`.

Check the stack before capturing: `curl -I http://127.0.0.1:18691/index.html`
should answer 200, and `ss -ltn` should list 8103.

## Tools

- **GuiAssert** (a checkout): its dev shell provides sway, the headless Wayland
  session the capture runs in, and the helper binaries it builds on first use.
- **capture_driver**: the Nim side. Build it from GuiAssert's dev shell:

  ```sh
  nix develop "$GUI_ASSERT_DIR" --command \
    nim c -d:release --path:"$GUI_ASSERT_DIR/src" \
      -o:/abs/path/capture_driver tools/psz-m3-gpui-capture/capture_driver.nim
  ```

- **chromium** and **node**: `CHROMIUM` and `NODE`. drive.mjs uses the Playwright
  that `tests/browser` installs (`npm install` there).

## Running it

```sh
export GUI_ASSERT_DIR=/path/to/GuiAssert
export CAPTURE_DRIVER=/abs/path/capture_driver
export NODE=$(command -v node) CHROMIUM=$(command -v chromium)

# Fit and 100% (the default states), into an empty directory:
PSZ_M3_GPUI_FRAMES=/tmp/psz-m3/frames tools/psz-m3-gpui-capture/capture.sh

# 100% opened by the URL, in a 2550x900 window:
PSZ_M3_GPUI_FRAMES=/tmp/psz-m3/frames-wide \
  PSZ_M3_URL='http://127.0.0.1:18691/index.html?view=page&storyGroup=Pages&story=Trip%20Planner&kind=page&index=0&viewport=desktop&zoom=100' \
  PSZ_M3_STATES=actual-wide PSZ_M3_OUTPUT=2550,900 PSZ_M3_WINDOW=2550,900 \
  tools/psz-m3-gpui-capture/capture.sh
```

`capture.sh` refuses a directory that is not empty, because the driver hands
over through files in it. A run takes a few minutes: the driver waits up to two
minutes for a rendered frame before it gives up.

The streamed-zoom test reads one directory with every state:

```sh
PSZ_M3_GPUI_FRAMES=/tmp/psz-m3/frames nim c -r tests/test_editor_preview_streamed_zoom.nim
```

To view a capture, convert it with `ppm_to_png.py in.ppm out.png [x y w h [scale]]`.

## Files

- `capture.sh`: runs the driver with the environment above.
- `capture_driver.nim`: starts sway, runs drive.mjs, takes each screen.
- `drive.mjs`: opens the page in chromium, selects the GPUI backend, waits for a
  rendered frame, and asks for each capture.
- `ppm_to_png.py`: PPM to PNG, with an optional crop and downscale.
