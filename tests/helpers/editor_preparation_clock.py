"""Conservative test clocks for genuine deferred optional-service preparation.

These helpers never prepare a service or create a session. The owning controller
publishes evidence outside the bound project after observing its real helper.
Only the intersection with verified prepublication samples is excluded; API,
provider, tool and cleanup time retain their original bounds.
"""
import json
import os
from pathlib import Path
import stat
import time

SCHEMA = 'isonim-owned-preparation-clock-v1'
COLD_BOUND_NS = 900 * 1_000_000_000


def overlap_ns(start, end, interval_start, interval_end):
    if not 0 <= start <= end or not 0 <= interval_start <= interval_end:
        raise AssertionError('Invalid monotonic interval')
    return max(0, min(end, interval_end) - max(start, interval_start))


def decode(data, nonce, now_ns):
    keys = {'schema', 'nonce', 'generation', 'startNs', 'lastAbsentNs',
            'publishedNs', 'completed', 'error'}
    if not isinstance(data, dict) or set(data) != keys or data['schema'] != SCHEMA or data['nonce'] != nonce:
        raise AssertionError('Malformed or stale preparation-clock evidence')
    if type(data['completed']) is not bool:
        raise AssertionError('Invalid preparation completion flag')
    if data['error'] is not None:
        if not isinstance(data['error'], str):
            raise AssertionError('Invalid observer failure')
        raise AssertionError('Owned preparation observer failed: ' + data['error'])
    if data['startNs'] is None:
        if any(data[key] is not None for key in ['generation', 'lastAbsentNs', 'publishedNs']) or data['completed']:
            raise AssertionError('Unobserved generation cannot grant time')
        return None
    generation = data['generation']
    if (not isinstance(generation, dict) or set(generation) != {'pid', 'starttime', 'directory'} or
        type(generation['pid']) is not int or generation['pid'] <= 0 or
        not isinstance(generation['starttime'], str) or not generation['starttime'] or
        not isinstance(generation['directory'], str) or not Path(generation['directory']).is_absolute()):
        raise AssertionError('Invalid actual preparation generation')
    def integer(key, nullable=False):
        value = data[key]
        if nullable and value is None:
            return None
        if not isinstance(value, str) or not value.isascii() or not value.isdecimal() or len(value) > 24:
            raise AssertionError('Invalid monotonic preparation sample')
        result = int(value)
        if result > now_ns:
            raise AssertionError('Future preparation samples cannot grant time')
        return result
    start = integer('startNs')
    absent = integer('lastAbsentNs', True)
    published = integer('publishedNs', True)
    if absent is not None and absent < start:
        raise AssertionError('Prepublication sample precedes helper observation')
    if data['completed']:
        if published is None or published < start or (absent is not None and published < absent):
            raise AssertionError('Invalid publication observation')
        cold_end = published
    else:
        if published is not None:
            raise AssertionError('Unfinished publication evidence')
        cold_end = now_ns
    if cold_end - start >= COLD_BOUND_NS:
        raise AssertionError('Owned preparation exceeded original cold900s bound')
    return start, start if absent is None else absent, generation


class PreparationClock:
    def __init__(self, filename, nonce):
        self.filename = Path(filename)
        self.nonce = nonce
        self.generation = None

    def interval(self, now_ns=None):
        # Atomic publishers may retire an inode during open/fstat. Retry only a
        # proven replacement; never relax private ownership or single-link rules.
        for attempt in range(32):
            try:
                fd = os.open(self.filename, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
            except FileNotFoundError:
                return None
            try:
                info = os.fstat(fd)
                def current():
                    try: return self.filename.lstat()
                    except FileNotFoundError: return None
                def replaced(other):
                    return other is None or (other.st_dev, other.st_ino) != (info.st_dev, info.st_ino)
                if info.st_nlink == 0:
                    retired = False
                    for probe in range(4):
                        if replaced(current()):
                            retired = True
                            break
                        time.sleep(.001)
                    if retired:
                        continue
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600:
                    raise AssertionError(f'Preparation timing requires its private controller file: mode={oct(stat.S_IMODE(info.st_mode))} uid={info.st_uid} expectedUid={os.getuid()} links={info.st_nlink}')
                with os.fdopen(os.dup(fd), 'rb') as stream:
                    raw = stream.read(65537)
                if len(raw) > 65536:
                    raise AssertionError('Oversized preparation evidence')
                latest = current()
                if replaced(latest):
                    continue
                if latest.st_nlink == 0:
                    retired = False
                    for probe in range(4):
                        if replaced(current()):
                            retired = True
                            break
                        time.sleep(.001)
                    if retired:
                        continue
                if latest.st_uid != os.getuid() or latest.st_nlink != 1 or stat.S_IMODE(latest.st_mode) != 0o600 or not stat.S_ISREG(latest.st_mode):
                    raise AssertionError('Preparation timing requires its private controller file')
                # Sample AFTER the stable read so a legitimate concurrent writer
                # cannot appear to publish a future timestamp. Explicit test
                # timestamps retain the strict future-evidence negative control.
                sampled = time.monotonic_ns() if now_ns is None else now_ns
                result = decode(json.loads(raw), self.nonce, sampled)
                if result is not None:
                    generation = result[2]
                    if self.generation is not None and self.generation != generation:
                        raise AssertionError('Stale preparation generation changed')
                    self.generation = generation
                return result
            finally:
                os.close(fd)
        raise AssertionError('Preparation evidence continuously replaced during bounded read')

    def excluded_ns(self, started_ns, now_ns=None):
        interval = self.interval(now_ns)
        now_ns = time.monotonic_ns() if now_ns is None else now_ns
        return 0 if interval is None else overlap_ns(started_ns, now_ns, interval[0], interval[1])

    def elapsed(self, started_ns):
        interval = self.interval()
        now_ns = time.monotonic_ns()
        excluded = 0 if interval is None else overlap_ns(started_ns, now_ns, interval[0], interval[1])
        return (now_ns - started_ns - excluded) / 1_000_000_000

    def wait(self, predicate, label, seconds=70):
        started = time.monotonic_ns()
        while self.elapsed(started) < seconds:
            value = predicate()
            if value:
                return value
            time.sleep(.03)
        raise AssertionError('Observable barrier timed out: ' + label)
