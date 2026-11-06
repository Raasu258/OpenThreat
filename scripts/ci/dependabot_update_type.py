#!/usr/bin/env python3
"""
Classify a Dependabot PR by its largest version jump.

Reads the PR body on stdin and prints one of: patch, minor, major, unknown.

Dependabot's commit metadata only carries `update-type` for version updates,
not for security updates, so the versions are taken from the PR body
instead ("Bumps x from A to B", "Updates `x` from A to B", and the table
rows of grouped PRs).

Semver as Dependabot reports it: only a change of the first number is
major (so 0.34 -> 0.54 is minor; CI has to prove it works). Calendar
versions (first number >= 2000, e.g. certifi 2025.x -> 2026.x) are not
major. Anything that can't be parsed or goes backwards is "unknown" -
never auto-merged.
"""

import re
import sys

_PAIR_TEXT = re.compile(
    r"^(?:Bumps|Updates)\b.*?\bfrom `?([0-9][^\s`]*?)`? to `?([0-9][^\s`]*?)`?\.?\s*$", re.M
)
_PAIR_TABLE = re.compile(r"^\|[^|]+\|\s*`([^`]+)`\s*\|\s*`([^`]+)`\s*\|\s*$", re.M)
_RANK = {"patch": 0, "minor": 1, "major": 2}


def _numbers(version: str):
    nums = [int(n) for n in re.findall(r"\d+", version)[:3]]
    return nums + [0] * (3 - len(nums)) if nums else None


def classify_pair(old: str, new: str) -> str:
    a, b = _numbers(old), _numbers(new)
    if a is None or b is None or b < a:
        return "unknown"
    if a[0] != b[0] and a[0] < 2000:
        return "major"
    if a[0] != b[0]:
        return "minor"  # calendar versioning
    if a[1] != b[1]:
        return "minor"
    return "patch"


def classify(body: str) -> str:
    # Release notes / changelogs / commit lists sit in <details> blocks and
    # contain unrelated "from X to Y" text - only read the summary above.
    header = body.split("<details", 1)[0]
    pairs = _PAIR_TEXT.findall(header) + _PAIR_TABLE.findall(header)
    if not pairs:
        return "unknown"
    kinds = {classify_pair(old, new) for old, new in pairs}
    if "unknown" in kinds:
        return "unknown"
    return max(kinds, key=_RANK.__getitem__)


if __name__ == "__main__":
    print(classify(sys.stdin.read()))
