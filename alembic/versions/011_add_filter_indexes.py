"""Indexes for vendor/product/CWE filters and newest-first sorting.

vendors/products/cwe_ids are JSON arrays. The filters match exact,
case-insensitive elements via `lower(col::text)::jsonb @> '["value"]'`
(see backend/api/vuln_filters.py); these expression GIN indexes make that
an index lookup instead of a full scan over every CVE.

Revision ID: 011_add_filter_indexes
Revises: 010_add_techstack_tables
"""

from alembic import op

revision = "011_add_filter_indexes"
down_revision = "010_add_techstack_tables"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_vuln_vendors_norm ON vulnerabilities "
        "USING gin ((lower(vendors::text)::jsonb) jsonb_path_ops)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_vuln_products_norm ON vulnerabilities "
        "USING gin ((lower(products::text)::jsonb) jsonb_path_ops)"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_vuln_cwe_ids ON vulnerabilities "
        "USING gin ((cwe_ids::jsonb) jsonb_path_ops)"
    )
    # Default list order is newest first with undated CVEs last
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_vuln_published_desc ON vulnerabilities "
        "(published_at DESC NULLS LAST, id DESC)"
    )


def downgrade() -> None:
    for name in (
        "ix_vuln_published_desc",
        "ix_vuln_cwe_ids",
        "ix_vuln_products_norm",
        "ix_vuln_vendors_norm",
    ):
        op.execute(f"DROP INDEX IF EXISTS {name}")
