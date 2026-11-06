"""
Tests for scripts/ci/dependabot_update_type.py (decides what gets auto-merged).
Bodies are trimmed versions of real Dependabot PRs from this repository.
"""

import importlib.util
from pathlib import Path

import pytest

_spec = importlib.util.spec_from_file_location(
    "dependabot_update_type",
    Path(__file__).resolve().parent.parent / "scripts" / "ci" / "dependabot_update_type.py",
)
mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mod)

RELEASE_NOTES = (
    "<details>\n<summary>Release notes</summary>\n"
    "<p>Migration guide: upgrading from 1.0.0 to 2.0.0 ...</p>\n"
    "| Package | From | To |\n| [x](u) | `1.0.0` | `9.0.0` |\n</details>\n"
)


@pytest.mark.unit
@pytest.mark.parametrize(
    "body,expected",
    [
        ("Bumps [urllib3](https://x) from 2.6.0 to 2.8.0.\n" + RELEASE_NOTES, "minor"),
        ("Bumps [python-dotenv](https://x) from 1.0.1 to 1.2.2.\n" + RELEASE_NOTES, "minor"),
        ("Bumps [idna](https://x) from 3.10 to 3.15.\n" + RELEASE_NOTES, "minor"),
        ("Bumps [postcss-selector-parser](https://x) from 6.1.2 to 6.1.5.\n", "patch"),
        ("Bumps [python-multipart](https://x) from 0.0.18 to 0.0.31.\n", "patch"),
        ("Bumps [certifi](https://x) from 2025.8.3 to 2026.10.18.\n", "minor"),
        ("Bumps [next](https://x) from 15.5.29 to 16.4.5.\n", "major"),
        ("Bumps [lucide-react](https://x) from 0.454.0 to 1.67.0.\n", "major"),
        ("Bumps node from 22-alpine to 25-alpine.\n", "major"),
        (
            "Removes [glob](https://x). It's no longer used.\n"
            "Removes `glob`\nUpdates `sucrase` from 3.35.0 to 3.35.1\n",
            "patch",
        ),
        (
            "Bumps the npm-minor group in /frontend with 2 updates:\n"
            "| Package | From | To |\n| --- | --- | --- |\n"
            "| [date-fns](https://x) | `4.1.0` | `4.4.0` |\n"
            "| [autoprefixer](https://x) | `10.4.21` | `10.6.2` |\n" + RELEASE_NOTES,
            "minor",
        ),
        (
            "Bumps the python-minor group with 2 updates:\n"
            "| Package | From | To |\n| --- | --- | --- |\n"
            "| [uvicorn](https://x) | `0.34.0` | `0.54.0` |\n"
            "| [bcrypt](https://x) | `4.1.2` | `5.0.0` |\n",
            "major",
        ),
        ("Bumps [x](https://x) from 2.0.0 to 1.9.0.\n", "unknown"),
        ("Some text without versions", "unknown"),
    ],
)
def test_classify(body, expected):
    assert mod.classify(body) == expected
