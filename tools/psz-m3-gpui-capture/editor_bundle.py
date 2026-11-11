#!/usr/bin/env python3
"""Checks that the editor server serves the bundle a capture was built to measure.

A capture is only evidence of the tree it names if the page it screenshots is
that tree's build. Two things can make it otherwise, and both happened in
PSZ-M3 note 23: an editor server left running from an older build directory,
and a build directory that predates the commit its sidecar names. This module
refuses both, before anything is captured, and writes what it checked into
bundle.json so the sidecar can carry it:

  1. The server answers /editor.js with the bytes of the build directory's
     editor.js (the sha256 is compared).
  2. The build directory's editor.js is not older than the commit at the tree's
     HEAD. A bundle built before that commit cannot contain it, so the build must
     be rerun (`just editor-build` in a clean checkout of that commit).

The check reads the server over HTTP, so it needs a running editor server. The
tests in test_sidecar.py start a real HTTP server on a free port.

Usage:
  editor_bundle.py --base http://127.0.0.1:18691 --build <tree>/build/editor \
      --tree <isonim checkout> [--out bundle.json]

Exit status 0 on success; 3 when the check refuses (the reason goes to stderr).
"""
import argparse
import datetime
import hashlib
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

import sidecar
from sidecar import CaptureRefused, sha256_file

# The served bundle. index.html is not compared: the editor server rewrites it on
# the way out (it injects the origin meta, see inject_origin_meta in
# tools/editor_server.py), so its bytes are the server's, not the build's.
CHECKED_FILES = ("editor.js",)
FETCH_TIMEOUT_SECONDS = 30


def origin_of(url):
    """The scheme://host:port of a URL, which is where the editor server listens."""
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise CaptureRefused(f"{url}: not an http(s) URL with a host")
    return f"{parts.scheme}://{parts.netloc}"


def fetch(url):
    """The bytes a URL answers with. A refusal when the server does not answer 200."""
    try:
        with urllib.request.urlopen(url, timeout=FETCH_TIMEOUT_SECONDS) as response:
            if response.status != 200:
                raise CaptureRefused(f"{url}: answered {response.status}")
            return response.read()
    except (urllib.error.URLError, OSError) as error:
        raise CaptureRefused(f"{url}: no editor server answered ({error})") from error


def head_commit_time(tree):
    """The HEAD commit's committer time as a UTC datetime, and the HEAD sha."""
    out = subprocess.run(["git", "-C", tree, "log", "-1", "--format=%H %ct", "HEAD"],
                         capture_output=True, text=True)
    if out.returncode != 0 or not out.stdout.strip():
        raise CaptureRefused(f"{tree}: no HEAD commit to check the bundle against")
    sha, stamp = out.stdout.split()
    return sha, datetime.datetime.fromtimestamp(int(stamp), datetime.timezone.utc)


def utc_iso(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def check(base, build_dir, tree):
    """Checks the served editor against build_dir, and build_dir against tree's HEAD.

    Returns the record bundle.json holds. Raises CaptureRefused on any mismatch.
    """
    origin = origin_of(base)
    files = {}
    for name in CHECKED_FILES:
        built_path = os.path.join(build_dir, name)
        if not os.path.isfile(built_path):
            raise CaptureRefused(f"{built_path}: the build directory has no {name}; run editor-build")
        built = sha256_file(built_path)
        served = hashlib.sha256(fetch(origin + "/" + name)).hexdigest()
        if served != built:
            raise CaptureRefused(
                f"{origin}/{name} serves sha256 {served}, but {built_path} is {built}: the "
                "server is not serving this build directory: it is a stale server from an "
                "older build, or it was started with another --directory. Stop it and start "
                "it from this build (the capture would otherwise measure the other bundle)")
        files[name] = {"servedSha256": served, "buildSha256": built}
    editor_js = os.path.join(build_dir, "editor.js")
    built_mtime = datetime.datetime.fromtimestamp(os.stat(editor_js).st_mtime, datetime.timezone.utc)
    head_sha, head_time = head_commit_time(tree)
    if built_mtime < head_time:
        raise CaptureRefused(
            f"{editor_js} was built at {utc_iso(built_mtime)}, before HEAD {head_sha[:12]} was "
            f"committed at {utc_iso(head_time)}: the bundle predates the tree it would be "
            "recorded against. Rebuild it (just editor-build) from that checkout")
    return {
        "url": origin,
        "buildDir": os.path.abspath(build_dir),
        "files": files,
        "builtAt": utc_iso(built_mtime),
        "treeHead": head_sha,
        "treeHeadCommittedAt": utc_iso(head_time),
        "checkedAt": sidecar.utc_now(),
    }


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--base", required=True, help="the editor server's URL (any page on it)")
    p.add_argument("--build", required=True, help="the build directory (build/editor)")
    p.add_argument("--tree", required=True, help="the isonim checkout the build was made from")
    p.add_argument("--out", help="write the record to this file")
    args = p.parse_args(argv)
    record = check(args.base, args.build, args.tree)
    text = json.dumps(record, indent=1) + "\n"
    if args.out:
        with open(args.out, "w") as f:
            f.write(text)
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except CaptureRefused as refusal:
        print("editor_bundle: refused:", refusal, file=sys.stderr)
        sys.exit(3)
