// OBSOLETE — superseded by Phase F.
//
// The Manual/Assistant tab pair in the right sidebar is gone (Phase
// A demolition, 2026-05-28).  Per ``Front-Ends/IsoNim/isonim-editor
// .md`` §"AI assistant placement", the AI chat now lives in a
// chrome-bar-driven slide-out drawer; per-chat affordances are the
// robot icons in ``[data-preview-chrome-bar] [data-chrome-chat-strip]``
// and the drawer itself is ``[data-ai-drawer]``.
//
// The replacement contract is exercised by:
//   * ``e2e_editor_chat_tabs_live.mjs`` — robot row + chrome-bar +
//     plus button + horizontal scroll.
//   * ``e2e_editor_ai_drawer_live.mjs`` — drawer open/close/toggle +
//     ESC + click-outside + chat composer reachability.
//
// This file is intentionally empty so ``node --test`` runs zero
// tests against it; the surrounding directory listing keeps the
// filename as a breadcrumb pointing at the new e2e coverage.
