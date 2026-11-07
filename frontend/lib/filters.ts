// Filter state for the CVE list. Lives in the URL so views can be
// bookmarked and shared, e.g. /?vendor=Nginx&product=Nginx&days=90&min_cvss=7

export type SortKey = "newest" | "oldest" | "cvss" | "priority" | "updated";

export interface Filters {
  q: string;
  vendor: string;
  product: string;
  severity: string; // CRITICAL | HIGH | MEDIUM | LOW | ""
  exploited: string; // "true" | "false" | ""
  cwe: string;
  minCvss: string; // "" | "4" | "7" | "9"
  days: string; // "" | "7" | "30" | ... | "custom"
  from: string; // YYYY-MM-DD (days=custom)
  to: string; // YYYY-MM-DD (days=custom)
  sort: SortKey;
  page: number;
}

export const DEFAULT_FILTERS: Filters = {
  q: "",
  vendor: "",
  product: "",
  severity: "",
  exploited: "",
  cwe: "",
  minCvss: "",
  days: "",
  from: "",
  to: "",
  sort: "newest",
  page: 1,
};

export const SORT_OPTIONS: { key: SortKey; label: string; sort_by: string; order: string }[] = [
  { key: "newest", label: "Newest first", sort_by: "published_at", order: "desc" },
  { key: "oldest", label: "Oldest first", sort_by: "published_at", order: "asc" },
  { key: "cvss", label: "Highest CVSS", sort_by: "cvss_score", order: "desc" },
  { key: "priority", label: "Highest priority", sort_by: "priority_score", order: "desc" },
  { key: "updated", label: "Recently updated", sort_by: "modified_at", order: "desc" },
];

export const TIME_OPTIONS = [
  { value: "", label: "Any time" },
  { value: "7", label: "Last 7 days" },
  { value: "30", label: "Last 30 days" },
  { value: "90", label: "Last 90 days" },
  { value: "365", label: "Last 12 months" },
  { value: "custom", label: "Custom range" },
];

// URL keys (snake_case to match the API)
const URL_KEYS: Record<keyof Omit<Filters, "page">, string> = {
  q: "q",
  vendor: "vendor",
  product: "product",
  severity: "severity",
  exploited: "exploited",
  cwe: "cwe",
  minCvss: "min_cvss",
  days: "days",
  from: "from",
  to: "to",
  sort: "sort",
};

const SORT_KEYS = new Set(SORT_OPTIONS.map((o) => o.key));

export function filtersFromParams(params: URLSearchParams): Filters {
  const f: Filters = { ...DEFAULT_FILTERS };
  for (const [field, key] of Object.entries(URL_KEYS) as [keyof typeof URL_KEYS, string][]) {
    const value = params.get(key);
    if (value === null) continue;
    if (field === "sort") {
      if (SORT_KEYS.has(value as SortKey)) f.sort = value as SortKey;
    } else {
      f[field] = value;
    }
  }
  const page = Number(params.get("page"));
  f.page = Number.isInteger(page) && page > 0 ? page : 1;
  return f;
}

/** URL query string for the browser address bar (defaults omitted). */
export function filtersToQuery(f: Filters): string {
  const p = new URLSearchParams();
  for (const [field, key] of Object.entries(URL_KEYS) as [keyof typeof URL_KEYS, string][]) {
    const value = f[field];
    if (value === "" || value === DEFAULT_FILTERS[field]) continue;
    if ((field === "from" || field === "to") && f.days !== "custom") continue;
    p.set(key, String(value));
  }
  if (f.page > 1) p.set("page", String(f.page));
  return p.toString();
}

/** Query string for GET /api/v1/search and /api/v1/catalog/timeline. */
export function filtersToApiParams(f: Filters, opts: { page?: boolean } = {}): URLSearchParams {
  const p = new URLSearchParams();
  if (f.q.trim()) p.set("q", f.q.trim());
  if (f.vendor.trim()) p.set("vendor", f.vendor.trim());
  if (f.product.trim()) p.set("product", f.product.trim());
  if (f.severity) p.set("severity", f.severity);
  if (f.exploited) p.set("exploited", f.exploited);
  if (f.cwe.trim()) p.set("cwe", f.cwe.trim());
  if (f.minCvss) p.set("min_cvss", f.minCvss);
  if (f.days === "custom") {
    if (f.from) p.set("published_after", f.from);
    if (f.to) p.set("published_before", f.to);
  } else if (f.days) {
    p.set("days", f.days);
  }
  if (opts.page !== false) {
    const sort = SORT_OPTIONS.find((o) => o.key === f.sort) ?? SORT_OPTIONS[0];
    p.set("sort_by", sort.sort_by);
    p.set("sort_order", sort.order);
    p.set("page", String(f.page));
    p.set("page_size", "20");
  }
  return p;
}

/** Filters other than sort/page that are set - drives the chips and "Reset". */
export function activeFilterCount(f: Filters): number {
  return (["q", "vendor", "product", "severity", "exploited", "cwe", "minCvss", "days"] as const).filter(
    (k) => f[k] !== ""
  ).length;
}

export function productPath(vendor: string, product?: string): string {
  const v = encodeURIComponent(vendor);
  return product ? `/products/${v}/${encodeURIComponent(product)}` : `/products/${v}`;
}
