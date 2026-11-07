"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import {
  Bar,
  CartesianGrid,
  ComposedChart,
  Legend,
  Line,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { AlertTriangle, ArrowLeft, Calendar, List, Package, Shield } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { formatDate, getSeverityAccentColor, getSeverityBadgeColor } from "@/lib/utils";
import { productPath } from "@/lib/filters";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "";

const SERIES = [
  { key: "critical", label: "Critical", color: "#dc2626" },
  { key: "high", label: "High", color: "#ea580c" },
  { key: "medium", label: "Medium", color: "#ca8a04" },
  { key: "low", label: "Low", color: "#2563eb" },
  { key: "unknown", label: "Unscored", color: "#9ca3af" },
] as const;

const RANGES = [
  { months: 12, label: "12 months" },
  { months: 24, label: "2 years" },
  { months: 60, label: "5 years" },
];

interface Bucket {
  month: string;
  total: number;
  exploited: number;
  critical: number;
  high: number;
  medium: number;
  low: number;
  unknown: number;
}

interface Timeline {
  buckets: Bucket[];
  summary: {
    total: number;
    exploited: number;
    critical: number;
    high: number;
    medium: number;
    low: number;
    avg_cvss: number | null;
    first_published: string | null;
    last_published: string | null;
  };
}

function monthLabel(month: string) {
  const [y, m] = month.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, 1)).toLocaleDateString("en-US", {
    month: "short",
    year: "2-digit",
    timeZone: "UTC",
  });
}

function Stat({ label, value, accent }: { label: string; value: string | number; accent?: string }) {
  return (
    <div className="bg-white dark:bg-gray-800 rounded-xl p-4 shadow-sm border border-gray-200 dark:border-gray-700">
      <p className={`text-2xl font-bold ${accent ?? "text-gray-900 dark:text-white"}`}>{value}</p>
      <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">{label}</p>
    </div>
  );
}

