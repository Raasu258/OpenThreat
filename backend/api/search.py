"""
Search endpoints with advanced filtering.
"""

from typing import Optional

from fastapi import APIRouter, Depends, Query
from sqlalchemy import desc, or_
from sqlalchemy.orm import Session

from ..database import get_db
from ..models import Vulnerability
from ..schemas import PaginatedResponse
from .vuln_filters import DEFAULT_SORT, apply_filters, apply_sort

router = APIRouter()


@router.get("/search", response_model=PaginatedResponse)
async def search_vulnerabilities(
    q: Optional[str] = Query(
        None, max_length=200, description="Search query (CVE ID, title, description)"
    ),
    severity: Optional[str] = Query(None, description="Filter by severity"),
    exploited: Optional[bool] = Query(
        None, description="Filter by exploitation status"
    ),
    vendor: Optional[str] = Query(
        None, max_length=200, description="Vendor (exact name, case-insensitive)"
    ),
    product: Optional[str] = Query(
        None, max_length=200, description="Product (exact name, case-insensitive)"
    ),
    cwe: Optional[str] = Query(None, max_length=20, description="Filter by CWE ID"),
    min_cvss: Optional[float] = Query(
        None, ge=0.0, le=10.0, description="Minimum CVSS score"
    ),
    max_cvss: Optional[float] = Query(
        None, ge=0.0, le=10.0, description="Maximum CVSS score"
    ),
    published_after: Optional[str] = Query(
        None, description="Published on/after date (YYYY-MM-DD)"
    ),
    published_before: Optional[str] = Query(
        None, description="Published on/before date (YYYY-MM-DD)"
    ),
    days: Optional[int] = Query(
        None, ge=1, le=36500, description="Only CVEs published in the last N days"
    ),
    page: int = Query(1, ge=1, description="Page number"),
    page_size: int = Query(20, ge=1, le=100, description="Items per page"),
    sort_by: str = Query(DEFAULT_SORT, description="Sort field"),
    sort_order: str = Query("desc", pattern="^(asc|desc)$", description="Sort order"),
    db: Session = Depends(get_db),
):
    """
    Search and filter vulnerabilities. Every parameter is optional; without
    any, this is the full list newest first.

    - `q`: text search in CVE ID, title and description
    - `vendor`, `product`: exact names as shown on CVE pages (case-insensitive)
    - `severity`, `exploited`, `cwe`, `min_cvss`, `max_cvss`
    - `published_after`, `published_before` (YYYY-MM-DD, inclusive) or `days`
    - `sort_by`: published_at (default), modified_at, cvss_score,
      priority_score, cve_id; `sort_order`: desc (default) or asc.
      CVEs without a value for the sort field always come last.
    """
    query = apply_filters(
        db.query(Vulnerability),
        q=q,
        severity=severity,
        exploited=exploited,
        vendor=vendor,
        product=product,
        cwe=cwe,
        min_cvss=min_cvss,
        max_cvss=max_cvss,
        published_after=published_after,
        published_before=published_before,
        days=days,
    )

    total = query.count()
    query = apply_sort(query, sort_by, sort_order)

    offset = (page - 1) * page_size
    items = query.offset(offset).limit(page_size).all()
    total_pages = (total + page_size - 1) // page_size

    return PaginatedResponse(
        total=total,
        page=page,
        page_size=page_size,
        total_pages=total_pages,
        items=items,
    )


@router.get("/search/suggest")
async def search_suggestions(
    q: str = Query(..., min_length=2, description="Search query"),
    limit: int = Query(10, ge=1, le=50, description="Number of suggestions"),
    db: Session = Depends(get_db),
):
    """
    Get search suggestions based on partial query.

    Returns CVE IDs and titles that match the query.
    """
    search_term = f"%{q}%"

    results = (
        db.query(Vulnerability.cve_id, Vulnerability.title)
        .filter(
            or_(
                Vulnerability.cve_id.ilike(search_term),
                Vulnerability.title.ilike(search_term),
            )
        )
        .order_by(desc(Vulnerability.priority_score))
        .limit(limit)
        .all()
    )

    return {
        "suggestions": [{"cve_id": cve_id, "title": title} for cve_id, title in results]
    }
