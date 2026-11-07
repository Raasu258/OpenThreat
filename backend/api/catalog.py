"""
Catalog endpoints: vendor/product autocomplete and CVE timelines.

- GET /api/v1/catalog/vendors?q=micro
- GET /api/v1/catalog/products?vendor=Microsoft&q=exch
- GET /api/v1/catalog/timeline?vendor=Nginx&product=Nginx&months=24
  (accepts every /search filter, so the dashboard can chart its current view)

Vendor/product lists are aggregated in SQL and cached in Redis; if Redis is
unavailable they are computed on the fly.
"""

import hashlib
import json
import logging
from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple

import redis
from fastapi import APIRouter, Depends, Query
from sqlalchemy import func, text
from sqlalchemy.orm import Session

from ..database import REDIS_URL, get_db
from ..models import Vulnerability
from .vuln_filters import apply_filters

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/catalog", tags=["Catalog"])

NAMES_TTL = 3600  # vendor/product name lists change slowly
TIMELINE_TTL = 600

try:
    _redis = redis.from_url(REDIS_URL, decode_responses=True, socket_timeout=2)
except Exception:  # pragma: no cover - misconfigured URL
    _redis = None


def _cache_get(key: str):
    if _redis is None:
        return None
    try:
        raw = _redis.get(key)
        return json.loads(raw) if raw else None
    except Exception:
        return None


def _cache_set(key: str, value, ttl: int) -> None:
    if _redis is None:
        return
    try:
        _redis.setex(key, ttl, json.dumps(value))
    except Exception:
        pass


# --------------------------------------------------------------- names

_NAMES_SQL = """
SELECT lower(x) AS k, mode() WITHIN GROUP (ORDER BY x) AS name, count(*) AS n
FROM vulnerabilities v, json_array_elements_text(v.{column}) x
WHERE json_typeof(v.{column}) = 'array'
  AND v.cve_id LIKE 'CVE-%%'
  {vendor_clause}
GROUP BY lower(x)
ORDER BY n DESC
"""


def _all_names(db: Session, column: str, vendor: Optional[str]) -> List[Tuple[str, int]]:
    """[(display name, cve count)] for all vendors, or all products of a vendor."""
    vendor_key = (vendor or "").strip().lower()
    cache_key = f"catalog:{column}:{vendor_key}"
    cached = _cache_get(cache_key)
    if cached is not None:
        return [tuple(item) for item in cached]

    vendor_clause = ""
    params: Dict[str, str] = {}
    if column == "products" and vendor_key:
        vendor_clause = "AND lower(v.vendors::text)::jsonb @> jsonb_build_array(CAST(:vendor AS text))"
        params["vendor"] = vendor_key
    sql = _NAMES_SQL.format(column=column, vendor_clause=vendor_clause).replace("%%", "%")
    rows = db.execute(text(sql), params).all()
    names = [(row.name, int(row.n)) for row in rows]
    _cache_set(cache_key, names, NAMES_TTL)
    return names


def _match(names: List[Tuple[str, int]], q: str, limit: int) -> List[dict]:
    needle = q.strip().lower()
    if not needle:
        picked = names[:limit]
    else:
        prefix = [n for n in names if n[0].lower().startswith(needle)]
        inner = [n for n in names if needle in n[0].lower() and not n[0].lower().startswith(needle)]
        picked = (prefix + inner)[:limit]  # both already sorted by count
    return [{"name": name, "count": count} for name, count in picked]


@router.get("/vendors")
async def list_vendors(
    q: str = Query("", max_length=100, description="Prefix or substring"),
    limit: int = Query(10, ge=1, le=50),
    db: Session = Depends(get_db),
):
    """Vendors with CVE counts; prefix matches first, then by CVE count."""
    return {"items": _match(_all_names(db, "vendors", None), q, limit)}


@router.get("/products")
async def list_products(
    vendor: Optional[str] = Query(None, max_length=200, description="Limit to one vendor"),
    q: str = Query("", max_length=100, description="Prefix or substring"),
    limit: int = Query(10, ge=1, le=50),
    db: Session = Depends(get_db),
):
    """Products (optionally of one vendor) with CVE counts."""
    return {"items": _match(_all_names(db, "products", vendor), q, limit)}


# ------------------------------------------------------------ timeline

_SEVERITIES = ("CRITICAL", "HIGH", "MEDIUM", "LOW")


