# Chat event presentation corpus

`chat-session-events.json` contains one data fixture for each of the 34 variants
in Agent Harbor's REST `SessionEvent` union at `ca478177`, defined in
`crates/ah-rest-api-contract/src/types.rs`. It uses actual serde field names,
including tool arguments, diff old/new text, reported usage, question options,
login and session lifecycle events. Fake credentials and login surface strings
are privacy controls: neither may reach the projected browser presentation.

The mounted GUI fixture normalizes these DTOs using production nim-agents,
serializes the safe wire shape, decodes it using the production editor SSE
adapter and applies it to the actual mounted editor reducer. This verifies
presentation, not provider execution. Real REST/provider coverage runs through
the existing registered Harbor scenario suite; deterministic agent behavior
workflows are extended in milestone EAC-M5.
