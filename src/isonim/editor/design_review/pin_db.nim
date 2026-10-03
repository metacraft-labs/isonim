## REV-M5 — persistence of workspace pins (migration 011).
##
## ``record_workspace_pin`` stores a pin's canonical lock record before
## ``start_run`` references it; ``fetch_workspace_pin`` returns it for
## replay.  Both are SECURITY DEFINER routines, so the app role needs no
## table grants.

import std/json

import db_connector/db_postgres

import ./db
import ./workspace_pin

proc recordWorkspacePin*(db: ReviewDb; pin: WorkspacePin; recordedBy: string) =
  ## Idempotent: recording the same pin twice is a no-op.
  discard db.conn.getValue(
    sql"SELECT design_review.record_workspace_pin(?, ?, ?, ?)",
    pin.pin, pin.lockToml, pin.lockRecord, recordedBy)

proc fetchWorkspacePinLock*(db: ReviewDb; pin: string): string =
  ## The stored canonical lock record for ``pin``.  Raises
  ## ``WorkspacePinError`` when no record exists or it does not hash to
  ## ``pin``.
  let raw =
    try:
      db.conn.getValue(sql"SELECT design_review.fetch_workspace_pin(?)::text",
                       pin)
    except DbError as e:
      raise newException(WorkspacePinError,
        "workspace pin " & pin & " is not recorded: " & e.msg)
  let lockToml = parseJson(raw)["lock_toml"].getStr
  discard resolvePin(pin, lockToml)
  lockToml
