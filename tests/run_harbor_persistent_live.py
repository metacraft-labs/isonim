#!/usr/bin/env python3
"""Real REST/provider acceptance harness; no test doubles.

Pass a built nim-agents/tests/test_harbor_persistent_live executable, a built ah,
and the actual Claude ACP executable. Artifacts retain HTTP/provider events and
Linux worker PID/starttime evidence. These Linux checks intentionally observe the
model worker beneath Harbor and the ACP adapter, not merely the server PID.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import urllib.request


def processes():
    result = {}
    for path in Path('/proc').iterdir():
        if not path.name.isdigit():
            continue
        try:
            stat = (path / 'stat').read_text().rsplit(')', 1)[1].split()
            command = (path / 'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace')
            result[int(path.name)] = (int(stat[1]), stat[19], command)
        except (OSError, ValueError, IndexError):
            pass
    return result


def descendants(table, root):
    found = {root}
    while True:
        added = {pid for pid, info in table.items() if info[0] in found} - found
        if not added:
            return found
        found.update(added)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--harbor-repo', type=Path, required=True)
    parser.add_argument('--ah', required=True)
    parser.add_argument('--provider', required=True)
    parser.add_argument('--driver', required=True)
    parser.add_argument('--scenario', type=Path)
    args = parser.parse_args()
    root = Path(tempfile.mkdtemp(prefix='isonim-persistent-'))
    print(root, flush=True)
    instructions = root / 'instructions.md'
    instructions.write_text('When asked for your instruction sentinel, reply ISONIM_SYSTEM_9182.\n')
    launcher = Path(__file__).resolve().parents[1] / 'tools/agent_session_launcher.py'
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    env = dict(os.environ, AH_DEV_MODE='1', AH_DAEMON_DB_PATH=str(root / 'db.sqlite'),
        AH_RECORDINGS_DIR=str(root / 'recordings'), AH_DAEMON_PID_FILE=str(root / 'server.pid'),
        AH_DAEMON_CONTROL_SOCK=str(root / 'control.sock'), AH_WEBUI_PID_FILE=str(root / 'webui.pid'),
        AH_LOG_FILE=str(root / 'harbor.log'))
    log = (root / 'server.log').open('w')
    server = subprocess.Popen(['repro', 'exec', '--', args.ah, 'server', 'start',
        '--no-access-point-loop', '--rest-host', '127.0.0.1', '--rest-port', str(port),
        '--recordings-dir', str(root / 'recordings'), '--pid-file', str(root / 'server.pid'),
        '--control-sock', str(root / 'control.sock'), '--task-manager-sock', str(root / 'tasks.sock'),
        '--webui-pid-file', str(root / 'webui.pid'), '--no-acp'], cwd=args.harbor_repo,
        env=env, stdout=log, stderr=log, start_new_session=True)
    driver = None
    try:
        url = f'http://127.0.0.1:{port}'
        deadline = time.monotonic() + 600
        while time.monotonic() < deadline:
            assert server.poll() is None, 'Harbor server exited'
            try:
                with urllib.request.urlopen(url + '/api/v1/healthz', timeout=1) as response:
                    if response.status == 200:
                        break
            except OSError:
                time.sleep(.2)
        else:
            raise AssertionError('Harbor readiness timeout')
        provider_command = [args.provider]
        if args.scenario:
            provider_command += ['--scenario', str(args.scenario), '--disable-follower']
        env.update(ISONIM_TEST_HARBOR_URL=url, ISONIM_TEST_ARTIFACTS=str(root),
            ISONIM_TEST_ACP_PROVIDER='/usr/bin/env',
            ISONIM_TEST_ACP_ARGS=json.dumps(['python3', str(launcher), '--instructions', str(instructions), '--'] + provider_command))
        driver_log = (root / 'driver.log').open('w')
        driver = subprocess.Popen([args.driver], env=env, stdout=driver_log, stderr=driver_log)
        workers = {}
        samples = 0
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            assert driver.poll() is None or driver.returncode == 0, 'Nim driver failed; inspect driver.log'
            table = processes()
            if workers:
                for pid, original in workers.items():
                    assert pid in table and table[pid][1] == original[1], 'model worker exited or restarted between turns'
                samples += 1
            if (root / 'first-complete').exists() and not workers:
                owned = {pid: table[pid] for pid in descendants(table, server.pid) if pid in table}
                (root / 'owned-processes.json').write_text(json.dumps(owned, indent=2))
                workers = {pid: table[pid] for pid in owned
                    if ((not args.scenario and '--output-format' in table[pid][2] and 'stream-json' in table[pid][2])
                        or (args.scenario and table[pid][2].startswith(args.provider + ' ')))}
                assert workers, 'No actual Claude model worker found beneath server'
                (root / 'workers.json').write_text(json.dumps(workers, indent=2))
                (root / 'continue').touch()
            if (root / 'second-complete').exists():
                assert workers and samples > 0
                (root / 'continuity.json').write_text(json.dumps({'samples': samples, 'workers': list(workers)}))
                (root / 'close').touch()
                break
            time.sleep(.05)
        else:
            raise AssertionError('two-turn deadline exceeded')
        assert driver.wait(timeout=30) == 0, 'Nim driver failed'
        for _ in range(300):
            table = processes()
            if all(pid not in table or table[pid][1] != value[1] for pid, value in workers.items()):
                break
            time.sleep(.05)
        else:
            raise AssertionError('session close left model worker alive')
        (root / 'PASS').write_text('scenario continuity and closure\n' if args.scenario else
            'same model worker/starttime, retained context, system instruction, explicit closure\n')
    finally:
        if driver is not None and driver.poll() is None:
            driver.terminate()
            driver.wait(timeout=10)
        os.killpg(server.pid, signal.SIGTERM)
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait()
        log.close()


if __name__ == '__main__':
    main()
