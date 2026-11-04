"""Exact filesystem custody for the registered-handler historical byte control.

These assertions authenticate whole core graphs, not a guessed import closure.
Compiler Processing provenance is checked separately on successful real builds.
"""
from contextlib import contextmanager
from pathlib import Path
import hashlib
import re
import subprocess

OWNER = "isonim/core/nondet.nim"

def digest(body):
    return hashlib.sha256(body).hexdigest()

def bodies(scope):
    return {str(p.relative_to(scope)): p.read_bytes()
            for p in (scope / "isonim/core").rglob("*") if p.is_file()}

def identities(graph):
    return {name: digest(body) for name, body in graph.items()}

def authenticate(scope, expected):
    assert identities(bodies(scope)) == expected, "exact expected core phase inventory"

def historical_graph(repo, revision):
    # Git objects, never a worktree or an implicit promisor fetch.
    import os
    env = os.environ | {"GIT_NO_LAZY_FETCH": "1", "GIT_OPTIONAL_LOCKS": "0"}
    records = subprocess.check_output(
        ["git", "ls-tree", "-rz", revision, "--", "src/isonim/core"],
        cwd=repo, env=env).split(b"\0")
    graph = {}
    for row in records:
        if not row:
            continue
        metadata, path = row.split(b"\t", 1)
        mode, kind, oid = metadata.split()
        assert mode == b"100644" and kind == b"blob", "historical regular core blob"
        key = path.decode().removeprefix("src/")
        graph[key] = subprocess.check_output(["git", "cat-file", "blob", oid.decode()], cwd=repo, env=env)
    assert OWNER in graph, "historical owner exists"
    return graph

def conserve_common(parent, candidate):
    assert all(name in candidate and candidate[name] == body
               for name, body in parent.items() if name != OWNER), "historical nonowner core conservation"

def install(scope, graph):
    # Only the private copied core scope is touched. Remove later-only files as
    # well as accidental extras; retaining empty directories has no input bytes.
    for p in (scope / "isonim/core").rglob("*"):
        if p.is_file() and str(p.relative_to(scope)) not in graph:
            p.unlink()
    for name, body in graph.items():
        p = scope / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(body)

@contextmanager
def phase(scope, graph, expected_graphs):
    previous = bodies(scope)
    previous_expected = expected_graphs[str(scope.resolve())]
    authenticate(scope, previous_expected)
    expected = identities(graph)
    try:
        expected_graphs[str(scope.resolve())] = expected
        install(scope, graph)
        authenticate(scope, expected)
        yield
    finally:
        install(scope, previous)
        expected_graphs[str(scope.resolve())] = previous_expected
        authenticate(scope, previous_expected)

def processed_modules(log):
    # Stock Nim --processing:filenames --filenames:abs: an actual processing
    # event, NOT dump searchPaths or source-text import speculation.
    return {Path(x).resolve() for x in re.findall(r"^Hint: .*?: (?:import(?:\(dirty\))?|include): (/.+?) \[Processing\]$", log, re.M)}

def reject_added_imports(log, scope, additions):
    actual = processed_modules(log)
    assert actual, "actual compiler Processing provenance required"
    assert not {((scope / name).resolve()) for name in additions} & actual, "added core leaf consumed by compiler"
    return actual

def administrative_controls(parent, candidate, scratch):
    """Real copied files and exact assertions; no semantic-inverse credit."""
    conserve_common(parent, candidate)
    existing = next(name for name in parent if name != OWNER)
    changed = dict(candidate)
    changed[existing] += b"\n# changed nonowner control\n"
    def rejected(label, operation, expected):
        try:
            operation()
        except AssertionError as error:
            assert str(error) == expected, (label, str(error))
            return label
        raise AssertionError("administrative control accepted: " + label)
    results = [rejected("changed-existing-nonowner",
        lambda: conserve_common(parent, changed), "historical nonowner core conservation")]
    scope = scratch / "administrative-source"
    install(scope, candidate)
    registry = {str(scope.resolve()): identities(candidate)}
    authenticate(scope, registry[str(scope.resolve())])
    expected = identities(parent)
    for label in ["wrong", "missing", "extra"]:
        broken = dict(parent)
        if label == "wrong": broken[existing] += b"\n# wrong body\n"
        if label == "missing": del broken[existing]
        if label == "extra": broken["isonim/core/extra_parent_control.nim"] = b"discard\n"
        with phase(scope, parent, registry):
            install(scope, broken)
            results.append(rejected("parent-" + label,
                lambda: authenticate(scope, expected), "exact expected core phase inventory"))
        authenticate(scope, identities(candidate))
    try:
        with phase(scope, parent, registry):
            (scope / "isonim/core/injected_extra.nim").write_text("discard\n")
            raise RuntimeError("injected parent compiler failure")
    except RuntimeError as error:
        assert str(error) == "injected parent compiler failure"
    authenticate(scope, identities(candidate))
    assert registry[str(scope.resolve())] == identities(candidate)
    results.append("restoration-on-injected-failure")
    return dict(administrativeOnly=True, rejected=results,
                exactUnmodifiedCompanions=True, restoration=True)
