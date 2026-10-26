#!/usr/bin/env python3
"""Check the status frontmatter of plan documents.

Usage: check.py GLOBS [GLOBS ...]

Each argument holds one or more whitespace-separated glob patterns, expanded
from the current directory with glob(recursive=True). Every pattern must match
at least one file. Each problem prints as a GitHub error annotation, then one
summary line.

The frontmatter parses through mikefarah yq v4 (`yq -o=json`), named by the
YQ environment variable or found on PATH.

Exit codes: 0 every plan is valid, 1 a plan has a problem or a pattern matches
no file, 2 yq could not run.
"""

from __future__ import annotations

import datetime
import glob
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass

DOCS_URL = "https://github.com/brettdavies/.github#plan-frontmatter"
TITLE = "plan frontmatter"

REQUIRED: dict[str, tuple[str, ...]] = {
    "proposed": (),
    "active": (),
    "blocked": ("blocked_on",),
    "merged": ("prs", "completed"),
    "released": ("prs", "completed", "released_in"),
    "done": ("completed",),
    "superseded": ("superseded_by",),
    "dropped": ("dropped_reason",),
}
STATUSES = tuple(REQUIRED)

# prs may record pull requests on any status; every other companion key
# belongs only to the statuses that require it.
OWNERS: dict[str, tuple[str, ...]] = {}
for _status, _keys in REQUIRED.items():
    for _key in _keys:
        if _key != "prs":
            OWNERS.setdefault(_key, ())
            OWNERS[_key] += (_status,)

PR_REF = re.compile(r"(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+")
DATE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")
RELEASE = re.compile(
    r"v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?"
    r"|#[0-9]+"
    r"|[0-9a-fA-F]{40}"
)
# A PR ref where YAML expects a value: after `[`, `,`, `:`, or a list dash.
UNQUOTED_REF = re.compile(r"(?:[\[,:]|^\s*-)\s*#[0-9]", re.MULTILINE)
YQ_LINE = re.compile(r"\bL([0-9]+)\.C[0-9]+")

QUOTE_HINT = "an unquoted # starts a YAML comment, so quote each PR ref"
TEXT_PURPOSE = {
    "blocked_on": "what the plan waits on",
    "superseded_by": "the plan that replaces it (a plan path or owner/repo:path)",
    "dropped_reason": "why the plan was abandoned",
}


class YqUnavailable(Exception):
    pass


@dataclass(frozen=True)
class Problem:
    path: str | None
    line: int | None
    message: str


def example(key: str) -> str:
    return {
        "prs": 'prs: ["#123"]',
        "completed": f"completed: {datetime.date.today().isoformat()}",
        "released_in": "released_in: v1.2.3",
        "blocked_on": "blocked_on: <what the plan waits on>",
        "superseded_by": "superseded_by: docs/plans/<replacement>.md",
        "dropped_reason": "dropped_reason: <why the plan was abandoned>",
    }[key]


def join(items: list[str], conj: str) -> str:
    if len(items) <= 2:
        return f" {conj} ".join(items)
    return ", ".join(items[:-1]) + f", {conj} " + items[-1]


def show(value: object) -> str:
    return json.dumps(value)


def check_prs(value: object) -> list[str]:
    if value is None:
        return [f'prs: has no value; write prs: ["#123"] ({QUOTE_HINT})']
    if not isinstance(value, list):
        return [f'prs: {show(value)} is not a list; write prs: ["#123"] ({QUOTE_HINT})']
    if not value:
        return [
            (
                'prs: is an empty list; write prs: ["#123"], or remove the key '
                f"({QUOTE_HINT}, and prs: [#123] reads as empty)"
            )
        ]
    messages = []
    for item in value:
        if item is None:
            messages.append(
                f'prs: has an empty entry; write it as "#123" ({QUOTE_HINT})'
            )
        elif not isinstance(item, str):
            messages.append(
                f'prs: entry {show(item)} is not a string; quote it, as in "#{item}"'
            )
        elif not PR_REF.fullmatch(item):
            messages.append(
                f"prs: entry {show(item)} is not #N or owner/repo#N; "
                'write it as "#123" or "owner/repo#123"'
            )
    return messages


