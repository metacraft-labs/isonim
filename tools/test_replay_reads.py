#!/usr/bin/env python3
"""Artifact-free custom-clock compatibility; real owner gate is separate."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
for target, flags, suffix in [("c", [], "native"), ("js", ["-d:nodejs"], "js"), ("js", ["-d:nodejs", "-d:isonimInternalReplayReads"], "internal-js")]:
    output = root / "build" / ("replay-read-custom." + suffix)
    subprocess.run(["nim", target, *flags, "--nimcache:" + str(root / "build/nimcache" / ("read-custom-" + suffix)), "--out:" + str(output), "tests/test_replay_read_guards.nim"], cwd=root, check=True)
    subprocess.run(([str(output)] if target == "c" else ["node", str(output)]), cwd=root, check=True)

# Same public nil scheduler contract with and without the internal define.
for name,flags in [("ordinary",[]),("internal",["-d:isonimInternalReplayReads"])]:
    output=root/"build"/("replay-nil-"+name+".js")
    subprocess.run(["nim","js","-d:nodejs",*flags,"--nimcache:"+str(root/"build/nimcache"/("replay-nil-"+name)),"--out:"+str(output),"tests/test_replay_nil.nim"],cwd=root,check=True)
    subprocess.run(["node",str(output)],cwd=root,check=True)
# Remove only the defensive nil check in isolated OWN source. Exact nil oracle
# must reject it; existing active-owner positives run separately unchanged.
import tempfile, shutil
with tempfile.TemporaryDirectory(prefix="isonim-nil-inverse-") as directory:
    tmp=Path(directory);shutil.copytree(root/"src",tmp/"src")
    fixture=tmp/"nil_oracle.nim";shutil.copyfile(root/"tests/test_replay_nil.nim",fixture)
    source=tmp/"src/isonim/core/private/replay_reads.nim"
    code=source.read_text();assert code.count("clock != nil and clock of ReadReplayClock")==1
    source.write_text(code.replace("clock != nil and clock of ReadReplayClock","clock of ReadReplayClock"))
    output=root/"build/replay-nil-inverse.js"
    subprocess.run(["nim","js","-d:nodejs","-d:isonimInternalReplayReads","--path:"+str(tmp/"src"),"--path:"+str(root.parent/"nim-everywhere/src"),"--nimcache:"+str(root/"build/nimcache/replay-nil-inverse"),"--out:"+str(output),str(fixture)],cwd=root,check=True)
    runner = """const assert=require('node:assert/strict');
try { require(process.argv[1]); }
catch(error) {
  assert(error instanceof TypeError, 'nil inverse must be a native TypeError');
  assert(error.message.includes('m_type') && error.stack.includes('isReadReplay'), 'wrong nil inverse location');
  console.error(error.stack); process.exit(7);
}
throw new Error('nil inverse escaped exact predicate oracle');"""
    result=subprocess.run(["node","-e",runner,str(output)],capture_output=True,text=True)
    print(result.stderr,end="")
    assert result.returncode==7,"nil inverse failed wrong typed oracle"
    print("nil-check restoration: REJECTED by exact typed predicate oracle")
