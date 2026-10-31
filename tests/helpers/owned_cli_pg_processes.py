"""Native metadata for test-owned PG roots; no process signals or mocks.

The Linux no-orphan query relies on the CALLER actually enabling subreaping.
It covers descendants that change sessions: ownership is parentage/adoption,
not a name, data-directory substring or process group.
"""
import json
import os
import sys
import signal
from editor_process_observer import process_observer, capture_owned

observer = process_observer()
mode = sys.argv[1]
if mode == "identity":
    pid = int(sys.argv[2])
    table = observer.snapshot()
    row = table[pid]
    print(json.dumps({"pid": pid, "ppid": row[0], "birth": row[1],
                      "argv": row[2], "exe": row[3], "sid": os.getsid(pid)}))
elif mode == "orphans":
    if not sys.platform.startswith("linux"):
        raise RuntimeError("Complete Darwin adopted-descendant authority is not implemented; no orphan acceptance")
    root, compose = map(int, sys.argv[2:4])
    root_birth, compose_birth = sys.argv[4:6]
    assert os.getppid() == root, "query must be the actual direct child of the retained test root"
    table = observer.snapshot()
    assert table[root][1] == root_birth
    assert table[compose][1] == compose_birth
    owned = capture_owned(table, {root})
    pg = capture_owned(table, {compose})
    query = capture_owned(table, {os.getpid()})
    unexpected = {pid: {"ppid": row[0], "birth": row[1], "exe": row[3]}
                  for pid, row in owned.items()
                  if pid != root and pid not in pg and pid not in query}
    print(json.dumps({"root": root, "rootBirth": root_birth,
                      "compose": compose, "composeBirth": compose_birth,
                      "orphans": unexpected}))
elif mode == "recover":
    if not sys.platform.startswith("linux"):
        raise RuntimeError("Linux pidfd recovery only; Darwin remains unresolved")
    root, root_birth = int(sys.argv[2]), sys.argv[3]
    requested = int(sys.argv[4]) if len(sys.argv) == 5 else signal.SIGTERM
    assert requested in (signal.SIGTERM, signal.SIGKILL)
    assert os.getppid() == root
    table = observer.snapshot()
    assert table[root][1] == root_birth
    owned = capture_owned(table, {root})
    query = capture_owned(table, {os.getpid()})
    children = []
    for pid, row in owned.items():
        if pid == root or pid in query:
            continue
        if row[0] == root:
            children.append({"pid": pid, "birth": row[1]})
        try:
            descriptor = os.pidfd_open(pid)
        except ProcessLookupError:
            continue
        try:
            current = observer.snapshot()
            assert current[root][1] == root_birth
            if pid not in current:
                continue
            assert current[pid][1] == row[1], "PID changed before held pidfd binding"
            assert pid in capture_owned(current, {root}), "descendant authority changed"
            # A held pidfd directs the signal to this exact process identity;
            # sessions, executable names and shared PG paths confer no authority.
            try:
                signal.pidfd_send_signal(descriptor, requested)
            except ProcessLookupError:
                pass
        finally:
            os.close(descriptor)
    print(json.dumps({"children": children,
                      "ownedCount": len(owned) - len(query) - 1}))
else:
    raise RuntimeError("Unknown owned-process query")