def check_completed(value: object) -> list[str]:
    fix = f"write {example('completed')}"
    if value is None:
        return [f"completed: has no value; {fix}"]
    if not isinstance(value, str) or not DATE.fullmatch(value):
        return [f"completed: {show(value)} is not a YYYY-MM-DD date; {fix}"]
    year, month, day = (int(part) for part in value.split("-"))
    try:
        datetime.date(year, month, day)
    except ValueError:
        return [f"completed: {value} is not a real date; {fix}"]
    return []


def check_released_in(value: object) -> list[str]:
    forms = (
        "write released_in: v1.2.3, a quoted release PR such as "
        'released_in: "#123", or the 40-character release commit SHA'
    )
    if value is None:
        return [f"released_in: has no value; {forms} ({QUOTE_HINT})"]
    if not isinstance(value, str):
        return [f"released_in: {show(value)} is not a string; quote it, or {forms}"]
    if not RELEASE.fullmatch(value):
        return [
            (
                f"released_in: {show(value)} is not a release tag (vX.Y.Z), a release PR (#N), "
                f"or a commit SHA; {forms}"
            )
        ]
    return []


def check_text(key: str):
    def validate(value: object) -> list[str]:
        if isinstance(value, str) and value.strip():
            return []
        return [f"{key}: must name {TEXT_PURPOSE[key]}; write {example(key)}"]

    return validate


VALIDATORS = {
    "prs": check_prs,
    "completed": check_completed,
    "released_in": check_released_in,
    **{key: check_text(key) for key in TEXT_PURPOSE},
}


def yq_command() -> list[str]:
    return [os.environ.get("YQ") or "yq", "-p=yaml", "-o=json", "-I=0", ".", "-"]


def parse_yaml(source: str) -> tuple[object, list[str], str | None]:
    """Return (value, duplicate keys, error) for one YAML document."""
    try:
        proc = subprocess.run(
            yq_command(), input=source, capture_output=True, text=True, check=False
        )
    except OSError as err:
        raise YqUnavailable(str(err)) from err
    if proc.returncode != 0:
        error = (
            proc.stderr.strip().removeprefix("Error: ").removeprefix("bad file '-': ")
        )
        return None, [], error or f"yq exited {proc.returncode}"
    duplicates: list[str] = []

    def pairs(items: list[tuple[str, object]]) -> dict[str, object]:
        seen: dict[str, object] = {}
        for key, value in items:
            if key in seen and key not in duplicates:
                duplicates.append(key)
            seen[key] = value
        return seen

    try:
        return json.loads(proc.stdout, object_pairs_hook=pairs), duplicates, None
    except json.JSONDecodeError as err:
        raise YqUnavailable(f"yq printed something other than JSON: {err}") from err


def key_lines(lines: list[str], key: str) -> list[int]:
    """File line numbers of a top-level `key:` in frontmatter starting on line 2."""
    pattern = re.compile(rf"{re.escape(key)}\s*:")
    return [index + 2 for index, line in enumerate(lines) if pattern.match(line)]


