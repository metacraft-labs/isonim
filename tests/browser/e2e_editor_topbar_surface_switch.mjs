// Phase I (2026-05-28) — OBSOLETE STUB.
//
// The top-bar Preview / Spec surface switch (TBAR-M3) was removed.
// The Surface cluster is gone; its Spec selection folds into the
// Mode cluster as a fourth option (Spec / View / Comment / Edit),
// and selecting ``emSpec`` couples ``surfaceSig`` to ``sSpec``
// via ``setEditMode``. See ``Front-Ends/IsoNim/isonim-editor.md``
// §"Mode-driven right sidebar (2026-05-28 revision)".
//
// The replacement live test that exercises the mode-strip Spec
// pill end-to-end is
// ``tests/browser/e2e_editor_mode_sidebar_swap_live.mjs``; the
// chevron screen-size selector behaviour previously asserted here
// is also exercised by the chrome-bar choice-group e2e suite
// (``e2e_editor_chrome_uses_choice_group.mjs``).

import test from "node:test";

test.skip("e2e_editor_topbar_surface_switch: OBSOLETE — Surface cluster removed in Phase I", () => {});
