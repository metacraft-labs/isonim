"""Native process identity for real editor/provider integration tests.

No OS metadata is mocked. Linux observes /proc; Darwin gets exact argv through
KERN_PROCARGS2 and executable paths through libproc. The portable ps observer
is also exercised with real Linux children. Darwin uses native BSD process start
time in microseconds; Linux retains kernel start ticks in both observers.
"""
import ctypes
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def capture_owned(table, roots, known=None):
    """Retain native identities while their observed ancestry proves ownership.

    An already recorded start identity remains a seed after reparenting. A reused
    PID never becomes a seed. Do not discover ownership from a path or a name.
    """
    result = dict(known or {})
    seeds = {pid for pid in roots if pid in table and
             (pid not in result or table[pid][1] == result[pid][1])}
    seeds.update(pid for pid, row in result.items()
                 if pid in table and table[pid][1] == row[1])
    while True:
        added = {pid for pid, row in table.items() if row[0] in seeds and
                 (pid not in result or row[1] == result[pid][1])} - seeds
        if not added:
            break
        seeds.update(added)
    for pid in seeds:
        if pid in table:
            result[pid] = table[pid]
    return result


def reap_owned(observer, identities, children=(), seconds=15):
    """Bound exceptional cleanup; require actual disappearance, including zombies.

    Every signal rechecks native start identity and the captured executable.
    Cleanup does not certify a crashed native process as a successful exit.
    """
    deadline = time.monotonic() + seconds

    def remaining():
        for child in children:
            child.poll()  # Reap only our actual Popen children.
        table = observer.snapshot()
        return {pid: row for pid, row in table.items() if pid in identities and
                row[1] == identities[pid][1]}

    def signal_remaining(signum):
        for pid, row in remaining().items():
            if row[3] is None:
                continue  # A zombie/inaccessible executable is not safe to signal.
            if row[3] != identities[pid][3]:
                raise AssertionError('Owned process executable changed before cleanup')
            try:
                os.kill(pid, signum)
            except ProcessLookupError:
                pass

    signal_remaining(signal.SIGTERM)
    grace = min(deadline, time.monotonic() + 5)
    while remaining() and time.monotonic() < grace:
        time.sleep(.03)
    if remaining():
        signal_remaining(signal.SIGKILL)
    while remaining() and time.monotonic() < deadline:
        time.sleep(.03)
    outstanding = remaining()
    if outstanding:
        raise AssertionError('Owned processes were not physically reaped: ' +
                             repr({pid: row[1] for pid, row in outstanding.items()}))


def require_exit(process, allowed, role):
    """Use actual wait status; signal/core failures never pass through log text."""
    code = process.poll()
    if code is None or code not in allowed:
        raise AssertionError(f'{role} native exit {code}; expected {sorted(allowed)}')
    return code


def linux_identity(pid):
    path = Path('/proc') / str(pid)
    stat = (path / 'stat').read_text().rsplit(')', 1)[1].split()
    try:
        raw = (path / 'cmdline').read_bytes()
        argv = [s.decode(errors='surrogateescape') for s in raw.split(b'\0')[:-1]]
    except OSError:
        argv = None
    try:
        executable = os.readlink(path / 'exe')
    except OSError:
        executable = None
    # In particular, zombies retain their native stat/starttime while their
    # command/executable becomes unavailable. They are not reaped processes.
    return int(stat[1]), stat[19], argv, executable


class DarwinBsdInfo(ctypes.Structure):
    # Native ABI: apple-oss-distributions/xnu bsd/sys/proc_info.h proc_bsdinfo.
    # Same PROC_PIDTBSDINFO start-time API used by io-mon's macOS runtime.
    _fields_ = [(name, ctypes.c_uint32) for name in (
        'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid',
        'rgid', 'svuid', 'svgid', 'reserved')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in ('nfiles', 'pgid', 'pjobc', 'tdev', 'tpgid')]
    _fields_ += [('nice', ctypes.c_int32), ('start_sec', ctypes.c_uint64), ('start_usec', ctypes.c_uint64)]


