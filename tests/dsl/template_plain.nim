## The fixtures of `template_fixtures.nim`, built with one renderer call per node.
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/dsl/ui

include template_fixtures

export staticCard, dynamicRow, withHandlers, mixed
