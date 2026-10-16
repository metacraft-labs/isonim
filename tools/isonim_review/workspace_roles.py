"""Resolve genuine source roles through Repro's workspace definition report."""
import json
import os
from pathlib import Path
import shutil
import subprocess


def workspace_root(project):
    for candidate in (project, *project.parents):
        if ((candidate / '.repro-workspace.toml').is_file() or
                ((candidate / '.repro/workspace.toml').is_file()
                  and (candidate / 'projects').is_dir()
                  and (candidate / 'repos').is_dir())):
            return candidate
    return None


def declared_role(report, workspace, name, *, required=True):
    if not isinstance(report, dict) or report.get('schema') != 'reprobuild.workspace-set-repos-list.v1':
        raise RuntimeError('Unsupported Repro workspace repository report')
    if not isinstance(report.get('workspaceRoot'), str) or not report['workspaceRoot']:
        raise RuntimeError('Missing Repro workspace report root')
    if Path(report['workspaceRoot']).resolve() != workspace.resolve():
        raise RuntimeError('Repro workspace repository report root mismatch')
    rows = report.get('repos')
    if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
        raise RuntimeError('Malformed Repro workspace repository rows')
    matches = [row for row in rows if row.get('repo') == name]
    if not matches and not required:
        absent = workspace / name
        if os.path.lexists(absent):
            raise RuntimeError('Undeclared source checkout cannot supply optional role: ' + name)
        return absent
    if len(matches) != 1:
        raise RuntimeError('Expected exactly one declared workspace role: ' + name)
    selected = matches[0]
    if selected.get('enabled') is not True:
        raise RuntimeError('Required workspace role is disabled: ' + name)
    value = selected.get('path')
    if not isinstance(value, str) or not value:
        raise RuntimeError('Missing workspace role path: ' + name)
    relative = Path(value)
    if relative.is_absolute() or '..' in relative.parts:
        raise RuntimeError('Invalid workspace role path: ' + name)
    path = (workspace / relative).resolve()
    # The declaration is workspace-relative; its genuine compiler checkout
    # may be a symlink to an immutable source sibling, as the existing
    # editor_scenario_checkout snapshot intentionally records. Bind the
    # selected principal and reject duplicate physical roles below.
    aliases = [row for row in rows if isinstance(row.get('path'), str)
                and (workspace / row['path']).resolve() == path]
    if len(aliases) != 1:
        raise RuntimeError('Ambiguous workspace role path: ' + name)
    if not (path / '.git').exists():
        raise FileNotFoundError('Declared required workspace checkout missing: ' + name)
    return path


def workspace_report(project, workspace):
    repro = os.environ.get('ISONIM_REVIEW_REPRO') or shutil.which('repro')
    if not repro:
        raise RuntimeError('Repro is required to resolve declared source roles')
    result = subprocess.run(
        [repro, 'workspace', 'repos', 'list', '--all', '--json',
          '--workspace-root=' + str(workspace)], cwd=project,
        check=True, capture_output=True, text=True, timeout=20)
    return json.loads(result.stdout)


def source_role(project, name, *, override=None, required=True):
    project = Path(project).resolve()
    workspace = workspace_root(project)
    if workspace is not None:
        path = declared_role(workspace_report(project, workspace), workspace, name,
                              required=required)
        if override and Path(override).resolve() != path:
            raise RuntimeError('Explicit source role differs from its declaration: ' + name)
    else:
        path = Path(override).resolve() if override else project.parent / name
        if required and not (path / '.git').exists():
            raise FileNotFoundError('Required source checkout missing: ' + name)
    if override or (path / '.git').exists():
        if name == 'agent-harbor' and not all((path / item).is_file()
                                            for item in ('Cargo.toml', 'repro.nim')):
            raise RuntimeError('Selected Agent Harbor source role is not its producer checkout')
    return path


if __name__ == '__main__':
    import sys
    if len(sys.argv) != 4 or sys.argv[1] != 'report':
        raise SystemExit('Expected report PROJECT OUTPUT')
    project = Path(sys.argv[2]).resolve()
    workspace = workspace_root(project)
    if workspace is None:
        raise RuntimeError('No declared workspace for repository query')
    report = workspace_report(project, workspace)
    with Path(sys.argv[3]).open('x') as output:
        json.dump(report, output)
