"""
Tests for the SQL statement splitter used by backend/migrations/run_migrations.py.
"""

from pathlib import Path

import pytest

from backend.migrations.run_migrations import split_sql

MIGRATIONS_DIR = Path(__file__).resolve().parent.parent / "backend" / "migrations"


@pytest.mark.unit
@pytest.mark.parametrize(
    "sql,expected",
    [
        ("select 1; select 2;", 2),
        (
            "create function f() returns void as $$ begin perform 1; perform 2; end $$ "
            "language plpgsql; select 1;",
            2,
        ),
        ("do $x$ begin raise notice 'a;b'; end $x$; select 3", 2),
        ("select 'a;b', \"we;ird\"; select 'it''s;'", 2),
        ("-- c;\nselect 1; /* x; y */ select 2; -- only comment\n", 2),
        ("create index concurrently i on t (c) where c like 'CVE-%';", 1),
        ("-- nothing but a comment\n", 0),
    ],
)
def test_split_sql(sql, expected):
    assert len(split_sql(sql)) == expected


@pytest.mark.unit
def test_function_body_kept_intact():
    sql = (MIGRATIONS_DIR / "create_stats_cache.sql").read_text()
    statements = split_sql(sql)
    functions = [s for s in statements if "FUNCTION refresh_vulnerability_stats_cache" in s]
    assert len(functions) == 1
    assert functions[0].count("$$") == 2


@pytest.mark.unit
@pytest.mark.parametrize("path", sorted(MIGRATIONS_DIR.glob("*.sql")), ids=lambda p: p.name)
def test_every_migration_splits(path):
    assert split_sql(path.read_text())
