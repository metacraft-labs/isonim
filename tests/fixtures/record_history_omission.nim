## Both native and omitted JS APIs must remain absent, not silently installed.
import isonim/core/private/record_history
static: doAssert not declared(RecordHistoryPrimitives)
echo "history omission PASS"
