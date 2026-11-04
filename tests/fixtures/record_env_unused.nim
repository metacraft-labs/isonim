## Import-only omission/inertness; no fake parent module or recorder import.
import isonim/core/private/record_env
when not defined(js) or not defined(isonimInternalRecordEnv):
  static: doAssert not declared(projectInternalRecordEnv)
echo "record-env-unused PASS"
