## Prints the brief ids of the index baked into this program, one per line.
## Compiled by `tests/test_design_review_consumer_brief_index.nim`, with and
## without `-d:isonimBriefIndexJson`.
import std/tables
import isonim/editor/design_review/brief_index_static

for id in builtInBriefIndex().byBriefId.keys:
  echo id
