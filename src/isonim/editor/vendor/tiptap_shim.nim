## TBAR-M4 — Nim shim around the vendored TipTap + marked bundle.
##
## The vendor file ``vendor/tiptap/isonim-tiptap.umd.min.js`` is loaded
## by the editor HTML scaffold via a ``<script>`` tag (see
## ``isonim-examples/editor/index.html``). It attaches
## ``window.IsoNimTipTap`` whose shape is documented in
## ``vendor/tiptap/MANIFEST.txt``. This module exposes the small Nim
## surface the editor's spec-pane mount consumes:
##
##   * ``mountTipTapViewer(container, markdown)`` — initialises a
##     read-only TipTap editor on ``container`` showing the markdown
##     rendered to HTML. A subsequent call on the same container
##     destroys the previous Editor instance to avoid ProseMirror
##     state leakage.
##   * ``unmountTipTapViewer(container)`` — explicit teardown.
##   * ``isTipTapAvailable()`` — true when ``window.IsoNimTipTap`` is
##     defined (i.e. the vendor bundle loaded successfully). The
##     editor's spec-pane mount falls back to a raw-markdown
##     rendering when this is false so a dev build that forgot to
##     copy ``vendor/tiptap/`` to ``build/editor/`` does not hard
##     crash.
##   * ``isTipTapEditableContainer(container)`` — exposes the
##     vendored shim's editability flag so the e2e test can assert
##     that a View-mode mount is non-editable.
##
## The native build (when ``not defined(js)``) compiles all of the
## procs as inert stubs returning sentinel values. This lets the
## headless VM test (``test_editor_spec_pane_vm``) compile + run on
## the native target without pulling in browser APIs.

