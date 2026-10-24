#!/usr/bin/env python3
"""IsoNim's reactive core imports nothing above it.

`src/isonim/core` is what renderer-free consumers (embedding facades, native
hosts) import for signals, ownership and platform boundaries. A core module
that imports a renderer (`web`, `ssr`, `native`, ...) drags that renderer into
every such consumer's import graph, so core may import only other core modules,
the Nim standard library and `nim_everywhere`.

Import statements are read without evaluating `when` branches: a JS-only
import is still an edge for a tool that walks the source graph, and that is
the shape this test exists to catch (a `when defined(js): import ../web/...`).

Runs against the real source tree; the self-check copies one real core module
into a temporary tree and adds a renderer import to it. No mocks.
"""
from pathlib import Path
import re
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
IMPORT = re.compile(r'^\s*(?:when\b[^:]*:\s*)?(import|include|from)\s+(.+?)\s*(?:#.*)?$')
ALLOWED_PACKAGES = ('std/', 'system', 'nim_everywhere')


def targets(clause: str, kind: str) -> list[str]:
    if kind == 'from':
        clause = clause.split(' import ', 1)[0]
    clause = re.sub(r'\s+as\s+\w+', '', clause)
    clause = re.sub(r'\s+except\s+.*$', '', clause)
    found = []
    for part in re.finditer(r'([\w./"]+)\s*(?:\[([^\]]*)\])?', clause):
        head, group = part.group(1).strip('"'), part.group(2)
        if group is None:
            found.append(head)
        else:
            found.extend(head.rstrip('/') + '/' + name.strip()
                         for name in group.split(',') if name.strip())
    return found


def violations(core: Path) -> list[str]:
    result = []
    for path in sorted(core.rglob('*.nim')):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            match = IMPORT.match(line)
            if not match:
                continue
            for target in targets(match.group(2), match.group(1)):
                if target.startswith(ALLOWED_PACKAGES):
                    continue
                if target.startswith('isonim/'):
                    resolved = core.parent / target[len('isonim/'):]
                else:
                    resolved = (path.parent / target)
                resolved = Path(str(resolved.resolve()).removesuffix('.nim'))
                if resolved == core.resolve() or core.resolve() in resolved.parents:
                    continue
                result.append(f'{path.relative_to(core.parent.parent)}:{number}: imports {target}')
    return result


def main() -> int:
    core = ROOT / 'src/isonim/core'
    found = violations(core)
    for line in found:
        print('VIOLATION core-imports-renderer: ' + line)
    if found:
        return 1
    print('core imports stay in core: PASS')

    with tempfile.TemporaryDirectory(prefix='core-layering-') as directory:
        copy = Path(directory) / 'isonim/core'
        copy.mkdir(parents=True)
        shutil.copyfile(core / 'nondet.nim', copy / 'nondet.nim')
        with open(copy / 'nondet.nim', 'a') as handle:
            handle.write('\nwhen defined(js):\n  import ../web/dom_api\n')
        caught = violations(copy)
        if not any('imports ../web/dom_api' in line for line in caught):
            print('self-check: a JS-only renderer import in core was NOT caught', caught)
            return 1
    print('self-check (JS-only renderer import in core is caught): PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
