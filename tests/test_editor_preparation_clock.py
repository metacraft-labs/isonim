#!/usr/bin/env python3
"""Unit timing/decoder controls plus real private-file reader checks.

Controlled integers/JSON are ordinary inputs to the pure interval/codec functions,
not mocked OS metadata or claims of a running Harbor. No OS/process is replaced.
The official native/stress/browser scenarios separately verify actual owned
helper identity/publication, original first admission and provider handoff.
"""
import json
import os
from pathlib import Path
import tempfile
import time
import threading
import unittest
from helpers.editor_preparation_clock import PreparationClock, decode, overlap_ns, COLD_BOUND_NS

NONCE = 'unit-controller-nonce'


def evidence(start=100, absent=200, published=220, completed=True):
    return {'schema':'isonim-owned-preparation-clock-v1','nonce':NONCE,
        'generation':{'pid':1,'starttime':'123','directory':'/unit-codec-input'},
        'startNs':str(start),'lastAbsentNs':None if absent is None else str(absent),
        'publishedNs':None if published is None else str(published),
        'completed':completed,'error':None}


class PreparationTiming(unittest.TestCase):
    def test_interval_intersections_preserve_wait_overhead(self):
        for start,end,expected in [(0,90,0),(0,100,0),(0,150,50),(0,300,100),
            (100,200,100),(150,180,30),(150,300,50),(200,300,0),(250,300,0)]:
            with self.subTest(start=start,end=end):
                self.assertEqual(overlap_ns(start,end,100,200),expected)
                self.assertLessEqual(expected,end-start)
        for values in [(-1,2,0,1),(3,2,0,1),(0,2,3,2)]:
            with self.assertRaises(AssertionError):overlap_ns(*values)

    def test_last_absent_sample_is_only_credit(self):
        self.assertEqual(decode(evidence(),NONCE,300)[:2],(100,200))
        self.assertEqual(decode(evidence(absent=None),NONCE,300)[:2],(100,100))
        self.assertEqual(decode(evidence(published=None,completed=False),NONCE,300)[:2],(100,200))

    def test_unobserved_generation_grants_zero(self):
        data=evidence();data.update(generation=None,startNs=None,lastAbsentNs=None,publishedNs=None,completed=False)
        self.assertIsNone(decode(data,NONCE,300))
        data['lastAbsentNs']='200'
        with self.assertRaises(AssertionError):decode(data,NONCE,300)

    def test_malformed_future_stale_and_failed_evidence_rejected(self):
        changes=[{'nonce':'previous-generation'}, {'schema':'unknown'}, {'extra':1},
            {'startNs':100}, {'lastAbsentNs':'999'}, {'publishedNs':'150'},
            {'completed':1}, {'generation':None}, {'startNs':'-1'},
            {'error':'actual observer failure'}, {'error':True},
            {'generation':{'pid':True,'starttime':'123','directory':'/unit-codec-input'}}]
        for change in changes:
            with self.subTest(change=change),self.assertRaises(AssertionError):
                decode({**evidence(),**change},NONCE,300)

    def test_cold900_expires_independently_of_excluded_clock(self):
        pending=evidence(start=100,absent=100+COLD_BOUND_NS-1,published=None,completed=False)
        self.assertIsNotNone(decode(pending,NONCE,100+COLD_BOUND_NS-1))
        with self.assertRaisesRegex(AssertionError,'cold900'):
            decode(pending,NONCE,100+COLD_BOUND_NS)
        completed=evidence(start=100,absent=100+COLD_BOUND_NS-1,published=100+COLD_BOUND_NS)
        with self.assertRaisesRegex(AssertionError,'cold900'):
            decode(completed,NONCE,100+COLD_BOUND_NS+1)

    def test_actual_private_file_missing_stale_generation_and_error(self):
        with tempfile.TemporaryDirectory(prefix='isonim-clock-codec-') as directory:
            filename=Path(directory)/'clock.json';clock=PreparationClock(filename,NONCE)
            now=time.monotonic_ns()
            self.assertEqual(clock.excluded_ns(now-10,now),0)
            def write(data):
                fd=os.open(filename,os.O_CREAT|os.O_WRONLY|os.O_TRUNC,0o600)
                with os.fdopen(fd,'w') as stream:json.dump(data,stream)
            data=evidence(start=now-100,absent=now-40,published=now-20)
            write(data)
            self.assertEqual(clock.excluded_ns(now-200,now),60)
            self.assertEqual(clock.excluded_ns(now-10,now),0) # Wait starts AFTER preparation.
            data['generation']['starttime']='124';write(data)
            with self.assertRaisesRegex(AssertionError,'generation changed'):clock.excluded_ns(now-200,now)
            data['generation']['starttime']='123';data['error']='real reader failed';write(data)
            with self.assertRaisesRegex(AssertionError,'observer failed'):clock.wait(lambda:False,'must fail promptly',70)
            data['error']=None;write(data);filename.chmod(0o644)
            with self.assertRaisesRegex(AssertionError,'private'):clock.excluded_ns(now-200,now)

    def test_actual_atomic_publication_and_unsafe_paths(self):
        with tempfile.TemporaryDirectory(prefix='isonim-clock-atomic-') as directory:
            root=Path(directory);filename=root/'clock.json'
            now=time.monotonic_ns();data=evidence(now-100,now-40,now-20)
            def publish():
                fd,name=tempfile.mkstemp(dir=root)
                with os.fdopen(fd,'w') as stream:json.dump(data,stream)
                os.replace(name,filename)
            publish();clock=PreparationClock(filename,NONCE)
            failures=[];done=threading.Event()
            def writer():
                try:
                    for _ in range(2000):publish();time.sleep(.0002)
                except BaseException as error:failures.append(error)
                finally:done.set()
            worker=threading.Thread(target=writer);worker.start();reads=0
            try:
                while not done.is_set():
                    self.assertEqual(clock.excluded_ns(now-200,now),60);reads+=1
            finally:worker.join()
            self.assertFalse(failures);self.assertGreater(reads,100)
            link=root/'linked.json';os.link(filename,link)
            with self.assertRaisesRegex(AssertionError,'private'):clock.excluded_ns(now-200,now)
            link.unlink();filename.rename(link);filename.symlink_to(link)
            with self.assertRaises(OSError):clock.excluded_ns(now-200,now)
            filename.unlink();link.rename(filename);filename.chmod(0o644)
            with self.assertRaisesRegex(AssertionError,'private'):clock.excluded_ns(now-200,now)


if __name__=='__main__':unittest.main(verbosity=2)