when defined(js):
  import std/dom

  type
    JsObject {.importc.} = ref object

  proc isTipTapAvailable*(): bool =
    ## Returns ``true`` when ``window.IsoNimTipTap`` is defined on the
    ## global object. The editor's spec-pane mount uses this to fall
    ## back to a raw-markdown rendering when the vendor UMD didn't
    ## load (e.g. ``build/editor/vendor/tiptap/`` is missing in a dev
    ## build).
    var present = 0
    {.emit: ["""
      try {
        if (typeof window !== 'undefined' &&
            window.IsoNimTipTap &&
            typeof window.IsoNimTipTap.mountViewer === 'function') {
          """, present, """ = 1;
        }
      } catch (_) {}
    """].}
    present == 1

  proc mountTipTapViewer*(container: Element; markdown: string) =
    ## Initialise a read-only TipTap editor on ``container``, renders
    ## ``markdown`` through the vendored ``marked`` parser, and sets
    ## that HTML as the editor's content. A second call on the same
    ## container destroys the prior Editor first, so there is no
    ## ProseMirror state leak across re-mounts (the vendor shim holds
    ## the per-container Editor in a ``WeakMap`` keyed by the DOM
    ## node).
    if container == nil:
      return
    let md = markdown.cstring
    {.emit: ["""
      try {
        // TBAR-M5: stash the most-recent markdown body on the host so
        // ``setTipTapEditable`` can seed the textarea overlay with it
        // (the user's last-rendered body becomes the editable
        // source).  Storing on a DOM attribute survives ProseMirror's
        // teardown/rebuild and lets the shim recover the seed even
        // when the editor flips between View and Edit several times.
        if (""", container, """ && """, container, """.setAttribute) {
          """, container, """.setAttribute('data-spec-pane-markdown', """, md, """);
        }
        if (typeof window !== 'undefined' &&
            window.IsoNimTipTap &&
            typeof window.IsoNimTipTap.mountViewer === 'function') {
          window.IsoNimTipTap.mountViewer(""", container, """, """, md, """);
        }
      } catch (e) {
        try { console.error('mountTipTapViewer failed', e); } catch (_) {}
      }
    """].}

  proc unmountTipTapViewer*(container: Element) =
    ## Tear down the TipTap editor mounted on ``container`` (if any).
    ## Safe to call when nothing was ever mounted.
    if container == nil:
      return
    {.emit: ["""
      try {
        if (typeof window !== 'undefined' &&
            window.IsoNimTipTap &&
            typeof window.IsoNimTipTap.unmount === 'function') {
          window.IsoNimTipTap.unmount(""", container, """);
        }
      } catch (_) {}
    """].}

  proc isTipTapEditableContainer*(container: Element): bool =
    ## Returns the read-only editability flag reported by the vendor
    ## shim for ``container``. The TBAR-M4 mount sets the editor to
    ## ``editable: false`` so this returns ``false`` after a
    ## ``mountTipTapViewer`` call.
    if container == nil:
      return false
    var editable = 0
    {.emit: ["""
      try {
        if (typeof window !== 'undefined' &&
            window.IsoNimTipTap &&
            typeof window.IsoNimTipTap.isEditableContainer === 'function') {
          if (window.IsoNimTipTap.isEditableContainer(""", container, """)) {
            """, editable, """ = 1;
          }
        }
      } catch (_) {}
    """].}
    editable == 1

  # TBAR-M5 — edit-mode primitives.
  #
  # Strategy choice for round-trip-stable markdown editing: instead of
  # asking TipTap to re-serialise its rich-text JSON back to markdown
  # (which would require vendoring a JSON-to-markdown serializer and
  # accepting the lossy round-trip that introduces), we keep TipTap
  # as the View-mode renderer and overlay a plain ``<textarea>`` for
  # Edit mode. The textarea round-trips losslessly — what the user
  # typed is what lands on disk.
  #
  # ``setTipTapEditable(container, editable)`` toggles between the two:
  #   * editable=true  — hide TipTap, show the textarea seeded with the
  #                      current markdown body, mark the host
  #                      ``data-tiptap-editable="true"`` so the e2e
  #                      test can sense edit mode.
  #   * editable=false — show TipTap, hide the textarea, mark
  #                      ``data-tiptap-editable="false"`` (matches the
  #                      TBAR-M4 View-mode contract).
  # ``getTipTapMarkdown(container)`` reads the textarea's current
  # value (the canonical source of truth in Edit mode); in View mode
  # the textarea may still exist (hidden) and carries the last-seeded
  # body, so the proc returns the same value the editor put there.
  proc setTipTapEditable*(container: Element; editable: bool) =
    if container == nil:
      return
    let editableFlag = (if editable: cstring("true") else: cstring("false"))
    {.emit: ["""
      try {
        var host = """, container, """;
        if (!host) return;
        var editable = """, editableFlag, """ === 'true';
        var ta = host.querySelector('textarea[data-spec-pane-textarea="true"]');
        if (editable && !ta) {
          ta = document.createElement('textarea');
          ta.setAttribute('data-spec-pane-textarea', 'true');
          ta.style.width = '100%';
          ta.style.height = '100%';
          ta.style.minHeight = '300px';
          ta.style.boxSizing = 'border-box';
          ta.style.fontFamily = "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace";
          ta.style.fontSize = '13px';
          ta.style.lineHeight = '1.5';
          ta.style.padding = '12px';
          ta.style.background = '#1A1B26';
          ta.style.color = '#D5D6DB';
          ta.style.border = '1px solid #2F3140';
          ta.style.borderRadius = '6px';
          ta.style.outline = 'none';
          ta.style.resize = 'none';
          ta.style.whiteSpace = 'pre';
          // Seed from a previously-stored markdown body if present;
          // mountTipTapViewer keeps the last body in
          // ``data-spec-pane-markdown`` so the textarea has a starting
          // point even when toggled on after a View-mode mount.
          var seed = host.getAttribute('data-spec-pane-markdown');
          if (seed === null || seed === undefined) seed = '';
          ta.value = seed;
          // Mark the host as "dirty since last save" on textarea
          // input.  The textarea ``input`` event bubbles to the
          // host, where the Nim mount has an ``input`` listener
          // that flips ``SpecPaneVM.dirty`` to true.  We also fire
          // a synthetic ``isonim-spec-dirty`` event for the e2e
          // tests that need a robust signal independent of the
          // native event bubbling.
          ta.addEventListener('input', function () {
            try {
              host.dispatchEvent(new CustomEvent('isonim-spec-dirty', {
                bubbles: true,
              }));
            } catch (_) {}
          });
          host.appendChild(ta);
        }
        // Toggle ProseMirror visibility so the textarea doesn't
        // compete with TipTap's surface for clicks/keyboard focus.
        var pm = host.querySelector('.ProseMirror');
        if (pm && pm.style) {
          pm.style.display = editable ? 'none' : '';
        }
        if (ta && ta.style) {
          ta.style.display = editable ? '' : 'none';
        }
        host.setAttribute('data-tiptap-editable', editable ? 'true' : 'false');
        if (editable && ta && typeof ta.focus === 'function') {
          try { ta.focus(); } catch (_) {}
        }
      } catch (e) {
        try { console.error('setTipTapEditable failed', e); } catch (_) {}
      }
    """].}

  proc getTipTapMarkdown*(container: Element): string =
    ## Returns the current markdown body the user sees in Edit mode.
    ## In View mode (or before any textarea is mounted) returns the
    ## last-seeded body the editor put on the host via
    ## ``mountTipTapViewer``.  Empty string when nothing has been
    ## written yet.
    if container == nil:
      return ""
    var raw: cstring = ""
    {.emit: ["""
      try {
        var host = """, container, """;
        if (host) {
          var ta = host.querySelector('textarea[data-spec-pane-textarea="true"]');
          if (ta && typeof ta.value === 'string') {
            """, raw, """ = ta.value;
          } else {
            var seed = host.getAttribute('data-spec-pane-markdown');
            """, raw, """ = seed === null ? '' : seed;
          }
        }
      } catch (_) {}
    """].}
    $raw

else:
  # Native (non-JS) build: the shim exists so modules that import it
  # compile in the headless test pipeline. None of these are called on
  # the native target — the editor's spec_pane VM tests never mount
  # TipTap; only the JS bundle does.
  type Element* = ref object

  proc isTipTapAvailable*(): bool = false

  proc mountTipTapViewer*(container: Element; markdown: string) =
    discard

  proc unmountTipTapViewer*(container: Element) =
    discard

  proc isTipTapEditableContainer*(container: Element): bool = false

  proc setTipTapEditable*(container: Element; editable: bool) =
    ## TBAR-M5 — native stub.  The headless VM tests never mount
    ## TipTap (or its textarea overlay); they only verify the VM-side
    ## reactive state.
    discard

  proc getTipTapMarkdown*(container: Element): string =
    ## TBAR-M5 — native stub.  Always returns the empty string; the
    ## VM tests use a separate ``markdown`` Signal as the source of
    ## truth and never touch the DOM.
    ""
