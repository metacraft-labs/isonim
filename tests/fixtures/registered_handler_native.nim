## Native common module omission proof: compile, link and execute real core.
import isonim/core/nondet
when declared(callInternalRegisteredHandler):
  {.error: "JS registered-handler API leaked into native common graph".}
when declared(rawCallInternalRegisteredHandler):
  {.error: "raw registered-handler API leaked into native common graph".}
let selected = newTestBackend(123)
install(selected)
doAssert selected.now() == 123.0
echo "registered-handler-native-common-omission PASS"
