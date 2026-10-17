"""Strict deferred substantive response checks, after real lifecycle evidence.

No mock provider. Codec tests may supply explicitly justified JSON records; real
host/browser tests collect these exact predicates from mounted assistant replies.
"""
import json
from pathlib import Path

KEYS={'contextOnlyNonce','actualHtmlDescription'}

def validate_responses(filename):
    checks=json.loads(Path(filename).read_text())
    if type(checks) is not dict or set(checks)!=KEYS:
        raise AssertionError('Exact substantive response-check schema required')
    if any(type(value) is not bool for value in checks.values()):
        raise AssertionError('Literal boolean response checks required')
    failed=sorted(key for key,value in checks.items() if value is not True)
    if failed: raise AssertionError('Substantive mounted response checks failed: '+', '.join(failed))
    return checks
