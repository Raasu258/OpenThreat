#!/usr/bin/env python3
"""
Run database migrations on startup.
This script is executed automatically when the backend starts.

Each file runs in its own transaction, so one failing file no longer
leaves the connection in an aborted state that silently breaks every
file after it. CREATE INDEX CONCURRENTLY cannot run inside a
transaction at all; files containing it are split into statements and
executed one by one in autocommit mode.

Applied files are recorded in sql_migrations (name + SHA-256) and skipped
next time. Running them again on every deploy/start was not harmless:
e.g. "ALTER TABLE vulnerabilities ADD COLUMN IF NOT EXISTS" takes an
ACCESS EXCLUSIVE lock even when the column exists, so it waited for every
long-running transaction (Celery tasks) and blocked all readers meanwhile.
A file whose content changed runs again (files are written idempotent).

Run manually (exits non-zero if any file failed):
    python -m backend.migrations.run_migrations
"""

import hashlib
import logging
import re
import sys
from pathlib import Path
from typing import List

from backend.database import engine

logger = logging.getLogger(__name__)

_CONCURRENTLY = re.compile(r"\bCONCURRENTLY\b", re.IGNORECASE)
_DOLLAR_TAG = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*\$|\$\$")


def split_sql(sql: str) -> List[str]:
    """
    Split a SQL script into statements on top-level semicolons.

    Semicolons inside single-quoted strings, double-quoted identifiers,
    dollar-quoted bodies ($$ ... $$, $tag$ ... $tag$), -- line comments
    and /* block comments */ are ignored.
    """
    statements: List[str] = []
    buf: List[str] = []
    i, n = 0, len(sql)

    while i < n:
        ch = sql[i]

        if sql.startswith("--", i):
            end = sql.find("\n", i)
            end = n if end == -1 else end
            buf.append(sql[i:end])
            i = end
            continue

        if sql.startswith("/*", i):
            end = sql.find("*/", i + 2)
            end = n if end == -1 else end + 2
            buf.append(sql[i:end])
            i = end
            continue

        if ch in ("'", '"'):
            j = i + 1
            while j < n:
                if sql[j] == ch:
                    if j + 1 < n and sql[j + 1] == ch:  # escaped '' or ""
                        j += 2
                        continue
                    break
                j += 1
            buf.append(sql[i : j + 1])
            i = j + 1
            continue

        if ch == "$":
            m = _DOLLAR_TAG.match(sql, i)
            if m:
                tag = m.group(0)
                end = sql.find(tag, m.end())
                end = n if end == -1 else end + len(tag)
                buf.append(sql[i:end])
                i = end
                continue

        if ch == ";":
            statement = "".join(buf).strip()
            if statement:
                statements.append(statement)
            buf = []
            i += 1
            continue

        buf.append(ch)
        i += 1

    tail = "".join(buf).strip()
    if tail:
        statements.append(tail)

    # Drop chunks that are only comments
    return [
        s
        for s in statements
        if any(
            line.strip() and not line.strip().startswith("--")
            for line in s.splitlines()
        )
    ]


_TRACKING_DDL = """
CREATE TABLE IF NOT EXISTS sql_migrations (
    filename   TEXT PRIMARY KEY,
    checksum   TEXT NOT NULL,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
)
"""
_RECORD = """
INSERT INTO sql_migrations (filename, checksum) VALUES (%s, %s)
ON CONFLICT (filename) DO UPDATE SET checksum = EXCLUDED.checksum, applied_at = now()
"""


def _checksum(sql: str) -> str:
    return hashlib.sha256(sql.encode()).hexdigest()


def _applied() -> dict:
    """filename -> checksum of the files already applied."""
    raw = engine.raw_connection()
    try:
        conn = raw.driver_connection
        with conn.cursor() as cur:
            cur.execute(_TRACKING_DDL)
            cur.execute("SELECT filename, checksum FROM sql_migrations")
            rows = dict(cur.fetchall())
        conn.commit()
        return rows
    finally:
        raw.close()


def _run_file(migration_file: Path) -> None:
    migration_sql = migration_file.read_text()
    checksum = _checksum(migration_sql)

    # Raw DB-API cursor without parameters: neither SQLAlchemy's ":name"
    # bind parsing nor psycopg2's "%" interpolation touches the SQL
    # (LIKE 'CVE-%', ::casts, $$ function bodies).
    raw = engine.raw_connection()
    dbapi_conn = raw.driver_connection
    try:
        if _CONCURRENTLY.search(migration_sql):
            dbapi_conn.autocommit = True
            try:
                with dbapi_conn.cursor() as cur:
                    for statement in split_sql(migration_sql):
                        cur.execute(statement)
                    cur.execute(_RECORD, (migration_file.name, checksum))
            finally:
                # Don't hand an autocommit connection back to the pool
                dbapi_conn.autocommit = False
            return

        try:
            with dbapi_conn.cursor() as cur:
                cur.execute(migration_sql)
                # recorded in the same transaction as the migration itself
                cur.execute(_RECORD, (migration_file.name, checksum))
            dbapi_conn.commit()
        except Exception:
            dbapi_conn.rollback()
            raise
    finally:
        raw.close()


def run_migrations() -> int:
    """
    Run the SQL migrations in the migrations directory that are not
    applied yet (or whose content changed).

    Returns:
        Number of files that failed.
    """
    migrations_dir = Path(__file__).parent
    migration_files = sorted(migrations_dir.glob("*.sql"))

    if not migration_files:
        logger.info("No migration files found")
        return 0

    applied = _applied()
    pending = [
        f for f in migration_files
        if applied.get(f.name) != _checksum(f.read_text())
    ]
    logger.info(
        f"Found {len(migration_files)} migration file(s), "
        f"{len(migration_files) - len(pending)} already applied"
    )

    failed = 0
    for migration_file in pending:
        logger.info(f"Running migration: {migration_file.name}")
        try:
            _run_file(migration_file)
            logger.info(f"✓ Migration {migration_file.name} completed successfully")
        except Exception as e:
            failed += 1
            logger.error(f"✗ Migration {migration_file.name} failed: {e}")
            # Don't raise - continue with other migrations

    logger.info(f"All migrations completed ({failed} failed)")
    return failed


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    )
    sys.exit(1 if run_migrations() else 0)
