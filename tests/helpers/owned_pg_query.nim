## Test-only asynchronous libpq readiness probe. No server/session replacement.
## One caller-owned absolute deadline covers connection, flush and all results.
import std/[monotimes, times, os, oserrors, posix]
import db_connector/[postgres, db_common]

proc deadlineCheck(deadline: MonoTime) =
  if getMonoTime() >= deadline:
    raise newException(IOError, "Original migration readiness deadline expired")

proc waitSocket(conn: PPGconn; events: cshort; deadline: MonoTime) =
  while true:
    deadlineCheck(deadline)
    # libpq may replace its socket during connection polling.
    let fd = pqsocket(conn)
    if fd < 0: raise newException(DbError, $pqerrorMessage(conn))
    let remaining = (deadline - getMonoTime()).inMilliseconds
    var event = TPollfd(fd: fd.cint, events: events)
    let status = posix.poll(addr event, 1, min(50'i64, max(1'i64, remaining)).cint)
    if status < 0:
      let error = osLastError()
      if error != OSErrorCode(EINTR): raiseOSError(error)
      continue
    deadlineCheck(deadline)
    if (event.revents and POLLNVAL) != 0:
      raise newException(DbError, "Readiness libpq socket became invalid")
    # Timeout/EINTR is not socket readiness. Terminal events let libpq
    # report its genuine connection error instead of spinning here.
    if status > 0 and (event.revents and (events or POLLERR or POLLHUP)) != 0:
      return

proc ownedPgValue*(conninfo, query: string; deadline: MonoTime): string =
  deadlineCheck(deadline)
  # Numeric loopback in the caller's unchanged conninfo avoids DNS resolution.
  let conn = pqconnectStart(conninfo.cstring)
  if conn == nil: raise newException(DbError, "libpq connection allocation failed")
  defer: pqfinish(conn)
  var connectionState = PGRES_POLLING_WRITING
  while true:
    deadlineCheck(deadline)
    case connectionState
    of PGRES_POLLING_READING: waitSocket(conn, POLLIN, deadline)
    of PGRES_POLLING_WRITING: waitSocket(conn, POLLOUT, deadline)
    of PGRES_POLLING_ACTIVE: discard
    of PGRES_POLLING_OK: break
    of PGRES_POLLING_FAILED: raise newException(DbError, $pqerrorMessage(conn))
    deadlineCheck(deadline)
    connectionState = pqconnectPoll(conn)
    case connectionState
    of PGRES_POLLING_OK: break
    of PGRES_POLLING_READING, PGRES_POLLING_WRITING, PGRES_POLLING_ACTIVE: discard
    of PGRES_POLLING_FAILED: raise newException(DbError, $pqerrorMessage(conn))
  deadlineCheck(deadline)
  if pqsetnonblocking(conn, 1) != 0 or pqsendQuery(conn, query.cstring) != 1:
    raise newException(DbError, $pqerrorMessage(conn))
  var flushPending = true
  var seen = false
  while true:
    deadlineCheck(deadline)
    if flushPending:
      let state = pqflush(conn)
      if state < 0: raise newException(DbError, $pqerrorMessage(conn))
      flushPending = state != 0
    if pqconsumeInput(conn) != 1:
      raise newException(DbError, $pqerrorMessage(conn))
    if not flushPending and pqisBusy(conn) == 0:
      let response = pqgetResult(conn)
      if response == nil: break
      try:
        if seen or pqresultStatus(response) != PGRES_TUPLES_OK or
            pqntuples(response) != 1 or pqnfields(response) != 1 or
            pqgetisnull(response, 0, 0) != 0:
          raise newException(DbError, "Unexpected original readiness query result")
        result = $pqgetvalue(response, 0, 0)
        seen = true
      finally: pqclear(response)
    else:
      waitSocket(conn, (POLLIN or (if flushPending: POLLOUT else: 0)).cshort, deadline)
  if not seen: raise newException(DbError, "Original readiness query returned no value")
