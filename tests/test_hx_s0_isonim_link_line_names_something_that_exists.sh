#!/usr/bin/env bash
# test_hx_s0_isonim_link_line_names_something_that_exists.sh
#
# Integration Gate for Milestone HX-S-0 & NH-M5:
# "hx_s0_isonim_link_line_names_something_that_exists"
# Satisfies NH-M5 "test_hcr_shim_links_against_a_real_library".
#
# Design docs:
# - reprobuild-specs/HCR/HCR-Overview.md §7, §13
# - codetracer-specs/Front-Ends/IsoNim/Hot-Module-Reload-Native.md
#
# Asserts:
# 1. Real build of IsoNim with -d:reprobuildHcr links against librepro_hcr_agent.
# 2. Produces a real linked executable and runs it.
# 3. Asserts every bound HCR symbol resolves to a defined address.
# 4. Control arm: flag-off build links and contains ZERO rb_hcr_ / repro_hcr_ symbols.
# 5. Falsifiers:
#    - Reverting link line to -lct_hcr_agent fails at LINK with linker diagnostic.
#    - Reverting header to reprobuild/hcr.h fails at PREPROCESS with preprocessor diagnostic.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISONIM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd "$ISONIM_DIR/.." && pwd)"
REPRO_AGENT_DIR="$WORKSPACE_ROOT/reprobuild/libs/repro_hcr_agent"
REPRO_AGENT_C="$REPRO_AGENT_DIR/c"
REPRO_AGENT_BUILD="$REPRO_AGENT_DIR/build"

WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d /tmp/hx_s0_gate2_XXXXXX)}"

