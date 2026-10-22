"""Read back the executable Reprobuild resolved for the editor's local Harbor.

The editor obtains Agent Harbor's ``ah`` through a Reprobuild consumer edge
(``tools/isonim_review/local_harbor.nim``). That edge records the executable
Reprobuild bound for it in ``<consumer>/harbor-executable``, and the editor's
startup diagnostic names both the selected checkout and the consumer directory.
Scenario tests use this to prove that the service they observe runs exactly the
executable Reprobuild resolved, without assuming where the producer builds it.
"""
from pathlib import Path
import re

CONSUMER_DIAGNOSTIC = re.compile(
    r'IsoNim: building workspace Agent Harbor with Reprobuild from (.+) \(consumer (.+)\)\s*$',
    re.M)


def resolved_harbor_executable(log_text, harbor):
    """Return the Reprobuild-resolved executable for checkout ``harbor``.

    Raises AssertionError when the editor reported no consumer for this
    checkout, or when its consumer state lives inside the Harbor checkout.
    """
    harbor = Path(harbor).resolve()
    reports = [Path(match[2]) for match in CONSUMER_DIAGNOSTIC.finditer(log_text)
               if Path(match[1]).resolve() == harbor]
    if not reports:
        raise AssertionError('editor did not report its Reprobuild Harbor consumer')
    consumer = reports[-1]
    if consumer.resolve().is_relative_to(harbor):
        raise AssertionError('editor consumer state must stay outside the Harbor checkout')
    return Path((consumer / 'harbor-executable').read_text().strip()).resolve()