def check_file(path: str) -> list[Problem]:
    def problem(line: int, message: str) -> Problem:
        return Problem(path, line, message)

    try:
        with open(path, encoding="utf-8-sig") as handle:
            text = handle.read()
    except (OSError, UnicodeDecodeError) as err:
        return [problem(1, f"cannot read the file as UTF-8 ({err}); save it as UTF-8")]

    lines = text.splitlines()
    if not lines or lines[0].rstrip() != "---":
        return [
            problem(
                1,
                "no frontmatter; start the file with a --- line, then status: "
                f"({', '.join(STATUSES)}) and the keys it needs, then a closing --- line",
            )
        ]
    close = next(
        (index for index in range(1, len(lines)) if lines[index].rstrip() == "---"),
        None,
    )
    if close is None:
        return [
            problem(
                1, "the frontmatter never closes; add a --- line after its last key"
            )
        ]
    fm_lines = lines[1:close]
    source = "\n".join(fm_lines) + "\n"

    data, duplicates, error = parse_yaml(source)
    if error is not None:
        message = f"the frontmatter is not valid YAML ({error})"
        ref = UNQUOTED_REF.search(source)
        if ref:
            # yq reports where the flow list ran out, not the ref that emptied it.
            line = source.count("\n", 0, ref.start()) + 2
            message += f'; {QUOTE_HINT}, as in prs: ["#123"]'
        else:
            match = YQ_LINE.search(error)
            line = min(int(match.group(1)) + 1, close + 1) if match else 1
            message += "; fix the syntax"
        return [problem(line, message)]
    if data is None:
        data = {}
    if not isinstance(data, dict):
        return [
            problem(
                2,
                "the frontmatter must be key: value lines; "
                "start it with status: and the keys that status needs",
            )
        ]

    def line_of(key: str) -> int:
        found = key_lines(fm_lines, key)
        return found[0] if found else 1

    problems = []
    for key in duplicates:
        found = key_lines(fm_lines, key)
        line = found[1] if len(found) > 1 else 1
        problems.append(problem(line, f"{key}: appears more than once; keep one"))

    status = data.get("status")
    if "status" not in data:
        problems.append(
            problem(
                1, f"status: is missing; add status: with one of {', '.join(STATUSES)}"
            )
        )
        status = None
    elif not isinstance(status, str) or status not in REQUIRED:
        problems.append(
            problem(
                line_of("status"),
                f"status: {show(status)} is not a known status; use one of {', '.join(STATUSES)}",
            )
        )
        status = None

    if status is not None:
        missing = [key for key in REQUIRED[status] if key not in data]
        if missing:
            problems.append(
                problem(
                    line_of("status"),
                    f"status: {status} needs {join([k + ':' for k in missing], 'and')}; "
                    f"add {join([example(k) for k in missing], 'and')}",
                )
            )
        for key, owners in OWNERS.items():
            if key in data and status not in owners:
                problems.append(
                    problem(
                        line_of(key),
                        f"{key}: applies only to status {join(list(owners), 'or')}, not {status}; "
                        "remove it, or change status:",
                    )
                )

    for key, validate in VALIDATORS.items():
        if key in data:
            problems.extend(
                problem(line_of(key), message) for message in validate(data[key])
            )
    return problems


def escape_data(value: str) -> str:
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def escape_property(value: str) -> str:
    return escape_data(value).replace(":", "%3A").replace(",", "%2C")


def annotation(item: Problem) -> str:
    props = f"title={TITLE}"
    if item.path is not None:
        props = f"file={escape_property(item.path)},line={item.line or 1},{props}"
    return f"::error {props}::{escape_data(item.message)}"


def expand(arguments: list[str]) -> tuple[list[str], list[Problem]]:
    patterns = [pattern for argument in arguments for pattern in argument.split()]
    if not patterns:
        return [], [
            Problem(
                None,
                None,
                "no glob patterns given; pass the plan globs, such as docs/plans/*.md",
            )
        ]
    files: list[str] = []
    problems = []
    for pattern in patterns:
        matched = sorted(
            path for path in glob.glob(pattern, recursive=True) if os.path.isfile(path)
        )
        if not matched:
            problems.append(
                Problem(
                    None,
                    None,
                    f'no file matches the glob "{pattern}"; correct the pattern, or drop it from the globs',
                )
            )
        files.extend(path for path in matched if path not in files)
    return files, problems


def main(arguments: list[str]) -> int:
    files, problems = expand(arguments)
    try:
        for path in files:
            problems.extend(check_file(path))
    except YqUnavailable as err:
        print(
            f"::error title={TITLE}::yq could not run ({escape_data(str(err))}); "
            "install mikefarah yq v4, or set YQ to its path"
        )
        return 2

    for item in problems:
        print(annotation(item))
    if problems:
        bad_files = len({item.path for item in problems if item.path is not None})
        print(
            f"{TITLE}: {len(problems)} problem(s) in {bad_files} of {len(files)} file(s); "
            f"the convention is at {DOCS_URL}"
        )
        return 1
    print(f"{TITLE}: {len(files)} file(s) valid")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
