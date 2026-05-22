// IsoNim TipTap bundle entry point.
//
// Exposes a single global ``window.IsoNimTipTap`` that wraps the
// TipTap v2 core + StarterKit + the ``marked`` markdown library.
// The shape is:
//
//   window.IsoNimTipTap = {
//     version: "2.x.x",
//     Editor: Editor,                           // @tiptap/core
//     StarterKit: StarterKit,                   // @tiptap/starter-kit
//     marked: marked,                            // markdown -> HTML
//     mountViewer: function(container, markdown) { ... },
//     unmount: function(container) { ... },
//     isEditableContainer: function(container) { ... }
//   }
//
// ``mountViewer`` constructs a read-only TipTap Editor (StarterKit
// only) on ``container``, converts ``markdown`` to HTML via
// ``marked``, and sets the editor content. Subsequent calls on the
// same container destroy the previous Editor instance first to avoid
// ProseMirror state leakage.
//
// Wiring of arrow keys / outside-click etc. is left to the existing
// TipTap defaults. Read-only mode is enforced via
// ``editor.setEditable(false)`` and the ``editable: false`` option.

import { Editor } from "@tiptap/core";
import { StarterKit } from "@tiptap/starter-kit";
import { marked } from "marked";

const REGISTRY = new WeakMap();

function destroyExisting(container) {
  const prev = REGISTRY.get(container);
  if (prev) {
    try { prev.destroy(); } catch (_) {}
    REGISTRY.delete(container);
  }
}

function mountViewer(container, markdown) {
  if (!container) return null;
  destroyExisting(container);
  const html = marked.parse(markdown || "", { async: false });
  const editor = new Editor({
    element: container,
    extensions: [StarterKit],
    content: html,
    editable: false,
  });
  // Mark the container so tests can assert it's a TipTap-mounted
  // surface without poking at internals.
  container.setAttribute("data-tiptap-mounted", "true");
  container.setAttribute("data-tiptap-editable",
    editor.isEditable ? "true" : "false");
  REGISTRY.set(container, editor);
  return editor;
}

function unmount(container) {
  if (!container) return;
  destroyExisting(container);
  container.removeAttribute("data-tiptap-mounted");
  container.removeAttribute("data-tiptap-editable");
}

function isEditableContainer(container) {
  const ed = REGISTRY.get(container);
  if (!ed) return false;
  return ed.isEditable === true;
}

const Bundle = {
  version: "tiptap-2.x + marked-18.x (vendored)",
  Editor,
  StarterKit,
  marked,
  mountViewer,
  unmount,
  isEditableContainer,
};

// UMD-ish global. We deliberately do NOT participate in an AMD /
// CommonJS loader handshake — the editor's index.html loads this via
// a plain ``<script>`` tag and reads the global.
if (typeof window !== "undefined") {
  window.IsoNimTipTap = Bundle;
}
if (typeof globalThis !== "undefined") {
  globalThis.IsoNimTipTap = Bundle;
}

export default Bundle;
