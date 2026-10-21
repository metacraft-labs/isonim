This metadata pins a private, genuine native literal-constant consumer fixture.
Only provenance is committed here; no private project source is vendored.

The integration test accepts the exact declared archive through
`ISONIM_SOURCE_PROVIDER_ARCHIVE`, or extracts it read-only from the declared
revision in an existing sibling checkout. The archive must match `source.json`.
There is no runtime fetch or fallback to a newer, incompatible source format.
A missing source object/archive is a test failure with acquisition instructions.
CI running this integration gate must provision that private dependency first.

The producer is an original format adapter around the fixture's real workspace
and SSR APIs. Compilation, native source transactions, catalog publication,
refusals and undo all execute normally. These tests qualify literal constants;
they do not claim support for a newer consumer's generated/tokenized format.
