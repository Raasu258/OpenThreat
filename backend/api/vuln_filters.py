"""
Shared vulnerability filters and sorting for /search and /catalog.

vendors / products / cwe_ids are JSON arrays. Vendor and product filters
match whole elements case-insensitively (no more substring hits such as
"sun" matching "samsung"), using expressions that the GIN indexes from
alembic 011_add_filter_indexes cover.
"""

from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import HTTPException
from sqlalchemy import Text, cast, func, or_
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Query

from ..models import Vulnerability

SORT_FIELDS = {
    "published_at": Vulnerability.published_at,
    "modified_at": Vulnerability.modified_at,
    "cvss_score": Vulnerability.cvss_score,
    "priority_score": Vulnerability.priority_score,
    "cve_id": Vulnerability.cve_id,
}
DEFAULT_SORT = "published_at"


def normalized_list(column):
    """lower(column::text)::jsonb - must match the index expression exactly."""
    return cast(func.lower(cast(column, Text)), JSONB)


def _parse_date(value: str, field: str, end_of_day: bool = False) -> datetime:
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        raise HTTPException(status_code=422, detail=f"{field}: expected ISO date (YYYY-MM-DD)")
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    # A bare date as upper bound means "up to and including that day"
    if end_of_day and len(value) == 10:
        parsed += timedelta(days=1)
    return parsed


def apply_filters(
    query: Query,
    *,
    q: Optional[str] = None,
    severity: Optional[str] = None,
    exploited: Optional[bool] = None,
    vendor: Optional[str] = None,
    product: Optional[str] = None,
    cwe: Optional[str] = None,
    min_cvss: Optional[float] = None,
    max_cvss: Optional[float] = None,
    published_after: Optional[str] = None,
    published_before: Optional[str] = None,
    days: Optional[int] = None,
) -> Query:
    query = query.filter(Vulnerability.cve_id.like("CVE-%"))

    if q:
        term = f"%{q.strip()}%"
        query = query.filter(
            or_(
                Vulnerability.cve_id.ilike(term),
                Vulnerability.title.ilike(term),
                Vulnerability.description.ilike(term),
            )
        )
    if severity:
        query = query.filter(Vulnerability.severity == severity.upper())
    if exploited is not None:
        query = query.filter(Vulnerability.exploited_in_the_wild == exploited)
    if vendor and vendor.strip():
        query = query.filter(
            normalized_list(Vulnerability.vendors).contains([vendor.strip().lower()])
        )
    if product and product.strip():
        query = query.filter(
            normalized_list(Vulnerability.products).contains([product.strip().lower()])
        )
    if cwe and cwe.strip():
        cwe_id = cwe.strip().upper()
        if not cwe_id.startswith("CWE-"):
            cwe_id = f"CWE-{cwe_id}"
        query = query.filter(cast(Vulnerability.cwe_ids, JSONB).contains([cwe_id]))
    if min_cvss is not None:
        query = query.filter(Vulnerability.cvss_score >= min_cvss)
    if max_cvss is not None:
        query = query.filter(Vulnerability.cvss_score <= max_cvss)
    if days is not None:
        query = query.filter(
            Vulnerability.published_at >= datetime.now(timezone.utc) - timedelta(days=days)
        )
    if published_after:
        query = query.filter(
            Vulnerability.published_at >= _parse_date(published_after, "published_after")
        )
    if published_before:
        query = query.filter(
            Vulnerability.published_at
            < _parse_date(published_before, "published_before", end_of_day=True)
        )
    return query


def apply_sort(query: Query, sort_by: str, sort_order: str) -> Query:
    column = SORT_FIELDS.get(sort_by)
    if column is None:
        raise HTTPException(
            status_code=422,
            detail=f"sort_by must be one of: {', '.join(sorted(SORT_FIELDS))}",
        )
    if sort_order.lower() == "asc":
        ordered = column.asc().nullslast()
    else:
        ordered = column.desc().nullslast()
    # id as tie-breaker keeps pagination stable
    tie = Vulnerability.id.asc() if sort_order.lower() == "asc" else Vulnerability.id.desc()
    return query.order_by(ordered, tie)