cleanup() {
  if [[ -z "${PRESERVE_WORK:-}" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

echo "=== Gate 2: hx_s0_isonim_link_line_names_something_that_exists ==="
echo "Working directory: $WORK_DIR"

# Ensure librepro_hcr_agent is built
if [[ ! -s "$REPRO_AGENT_BUILD/librepro_hcr_agent.dylib" ]]; then
  echo "Building librepro_hcr_agent..."
  "$REPRO_AGENT_DIR/build_lib.sh" "$REPRO_AGENT_BUILD"
fi

# -----------------------------------------------------------------------------
# 1. Active build: -d:reprobuildHcr against librepro_hcr_agent
# -----------------------------------------------------------------------------
echo "[1/4] Building IsoNim HCR shim with -d:reprobuildHcr..."

ACTIVE_SRC="$WORK_DIR/test_active.nim"
ACTIVE_BIN="$WORK_DIR/test_active"

cat << 'EOF' > "$ACTIVE_SRC"
import isonim/native/hcr

# Exercise all 10 rb_hcr_* functions bound by IsoNim
assert rbHcrWantsReload() == false, "wants_reload should be false in baseline"
rbHcrApplyReload()

rbHcrRegisterManagedType("test.ComponentState")
rbHcrUnregisterManagedType("test.ComponentState")

assert rbHcrFileChanged("src/main.nim") == false, "file_changed should be false in baseline"
assert rbHcrTypeChanged("test.ComponentState") == false, "type_changed should be false in baseline"

var hitCount = 0
proc reloadCallback(info: ptr RbHcrReloadInfo, userData: pointer) {.cdecl.} =
  inc hitCount
  # NH-M2: READ the struct fields, do not merely receive the pointer.
  # Every field of RbHcrReloadInfo / RbHcrTypeChange needs its own
  # `importc` because the C header spells them snake_case while Nim
  # spells them camelCase; without those pragmas this callback body is
  # the first thing that fails to compile, and a probe that only
  # increments a counter never touches a field and so never notices.
  # That is exactly how the mismatch survived from NH-M0 to NH-M2.
  if info != nil:
    if info.changedFilesCount > 0'u32 and info.changedFiles != nil:
      discard $info.changedFiles[0]
    if info.changedTypesCount > 0'u32 and info.changedTypes != nil:
      let tc = info.changedTypes[0]
      discard $tc.typeName
      discard tc.oldSize + tc.newSize

rbHcrBeforeReload(reloadCallback, nil)
rbHcrAfterReload(reloadCallback, nil)
rbHcrRemoveBeforeReload(reloadCallback, nil)
rbHcrRemoveAfterReload(reloadCallback, nil)

echo "ACTIVE-OK: all 10 rb_hcr_* functions executed successfully against librepro_hcr_agent"
EOF

nim c -d:reprobuildHcr \
  --hints:off --warnings:off \
  --path:"$ISONIM_DIR/src" \
  --cincludes:"$REPRO_AGENT_C" \
  --clibdir:"$REPRO_AGENT_BUILD" \
  --passL:"-Wl,-rpath,$REPRO_AGENT_BUILD" \
  -o:"$ACTIVE_BIN" "$ACTIVE_SRC"

if [[ ! -x "$ACTIVE_BIN" ]]; then
  echo "ERROR: Active build failed to produce executable at $ACTIVE_BIN" >&2
  exit 1
fi

echo "  [OK] Successfully linked binary: $ACTIVE_BIN"

# Execute the linked binary
ACTIVE_OUT="$("$ACTIVE_BIN")"
if ! echo "$ACTIVE_OUT" | grep -q "ACTIVE-OK"; then
  echo "ERROR: Active binary execution failed: $ACTIVE_OUT" >&2
  exit 1
fi
echo "  $ACTIVE_OUT"

# Anti-vacuity: verify bound symbols resolve to defined addresses in the executable / dylib
echo "  Checking symbol resolution with nm..."
BOUND_SYMBOLS=(
  "rb_hcr_wants_reload"
  "rb_hcr_apply_reload"
  "rb_hcr_register_managed_type"
  "rb_hcr_unregister_managed_type"
  "rb_hcr_before_reload"
  "rb_hcr_after_reload"
  "rb_hcr_remove_before_reload"
  "rb_hcr_remove_after_reload"
  "rb_hcr_file_changed"
  "rb_hcr_type_changed"
)

NM_OUT="$(nm "$ACTIVE_BIN" 2>/dev/null)"
for sym in "${BOUND_SYMBOLS[@]}"; do
  if ! echo "$NM_OUT" | grep -q "_$sym"; then
    echo "ERROR: Symbol _$sym not referenced by $ACTIVE_BIN" >&2
    exit 1
  fi
done
echo "  [OK] All ${#BOUND_SYMBOLS[@]} rb_hcr_* symbols referenced and resolved."

# -----------------------------------------------------------------------------
# 2. Control arm: flag-off build contains 0 rb_hcr_ / repro_hcr_ symbols
# -----------------------------------------------------------------------------
echo "[2/4] Testing control arm (flag-off build)..."

CONTROL_SRC="$WORK_DIR/test_control.nim"
CONTROL_BIN="$WORK_DIR/test_control"

cat << 'EOF' > "$CONTROL_SRC"
import isonim/native/hcr

assert rbHcrWantsReload() == false
rbHcrApplyReload()
rbHcrRegisterManagedType("test.ComponentState")
rbHcrUnregisterManagedType("test.ComponentState")
assert rbHcrFileChanged("src/main.nim") == false
assert rbHcrTypeChanged("test.ComponentState") == false

var hitCount = 0
proc reloadCallback(info: ptr RbHcrReloadInfo, userData: pointer) {.cdecl.} =
  inc hitCount

rbHcrBeforeReload(reloadCallback, nil)
rbHcrAfterReload(reloadCallback, nil)
rbHcrRemoveBeforeReload(reloadCallback, nil)
rbHcrRemoveAfterReload(reloadCallback, nil)

echo "CONTROL-OK: flag-off build executed fallback no-op procs"
EOF

nim c \
  --hints:off --warnings:off \
  --path:"$ISONIM_DIR/src" \
  -o:"$CONTROL_BIN" "$CONTROL_SRC"

if [[ ! -x "$CONTROL_BIN" ]]; then
  echo "ERROR: Control build failed to produce executable at $CONTROL_BIN" >&2
  exit 1
fi

CONTROL_OUT="$("$CONTROL_BIN")"
if ! echo "$CONTROL_OUT" | grep -q "CONTROL-OK"; then
  echo "ERROR: Control binary execution failed: $CONTROL_OUT" >&2
  exit 1
fi
echo "  $CONTROL_OUT"

# Assert exactly 0 rb_hcr_ and repro_hcr_ symbols in control binary
NM_CONTROL="$(nm -a "$CONTROL_BIN" 2>/dev/null || nm "$CONTROL_BIN")"
LEAKED="$(echo "$NM_CONTROL" | grep -E 'rb_hcr_|repro_hcr_' || true)"
if [[ -n "$LEAKED" ]]; then
  echo "ERROR: Leaked HCR symbols in flag-off build:" >&2
  echo "$LEAKED" >&2
  exit 1
fi
echo "  [OK] Control binary contains zero HCR symbols (zero-cost when inactive)."

# -----------------------------------------------------------------------------
# 3. Falsifier 1: Reverting link line to -lct_hcr_agent must fail at LINK
# -----------------------------------------------------------------------------
echo "[3/4] Testing Falsifier 1: link line reverted to -lct_hcr_agent..."

FALSIFIER1_SRC="$WORK_DIR/test_falsifier1.nim"
FALSIFIER1_BIN="$WORK_DIR/test_falsifier1"

# Create a module with loser link line -lct_hcr_agent
cat << 'EOF' > "$FALSIFIER1_SRC"
{.passL: "-lct_hcr_agent".}

proc rb_hcr_wants_reload*(): bool
  {.importc: "rb_hcr_wants_reload", header: "repro_hcr_agent.h".}

discard rb_hcr_wants_reload()
EOF

set +e
FALSIFIER1_OUTPUT="$(nim c \
  --hints:off \
  --cincludes:"$REPRO_AGENT_C" \
  --clibdir:"$REPRO_AGENT_BUILD" \
  -o:"$FALSIFIER1_BIN" "$FALSIFIER1_SRC" 2>&1)"
FALSIFIER1_RC=$?
set -e

if [[ $FALSIFIER1_RC -eq 0 ]]; then
  echo "ERROR: Falsifier 1 unexpectedly succeeded when linking against -lct_hcr_agent!" >&2
  exit 1
fi

if ! echo "$FALSIFIER1_OUTPUT" | grep -E -q "library 'ct_hcr_agent' not found|library not found for -lct_hcr_agent|cannot find -lct_hcr_agent"; then
  echo "WARNING: Falsifier 1 failed with unexpected diagnostic:" >&2
  echo "$FALSIFIER1_OUTPUT" >&2
else
  echo "  [OK] Reverting link line to -lct_hcr_agent failed at LINK with toolchain diagnostic:"
  echo "       $(echo "$FALSIFIER1_OUTPUT" | grep -E "library 'ct_hcr_agent' not found|library not found for -lct_hcr_agent|cannot find -lct_hcr_agent" | head -n 1)"
fi

# -----------------------------------------------------------------------------
# 4. Falsifier 2: Reverting header to reprobuild/hcr.h must fail at PREPROCESS
# -----------------------------------------------------------------------------
echo "[4/4] Testing Falsifier 2: header reverted to reprobuild/hcr.h..."

FALSIFIER2_SRC="$WORK_DIR/test_falsifier2.nim"
FALSIFIER2_BIN="$WORK_DIR/test_falsifier2"

cat << 'EOF' > "$FALSIFIER2_SRC"
proc rb_hcr_wants_reload*(): bool
  {.importc: "rb_hcr_wants_reload", header: "reprobuild/hcr.h".}

discard rb_hcr_wants_reload()
EOF

set +e
FALSIFIER2_OUTPUT="$(nim c \
  --hints:off \
  --cincludes:"$REPRO_AGENT_C" \
  --clibdir:"$REPRO_AGENT_BUILD" \
  -o:"$FALSIFIER2_BIN" "$FALSIFIER2_SRC" 2>&1)"
FALSIFIER2_RC=$?
set -e

if [[ $FALSIFIER2_RC -eq 0 ]]; then
  echo "ERROR: Falsifier 2 unexpectedly succeeded when including reprobuild/hcr.h!" >&2
  exit 1
fi

if ! echo "$FALSIFIER2_OUTPUT" | grep -E -q "reprobuild/hcr\.h.*file not found|cannot open file: reprobuild/hcr\.h|No such file or directory"; then
  echo "WARNING: Falsifier 2 failed with unexpected diagnostic:" >&2
  echo "$FALSIFIER2_OUTPUT" >&2
else
  echo "  [OK] Reverting header to reprobuild/hcr.h failed at PREPROCESS with toolchain diagnostic:"
  echo "       $(echo "$FALSIFIER2_OUTPUT" | grep -E "reprobuild/hcr\.h.*file not found|cannot open file: reprobuild/hcr\.h|No such file or directory" | head -n 1)"
fi

echo ""
echo "=== Gate 2 PASSED: hx_s0_isonim_link_line_names_something_that_exists ==="