class DarwinIdentity:
    def __init__(self):
        self.libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        self.libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        self.libc.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint,
                                    ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t),
                                    ctypes.c_void_p, ctypes.c_size_t]
        self.libc.sysctl.restype = ctypes.c_int
        self.libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint]
        self.libproc.proc_pidpath.restype = ctypes.c_int
        self.libproc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                             ctypes.c_void_p, ctypes.c_int]
        self.libproc.proc_pidinfo.restype = ctypes.c_int

    def arguments(self, pid):
        # Darwin KERN_PROCARGS2 returns argc, executable, alignment NULs,
        # then exactly argc NUL-terminated arguments followed by environment.
        mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2, pid
        size = ctypes.c_size_t()
        if self.libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
            raise OSError(ctypes.get_errno(), 'KERN_PROCARGS2 size')
        if not ctypes.sizeof(ctypes.c_int) < size.value <= 1024 * 1024:
            raise OSError('Invalid native argument buffer size')
        data = ctypes.create_string_buffer(size.value)
        if self.libc.sysctl(mib, 3, data, ctypes.byref(size), None, 0) != 0:
            raise OSError(ctypes.get_errno(), 'KERN_PROCARGS2 arguments')
        raw = data.raw[:size.value]
        argc = ctypes.c_int.from_buffer_copy(raw).value
        offset = raw.index(b'\0', ctypes.sizeof(ctypes.c_int)) + 1
        while offset < len(raw) and raw[offset] == 0:
            offset += 1
        argv = []
        for _ in range(argc):
            end = raw.index(b'\0', offset)
            argv.append(raw[offset:end].decode(errors='surrogateescape'))
            offset = end + 1
        return argv

    def executable(self, pid):
        executable = ctypes.create_string_buffer(4096)  # PROC_PIDPATHINFO_MAXSIZE
        if self.libproc.proc_pidpath(pid, executable, len(executable)) <= 0:
            raise OSError(ctypes.get_errno(), 'proc_pidpath')
        return os.fsdecode(executable.value)

    def __call__(self, pid):
        # Obtain stable BSD identity first. A failed argv/path query must not
        # turn an existing process (including a zombie) into an absent one.
        info = DarwinBsdInfo()
        if self.libproc.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
            raise OSError(ctypes.get_errno(), 'PROC_PIDTBSDINFO start time')
        if info.pid != pid or info.start_sec == 0:
            raise OSError('Native BSD process identity is unavailable')
        start = str(info.start_sec * 1000000 + info.start_usec)
        try:
            argv = self.arguments(pid)
        except (OSError, ValueError, IndexError):
            argv = None
        try:
            executable = self.executable(pid)
        except OSError:
            executable = None
        return info.ppid, start, argv, executable


class LinuxProcessObserver:
    starttime_kind = 'linux-kernel-start-ticks'

    def snapshot(self):
        result = {}
        for path in Path('/proc').iterdir():
            if not path.name.isdigit():
                continue
            try:
                result[int(path.name)] = linux_identity(int(path.name))
            except (OSError, ValueError, IndexError):
                pass  # Exit races and inaccessible unrelated processes.
        return result


class PosixProcessObserver:
    def __init__(self):
        self.ps = shutil.which('ps')
        if self.ps is None:
            raise OSError('Native ps is required for process continuity acceptance')
        self.ps = str(Path(self.ps).resolve())
        self.native = DarwinIdentity() if sys.platform == 'darwin' else None
        self.starttime_kind = ('darwin-native-start-microseconds-since-epoch' if self.native is not None
                               else 'linux-kernel-start-ticks')
        if self.native is None and sys.platform != 'linux':
            raise OSError('Exact native argv observation is implemented for Linux and Darwin')
        self.known = {}

    def snapshot(self):
        # Regular files avoid waiting for inherited stdout/stderr pipe EOF.
        # Freeze ps at construction and bound its real process lifetime.
        with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
            env = dict(os.environ, LC_ALL='C', LANG='C')
            proc = subprocess.Popen([self.ps, '-axo', 'pid=,ppid='],
                                    stdout=output, stderr=errors, env=env, start_new_session=True)
            try:
                code = proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait(timeout=5)
                raise OSError('Native ps process enumeration exceeded five seconds')
            if code != 0:
                errors.seek(0)
                raise OSError('Native ps process enumeration failed: ' + errors.read().decode(errors='replace'))
            output.seek(0)
            rows = output.read().decode().splitlines()
        result = {}
        for row in rows:
            fields = row.split()
            if len(fields) != 2:
                raise OSError('Malformed native ps process row')
            pid, parent = int(fields[0]), int(fields[1])
            # ps enumerates identities; exact argv/executable/starttime come
            # from native APIs. Never parse a command or path on whitespace.
            try:
                identity = self.native(pid) if self.native is not None else linux_identity(pid)
                # Native metadata is newer than the enumeration. Reparenting
                # between those reads is not evidence that the PID was reaped.
                result[pid] = identity
            except (OSError, ValueError, IndexError):
                # If ps still lists a known PID, unavailable BSD metadata is
                # uncertainty, not reaping. Retain its last verified starttime
                # without claiming current argv/executable. Live checks fail;
                # close waits for disappearance or a new native start identity.
                if pid in self.known:
                    result[pid] = parent, self.known[pid][1], None, None
        self.known = result
        return result


def process_observer():
    return LinuxProcessObserver() if sys.platform == 'linux' else PosixProcessObserver()


def optional_sibling_available(path):
    """Only a genuinely absent path is optional; broken checkouts fail."""
    if not os.path.lexists(path):
        return False
    if not path.is_dir():
        raise OSError('Present Agent Harbor sibling is not a directory: ' + str(path))
    for name in ('Cargo.toml', 'repro.nim'):
        if not (path / name).is_file():
            raise OSError('Present Agent Harbor sibling is missing required ' + name + ': ' + str(path))
    return True
