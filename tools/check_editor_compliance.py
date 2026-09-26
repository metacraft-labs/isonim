#!/usr/bin/env python3
"""Refuse an UNEXPLAINED editor-compliance exception in an IsoNim project.

WHY THIS EXISTS
===============

An IsoNim project is not only a program that renders a page; it is the input
to an editor. Whether that editor can do anything useful is decided by how the
code is written, it fails silently, and nothing in the build warns you.
``isonim-specs/Authoring-IsoNim-Projects.md`` is the guide; this is the part of
it a machine can check.

WHY THIS IS NOT A COVERAGE PERCENTAGE
=====================================

Because the obvious design would have made the reference project WORSE, and we
can show it with its own numbers. Measured on ``web-site-prototypes/grip/isonim``
at the commit this tool was calibrated against:

    elements carrying data-isonim-src ............  1,211 of 4,138  (29.3%)
    ...of the STRUCTURAL elements ................  1,211 of 1,218  (99.4%)

Same page, same build. The difference is entirely the denominator: 2,920 of the
4,138 elements are syntax-highlighter output (2,915 ``<i>`` tokens across 14
distinct classes, every one of which is already a ``comp.code.*`` design token)
and they are ``raw`` ON PURPOSE. A check reporting 29.3% would have told the
agent to attribute the highlighter, which would take the editor's Layers panel
from 1,211 rows to 4,126 -- 209 of them the word ``n`` -- and make it useless.

So the design principle, and it is the whole tool:

    ACCOUNT FOR THE RESIDUE; DO NOT COUNT IT.
    Fail on an UNEXPLAINED exception, never on a ratio.

This is house practice, not novelty. ``reprobuild/scripts/check_bare_skips.py``
refuses a NEW bare ``skip()`` against a baseline of known sites, and
``check_vacuous_test_cases.py`` pairs each row with a verdict and a written
justification. This tool's population is ~15 rows, so it follows the second:
EVERY ROW CARRIES A REASON AND THE TOOL REFUSES A ROW THAT DOES NOT.

THE TYPED REASON, AND WHERE THE REASON SHOULD EVENTUALLY LIVE
=============================================================

A row's second column is not free text, it is a TYPED reason drawn from a fixed
vocabulary (``generated-content``, ``contextual-selector``, ``runtime-computed``,
``codegen-artifact``, ``non-visual``, ``behaviour-hook``). The free-text reason
is required as well. A typed reason with no text is this feature's version of a
bare ``skip()`` -- the exact defect the baseline pattern exists to prevent --
and the tool rejects it.

The types are here for two reasons. They let the tool AGGREGATE, so we can see
which exception is common across projects rather than reading fifteen
sentences. And they are the vocabulary an in-source annotation would use::

    rawRegion(erGeneratedContent, "the highlighter emits <i> runs; the
                                   editable unit is span.code-line"):
      raw highlight(code)

That is where these obligations SHOULD be discharged -- beside the decision,
surviving a refactor, visible to a reviewer without opening a sidecar, and
leaving a compliant project with an EMPTY check output rather than "47
baselined exceptions". This file is deliberately written so that migration is a
transport change and not a semantic one: the kinds are the same, the reasons
are the same, and only the place they are read from moves. See
``isonim-specs/Editor-Compliance-Check.md``.

THE DIMENSIONS
==============

Each is a separate check that passes or fails on its own and names its own
remedy. Deliberately not a single score: a score tells an agent it is at 73%
without telling it what to do.

  D1  Attribution      every STRUCTURAL element carries ``data-isonim-src``,
                       so the editor can locate what it renders. An element is
                       structural unless it is inside a declared raw region.
  D2  Resolution       every class on the page reaches the compile-time class
                       index, so the inspector can show provenance instead of
                       an orphan value.
  D4  Tier discipline  no component binds a ``ref`` primitive; no ``comp``
                       token references a ``ref`` directly.
  D5  Intended surface every agent-facing token carries ``usage``; every
                       non-agent-facing one is marked as machinery.
  D6  Reachability     everything handed to the workspace is reachable through
                       some surface. (Needs ``--manifest``.)
  D7  Edit contract    ``writeSource`` and the presence of a
                       ``WorkspaceEditAdapter`` agree. (Needs ``--manifest``.)

D3 (binding: "this value matches a token but is not bound to it") IS NOT
SHIPPED. The spec leaves it open and the open question is the right one: a
design system has coincidental matches, and a direction test that fires on them
is a test an agent learns to ignore. It is not implemented rather than
implemented badly.

D4's ALIAS-ONLY TEST IS NOT SHIPPED EITHER, and this is a correction to the
spec rather than an omission. "A ``sys`` token resolving straight to a ``ref``
nothing else uses is a rename, not a role" fires on 21 of grip's 63 ``sys``
tokens, including ``sys.color.surface.page -> ref.color.neutral.0``, which is
plainly a role and not a rename. The reason is structural: grip's ``ref`` tier
is a deliberate RAMP whose build fails if a step has no consumer, so 1:1 is the
DESIGNED shape there and the test is ~100% false-positive on its only
calibration target. The anti-pattern the spec was reaching for is real; the
signal for it is not this one, and no test is better than a wrong test.

WHAT THIS TOOL MUST NOT BE TRUSTED TO KNOW
==========================================

Stated so a green result is not read as approval:

  * whether token NAMES mean anything -- ``sys.color.brand.primary`` and
    ``sys.color.blue`` are equally well-formed;
  * whether the component decomposition is sensible -- four components or
    forty is a judgement;
  * whether the intended surface is the RIGHT surface -- D5 checks it is
    MARKED, not that it is well chosen;
  * whether the design is good.

HOW A SITE IS IDENTIFIED
========================

By its NEAREST ATTRIBUTED ANCESTOR'S FILE plus a description of the element
(``tag.class``), never by line number. Line numbers are invalidated by any edit
above the site, so a line-keyed baseline churns for reasons that have nothing
to do with the population it pins -- the same reasoning
``scripts/shell-command-strings-baseline.txt`` records.

The nearest ATTRIBUTED ancestor is also what makes the diagnostic actionable.
An unattributed element by definition has no source location of its own; its
nearest attributed ancestor has one, and that is the file an author can open.

COUNTS, AND WHY SOME OF THEM ARE ``*``
======================================

A row's count pins a population so it cannot grow. For content-shaped
populations that is churn with no signal: pinning the 2,920 elements inside
``span.code-line`` would fail the build every time the corpus gains an example,
while telling nobody anything. Those rows record ``*``. What is under review
for a raw region is THE SELECTOR -- "everything under this is content" is the
claim a reviewer must agree with, and its size is not the claim.

A row with a NUMBER ratchets one way, like its siblings: exceeding it fails by
name, and falling below it rewrites the file smaller so that fixing a site does
not also cost a manual baseline edit.

USAGE
=====

  check_editor_compliance.py --project DIR
      [--html FILE ...]      # editor-build (-d:isonimEditor) rendered pages
      [--class-index FILE]   # the compile-time class index JSON
      [--tokens FILE ...]    # DTCG token files (D4, D5)
      [--manifest FILE]      # workspace manifest JSON (D6, D7)
      [--baseline FILE]      # default <project>/compliance-baseline.tsv
      [--dimensions D1,D2]   # default: every dimension its inputs support
      [--mode gate|report]   # default gate
      [--write-baseline]     # re-record accepted exceptions from this tree
      [--json]               # machine-readable result
      [--self-test]          # run the embedded fixtures and stop

Exit codes:
  0 -- compliant, or ``--mode report``.
  1 -- at least one UNEXPLAINED exception, or the baseline is unusable, or the
       scan came back below its anti-vacuity floor. stderr names each one.
  2 -- an unusable combination of flags.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
from collections import Counter, defaultdict
from html.parser import HTMLParser

# ---------------------------------------------------------------------------
# The typed reason vocabulary
# ---------------------------------------------------------------------------
#
# Fixed on purpose. A free-text-only reason cannot be aggregated, and the point
# of aggregating is to learn which exception is common enough to deserve a
# framework fix rather than a per-project sentence. ``codegen-artifact`` is the
# one that has already earned that: it means the FRAMEWORK could not attribute
# something, which is a gap in isonim and not a defect in the project, and the
# tool says so in its report.

REASON_KINDS = {
    "generated-content":
        "markup produced by a generator (a highlighter, a Markdown render, a "
        "const string) whose interior is content, not structure",
    "contextual-selector":
        "a class that exists only inside a selector context "
        "(`#panel .hd`, `.plot-axis.is-faint`) which the class index cannot "
        "express",
    "runtime-computed":
        "an attribute chosen at runtime, so no literal exists at compile time",
    "codegen-artifact":
        "an element the framework's own codegen inserts and does not "
        "attribute -- a gap in isonim, not in the project",
    "non-visual":
        "an element with no visual surface (`<script>`, `<style>`, `<link>`); "
        "not a thing a designer selects",
    "behaviour-hook":
        "a class that carries no declarations because it is a script "
        "selector rather than a style class",
    "design-decision":
        "an argued departure from a tier or surface rule, recorded so the "
        "next project inherits the ARGUMENT and not just the departure",
}

# Which kinds each row type may carry. A `raw-region` justified as
# `runtime-computed` would be nonsense, and a vocabulary that permits nonsense
# is not a vocabulary.
ROW_KINDS = {
    ("D1", "raw-region"): {"generated-content"},
    ("D1", "unattributed"): {"generated-content", "codegen-artifact",
                             "non-visual"},
    ("D2", "class"): {"contextual-selector", "behaviour-hook"},
    ("D2", "runtime-class"): {"runtime-computed"},
    ("D4", "comp-references-ref"): {"design-decision"},
    ("D4", "component-references-ref"): {"design-decision"},
    ("D4", "missed-role-binding"): {"design-decision"},
    ("D5", "token"): {"design-decision"},
    ("D6", "unreachable"): {"design-decision"},
    ("D7", "edit-contract"): {"design-decision"},
}

DIMENSION_TITLES = {
    "D1": "attribution",
    "D2": "resolution",
    "D4": "tier discipline",
    "D5": "intended surface",
    "D6": "reachability",
    "D7": "edit contract",
}

ALL_DIMENSIONS = ["D1", "D2", "D4", "D5", "D6", "D7"]

# A reason that says nothing. Rejected by name so that the escape hatch cannot
# be taken without thinking, which is the only property that makes a baseline
# with reasons better than one without.
VACUOUS_REASONS = {
    "", "-", "n/a", "na", "tbd", "todo", "fixme", "see above", "ok", "fine",
    "accepted", "known", "expected", "by design", "intentional", "wontfix",
    "legacy", "?",
}
MIN_REASON_WORDS = 5


# ---------------------------------------------------------------------------
# HTML
# ---------------------------------------------------------------------------

VOID_ELEMENTS = {
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
    "meta", "param", "source", "track", "wbr",
}


class _Document(HTMLParser):
    """A DOM-shaped element list.

    Not an XML parser and deliberately not one: the input is the project's own
    SSR output, which is well-formed by construction, and a dependency-free
    scanner is what makes this tool start in milliseconds. ``convert_charrefs``
    is on because entity text never matters here; only tags and attributes do.
    """

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.nodes: list[dict] = []
        self._open: list[int] = []

    def _push(self, tag: str, attrs, self_closing: bool) -> None:
        collected: dict[str, str] = {}
        for key, value in attrs:
            # First wins, which is what a browser does with a duplicate
            # attribute. Matters only for malformed input, but silently
            # disagreeing with the browser would make every downstream count
            # suspect.
            if key not in collected:
                collected[key] = value if value is not None else ""
        node = {
            "tag": tag,
            "attrs": collected,
            "parent": self._open[-1] if self._open else None,
            "index": len(self.nodes),
        }
        self.nodes.append(node)
        if not self_closing and tag not in VOID_ELEMENTS:
            self._open.append(node["index"])

    def handle_starttag(self, tag, attrs):
        self._push(tag, attrs, False)

    def handle_startendtag(self, tag, attrs):
        self._push(tag, attrs, True)

    def handle_endtag(self, tag):
        if tag in VOID_ELEMENTS:
            return
        # Close the innermost matching open element and discard anything left
        # open inside it. An unmatched end tag closes nothing, which is again
        # what a browser does.
        for depth in range(len(self._open) - 1, -1, -1):
            if self.nodes[self._open[depth]]["tag"] == tag:
                del self._open[depth:]
                return


def parse_html(text: str) -> list[dict]:
    document = _Document()
    document.feed(text)
    return document.nodes


def classes_of(node: dict) -> list[str]:
    return (node["attrs"].get("class") or "").split()


def describe(node: dict) -> str:
    """``tag.class1.class2``, or ``tag#id`` -- how a row's key names an element.

    Classes are SORTED. The authored order is not stable under an edit that
    rewrites a class string, and a key that churns on a cosmetic reorder is a
    key that gets regenerated instead of read.
    """
    out = node["tag"]
    node_id = node["attrs"].get("id")
    if node_id:
        out += "#" + node_id
    for name in sorted(classes_of(node)):
        out += "." + name
    return out


def ancestors(nodes: list[dict], index: int | None):
    """Self-and-ancestors, innermost first."""
    while index is not None:
        yield index
        index = nodes[index]["parent"]


# ---------------------------------------------------------------------------
# Source locations
# ---------------------------------------------------------------------------

def relative_source(raw: str, project: pathlib.Path) -> str:
    """``data-isonim-src`` is an absolute ``file:line:column``; make it local.

    The attribute carries the compiling machine's absolute path. Relativising
    is not cosmetic: the path is half of every baseline key, and an absolute
    one would make the file unusable on any other checkout -- including CI's.
    """
    parts = raw.rsplit(":", 2)
    path_text = parts[0] if len(parts) == 3 else raw
    line = parts[1] if len(parts) == 3 else ""
    try:
        path = pathlib.Path(path_text).resolve().relative_to(project.resolve())
        path_text = path.as_posix()
    except (ValueError, OSError):
        pass
    return f"{path_text}:{line}" if line else path_text


def nearest_attributed(nodes: list[dict], index: int, project: pathlib.Path):
    """``(file:line, description)`` of the closest ancestor with attribution.

    This is what makes a D1 diagnostic actionable. The element being reported
    has no source location -- that IS the report -- so the only file an author
    can be sent to is the one that produced its container.
    """
    for candidate in ancestors(nodes, nodes[index]["parent"]):
        source = nodes[candidate]["attrs"].get("data-isonim-src")
        if source:
            return relative_source(source, project), describe(nodes[candidate])
    return "<unattributed>", "<document>"


def source_for(nodes: list[dict], index: int, project: pathlib.Path) -> str:
    """The element's OWN ``file:line`` when it has one, else its container's.

    D2 reports elements that ARE attributed -- the defect is in the class, not
    the element -- so sending the author to the parent's line would be sending
    them to the wrong line. D1 reports elements that are not, where the parent
    is the only answer that exists. One helper, and the caller's choice of
    which question it is asking is explicit at the call site.
    """
    own = nodes[index]["attrs"].get("data-isonim-src")
    if own:
        return relative_source(own, project)
    return nearest_attributed(nodes, index, project)[0]


# ---------------------------------------------------------------------------
# Style-binding provenance
# ---------------------------------------------------------------------------
#
# The wire format is owned by ``src/isonim/dsl/style_provenance.nim``:
#   property|value|kind|detail|token|note   records separated by ';'
# This decoder mirrors ``decodeStyleBindings`` exactly, including its tolerance
# of a short or unknown record -- a decode failure must not take down the
# check any more than it may take down the inspector.

def _unescape_field(text: str) -> str:
    out: list[str] = []
    position = 0
    while position < len(text):
        if text[position] == "\\" and position + 1 < len(text):
            out.append({"\\": "\\", "p": "|", "s": ";"}.get(
                text[position + 1], text[position + 1]))
            position += 2
        else:
            out.append(text[position])
            position += 1
    return "".join(out)


def decode_style_bindings(encoded: str) -> list[dict]:
    records: list[dict] = []
    if not encoded:
        return records
    for chunk in encoded.split(";"):
        if not chunk:
            continue
        fields = [_unescape_field(f) for f in chunk.split("|")]
        if len(fields) < 3:
            continue
        fields += [""] * (6 - len(fields))
        records.append({
            "property": fields[0], "value": fields[1], "kind": fields[2],
            "detail": fields[3], "token": fields[4], "note": fields[5],
        })
    return records


# ---------------------------------------------------------------------------
# Selectors
# ---------------------------------------------------------------------------
#
# A raw region is declared by a selector rather than a source location because
# the selector is the reviewable claim and survives an edit above the site.
# The grammar is deliberately tiny -- tag, #id, .class, and compounds of them.
# A descendant combinator is NOT supported, and that is a decision: a raw
# region declared as `.a .b` would be a claim about two things at once, and the
# one that matters (what is inside) is the second.

SELECTOR_RE = re.compile(r"^([a-zA-Z][\w-]*)?((?:[.#][\w-]+)*)$")


class Selector:
    def __init__(self, text: str) -> None:
        match = SELECTOR_RE.match(text.strip())
        if not match:
            raise ValueError(
                f"`{text}` is not a supported raw-region selector. Use a tag, "
                f"`.class`, `#id`, or a compound such as `span.code-line`.")
        self.text = text.strip()
        self.tag = (match.group(1) or "").lower()
        self.classes = [p[1:] for p in re.findall(r"[.][\w-]+", match.group(2))]
        ids = [p[1:] for p in re.findall(r"[#][\w-]+", match.group(2))]
        self.id = ids[0] if ids else ""
        if not self.tag and not self.classes and not self.id:
            raise ValueError(f"`{text}` selects everything; refusing it.")

    def matches(self, node: dict) -> bool:
        if self.tag and node["tag"].lower() != self.tag:
            return False
        if self.id and node["attrs"].get("id") != self.id:
            return False
        node_classes = set(classes_of(node))
        return all(name in node_classes for name in self.classes)


# ---------------------------------------------------------------------------
# The baseline
# ---------------------------------------------------------------------------

BASELINE_HEADER = """\
# editor-compliance baseline -- every ACCEPTED exception, with a typed reason
# and a written one.
#
# See isonim/tools/check_editor_compliance.py for what this is. In short: the
# check fails on an UNEXPLAINED exception and never on a ratio, because the
# same grip page is 29.3% attributed by raw element count and 99.4% by
# structural element count, and a threshold would have told an agent to
# attribute 2,920 syntax-highlighter tokens.
#
# Regenerate the KEYS with:
#     check_editor_compliance.py --project . --write-baseline
# then WRITE THE REASON for each new row. A row with no reason, or with a
# reason from the vacuity list, is REFUSED -- a reason nobody chose is worth no
# more than the empty string.
#
# Format: <dimension>\\t<kind>\\t<key>\\t<count>\\t<reason>
#
#   dimension  D1 | D2 | D4 | D5 | D6 | D7
#   kind       the TYPED reason. One of:
#                generated-content    a generator's output; content, not structure
#                contextual-selector  a class that exists only inside a context
#                runtime-computed     an attribute chosen at runtime
#                codegen-artifact     the framework's codegen did not attribute it
#                non-visual           <script>/<style>; no visual surface
#                behaviour-hook       a script selector carrying no declarations
#   key        row-type dependent; `--write-baseline` spells it for you
#   count      an integer, which ratchets one way, or `*` for a
#              content-shaped population whose size is not the claim
#   reason     free text. REQUIRED. It is what the next agent reads.
#
# Line numbers are deliberately absent from every key so that an edit above a
# site does not invalidate the file.
#
# THESE REASONS SHOULD EVENTUALLY LIVE IN THE SOURCE, beside the decision, via
# `rawRegion(erGeneratedContent, "...")` and friends. The typed vocabulary here
# is that vocabulary, so the migration is a transport change.
"""


class BaselineRow:
    __slots__ = ("dimension", "kind", "key", "count", "reason", "line", "used")

    def __init__(self, dimension, kind, key, count, reason, line=0):
        self.dimension = dimension
        self.kind = kind
        self.key = key
        self.count = count          # int, or None meaning `*`
        self.reason = reason
        self.line = line
        self.used = False

    @property
    def row_type(self) -> str:
        return ROW_TYPE_OF_KEY(self.dimension, self.key)


def row_type_for(dimension: str, key: str) -> str:
    """Which row type a key belongs to, from the key's own shape.

    The file does not carry a separate row-type column. It could, but the shape
    of the key already says it unambiguously and a redundant column is a place
    for the two to disagree.
    """
    if dimension == "D1":
        return "unattributed" if "::" in key else "raw-region"
    if dimension == "D2":
        return "runtime-class" if "::" in key else "class"
    if dimension == "D4":
        if key.startswith("role::"):
            return "missed-role-binding"
        return "component-references-ref" if "::" in key else \
               "comp-references-ref"
    if dimension == "D5":
        return "token"
    if dimension == "D6":
        return "unreachable"
    return "edit-contract"


ROW_TYPE_OF_KEY = row_type_for


def read_baseline(path: pathlib.Path):
    """Parse the baseline. A malformed row is an ERROR, never a skipped line.

    A parser that shrugged at a bad row would let the file be emptied by
    corruption and still report "compliant" -- the failure this file exists to
    prevent, reached through the file itself.
    """
    rows: list[BaselineRow] = []
    errors: list[str] = []
    if not path.exists():
        return rows, []          # absent is legal: a compliant project has none
    seen: set[tuple[str, str]] = set()
    for number, line in enumerate(
            path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 5:
            errors.append(
                f"{path.name}:{number}: expected 5 tab-separated fields "
                f"(dimension, kind, key, count, reason), got {len(fields)}")
            continue
        dimension, kind, key, raw_count, reason = (f.strip() for f in fields)
        if dimension not in DIMENSION_TITLES:
            errors.append(f"{path.name}:{number}: unknown dimension "
                          f"`{dimension}`")
            continue
        if kind not in REASON_KINDS:
            errors.append(
                f"{path.name}:{number}: `{kind}` is not a typed reason. "
                f"Use one of: {', '.join(sorted(REASON_KINDS))}")
            continue
        allowed = ROW_KINDS.get((dimension, row_type_for(dimension, key)))
        if allowed is not None and kind not in allowed:
            errors.append(
                f"{path.name}:{number}: a "
                f"{row_type_for(dimension, key)} row may not be justified as "
                f"`{kind}`; allowed here: {', '.join(sorted(allowed))}")
            continue
        if raw_count == "*":
            count = None
        else:
            try:
                count = int(raw_count)
            except ValueError:
                errors.append(f"{path.name}:{number}: count `{raw_count}` is "
                              f"neither an integer nor `*`")
                continue
            if count < 1:
                errors.append(
                    f"{path.name}:{number}: count {count} pins nothing; a row "
                    f"that has reached zero should be deleted, which "
                    f"--write-baseline does for you")
                continue
        problem = vacuous_reason(reason)
        if problem:
            errors.append(f"{path.name}:{number}: {problem}\n"
                          f"        row: {dimension} {kind} {key}")
            continue
        if (dimension, key) in seen:
            errors.append(f"{path.name}:{number}: duplicate row for "
                          f"{dimension} {key}")
            continue
        seen.add((dimension, key))
        rows.append(BaselineRow(dimension, kind, key, count, reason, number))
    return rows, errors


def vacuous_reason(reason: str) -> str:
    """Why this reason is not one, or "" if it is.

    The whole argument for a reason column over a bare count is that somebody
    had to think. A column that accepts "by design" has given that back.
    """
    stripped = reason.strip()
    if stripped.lower().rstrip(".") in VACUOUS_REASONS:
        return (f"the reason `{stripped}` says nothing. Name the specific "
                f"thing: what the markup is, or what the class is styled as, "
                f"and why the alternative is worse.")
    if len(stripped.split()) < MIN_REASON_WORDS:
        return (f"the reason `{stripped}` is {len(stripped.split())} words; "
                f"at least {MIN_REASON_WORDS} are expected. It is read by the "
                f"next agent, not by this script.")
    return ""


def render_baseline(rows: list[BaselineRow]) -> str:
    out = [BASELINE_HEADER]
    for row in sorted(rows, key=lambda r: (r.dimension, r.key)):
        count = "*" if row.count is None else str(row.count)
        out.append(f"{row.dimension}\t{row.kind}\t{row.key}\t{count}"
                   f"\t{row.reason}\n")
    return "".join(out)


# ---------------------------------------------------------------------------
# Findings
# ---------------------------------------------------------------------------

class Finding:
    """One unexplained exception, with everything an author needs to fix it."""

    def __init__(self, dimension, headline, detail, remedy, row):
        self.dimension = dimension
        self.headline = headline    # element + file:line, one line
        self.detail = detail        # what the editor cannot do, one sentence
        self.remedy = remedy        # what to change, in the author's terms
        self.row = row              # the baseline row that would accept it

    def render(self, indent: str = "  ") -> str:
        lines = [f"{indent}{self.headline}"]
        for chunk in self.detail.split("\n"):
            lines.append(f"{indent}    {chunk}")
        for chunk in self.remedy.split("\n"):
            lines.append(f"{indent}    {chunk}")
        if self.row:
            lines.append(f"{indent}    To accept it instead, add to the "
                         f"baseline (tab-separated), with a real reason:")
            lines.append(f"{indent}      {self.row}")
        return "\n".join(lines)


class DimensionResult:
    def __init__(self, dimension: str) -> None:
        self.dimension = dimension
        self.ran = False
        self.summary = ""
        self.skipped_because = ""
        self.findings: list[Finding] = []
        self.observations: list[str] = []
        self.measurements: dict = {}

    @property
    def failed(self) -> bool:
        return self.ran and bool(self.findings)

    @property
    def verdict(self) -> str:
        if not self.ran:
            return "SKIP"
        return "FAIL" if self.findings else "PASS"


# ---------------------------------------------------------------------------
# D1 -- attribution
# ---------------------------------------------------------------------------

def check_d1(nodes, project, rows, observed):
    """Every structural element carries ``data-isonim-src``.

    Structural means "not inside a declared raw region". The check cannot infer
    a raw region -- an element inside one and an element the DSL forgot to
    attribute look identical in the output, which is precisely why the region
    has to be DECLARED. A declaration is therefore not a loophole in the check;
    it is the only place the information exists.
    """
    result = DimensionResult("D1")
    result.ran = True

    regions = [r for r in rows if r.dimension == "D1"
               and row_type_for("D1", r.key) == "raw-region"]
    accepted = {r.key: r for r in rows if r.dimension == "D1"
                and row_type_for("D1", r.key) == "unattributed"}

    # --- resolve the declared regions -------------------------------------
    selectors = []
    for row in regions:
        try:
            selectors.append((Selector(row.key), row))
        except ValueError as error:
            result.findings.append(Finding(
                "D1",
                f"the raw-region selector `{row.key}` in the baseline is "
                f"unusable",
                str(error),
                "Fix the selector, or delete the row and let the elements be "
                "reported individually.",
                ""))

    raw_roots: set[int] = set()
    region_hits: Counter = Counter()
    for node in nodes:
        for selector, row in selectors:
            if selector.matches(node):
                raw_roots.add(node["index"])
                region_hits[row.key] += 1
                break

    inside_raw: set[int] = set()
    if raw_roots:
        for node in nodes:
            parent = node["parent"]
            if parent is None:
                continue
            if any(a in raw_roots for a in ancestors(nodes, parent)):
                inside_raw.add(node["index"])

    for selector, row in selectors:
        row.used = True
        if region_hits[row.key] == 0:
            # A region that matches nothing is a row left behind by a refactor.
            # Reported, not failed: a page that stopped emitting the markup is
            # an improvement, and the remedy is a deletion.
            result.observations.append(
                f"raw region `{row.key}` matched no element; the markup it "
                f"accounted for is gone. Delete the row.")

    structural = [n for n in nodes if n["index"] not in inside_raw]
    attributed = [n for n in structural if "data-isonim-src" in n["attrs"]]
    unattributed = [n for n in structural if "data-isonim-src" not in n["attrs"]]

    # --- anti-vacuity ------------------------------------------------------
    #
    # Asserted BEFORE the comparison, for the reason check_bare_skips.py's own
    # floors give: a scan that parsed nothing finds no exceptions, every
    # baseline row then looks fixed, and --write-baseline would ERASE the
    # record on its way through.
    if not nodes:
        result.findings.append(Finding(
            "D1", "the rendered page contains no elements at all",
            "Nothing was parsed, so a clean verdict would mean nothing.",
            "Check that --html points at a real render.", ""))
        return result
    if not attributed:
        result.findings.append(Finding(
            "D1",
            f"none of the {len(nodes)} elements carries `data-isonim-src`",
            "That is what a page built WITHOUT -d:isonimEditor looks like: the\n"
            "provenance seam compiles to a no-op in production, so the page is\n"
            "byte-identical to one built before the feature existed.",
            "Rebuild with `-d:isonimEditor` and re-run. If this IS an editor\n"
            "build, the DSL is not stamping at all and that is a framework bug,\n"
            "not a project one.", ""))
        return result

    # --- group the exceptions ---------------------------------------------
    groups: dict[str, list[dict]] = defaultdict(list)
    for node in unattributed:
        source, _ = nearest_attributed(nodes, node["index"], project)
        file_part = source.rsplit(":", 1)[0]
        groups[f"{file_part}::{describe(node)}"].append(node)

    for key in sorted(groups):
        members = groups[key]
        row = accepted.get(key)
        observed[("D1", key)] = len(members)
        if row is not None:
            row.used = True
            if row.count is None or len(members) <= row.count:
                continue
            excess = len(members) - row.count
            node = members[0]
            source, parent_desc = nearest_attributed(
                nodes, node["index"], project)
            result.findings.append(Finding(
                "D1",
                f"`{describe(node)}` inside `{parent_desc}` at `{source}` -- "
                f"{len(members)} unattributed, baseline pins {row.count} "
                f"({excess} new)",
                f"The baseline accepts {row.count} of these with the reason\n"
                f"\"{row.reason}\".\n"
                f"{excess} more appeared. Either the same reason covers them, "
                f"in which case\nraise the count, or something new is "
                f"unattributed under the same key.",
                f"Raise the count on the `{key}` row, or write the new markup "
                f"in the `ui:`\nDSL so the macro can stamp its source location.",
                ""))
            continue

        node = members[0]
        source, parent_desc = nearest_attributed(nodes, node["index"], project)
        plural = "" if len(members) == 1 else f" ({len(members)} of them)"
        result.findings.append(Finding(
            "D1",
            f"`{describe(node)}`{plural} inside `{parent_desc}` at `{source}` "
            f"carries no `data-isonim-src`",
            "The editor's Layers panel walks the rendered DOM, so it will SHOW "
            "this row --\n"
            "but selecting it gives the inspector no source location, so "
            "nothing about it\n"
            "can be edited or bound to a token. Seeing a row is not the same "
            "as being able\n"
            "to edit it.",
            "Write it in the `ui:` DSL -- a `for` inside the DSL body produces "
            "real,\n"
            "attributable elements where a string built with `&` produces one "
            "opaque blob.\n"
            "If it genuinely comes from outside (a Markdown render, a const "
            "SVG, a\n"
            "highlighter), declare the region that contains it instead of the "
            "element.",
            f"D1\t<typed-reason>\t{key}\t{len(members)}\t<why this cannot be "
            f"written in the DSL>"))

    result.measurements = {
        "elements": len(nodes),
        "structural": len(structural),
        "attributed": len(attributed),
        "unattributed": len(unattributed),
        "inRawRegions": len(inside_raw),
        "rawRegions": len(selectors),
    }
    share = 100.0 * len(attributed) / len(structural) if structural else 0.0
    result.summary = (
        f"{len(attributed):,} of {len(structural):,} structural elements "
        f"attributed ({share:.1f}%); "
        f"{len(unattributed)} accounted for, "
        f"{len(inside_raw):,} inside {len(selectors)} declared raw "
        f"region{'' if len(selectors) == 1 else 's'} "
        f"(of {len(nodes):,} elements rendered)")
    return result


# ---------------------------------------------------------------------------
# D2 -- class resolution
# ---------------------------------------------------------------------------

def check_d2(nodes, project, rows, observed, class_index_path):
    """Every class on the page reaches the compile-time class index.

    A class that is not in the index binds to nothing the editor can follow:
    the inspector shows a value with no provenance and the DSL records
    ``sbkUnresolved``. The refusals are not automatically debt -- a class that
    exists only inside a selector context is one the index CANNOT express, and
    indexing it anyway would assert that `.claim`'s hover colour is its resting
    colour, which is worse than silence.
    """
    result = DimensionResult("D2")
    result.ran = True

    accepted_class = {r.key: r for r in rows if r.dimension == "D2"
                      and row_type_for("D2", r.key) == "class"}
    accepted_runtime = {r.key: r for r in rows if r.dimension == "D2"
                        and row_type_for("D2", r.key) == "runtime-class"}

    resolved_records = 0
    unresolved_records = 0
    resolved_classes: set[str] = set()
    token_records = 0
    tokens_seen: set[str] = set()
    # class -> list of (node, record)
    unresolved_sites: dict[str, list] = defaultdict(list)
    runtime_sites: dict[str, list] = defaultdict(list)

    for node in nodes:
        encoded = node["attrs"].get("data-isonim-props")
        if not encoded:
            continue
        for record in decode_style_bindings(encoded):
            detail = record["detail"]
            if record["kind"] == "tok":
                token_records += 1
                if record["token"]:
                    tokens_seen.add(record["token"])
            if detail.startswith("class:"):
                name = detail[len("class:"):]
                if record["kind"] == "?":
                    unresolved_records += 1
                    unresolved_sites[name].append((node, record))
                else:
                    resolved_records += 1
                    resolved_classes.add(name)
            elif record["kind"] == "?":
                # detail == "class" with no name: the class attribute is an
                # expression, so no literal existed for the macro to resolve.
                source = source_for(nodes, node["index"], project)
                key = f"{source.rsplit(':', 1)[0]}::{node['tag']}"
                runtime_sites[key].append((node, record))

    total_class_records = resolved_records + unresolved_records
    distinct = resolved_classes | set(unresolved_sites)

    if not nodes or (total_class_records == 0 and not runtime_sites):
        result.findings.append(Finding(
            "D2", "no style-binding provenance was found on the page",
            "`data-isonim-props` is stamped in the same `when sceneGraphEnabled`\n"
            "block as `data-isonim-src`, so an empty payload usually means a\n"
            "production build.",
            "Rebuild with `-d:isonimEditor` and re-run.", ""))
        return result

    index_hint = (class_index_path if class_index_path
                  else "the project's class index")

    for name in sorted(unresolved_sites):
        sites = unresolved_sites[name]
        observed[("D2", name)] = len(sites)
        row = accepted_class.get(name)
        if row is not None:
            row.used = True
            if row.count is None or len(sites) <= row.count:
                continue
        node, _ = sites[0]
        source = source_for(nodes, node["index"], project)
        where = (f"{len(sites)} elements, the first"
                 if len(sites) > 1 else "the element")
        result.findings.append(Finding(
            "D2",
            f"`{describe(node)}` at `{source}` carries class `{name}`, which "
            f"is not in the class index"
            + (f" ({len(sites)} elements carry it)" if len(sites) > 1 else ""),
            f"The DSL recorded it as `sbkUnresolved`, so the inspector shows "
            f"{where}'s\n"
            f"properties with no provenance and cannot chase any of them to a "
            f"token.",
            f"Either declare it in {index_hint} -- or, if it is styled only in "
            f"a context\n"
            f"like `.some-parent {name}` or `.{name}[hidden]`, which the index "
            f"has no way to\n"
            f"express, record it as a deliberate refusal. Indexing a "
            f"context-only class\n"
            f"would assert that its contextual value is its resting value, "
            f"which is worse\n"
            f"than silence.",
            f"D2\tcontextual-selector\t{name}\t*\tonly styled as "
            f"`<the real selector>`; <why indexing the bare class would lie>"))

    for key in sorted(runtime_sites):
        sites = runtime_sites[key]
        observed[("D2", key)] = len(sites)
        row = accepted_runtime.get(key)
        if row is not None:
            row.used = True
            if row.count is None or len(sites) <= row.count:
                continue
        node, record = sites[0]
        source = source_for(nodes, node["index"], project)
        result.findings.append(Finding(
            "D2",
            f"`{describe(node)}` at `{source}` computes its `class` at "
            f"runtime"
            + (f" ({len(sites)} elements)" if len(sites) > 1 else ""),
            f"The DSL recorded: \"{record['note']}\".\n"
            f"This is often CORRECT and is the feature working -- the "
            f"alternative is an\n"
            f"element that looks unstyled -- but it has to be said out loud, "
            f"because the\n"
            f"editor cannot bind anything on this element.",
            "If the class is really a choice between two literals, lift it: "
            "put the\n"
            "condition in the DSL body (`if selected: span(class = \"a\") else: "
            "span(class = \"b\")`)\n"
            "so each arm has a literal the macro can resolve. If it genuinely "
            "depends on\n"
            "runtime data, record it.",
            f"D2\truntime-computed\t{key}\t*\t<what the class depends on, and "
            f"why it cannot be a literal>"))

    result.measurements = {
        "classRecords": total_class_records,
        "classRecordsResolved": resolved_records,
        "distinctClasses": len(distinct),
        "distinctResolved": len(resolved_classes),
        "tokenRecords": token_records,
        "distinctTokens": len(tokens_seen),
        "runtimeComputed": sum(len(v) for v in runtime_sites.values()),
    }
    result.summary = (
        f"{len(resolved_classes)} of {len(distinct)} distinct classes resolve "
        f"({resolved_records:,} of {total_class_records:,} records); "
        f"{token_records:,} records reach a token across "
        f"{len(tokens_seen)} tokens")
    return result


# ---------------------------------------------------------------------------
# Tokens (DTCG) -- shared by D4 and D5
# ---------------------------------------------------------------------------

TOKEN_REF_RE = re.compile(r"\{([a-zA-Z0-9_.-]+)\}")
AGENT_EXTENSION = "com.metacraft.agent"


def flatten_tokens(node, path, out):
    """Walk a DTCG tree to its tokens.

    A token is a node carrying ``$value``. Stopping there matters: a composite
    (a DTCG typography token) has a DICT ``$value`` whose members are not
    themselves tokens, and a walker that recursed into it would report a
    72-token tier as 14.
    """
    if not isinstance(node, dict):
        return
    if "$value" in node:
        out.append({"key": ".".join(path), "value": node["$value"],
                    "node": node})
        return
    for name, child in node.items():
        if name.startswith("$"):
            continue
        flatten_tokens(child, path + [name], out)


def references_in(value) -> list[str]:
    if isinstance(value, str):
        return TOKEN_REF_RE.findall(value)
    if isinstance(value, dict):
        found: list[str] = []
        for item in value.values():
            found += references_in(item)
        return found
    if isinstance(value, list):
        found = []
        for item in value:
            found += references_in(item)
        return found
    return []


def load_tokens(paths):
    """``{tier: [token, ...]}`` keyed by the tier the token's key starts with.

    Keyed by the KEY, not by the file it came from. A project is free to put
    all three tiers in one file; the tier is a property of the name.
    """
    tiers: dict[str, list] = defaultdict(list)
    inherited: dict[str, dict] = {}
    for path in paths:
        data = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
        found: list[dict] = []
        flatten_tokens(data, [], found)
        for token in found:
            token["file"] = path
            token["group"] = group_extension(data, token["key"])
            tiers[token["key"].split(".")[0]].append(token)
        inherited.update({})
    return tiers


def group_extension(root, key: str) -> dict:
    """The nearest ancestor group's agent extension, for an inherited mark.

    grip marks a whole ``ref`` GROUP ``"surface": "not-agent-facing"`` rather
    than repeating it on 72 tokens, which is the right shape. So "is this token
    marked" has to be answered by walking up, not by reading the leaf.
    """
    node = root
    marks: dict = {}
    for part in key.split("."):
        if not isinstance(node, dict) or part not in node:
            break
        node = node[part]
        if isinstance(node, dict):
            extension = (node.get("$extensions", {}) or {}).get(
                AGENT_EXTENSION, {}) or {}
            if extension:
                marks = {**marks, **extension}
    return marks


def agent_marks(token) -> dict:
    """The token's own agent extension merged over its groups'."""
    own = (token["node"].get("$extensions", {}) or {}).get(
        AGENT_EXTENSION, {}) or {}
    return {**token.get("group", {}), **own}


# ---------------------------------------------------------------------------
# D4 -- tier discipline
# ---------------------------------------------------------------------------

def check_d4(tiers, nodes, class_index, rows, observed):
    """No component binds a ``ref``; no ``comp`` token references one directly.

    From Material, adopted in ``Design-System-Model.md``, and Primer's wording
    for the first half: base tokens "should never be used directly in code or
    design". A class that says ``var(--ref-color-neutral-400)`` has named a
    swatch rather than a decision, and the next person cannot tell whether it
    meant "a strong border" or "that grey".

    The spec's third test -- alias-only detection -- is NOT implemented. See
    the module docstring: it is ~100% false-positive on the only calibration
    target, because a `ref` ramp whose build fails on an unused step is 1:1
    with its roles BY CONSTRUCTION.
    """
    result = DimensionResult("D4")
    result.ran = True

    accepted = {r.key: r for r in rows if r.dimension == "D4"}

    # --- D4a: does anything a component renders bind a `ref`? -------------
    component_hits: dict[str, list[str]] = defaultdict(list)
    for node in nodes:
        for record in decode_style_bindings(
                node["attrs"].get("data-isonim-props") or ""):
            token = record["token"]
            if token and re.match(r"^ref[-.]", token):
                component_hits[token].append(describe(node))
    for name, properties in (class_index or {}).items():
        if not isinstance(properties, dict):
            continue
        for prop, value in properties.items():
            if not isinstance(value, str):
                continue
            for match in re.findall(r"var\(--(ref[\w-]*)\)", value):
                component_hits[match].append(f".{name} {{{prop}}}")

    for token in sorted(component_hits):
        sites = component_hits[token]
        key = f"component::{token}"
        observed[("D4", key)] = len(sites)
        row = accepted.get(key)
        if row is not None:
            row.used = True
            if row.count is None or len(sites) <= row.count:
                continue
        result.findings.append(Finding(
            "D4",
            f"`{token}` -- a `ref` primitive -- is bound directly by "
            f"{len(sites)} site(s), e.g. `{sites[0]}`",
            "`ref` is machinery. A component that binds one has named a swatch "
            "rather than\n"
            "a decision, so changing the role it meant changes nothing and the "
            "next reader\n"
            "cannot tell which role was intended.",
            "Bind the `sys` (or, inside one component, `comp`) role that names "
            "the\n"
            "decision. If no role names it, that is the role that is missing.",
            f"D4\tdesign-decision\t{key}\t{len(sites)}\t<why no semantic role "
            f"can name this>"))

    # --- D4b: does a `comp` token reference a `ref` directly? -------------
    comp_to_ref: list[tuple[str, str]] = []
    for token in tiers.get("comp", []):
        for reference in references_in(token["value"]):
            if reference.startswith("ref."):
                comp_to_ref.append((token["key"], reference))

    if comp_to_ref:
        # Grouped under the longest shared prefix so that 26 tokens of one
        # component's theme are ONE reviewable line rather than 26. A glob row
        # (`comp.code.*`) accepts every key it covers.
        by_group: dict[str, list[tuple[str, str]]] = defaultdict(list)
        for key, reference in comp_to_ref:
            parts = key.split(".")
            by_group[".".join(parts[:2]) + ".*" if len(parts) > 2 else key
                     ].append((key, reference))
        for group in sorted(by_group):
            members = by_group[group]
            observed[("D4", group)] = len(members)
            row = accepted.get(group)
            if row is not None:
                row.used = True
                if row.count is None or len(members) <= row.count:
                    continue
            key, reference = members[0]
            result.findings.append(Finding(
                "D4",
                f"{len(members)} `comp` token(s) under `{group}` reference a "
                f"`ref` primitive directly, e.g. `{key}` -> `{reference}`",
                "Material's tier rule is comp -> sys -> ref. A `comp` tier "
                "bound straight to\n"
                "primitives is not connected to the semantic tier at all, so a "
                "change to the\n"
                "system's roles does not move it.",
                "Point them at the `sys` roles that name the decisions -- or, "
                "if this\n"
                "component is a self-contained surface whose `comp` tier IS "
                "its semantic\n"
                "layer, say so. That is a defensible answer and it is the one "
                "grip gives,\n"
                "but it has to be given rather than assumed.",
                f"D4\tdesign-decision\t{group}\t{len(members)}\t<why this "
                f"component's comp tier is its own semantic layer>"))

    # --- D4c: a `comp` token that could have bound a `sys` role -----------
    #
    # THIS IS THE PART OF D3 THAT SURVIVES MECHANISATION, and it is worth
    # saying why it is here rather than there. D3's open question is "value
    # matches a token but is not bound", and the objection to it is sound: a
    # design system has coincidental value matches and a test that fires on
    # them gets ignored.
    #
    # This test does not compare VALUES. It compares REFERENCES: a `comp`
    # token and a `sys` role that resolve to the SAME `ref` primitive are not
    # coincidentally equal, they are the same decision written twice, and one
    # of the two writings has a name that says what the decision is. Measured
    # on grip it fires four times and every one is arguable in a sentence,
    # which is the frequency a gated check can carry.
    #
    # It fires only where D4b already fires, so it costs no new scan and adds
    # no new failure mode: a project whose `comp` tier goes through `sys` has
    # nothing here by construction.
    sys_by_ref: dict[str, list[str]] = defaultdict(list)
    for token in tiers.get("sys", []):
        if not isinstance(token["value"], str):
            continue
        match = re.fullmatch(r"\{(ref\.[a-zA-Z0-9_.-]+)\}",
                             token["value"].strip())
        if match:
            sys_by_ref[match.group(1)].append(token["key"])

    missed = 0
    for token in tiers.get("comp", []):
        if not isinstance(token["value"], str):
            continue
        match = re.fullmatch(r"\{(ref\.[a-zA-Z0-9_.-]+)\}",
                             token["value"].strip())
        if not match:
            continue
        roles = sys_by_ref.get(match.group(1))
        if not roles:
            continue
        missed += 1
        key = f"role::{token['key']}"
        observed[("D4", key)] = 1
        row = accepted.get(key)
        if row is not None:
            row.used = True
            continue
        result.findings.append(Finding(
            "D4",
            f"`{token['key']}` resolves to `{match.group(1)}`, which "
            f"`{roles[0]}` already names",
            "The same primitive is reached by two paths, and one of them has a "
            "name that\n"
            "says what the decision IS. This is not a coincidental value "
            "match -- both\n"
            "tokens point at the identical `ref` -- so either they are the "
            "same decision,\n"
            "in which case one should bind the other, or they are two "
            "decisions that\n"
            "happen to coincide today and will drift apart the moment either "
            "moves.",
            f"Bind `{roles[0]}` instead of the primitive -- or, if these are "
            f"genuinely two\n"
            f"different decisions, say which two, because nothing in the "
            f"files says it now.",
            f"D4\tdesign-decision\t{key}\t1\t<the two different decisions, "
            f"named>"))

    result.measurements = {
        "refTokens": len(tiers.get("ref", [])),
        "sysTokens": len(tiers.get("sys", [])),
        "compTokens": len(tiers.get("comp", [])),
        "compReferencingRef": len(comp_to_ref),
        "componentsBindingRef": sum(len(v) for v in component_hits.values()),
        "missedRoleBindings": missed,
    }
    result.summary = (
        f"{len(tiers.get('ref', []))} ref / {len(tiers.get('sys', []))} sys / "
        f"{len(tiers.get('comp', []))} comp; "
        f"{sum(len(v) for v in component_hits.values())} component bindings "
        f"reach a `ref`; {len(comp_to_ref)} comp tokens reference a `ref`, "
        f"{missed} of them one a `sys` role already names")

    # The advisory the spec asked for as a test. Printed, never a verdict.
    alias_only = alias_only_sys_tokens(tiers)
    if alias_only:
        result.observations.append(
            f"advisory, NOT a verdict: {len(alias_only)} of "
            f"{len(tiers.get('sys', []))} `sys` tokens are the sole consumer "
            f"of the `ref` they resolve to (e.g. `{alias_only[0][0]}` -> "
            f"`{alias_only[0][1]}`). The spec calls that shape \"a rename, not "
            f"a role\"; measured here it is the DESIGNED shape of a ramp whose "
            f"build refuses an unused step, so it is reported and never "
            f"gated.")
    return result


def alias_only_sys_tokens(tiers):
    consumers: dict[str, list[str]] = defaultdict(list)
    for tier in tiers.values():
        for token in tier:
            for reference in references_in(token["value"]):
                consumers[reference].append(token["key"])
    out = []
    for token in tiers.get("sys", []):
        value = token["value"]
        if not isinstance(value, str):
            continue
        match = re.fullmatch(r"\{(ref\.[a-zA-Z0-9_.-]+)\}", value.strip())
        if match and len(consumers[match.group(1)]) == 1:
            out.append((token["key"], match.group(1)))
    return out


# ---------------------------------------------------------------------------
# D5 -- intended surface
# ---------------------------------------------------------------------------

def check_d5(tiers, rows, observed):
    """Every agent-facing token has ``usage``; every other one is marked.

    Primer publishes 13,426 colour values and annotates 93 for machine use.
    ``Design-System-Practices.md`` section 8f's finding is that SIZE MATTERS
    LESS THAN MARKING THE DIFFERENCE, and that is the whole of this check: it
    does not judge the surface, it requires that the surface be declared.
    """
    result = DimensionResult("D5")
    result.ran = True
    accepted = {r.key: r for r in rows if r.dimension == "D5"}

    surface = 0
    machinery = 0
    unmarked: list[str] = []
    without_usage: list[str] = []
    with_rules = 0
    rule_count = 0

    for tier_name, tokens in sorted(tiers.items()):
        for token in tokens:
            marks = agent_marks(token)
            declared = marks.get("surface")
            usage = (marks.get("usage") or "").strip()
            rules = marks.get("rules") or []
            if declared == "not-agent-facing":
                machinery += 1
                continue
            if declared is None and not usage and not rules:
                unmarked.append(token["key"])
                continue
            surface += 1
            if rules:
                with_rules += 1
                rule_count += len(rules)
            if not usage:
                without_usage.append(token["key"])

    for key in without_usage:
        observed[("D5", key)] = 1
        row = accepted.get(key)
        if row is not None:
            row.used = True
            continue
        result.findings.append(Finding(
            "D5",
            f"`{key}` is on the intended surface and has no `usage`",
            "An agent binding it has nothing to read but the name, and a name "
            "is not a\n"
            "rule. This is section 8f's \"every token you add, you document\" "
            "-- and if you\n"
            "are not going to write the rule, do not add the token: use the "
            "value.",
            f"Add `$extensions.\"{AGENT_EXTENSION}\".usage` -- one sentence "
            f"saying what\n"
            f"recurring decision this token names -- or mark it "
            f"`\"surface\": \"not-agent-facing\"`\n"
            f"if it is machinery.",
            f"D5\tdesign-decision\t{key}\t1\t<why this token can carry no "
            f"usage sentence>"))

    for key in unmarked:
        observed[("D5", key)] = 1
        row = accepted.get(key)
        if row is not None:
            row.used = True
            continue
        result.findings.append(Finding(
            "D5",
            f"`{key}` is marked neither agent-facing nor machinery",
            "So nobody can tell whether an agent may bind it. An unmarked "
            "token is the\n"
            "failure section 8f names: a published surface that is not an "
            "intended one.",
            f"Mark it. Either give it "
            f"`$extensions.\"{AGENT_EXTENSION}\".usage`, or mark its group\n"
            f"`\"surface\": \"not-agent-facing\"` the way a primitive tier "
            f"should be.",
            f"D5\tdesign-decision\t{key}\t1\t<why it can be neither>"))

    total = sum(len(v) for v in tiers.values())
    result.measurements = {
        "tokens": total, "surface": surface, "machinery": machinery,
        "unmarked": len(unmarked), "withoutUsage": len(without_usage),
        "withRules": with_rules, "rules": rule_count,
    }
    result.summary = (
        f"{surface} of {total} tokens are the intended surface, every one with "
        f"`usage` ({rule_count} rules across {with_rules}); "
        f"{machinery} marked machinery")
    return result


# ---------------------------------------------------------------------------
# D6 / D7 -- the workspace declaration
# ---------------------------------------------------------------------------

STORY_VIEW = {
    "skFlow": "the storyboard",
    "skPage": "the page preview",
    "skFoundation": "the Foundations page",
    "skComponent": "the component detail view",
    "skPattern": "the component detail view",
    "skGuideline": "the component detail view",
    "skVectorSymbol": "the component detail view",
}
GROUP_SECTION = {
    "skFlow": "USER JOURNEYS", "skPage": "PAGES",
    "skComponent": "COMPONENTS", "skPattern": "COMPONENTS",
    "skFoundation": "FOUNDATIONS", "skVectorSymbol": "FOUNDATIONS",
    "skGuideline": "GUIDELINES",
}


def check_d6(manifest, rows, observed):
    """Is what the project declared actually usable?

    THIS DIMENSION EXISTS BECAUSE OF A DEFECT NOTHING ELSE WOULD HAVE CAUGHT.
    grip handed ``newEditorWorkspace`` 161 foundation tokens and declared no
    story of kind ``skFoundation``. The editor's Foundations PAGE becomes the
    active view only when a foundation story is selected
    (``viewmodels.nim`` ``viewForStoryKind``), so all 161 tokens went into the
    variable picker and nowhere else and the sidebar's FOUNDATIONS heading sat
    expanded over an empty list. Measured: 0 rows. Nothing errored, nothing
    warned, every other check passed, and reading the source would never have
    shown it.
    """
    result = DimensionResult("D6")
    result.ran = True
    accepted = {r.key: r for r in rows if r.dimension == "D6"}

    groups = manifest.get("storyGroups", []) or []
    items = [(g, i) for g in groups for i in (g.get("items") or [])]
    kinds_present = {i.get("kind") for _, i in items}

    def report(key, headline, detail, remedy, row_hint):
        observed[("D6", key)] = 1
        row = accepted.get(key)
        if row is not None:
            row.used = True
            return
        result.findings.append(
            Finding("D6", headline, detail, remedy, row_hint))

    # --- tokens without a foundation story: grip's original defect ---------
    tokens = manifest.get("foundationTokens", []) or []
    if tokens and "skFoundation" not in kinds_present:
        report(
            "foundationTokens",
            f"{len(tokens)} foundation tokens are declared and no story has "
            f"kind `skFoundation`",
            "The Foundations page becomes the active view only when a "
            "foundation story is\n"
            "selected, so every one of these tokens goes into the variable "
            "picker and\n"
            "nowhere else, and the sidebar's FOUNDATIONS heading sits expanded "
            "over an\n"
            "empty list. The panel will measure 0 rows and nothing will warn "
            "you.",
            "Declare at least one `StoryGroup(kind: skFoundation)` with one "
            "item per token\n"
            "domain. The project's preview hook can render whatever sheet it "
            "likes for\n"
            "them; the editor's own token grid appears underneath.",
            "D6\tdesign-decision\tfoundationTokens\t1\t<why the tokens are "
            "meant to be unreachable>")

    # --- a group whose kind disagrees with its items ----------------------
    #
    # The sidebar files a GROUP into a section by `group.kind`
    # (`groupInSection`), and chooses the view from the ITEM's kind
    # (`viewForStoryKind`). When they disagree, the row is listed under one
    # heading and opens a different surface -- the mode-switch defect recorded
    # in isonim's issues directory, reached by declaration instead of by a
    # mode switch.
    for group in groups:
        group_kind = group.get("kind")
        for item in group.get("items") or []:
            if item.get("kind") == group_kind:
                continue
            key = f"story-kind::{group.get('name')}::{item.get('kind')}"
            report(
                key,
                f"story `{item.get('name')}` has kind `{item.get('kind')}` "
                f"inside group `{group.get('name')}` of kind `{group_kind}`",
                f"The sidebar files the GROUP into "
                f"{GROUP_SECTION.get(group_kind, '?')} by the group's kind, "
                f"but clicking the\n"
                f"row opens {STORY_VIEW.get(item.get('kind'), 'another view')} "
                f"because the view is chosen by the ITEM's kind. The row is\n"
                f"listed under one heading and renders somewhere else.",
                "Give the group and its items the same kind, or move the item "
                "to a group\n"
                "that matches it.",
                f"D6\tdesign-decision\t{key}\t1\t<why the mismatch is "
                f"intended>")

    # --- a component variant whose story does not exist -------------------
    story_names = {(g.get("name"), i.get("name"))
                   for g in groups for i in (g.get("items") or [])}
    for variant in manifest.get("componentVariants", []) or []:
        story = variant.get("story") or {}
        if not story.get("name"):
            continue
        if (story.get("group"), story.get("name")) in story_names:
            continue
        key = (f"variant::{variant.get('component')}."
               f"{variant.get('variantKey')}")
        report(
            key,
            f"component variant `{variant.get('component')}."
            f"{variant.get('variantKey')}` points at story "
            f"`{story.get('group')} / {story.get('name')}`, which no story "
            f"group declares",
            "Its declared editable properties are reachable only through that "
            "story, so\n"
            "the inspector will never offer them.",
            "Add the story, or point the variant at the story that renders "
            "this component.",
            f"D6\tdesign-decision\t{key}\t1\t<why the variant needs no story>")

    result.measurements = {
        "storyGroups": len(groups), "stories": len(items),
        "foundationTokens": len(tokens),
        "componentVariants": len(manifest.get("componentVariants", []) or []),
    }
    result.summary = (
        f"{len(items)} stories in {len(groups)} groups "
        f"({', '.join(sorted(k for k in kinds_present if k)) or 'none'}); "
        f"{len(tokens)} foundation tokens, "
        f"{len(manifest.get('componentVariants', []) or [])} component "
        f"variants")
    return result


def check_d7(manifest, rows, observed):
    """Does the edit contract cohere?

    ``writeSource: true`` with no ``WorkspaceEditAdapter`` is incoherent -- the
    editor will offer edits that cannot land, and an edit that silently does
    nothing is the worst outcome. ``writeSource: false`` WITH an adapter is
    fine and is grip's state; the editor should refuse clearly.
    """
    result = DimensionResult("D7")
    result.ran = True
    accepted = {r.key: r for r in rows if r.dimension == "D7"}

    permissions = manifest.get("permissions", {}) or {}
    write = bool(permissions.get("writeSource"))
    has_adapter = bool(manifest.get("hasEditAdapter"))
    schema = manifest.get("schema", []) or []

    def report(key, headline, detail, remedy, row_hint):
        observed[("D7", key)] = 1
        row = accepted.get(key)
        if row is not None:
            row.used = True
            return
        result.findings.append(
            Finding("D7", headline, detail, remedy, row_hint))

    if write and not has_adapter:
        report(
            "writeSource-without-adapter",
            "`permissions.writeSource` is true and the workspace supplies no "
            "`WorkspaceEditAdapter`",
            "The editor will offer every edit affordance and none of them can "
            "land. The\n"
            "project owns reading and writing its own source; with no adapter "
            "there is\n"
            "nothing to call, so an edit reports success and changes no file.",
            "Supply an `editAdapter`, or set `writeSource: false` so the "
            "editor refuses\n"
            "visibly instead of silently.",
            "D7\tdesign-decision\twriteSource-without-adapter\t1\t<why>")

    if write and has_adapter and not schema:
        report(
            "writeSource-without-schema",
            "`writeSource` is true and the workspace declares no "
            "`WorkspaceEditableSchemaEntry`",
            "The schema maps a stable edit key to a file, path and property. "
            "Without it an\n"
            "edit knows what to change but not where it lives.",
            "Declare the schema entries for the keys the variants and tokens "
            "carry.",
            "D7\tdesign-decision\twriteSource-without-schema\t1\t<why>")

    if not write:
        # Not a finding. A read-only instance is a legitimate and common state
        # -- `defaultEditorPermissions()` IS read-only -- and the thing that
        # matters is that the refusal is visible, which this tool cannot see
        # from here and must not pretend to.
        result.observations.append(
            "read-only: `writeSource` is false"
            + (", and an edit adapter IS supplied, so the adapter is dormant "
               "by permission rather than by absence"
               if has_adapter else " and no edit adapter is supplied")
            + ". An instance can look broken when it is behaving exactly as "
              "declared; check by hand that the editor REFUSES visibly rather "
              "than doing nothing.")

    result.measurements = {
        "writeSource": write, "hasEditAdapter": has_adapter,
        "schemaEntries": len(schema),
    }
    result.summary = (
        f"writeSource={'true' if write else 'false'}, "
        f"editAdapter={'present' if has_adapter else 'absent'}, "
        f"{len(schema)} schema entries")
    return result


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
#
# A check that cannot fail is worthless, so this one must not be one. Before
# the tree is scanned, the scanner classifies a fixture whose verdicts are
# known and asserts them -- the same shape check_bare_skips.py uses, and the
# same shape check_workflows.sh uses when it feeds actionlint a known-bad
# workflow first. Without it, a scanner broken badly enough to parse nothing
# would report a clean project.

SELF_TEST_HTML = """<!doctype html>
<html data-isonim-src="/p/src/pages/home.nim:1:1"><head data-isonim-src="/p/src/pages/home.nim:2:1">
<title data-isonim-src="/p/src/pages/home.nim:3:1">t</title></head>
<body data-isonim-src="/p/src/pages/home.nim:4:1">
  <h1 data-isonim-src="/p/src/pages/home.nim:5:3"
      data-isonim-props="font|var(--sys-type-display)|tok|class:tagline|sys-type-display|;margin|0 0 30px|cls|class:tagline||">ok</h1>
  <span data-isonim-src="/p/src/components/pane.nim:10:5"
        data-isonim-props="color|inherit|?|class:hl-kw||not in the compile-time class index"><i>raw</i><i>raw</i></span>
  <div data-isonim-src="/p/src/components/pane.nim:20:5"><em>unattributed</em></div>
  <svg data-isonim-src="/p/src/components/layout.nim:30:5"
       data-isonim-props="||?|class||the class attribute is computed at runtime"><path d="M0"/></svg>
  <script>void 0;</script>
