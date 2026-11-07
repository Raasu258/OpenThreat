"use client";

import { useState, useEffect, useMemo } from "react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { Card, CardContent } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { AlertTriangle, Shield, Clock, Calendar, Filter, Search, ChevronLeft, ChevronRight, BarChart3, Package } from "lucide-react";
import Link from "next/link";
import { formatDate, getSeverityBadgeColor, getSeverityAccentColor } from "@/lib/utils";
import { FilterChips, FilterPanel } from "@/components/FilterPanel";
import {
  DEFAULT_FILTERS,
  Filters,
  SORT_OPTIONS,
  SortKey,
  activeFilterCount,
  filtersFromParams,
  filtersToApiParams,
  filtersToQuery,
  productPath,
} from "@/lib/filters";

const CLIENT_API_URL = process.env.NEXT_PUBLIC_API_URL ?? '';

// In-memory cache with timestamps
const cache = new Map<string, { data: any; timestamp: number }>();
const CACHE_DURATION = 3 * 60 * 1000; // 3 minutes

function getCachedData(key: string) {
  const cached = cache.get(key);
  if (cached && Date.now() - cached.timestamp < CACHE_DURATION) {
    return cached.data;
  }
  return null;
}

function setCachedData(key: string, data: any) {
  cache.set(key, { data, timestamp: Date.now() });
}

