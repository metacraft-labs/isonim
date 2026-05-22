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

// Each global is a small namespace object. Keeping a single named
// global per logical library matches the per-library FFI module
// design (one Nim file per JS library) and lets the bundle expose
// the constructors + helpers each consumer needs without colliding
// with anything else on ``globalThis``.

globalThis.TipTap = { Editor };
globalThis.TipTapStarterKit = { StarterKit };
globalThis.TipTapMarkdown = { Markdown };