</body></html>"""

# What the scanner must say about the fixture, with NOTHING baselined.
#   * <i> x2 inside span.code-line?  No: the fixture declares no raw region, so
#     they are structural and unattributed -- proving a region is not inferred.
#   * em, path, script are unattributed too.
#   * `hl-kw` does not resolve; `tagline` does.
#   * the <svg> computes its class at runtime.
SELF_TEST_D1_KEYS = {
    "src/components/pane.nim::em": 1,
    "src/components/pane.nim::i": 2,
    "src/components/layout.nim::path": 1,
    "src/pages/home.nim::script": 1,
}
SELF_TEST_D2_KEYS = {
    "hl-kw": 1,
    "src/components/layout.nim::svg": 1,
}
SELF_TEST_MEASURED = {"elements": 13, "structural": 13, "attributed": 8}

SELF_TEST_TOKENS = {
    "ref": {"$extensions": {AGENT_EXTENSION: {"surface": "not-agent-facing"}},
            "color": {"blue": {"500": {"$value": "#06c"}}}},
    "sys": {"color": {"accent": {
        "$value": "{ref.color.blue.500}",
        "$extensions": {AGENT_EXTENSION: {"usage": "The one accent."}}}}},
    "comp": {"code": {"keyword": {"$value": "{ref.color.blue.500}"}}},
}
# `comp.code.keyword` -> `ref.color.blue.500` is a D4b hit; `comp.code.keyword`
# is unmarked, which is a D5 hit. Both must fire.


def self_test() -> None:
    failures: list[str] = []
    project = pathlib.Path("/p")
    nodes = parse_html(SELF_TEST_HTML)

    observed: dict = {}
    d1 = check_d1(nodes, project, [], observed)
    got = {k[1]: v for k, v in observed.items() if k[0] == "D1"}
    if got != SELF_TEST_D1_KEYS:
        failures.append(f"D1 keys: expected {SELF_TEST_D1_KEYS}, got {got}")
    for name, expected in SELF_TEST_MEASURED.items():
        if d1.measurements.get(name) != expected:
            failures.append(f"D1 {name}: expected {expected}, got "
                            f"{d1.measurements.get(name)}")
    if len(d1.findings) != len(SELF_TEST_D1_KEYS):
        failures.append(f"D1 findings: expected {len(SELF_TEST_D1_KEYS)}, got "
                        f"{len(d1.findings)}")

    # A declared raw region must remove its contents from the denominator --
    # and ONLY its contents.
    region = [BaselineRow("D1", "generated-content", "span", None,
                          "the fixture's highlighter run, declared raw", 1)]
    d1_raw = check_d1(nodes, project, region, {})
    if d1_raw.measurements.get("structural") != 11:
        failures.append(f"D1 with a raw region: expected 11 structural, got "
                        f"{d1_raw.measurements.get('structural')}")

    observed = {}
    d2 = check_d2(nodes, project, [], observed, None)
    got = {k[1]: v for k, v in observed.items() if k[0] == "D2"}
    if got != SELF_TEST_D2_KEYS:
        failures.append(f"D2 keys: expected {SELF_TEST_D2_KEYS}, got {got}")
    if d2.measurements.get("distinctResolved") != 1:
        failures.append("D2: `tagline` should resolve")
    if d2.measurements.get("tokenRecords") != 1:
        failures.append("D2: one record should reach a token")

    # A baselined class must silence its finding and nothing else's.
    rows = [BaselineRow("D2", "contextual-selector", "hl-kw", None,
                        "only styled as `.code-pane .hl-kw` in the fixture", 1)]
    d2_baselined = check_d2(nodes, project, rows, {}, None)
    if len(d2_baselined.findings) != len(d2.findings) - 1:
        failures.append("D2: a baselined class did not silence exactly one "
                        "finding")
    if not rows[0].used:
        failures.append("D2: a row that silenced a finding was not marked used")

    tiers = load_tokens_from_object(SELF_TEST_TOKENS)
    d4 = check_d4(tiers, nodes, {"x": {"color": "var(--ref-color-blue-500)"}},
                  [], {})
    if len(d4.findings) != 3:
        failures.append(f"D4: expected 3 findings (one comp->ref group, one "
                        f"component binding a ref, one missed role binding), "
                        f"got {len(d4.findings)}")
    if d4.measurements.get("missedRoleBindings") != 1:
        failures.append("D4: `comp.code.keyword` and `sys.color.accent` "
                        "resolve to the same ref and that was not reported")
    d5 = check_d5(tiers, [], {})
    if len(d5.findings) != 1:
        failures.append(f"D5: expected 1 unmarked token, got "
                        f"{len(d5.findings)}")
    if d5.measurements.get("machinery") != 1:
        failures.append("D5: the ref token's GROUP mark should be inherited")

    # The reason column must actually refuse a reason that says nothing.
    for bad in ["", "by design", "known", "it is fine"]:
        if not vacuous_reason(bad):
            failures.append(f"vacuous_reason accepted `{bad}`")
    if vacuous_reason("only styled as `#panel .hd`; the dev HUD alone"):
        failures.append("vacuous_reason rejected a real reason")

    if failures:
        raise SystemExit(
            "check_editor_compliance: SELF-TEST FAILED. The scanner does not "
            "classify its own fixture correctly, so its verdict on the project "
            "means nothing.\n    " + "\n    ".join(failures))


def load_tokens_from_object(data) -> dict:
    tiers: dict[str, list] = defaultdict(list)
    found: list[dict] = []
    flatten_tokens(data, [], found)
    for token in found:
        token["file"] = "<self-test>"
        token["group"] = group_extension(data, token["key"])
        tiers[token["key"].split(".")[0]].append(token)
    return tiers


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Refuse an unexplained editor-compliance exception.",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--project", type=pathlib.Path,
                        help="project root; source paths are relative to it")
    parser.add_argument("--html", action="append", default=[],
                        help="an editor-build (-d:isonimEditor) rendered page")
    parser.add_argument("--class-index",
                        help="the compile-time class index JSON, named in "
                             "D2's remedy")
    parser.add_argument("--tokens", action="append", default=[],
                        help="a DTCG token file (D4, D5)")
    parser.add_argument("--manifest",
                        help="the workspace manifest JSON (D6, D7)")
    parser.add_argument("--baseline", type=pathlib.Path,
                        help="default <project>/compliance-baseline.tsv")
    parser.add_argument("--dimensions",
                        help="comma-separated subset, e.g. D1,D2")
    parser.add_argument("--mode", choices=("gate", "report"), default="gate")
    parser.add_argument("--write-baseline", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--self-test", action="store_true",
                        help="run the embedded fixtures and stop")
    args = parser.parse_args(argv)

    self_test()
    if args.self_test:
        print("check_editor_compliance: self-test passed.")
        return 0

    if args.project is None:
        parser.error("--project is required")
    project = args.project
    if not project.is_dir():
        parser.error(f"--project {project} is not a directory")

    wanted = ALL_DIMENSIONS
    if args.dimensions:
        wanted = [d.strip().upper() for d in args.dimensions.split(",")]
        for name in wanted:
            if name not in DIMENSION_TITLES:
                parser.error(f"unknown dimension `{name}`")
            if name == "D3":
                parser.error("D3 is not implemented; see the module docstring")

    baseline_path = args.baseline or (project / "compliance-baseline.tsv")
    rows, errors = read_baseline(baseline_path)
    if errors and not args.write_baseline:
        print("error: the editor-compliance baseline does not parse:",
              file=sys.stderr)
        for message in errors:
            print(f"    {message}", file=sys.stderr)
        return 1

    nodes: list[dict] = []
    for path in args.html:
        nodes += parse_html(pathlib.Path(path).read_text(encoding="utf-8"))
    class_index = None
    if args.class_index:
        class_index = json.loads(
            pathlib.Path(args.class_index).read_text(encoding="utf-8"))
    tiers = load_tokens(args.tokens) if args.tokens else {}
    manifest = None
    if args.manifest:
        manifest = json.loads(
            pathlib.Path(args.manifest).read_text(encoding="utf-8"))

    observed: dict = {}
    results: list[DimensionResult] = []

    def skipped(name, because):
        result = DimensionResult(name)
        result.skipped_because = because
        return result

    for name in wanted:
        if name == "D1":
            results.append(check_d1(nodes, project, rows, observed) if nodes
                           else skipped("D1", "no --html given"))
        elif name == "D2":
            results.append(
                check_d2(nodes, project, rows, observed,
                         args.class_index) if nodes
                else skipped("D2", "no --html given"))
        elif name == "D4":
            results.append(
                check_d4(tiers, nodes, class_index, rows, observed) if tiers
                else skipped("D4", "no --tokens given"))
        elif name == "D5":
            results.append(check_d5(tiers, rows, observed) if tiers
                           else skipped("D5", "no --tokens given"))
        elif name == "D6":
            results.append(check_d6(manifest, rows, observed)
                           if manifest is not None
                           else skipped("D6", "no --manifest given"))
        elif name == "D7":
            results.append(check_d7(manifest, rows, observed)
                           if manifest is not None
                           else skipped("D7", "no --manifest given"))

    if args.write_baseline:
        return write_baseline(baseline_path, rows, observed, results)

    return report(results, rows, observed, project, baseline_path,
                  args.mode, args.json)


def write_baseline(path, rows, observed, results) -> int:
    """Re-record the keys, PRESERVING every reason already written.

    The reason is the expensive half and this tool must never eat it. A key
    that is still present keeps its row verbatim; a key that has gone is
    dropped, so fixing a site costs no manual edit; a NEW key is written with a
    placeholder reason that the check itself then refuses, which is what forces
    somebody to write one.
    """
    existing = {(r.dimension, r.key): r for r in rows}
    out: list[BaselineRow] = []
    ran = {r.dimension for r in results if r.ran}
    added = 0
    for (dimension, key), count in sorted(observed.items()):
        previous = existing.get((dimension, key))
        if previous is not None:
            # Keep `*` if that is what was chosen; otherwise re-pin the count,
            # which also shrinks a row whose population has fallen.
            previous.count = None if previous.count is None else count
            out.append(previous)
            continue
        out.append(BaselineRow(dimension, placeholder_kind(dimension, key), key,
                               count, "TODO: say why this cannot be fixed"))
        added += 1
    # Rows for dimensions that did not run this time are preserved untouched:
    # a run without --tokens must not delete D4 and D5's reasons.
    for (dimension, key), row in sorted(existing.items()):
        if dimension not in ran:
            out.append(row)
    path.write_text(render_baseline(out), encoding="utf-8")
    print(f"wrote {path} ({len(out)} rows, {added} new)")
    if added:
        print(f"  {added} row(s) carry a placeholder reason and WILL FAIL the "
              f"check until you replace them.", file=sys.stderr)
    return 0


def placeholder_kind(dimension: str, key: str) -> str:
    allowed = ROW_KINDS.get((dimension, row_type_for(dimension, key)))
    if allowed and len(allowed) == 1:
        return next(iter(allowed))
    if dimension == "D2":
        return ("runtime-computed" if "::" in key else "contextual-selector")
    if dimension in {"D4", "D5", "D6", "D7"}:
        return "design-decision"
    return "generated-content"


def report(results, rows, observed, project, baseline_path, mode,
           as_json) -> int:
    failed = [r for r in results if r.failed]

    unused = [r for r in rows
              if not r.used and r.dimension in {x.dimension for x in results
                                                if x.ran}]

    if as_json:
        print(json.dumps({
            "project": str(project),
            "dimensions": [{
                "dimension": r.dimension,
                "title": DIMENSION_TITLES[r.dimension],
                "verdict": r.verdict,
                "summary": r.summary or r.skipped_because,
                "measurements": r.measurements,
                "findings": [f.headline for f in r.findings],
                "observations": r.observations,
            } for r in results],
            "staleBaselineRows": [f"{r.dimension} {r.key}" for r in unused],
            "compliant": not failed,
        }, indent=2))
        return 1 if failed and mode == "gate" else 0

    # Two path components, not one: a dozen projects in this workspace are
    # called `isonim`, and a header that says which one is the difference
    # between a report you can paste and one you have to explain.
    resolved = project.resolve()
    name = f"{resolved.parent.name}/{resolved.name}" if resolved.parent \
        else resolved.name
    print(f"isonim editor compliance — {name}")
    print()
    for result in results:
        title = DIMENSION_TITLES[result.dimension]
        label = f"{result.dimension} {title}"
        if not result.ran:
            print(f"  {label:<22} SKIP   {result.skipped_because}")
            continue
        print(f"  {label:<22} {result.verdict:<6} {result.summary}")
    print()

    for result in results:
        if not result.observations and not result.findings:
            continue
        for note in result.observations:
            print(f"  note ({result.dimension}): {note}")
    if any(r.observations for r in results):
        print()

    for result in failed:
        count = len(result.findings)
        print(f"{result.dimension} {DIMENSION_TITLES[result.dimension]} — "
              f"{count} unexplained exception{'' if count == 1 else 's'}")
        print()
        for finding in result.findings:
            print(finding.render())
            print()

    if unused:
        # Not a failure. A stale row means the project improved; the remedy is
        # a deletion and `--write-baseline` performs it.
        print(f"{len(unused)} baseline row(s) no longer match anything and "
              f"should be deleted:")
        for row in unused:
            print(f"    {baseline_path.name}:{row.line}: {row.dimension} "
                  f"{row.key}")
        print("  `--write-baseline` drops them for you.")
        print()

    accepted = Counter(r.kind for r in rows if r.used)
    if accepted:
        print("accepted exceptions, by typed reason:")
        for kind, number in accepted.most_common():
            print(f"    {number:>3}  {kind:<20} {REASON_KINDS[kind]}")
        if accepted.get("codegen-artifact"):
            print()
            print("  `codegen-artifact` rows are a gap in isonim, not in this "
                  "project: the")
            print("  framework inserted an element it did not attribute. They "
                  "belong in an")
            print("  isonim issue, and they should shrink to zero without "
                  "this project changing.")
        print()

    if failed:
        print(f"NOT COMPLIANT — {sum(len(r.findings) for r in failed)} "
              f"unexplained exception(s) across "
              f"{len(failed)} dimension(s).")
        if mode == "report":
            print("(--mode report: not failing the run.)")
            return 0
        return 1

    print("compliant — every exception is accounted for, with a reason.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