export function ProductOverview({ vendor, product }: { vendor: string; product?: string }) {
  const [months, setMonths] = useState(24);
  const [timeline, setTimeline] = useState<Timeline | null>(null);
  const [recent, setRecent] = useState<any[] | null>(null);
  const [products, setProducts] = useState<{ name: string; count: number }[]>([]);
  const [error, setError] = useState(false);

  const scope = new URLSearchParams({ vendor, ...(product ? { product } : {}) });
  const scopeKey = scope.toString();
  const title = product ? `${vendor} ${product}` : vendor;

  useEffect(() => {
    const controller = new AbortController();
    fetch(`${API_URL}/api/v1/catalog/timeline?${scopeKey}&months=${months}`, { signal: controller.signal })
      .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
      .then(setTimeline)
      .catch((e) => e?.name !== "AbortError" && setError(true));
    return () => controller.abort();
  }, [scopeKey, months]);

  useEffect(() => {
    const controller = new AbortController();
    const opts = { signal: controller.signal };
    fetch(`${API_URL}/api/v1/search?${scopeKey}&page_size=10&sort_by=published_at&sort_order=desc`, opts)
      .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
      .then((d) => setRecent(d.items))
      .catch((e) => e?.name !== "AbortError" && setError(true));
    if (!product) {
      fetch(`${API_URL}/api/v1/catalog/products?vendor=${encodeURIComponent(vendor)}&limit=30`, opts)
        .then((r) => (r.ok ? r.json() : { items: [] }))
        .then((d) => setProducts(d.items))
        .catch(() => undefined);
    }
    return () => controller.abort();
  }, [scopeKey, vendor, product]);

  const s = timeline?.summary;
  const listHref = `/?${scopeKey}`;

  return (
    <div className="space-y-8 py-6">
      {/* Header */}
      <div className="space-y-3">
        <nav className="flex items-center gap-2 text-sm text-gray-500 dark:text-gray-400">
          <Link href="/" className="inline-flex items-center gap-1 hover:text-primary">
            <ArrowLeft className="h-4 w-4" /> All CVEs
          </Link>
          <span>/</span>
          {product ? (
            <>
              <Link href={productPath(vendor)} className="hover:text-primary">{vendor}</Link>
              <span>/</span>
              <span className="text-gray-900 dark:text-white">{product}</span>
            </>
          ) : (
            <span className="text-gray-900 dark:text-white">{vendor}</span>
          )}
        </nav>
        <div className="flex flex-wrap items-end justify-between gap-4">
          <div>
            <p className="text-xs font-semibold uppercase tracking-wide text-primary flex items-center gap-1">
              <Package className="h-3.5 w-3.5" /> {product ? "Product" : "Vendor"}
            </p>
            <h1 className="text-3xl md:text-4xl font-bold text-gray-900 dark:text-white">{title}</h1>
          </div>
          <Link
            href={listHref}
            className="inline-flex items-center gap-2 rounded-md border border-gray-300 dark:border-gray-600 px-3 py-2 text-sm font-medium text-gray-700 dark:text-gray-200 hover:border-primary hover:text-primary"
          >
            <List className="h-4 w-4" /> Filter all CVEs of {title}
          </Link>
        </div>
      </div>

      {error && (
        <Card className="p-6 text-center text-red-600 dark:text-red-400">
          Could not load data for {title}.
        </Card>
      )}

      {/* Summary */}
      {s && (
        <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-4">
          <Stat label="CVEs in total" value={s.total.toLocaleString()} />
          <Stat label="Critical" value={s.critical.toLocaleString()} accent="text-red-600 dark:text-red-400" />
          <Stat label="High" value={s.high.toLocaleString()} accent="text-orange-600 dark:text-orange-400" />
          <Stat label="Known exploited" value={s.exploited.toLocaleString()} accent="text-red-700 dark:text-red-300" />
          <Stat label="Average CVSS" value={s.avg_cvss ?? "–"} />
          <Stat label="Latest CVE" value={s.last_published ? formatDate(s.last_published) : "–"} />
        </div>
      )}

      {s && s.total === 0 && (
        <Card className="p-8 text-center text-gray-600 dark:text-gray-400">
          No CVEs found for {title}. Names are matched exactly; try the vendor/product search on the dashboard.
        </Card>
      )}

      {/* Timeline */}
      {timeline && s && s.total > 0 && (
        <div className="bg-white dark:bg-gray-800 rounded-xl p-6 shadow-sm border border-gray-200 dark:border-gray-700">
          <div className="flex flex-wrap items-center justify-between gap-3 mb-4">
            <h2 className="text-lg font-semibold text-gray-900 dark:text-white flex items-center gap-2">
              <Calendar className="h-5 w-5" /> CVEs per month
            </h2>
            <div className="flex gap-1" role="group" aria-label="Time range">
              {RANGES.map((r) => (
                <button
                  key={r.months}
                  type="button"
                  onClick={() => setMonths(r.months)}
                  aria-pressed={months === r.months}
                  className={`px-3 py-1 rounded-md text-sm border ${
                    months === r.months
                      ? "bg-primary text-primary-foreground border-primary"
                      : "border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-300 hover:border-primary"
                  }`}
                >
                  {r.label}
                </button>
              ))}
            </div>
          </div>
          <div className="h-80 text-gray-500 dark:text-gray-400">
            <ResponsiveContainer width="100%" height="100%">
              <ComposedChart data={timeline.buckets} margin={{ top: 8, right: 8, bottom: 0, left: -16 }}>
                <CartesianGrid strokeDasharray="3 3" stroke="currentColor" strokeOpacity={0.15} vertical={false} />
                <XAxis
                  dataKey="month"
                  tickFormatter={monthLabel}
                  tick={{ fill: "currentColor", fontSize: 12 }}
                  interval="preserveStartEnd"
                  minTickGap={16}
                />
                <YAxis allowDecimals={false} tick={{ fill: "currentColor", fontSize: 12 }} />
                <Tooltip
                  labelFormatter={(m) => monthLabel(String(m))}
                  contentStyle={{ borderRadius: 8, fontSize: 13 }}
                />
                <Legend wrapperStyle={{ fontSize: 13 }} />
                {SERIES.map((ser) => (
                  <Bar key={ser.key} dataKey={ser.key} name={ser.label} stackId="sev" fill={ser.color} />
                ))}
                <Line
                  type="monotone"
                  dataKey="exploited"
                  name="Known exploited"
                  stroke="#7f1d1d"
                  strokeWidth={2}
                  strokeDasharray="4 3"
                  dot={false}
                />
              </ComposedChart>
            </ResponsiveContainer>
          </div>
        </div>
      )}

      {/* Products of this vendor */}
      {!product && products.length > 0 && (
        <div className="space-y-3">
          <h2 className="text-lg font-semibold text-gray-900 dark:text-white">Products</h2>
          <div className="flex flex-wrap gap-2">
            {products.map((p) => (
              <Link
                key={p.name}
                href={productPath(vendor, p.name)}
                className="inline-flex items-center gap-2 rounded-full border border-gray-300 dark:border-gray-600 px-3 py-1 text-sm text-gray-700 dark:text-gray-200 hover:border-primary hover:text-primary"
              >
                {p.name}
                <span className="text-xs text-gray-500 dark:text-gray-400">{p.count.toLocaleString()}</span>
              </Link>
            ))}
          </div>
        </div>
      )}

      {/* Latest CVEs */}
      {recent && recent.length > 0 && (
        <div className="space-y-3">
          <div className="flex items-center justify-between">
            <h2 className="text-lg font-semibold text-gray-900 dark:text-white">Latest CVEs</h2>
            <Link href={listHref} className="text-sm font-medium text-primary hover:underline">
              Show all →
            </Link>
          </div>
          {recent.map((v) => (
            <Link key={v.cve_id} href={`/vulnerabilities/${v.cve_id}`} className="block">
              <Card className={`border-l-4 ${getSeverityAccentColor(v.severity)} hover:shadow-md transition-shadow`}>
                <CardContent className="p-4 flex flex-wrap items-center gap-3">
                  <span className="font-mono text-sm font-semibold text-primary">{v.cve_id}</span>
                  {v.severity && v.severity !== "UNKNOWN" && (
                    <Badge className={getSeverityBadgeColor(v.severity)}>{v.severity}</Badge>
                  )}
                  {v.exploited_in_the_wild && (
                    <Badge className="bg-red-100 dark:bg-red-900/30 text-red-800 dark:text-red-400 border-red-300 dark:border-red-700">
                      <AlertTriangle className="h-3 w-3 mr-1" /> Exploited
                    </Badge>
                  )}
                  <span className="flex-1 min-w-[12rem] truncate text-gray-800 dark:text-gray-200">
                    {v.simple_title || v.title}
                  </span>
                  {v.cvss_score && (
                    <span className="flex items-center gap-1 text-sm text-gray-600 dark:text-gray-400">
                      <Shield className="h-3 w-3" /> {v.cvss_score}
                    </span>
                  )}
                  {v.published_at && (
                    <span className="text-sm text-gray-500">{formatDate(v.published_at)}</span>
                  )}
                </CardContent>
              </Card>
            </Link>
          ))}
        </div>
      )}
    </div>
  );
}
