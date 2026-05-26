// TBAR-M5b: TipTap UMD bundle entry point.
//
// Imports the runtime-relevant pieces of TipTap from the yarn-managed
// node_modules tree and assigns them to three named ``globalThis``
// objects so the Nim per-library FFI modules
// (``vendor/tiptap.nim``, ``vendor/tiptap_starter_kit.nim``,
// ``vendor/tiptap_markdown.nim``) can pick them up at runtime via
// ``{.importc, nodecl.}``.
//
// The bundle is produced by esbuild (see ``esbuild.config.mjs``) with
// ``--format=iife --bundle --minify`` so a single UMD-shaped file
// drops into ``build/editor/vendor/tiptap.umd.js`` and the editor's
// ``index.html`` loads it with a plain ``<script>`` tag.

import { Editor } from "@tiptap/core";
import { StarterKit } from "@tiptap/starter-kit";
import { Markdown } from "tiptap-markdown";
import { Link } from "@tiptap/extension-link";

// Each global is a small namespace object. Keeping a single named
// global per logical library matches the per-library FFI module
// design (one Nim file per JS library) and lets the bundle expose
// the constructors + helpers each consumer needs without colliding
// with anything else on ``globalThis``.

globalThis.TipTap = { Editor };
globalThis.TipTapStarterKit = { StarterKit };
globalThis.TipTapMarkdown = { Markdown };
// CHRM-M4: ``@tiptap/extension-link`` is vendored here to back the
// formatting toolbar's Link button (Ctrl/Cmd+K).  The package is a
// transitive dep of ``@tiptap/starter-kit`` so the offline-cache hash
// did not change when it was pinned as a direct dependency, but we
// add it to the StarterKit-installed extension set explicitly here
// so the editor instance recognises ``setLink`` / ``unsetLink``
// commands and the ``link`` mark for ``isActive('link')`` queries.
globalThis.TipTapLink = { Link };