export function DashboardContent() {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();

  // All filter state lives in the URL (bookmarkable, back/forward works)
  const filters = useMemo(
    () => filtersFromParams(new URLSearchParams(searchParams.toString())),
    [searchParams]
  );
  const activeCount = activeFilterCount(filters);
  const page = filters.page;

  const [recentVulns, setRecentVulns] = useState<any>(null);
  const [loading, setLoading] = useState(true);
  const [isFiltering, setIsFiltering] = useState(false);
  const [showFilters, setShowFilters] = useState(activeCount > 0);
  const [searchQuery, setSearchQuery] = useState(filters.q);

  useEffect(() => setSearchQuery(filters.q), [filters.q]);

  const updateFilters = (patch: Partial<Filters>) => {
    const next: Filters = { ...filters, ...patch };
    if (!("page" in patch)) next.page = 1;
    const qs = filtersToQuery(next);
    router.replace(qs ? `${pathname}?${qs}` : pathname, { scroll: false });
  };

  // Load whenever the URL filters change
  useEffect(() => {
    const apiQuery = filtersToApiParams(filters).toString();
    const cached = getCachedData(apiQuery);
    if (cached) {
      setRecentVulns(cached);
      setLoading(false);
      return;
    }
    const controller = new AbortController();
    setIsFiltering(true);
    fetch(`${CLIENT_API_URL}/api/v1/search?${apiQuery}`, { signal: controller.signal })
      .then((res) => (res.ok ? res.json() : Promise.reject(res.status)))
      .then((data) => {
        setCachedData(apiQuery, data);
        setRecentVulns(data);
      })
      .catch((error) => {
        if (error?.name !== "AbortError") console.error("Failed to fetch vulnerabilities:", error);
      })
      .finally(() => {
        setIsFiltering(false);
        setLoading(false);
      });
    return () => controller.abort();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [searchParams]);

  const handleSearch = (e: React.FormEvent) => {
    e.preventDefault();
    updateFilters({ q: searchQuery.trim() });
  };

  const handlePageChange = (newPage: number) => {
    updateFilters({ page: newPage });
    window.scrollTo({ top: 300, behavior: 'smooth' });
  };

  const resetFilters = () => {
    setSearchQuery("");
    updateFilters({ ...DEFAULT_FILTERS, sort: filters.sort });
  };

  const isSearchMode = activeCount > 0;

  if (loading || !recentVulns) {
    return (
      <div className="flex items-center justify-center min-h-screen">
        <div className="text-center">
          <Clock className="h-12 w-12 animate-spin mx-auto mb-4 text-primary" />
          <p className="text-gray-600 dark:text-gray-400">Loading...</p>
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-8">
      {/* Hero Section with Search */}
      <div className="text-center space-y-6 py-10">
        <div className="inline-flex items-center gap-2 px-3 py-1 rounded-full bg-primary/10 text-primary text-xs font-semibold tracking-wide uppercase">
          <Shield className="h-3.5 w-3.5" />
          Live Threat Feed
        </div>
        <h1 className="text-4xl md:text-5xl font-bold tracking-tight text-gray-900 dark:text-white">
          Latest Security Threats
        </h1>
        <p className="text-lg md:text-xl text-gray-600 dark:text-gray-400 max-w-2xl mx-auto">
          Track newly disclosed vulnerabilities as they're published, aggregated from CISA, NVD, and BSI CERT-Bund.
        </p>

        {/* Search Bar */}
        <form onSubmit={handleSearch} className="max-w-2xl mx-auto">
          <div className="relative">
            <Search className="absolute left-4 top-1/2 transform -translate-y-1/2 h-5 w-5 text-gray-400" />
            <input
              type="text"
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              placeholder="Search CVE ID, title, description, vendor, product..."
              className="w-full pl-12 pr-24 py-3 border border-gray-300 dark:border-gray-600 rounded-full bg-white dark:bg-gray-800 text-gray-900 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:outline-none focus:ring-2 focus:ring-ring focus:border-transparent shadow-sm"
            />
            <Button
              type="submit"
              disabled={isFiltering}
              className="absolute right-2 top-1/2 transform -translate-y-1/2 rounded-full px-6"
            >
              Search
            </Button>
          </div>
        </form>
      </div>

      {/* CVE List Section */}
      <div className="space-y-4">
        {/* Header */}
        <div className="space-y-3">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <h2 className="text-xl md:text-2xl font-bold text-gray-900 dark:text-white">
              {isSearchMode ? 'Filtered CVEs' : 'Recent CVEs'}
            </h2>
            <div className="flex flex-wrap items-center gap-3">
              {recentVulns && (
                <span className="text-sm text-gray-500 dark:text-gray-400">
                  {isFiltering ? "Loading..." : `${recentVulns.total?.toLocaleString() || 0} results`}
                </span>
              )}
              <select
                aria-label="Sort order"
                value={filters.sort}
                onChange={(e) => updateFilters({ sort: e.target.value as SortKey })}
                disabled={isFiltering}
                className="px-3 py-1.5 border border-gray-300 dark:border-gray-600 rounded-md text-sm bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:outline-none focus:ring-2 focus:ring-ring disabled:opacity-50"
              >
                {SORT_OPTIONS.map((o) => (
                  <option key={o.key} value={o.key}>{o.label}</option>
                ))}
              </select>
              <Button
                variant="outline"
                size="sm"
                onClick={() => setShowFilters(!showFilters)}
                aria-expanded={showFilters}
                className={activeCount > 0 ? "border-primary text-primary" : ""}
              >
                <Filter className="h-4 w-4 md:mr-2" />
                <span className="hidden md:inline">Filter</span>
                {activeCount > 0 && (
                  <span className="ml-1 md:ml-2 bg-primary text-primary-foreground rounded-full px-1.5 md:px-2 py-0.5 text-xs">
                    {activeCount}
                  </span>
                )}
              </Button>
            </div>
          </div>

          <FilterChips filters={filters} onChange={updateFilters} />

          {filters.vendor && (
            <Link
              href={productPath(filters.vendor, filters.product || undefined)}
              className="inline-flex items-center gap-2 text-sm font-medium text-primary hover:underline"
            >
              <BarChart3 className="h-4 w-4" />
              Timeline and overview for {filters.product ? `${filters.vendor} ${filters.product}` : filters.vendor}
            </Link>
          )}
        </div>

        {/* Filter Panel */}
        {showFilters && (
          <FilterPanel
            filters={filters}
            onChange={updateFilters}
            onReset={resetFilters}
            disabled={isFiltering}
          />
        )}

        {recentVulns.items.length === 0 && (
          <Card className="p-8 text-center text-gray-600 dark:text-gray-400">
            No CVEs match these filters.
            {activeCount > 0 && (
              <Button variant="link" onClick={resetFilters} className="ml-1">Reset filters</Button>
            )}
          </Card>
        )}

        {/* CVE List */}
        <div className="space-y-4">
          {recentVulns.items.map((vuln: any) => {
            const displayTitle = vuln.simple_title || vuln.title;
            const displayDescription = vuln.simple_description || vuln.description;

            return (
              <Link
                key={vuln.cve_id}
                href={`/vulnerabilities/${vuln.cve_id}`}
                className="block"
              >
                <Card className={`border-l-4 ${getSeverityAccentColor(vuln.severity)} hover:shadow-lg transition-shadow cursor-pointer`}>
                  <CardContent className="p-6">
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2 mb-2">
                        <span className="font-mono text-sm font-semibold text-primary">
                          {vuln.cve_id}
                        </span>
                        {vuln.severity && vuln.severity !== 'UNKNOWN' && (
                          <Badge className={getSeverityBadgeColor(vuln.severity)}>
                            {vuln.severity}
                          </Badge>
                        )}
                        {vuln.exploited_in_the_wild && (
                          <Badge className="bg-red-100 dark:bg-red-900/30 text-red-800 dark:text-red-400 border-red-300 dark:border-red-700">
                            <AlertTriangle className="h-3 w-3 mr-1" />
                            Exploited
                          </Badge>
                        )}
                      </div>

                      <h3 className="text-xl font-bold text-gray-900 dark:text-white hover:text-primary transition-colors mb-3">
                        {displayTitle}
                      </h3>

                      <p className="text-gray-700 dark:text-gray-300 mb-4 line-clamp-3">
                        {displayDescription}
                      </p>

                      <div className="flex flex-wrap items-center gap-3 text-sm text-gray-600 dark:text-gray-400">
                        {(vuln.vendors?.length > 0 || vuln.products?.length > 0) && (
                          <span className="flex items-center gap-1 min-w-0">
                            <Package className="h-3 w-3 shrink-0" />
                            <span className="truncate max-w-[22rem]">
                              {[...(vuln.vendors ?? []).slice(0, 2), ...(vuln.products ?? []).slice(0, 2)].join(" · ")}
                            </span>
                          </span>
                        )}
                        {vuln.cvss_score && (
                          <span className="flex items-center gap-1">
                            <Shield className="h-3 w-3" />
                            CVSS {vuln.cvss_score}
                          </span>
                        )}

                        {vuln.published_at && (
                          <span className="flex items-center gap-1 ml-auto text-gray-500 dark:text-gray-500">
                            <Calendar className="h-3 w-3" />
                            {formatDate(vuln.published_at)}
                          </span>
                        )}

                        {!vuln.published_at && vuln.modified_at && (
                          <span className="flex items-center gap-1 ml-auto text-gray-500 dark:text-gray-500">
                            <Clock className="h-3 w-3" />
                            {formatDate(vuln.modified_at)}
                          </span>
                        )}
                      </div>
                    </div>
                  </CardContent>
                </Card>
              </Link>
            );
          })}
        </div>

        {/* Pagination */}
        {recentVulns && recentVulns.total_pages > 1 && (
          <div className="flex items-center justify-center gap-2 pt-6">
            <Button
              variant="outline"
              size="sm"
              onClick={() => handlePageChange(page - 1)}
              disabled={page === 1 || isFiltering}
            >
              <ChevronLeft className="h-4 w-4" />
              <span className="hidden sm:inline ml-1">Previous</span>
            </Button>

            <div className="flex items-center gap-1">
              {page > 2 && (
                <>
                  <Button variant="outline" size="sm" onClick={() => handlePageChange(1)}>1</Button>
                  {page > 3 && <span className="text-gray-400 px-1">...</span>}
                </>
              )}

              {page > 1 && (
                <Button variant="outline" size="sm" onClick={() => handlePageChange(page - 1)}>
                  {page - 1}
                </Button>
              )}

              <Button variant="default" size="sm" disabled>{page}</Button>

              {page < recentVulns.total_pages && (
                <Button variant="outline" size="sm" onClick={() => handlePageChange(page + 1)}>
                  {page + 1}
                </Button>
              )}

              {page < recentVulns.total_pages - 1 && (
                <>
                  {page < recentVulns.total_pages - 2 && <span className="text-gray-400 px-1">...</span>}
                  <Button variant="outline" size="sm" onClick={() => handlePageChange(recentVulns.total_pages)}>
                    {recentVulns.total_pages}
                  </Button>
                </>
              )}
            </div>

            <Button
              variant="outline"
              size="sm"
              onClick={() => handlePageChange(page + 1)}
              disabled={page === recentVulns.total_pages || isFiltering}
            >
              <span className="hidden sm:inline mr-1">Next</span>
              <ChevronRight className="h-4 w-4" />
            </Button>
          </div>
        )}
      </div>
    </div>
  );
}
