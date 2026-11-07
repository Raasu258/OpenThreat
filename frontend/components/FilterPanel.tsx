"use client";

import { useEffect, useState } from "react";
import { X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Autocomplete } from "@/components/Autocomplete";
import { Filters, TIME_OPTIONS, activeFilterCount } from "@/lib/filters";

const selectClass =
  "w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md text-sm bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:outline-none focus:ring-2 focus:ring-ring disabled:opacity-50";
const labelClass = "block text-xs font-medium text-gray-600 dark:text-gray-400 mb-1";

interface FilterPanelProps {
  filters: Filters;
  onChange: (patch: Partial<Filters>) => void;
  onReset: () => void;
  disabled?: boolean;
}

export function FilterPanel({ filters, onChange, onReset, disabled }: FilterPanelProps) {
  // CWE is free text: commit on Enter/blur, not on every keystroke
  const [cwe, setCwe] = useState(filters.cwe);
  useEffect(() => setCwe(filters.cwe), [filters.cwe]);
  const commitCwe = () => {
    if (cwe.trim() !== filters.cwe) onChange({ cwe: cwe.trim() });
  };

  return (
    <Card className="p-4 bg-gray-50 dark:bg-gray-800">
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Autocomplete
          label="Vendor"
          placeholder="e.g. Microsoft"
          value={filters.vendor}
          endpoint="/api/v1/catalog/vendors"
          onChange={(vendor) => onChange({ vendor, product: "" })}
          disabled={disabled}
        />
        <Autocomplete
          label="Product"
          placeholder={filters.vendor ? `Products of ${filters.vendor}` : "e.g. Exchange Server"}
          value={filters.product}
          endpoint="/api/v1/catalog/products"
          extraParams={filters.vendor ? { vendor: filters.vendor } : undefined}
          onChange={(product) => onChange({ product })}
          disabled={disabled}
        />

        <div>
          <label htmlFor="fp-severity" className={labelClass}>Severity</label>
          <select
            id="fp-severity"
            value={filters.severity}
            onChange={(e) => onChange({ severity: e.target.value })}
            disabled={disabled}
            className={selectClass}
          >
            <option value="">All severities</option>
            <option value="CRITICAL">Critical</option>
            <option value="HIGH">High</option>
            <option value="MEDIUM">Medium</option>
            <option value="LOW">Low</option>
          </select>
        </div>

        <div>
          <label htmlFor="fp-exploited" className={labelClass}>Exploitation</label>
          <select
            id="fp-exploited"
            value={filters.exploited}
            onChange={(e) => onChange({ exploited: e.target.value })}
            disabled={disabled}
            className={selectClass}
          >
            <option value="">All CVEs</option>
            <option value="true">Known exploited (KEV)</option>
            <option value="false">Not known exploited</option>
          </select>
        </div>

        <div>
          <label htmlFor="fp-published" className={labelClass}>Published</label>
          <select
            id="fp-published"
            value={filters.days}
            onChange={(e) => onChange({ days: e.target.value })}
            disabled={disabled}
            className={selectClass}
          >
            {TIME_OPTIONS.map((o) => (
              <option key={o.value} value={o.value}>
                {o.label}
              </option>
            ))}
          </select>
        </div>

        {filters.days === "custom" && (
          <div className="flex gap-2">
            <div className="flex-1">
              <label htmlFor="fp-from" className={labelClass}>From</label>
              <input
            id="fp-from"
                type="date"
                value={filters.from}
                max={filters.to || undefined}
                onChange={(e) => onChange({ from: e.target.value })}
                disabled={disabled}
                className={selectClass}
              />
            </div>
            <div className="flex-1">
              <label htmlFor="fp-to" className={labelClass}>To</label>
              <input
            id="fp-to"
                type="date"
                value={filters.to}
                min={filters.from || undefined}
                onChange={(e) => onChange({ to: e.target.value })}
                disabled={disabled}
                className={selectClass}
              />
            </div>
          </div>
        )}

        <div>
          <label htmlFor="fp-min-cvss" className={labelClass}>Minimum CVSS</label>
          <select
            id="fp-min-cvss"
            value={filters.minCvss}
            onChange={(e) => onChange({ minCvss: e.target.value })}
            disabled={disabled}
            className={selectClass}
          >
            <option value="">Any score</option>
            <option value="4">4.0+ (medium and up)</option>
            <option value="7">7.0+ (high and up)</option>
            <option value="9">9.0+ (critical)</option>
          </select>
        </div>

        <div>
          <label htmlFor="fp-cwe" className={labelClass}>CWE</label>
          <input
            id="fp-cwe"
            type="text"
            value={cwe}
            placeholder="e.g. CWE-79 or 89"
            onChange={(e) => setCwe(e.target.value)}
            onBlur={commitCwe}
            onKeyDown={(e) => e.key === "Enter" && commitCwe()}
            disabled={disabled}
            className={selectClass}
          />
        </div>
      </div>

      {activeFilterCount(filters) > 0 && (
        <div className="mt-4 flex justify-end">
          <Button
            variant="ghost"
            size="sm"
            onClick={onReset}
            disabled={disabled}
            className="text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white"
          >
            <X className="h-4 w-4 mr-1" />
            Reset all filters
          </Button>
        </div>
      )}
    </Card>
  );
}

const CHIP_LABELS: { key: keyof Filters; label: (f: Filters) => string }[] = [
  { key: "q", label: (f) => `"${f.q}"` },
  { key: "vendor", label: (f) => `Vendor: ${f.vendor}` },
  { key: "product", label: (f) => `Product: ${f.product}` },
  { key: "severity", label: (f) => f.severity.charAt(0) + f.severity.slice(1).toLowerCase() },
  { key: "exploited", label: (f) => (f.exploited === "true" ? "Known exploited" : "Not known exploited") },
  {
    key: "days",
    label: (f) =>
      f.days === "custom"
        ? `${f.from || "…"} – ${f.to || "today"}`
        : TIME_OPTIONS.find((o) => o.value === f.days)?.label ?? `${f.days} days`,
  },
  { key: "minCvss", label: (f) => `CVSS ${f.minCvss}+` },
  { key: "cwe", label: (f) => f.cwe.toUpperCase().startsWith("CWE-") ? f.cwe.toUpperCase() : `CWE-${f.cwe}` },
];

/** Removable chips for the active filters. */
export function FilterChips({ filters, onChange }: { filters: Filters; onChange: (patch: Partial<Filters>) => void }) {
  const chips = CHIP_LABELS.filter((c) => filters[c.key] !== "");
  if (chips.length === 0) return null;
  return (
    <div className="flex flex-wrap gap-2">
      {chips.map((c) => (
        <button
          key={c.key}
          type="button"
          onClick={() => onChange({ [c.key]: "", ...(c.key === "vendor" ? { product: "" } : {}) } as Partial<Filters>)}
          className="inline-flex items-center gap-1 rounded-full border border-primary/30 bg-primary/10 px-3 py-1 text-xs font-medium text-primary hover:bg-primary/20"
          aria-label={`Remove filter ${c.label(filters)}`}
        >
          {c.label(filters)}
          <X className="h-3 w-3" />
        </button>
      ))}
    </div>
  );
}