def _month_range(first: datetime, last: datetime) -> List[str]:
    months = []
    y, m = first.year, first.month
    while (y, m) <= (last.year, last.month):
        months.append(f"{y:04d}-{m:02d}")
        m += 1
        if m == 13:
            y, m = y + 1, 1
    return months


@router.get("/timeline")
async def timeline(
    vendor: Optional[str] = Query(None, max_length=200),
    product: Optional[str] = Query(None, max_length=200),
    q: Optional[str] = Query(None, max_length=200),
    severity: Optional[str] = Query(None),
    exploited: Optional[bool] = Query(None),
    cwe: Optional[str] = Query(None, max_length=20),
    min_cvss: Optional[float] = Query(None, ge=0.0, le=10.0),
    max_cvss: Optional[float] = Query(None, ge=0.0, le=10.0),
    published_after: Optional[str] = Query(None),
    published_before: Optional[str] = Query(None),
    days: Optional[int] = Query(None, ge=1, le=36500),
    months: int = Query(24, ge=1, le=240, description="Months shown in the chart"),
    db: Session = Depends(get_db),
):
    """
    Monthly CVE counts by severity (plus exploited) for any filter set, and
    totals over all matching CVEs. Missing months are filled with zeros.
    """
    filters = dict(
        vendor=vendor, product=product, q=q, severity=severity, exploited=exploited,
        cwe=cwe, min_cvss=min_cvss, max_cvss=max_cvss,
        published_after=published_after, published_before=published_before, days=days,
    )
    cache_key = "catalog:timeline:" + hashlib.sha1(
        json.dumps({**filters, "months": months}, sort_keys=True, default=str).encode()
    ).hexdigest()
    cached = _cache_get(cache_key)
    if cached is not None:
        return cached

    base = apply_filters(db.query(Vulnerability), **filters)
    sev = Vulnerability.severity

    summary_row = base.with_entities(
        func.count(Vulnerability.id),
        func.count(Vulnerability.id).filter(Vulnerability.exploited_in_the_wild.is_(True)),
        *[func.count(Vulnerability.id).filter(sev == s) for s in _SEVERITIES],
        func.avg(Vulnerability.cvss_score),
        func.min(Vulnerability.published_at),
        func.max(Vulnerability.published_at),
    ).one()
    total, exploited_n, crit, high, med, low, avg_cvss, first_pub, last_pub = summary_row

    now = datetime.now(timezone.utc)
    start_y, start_m = now.year, now.month - (months - 1)
    while start_m <= 0:
        start_y, start_m = start_y - 1, start_m + 12
    window_start = datetime(start_y, start_m, 1, tzinfo=timezone.utc)

    month = func.to_char(
        func.date_trunc("month", func.timezone("UTC", Vulnerability.published_at)), "YYYY-MM"
    ).label("month")
    rows = (
        base.filter(Vulnerability.published_at >= window_start)
        .with_entities(
            month,
            func.count(Vulnerability.id),
            func.count(Vulnerability.id).filter(Vulnerability.exploited_in_the_wild.is_(True)),
            *[func.count(Vulnerability.id).filter(sev == s) for s in _SEVERITIES],
        )
        .group_by(month)
        .all()
    )
    by_month = {r[0]: r for r in rows}

    buckets = []
    for key in _month_range(window_start, now):
        r = by_month.get(key)
        counts = [int(x) for x in r[1:]] if r else [0] * 6
        total_m, expl_m, c, h, m_, l_ = counts
        buckets.append({
            "month": key, "total": total_m, "exploited": expl_m,
            "critical": c, "high": h, "medium": m_, "low": l_,
            "unknown": total_m - c - h - m_ - l_,
        })

    result = {
        "filters": {k: v for k, v in filters.items() if v not in (None, "")},
        "months": months,
        "buckets": buckets,
        "summary": {
            "total": int(total or 0),
            "exploited": int(exploited_n or 0),
            "critical": int(crit or 0),
            "high": int(high or 0),
            "medium": int(med or 0),
            "low": int(low or 0),
            "avg_cvss": round(float(avg_cvss), 1) if avg_cvss is not None else None,
            "first_published": first_pub.isoformat() if first_pub else None,
            "last_published": last_pub.isoformat() if last_pub else None,
        },
    }
    _cache_set(cache_key, result, TIMELINE_TTL)
    return result
