"use client";

import { useEffect, useId, useRef, useState } from "react";
import { X } from "lucide-react";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "";

interface Suggestion {
  name: string;
  count: number;
}

interface AutocompleteProps {
  label: string;
  placeholder: string;
  value: string;
  onChange: (value: string) => void;
  /** e.g. "/api/v1/catalog/vendors" */
  endpoint: string;
  /** extra query params, e.g. { vendor: "Nginx" } */
  extraParams?: Record<string, string>;
  disabled?: boolean;
}

/**
 * Text input with server-side suggestions (debounced). Picking a suggestion
 * or pressing Enter commits the value via onChange; typing alone doesn't
 * trigger a search, so each keystroke doesn't reload the list.
 */
export function Autocomplete({
  label,
  placeholder,
  value,
  onChange,
  endpoint,
  extraParams,
  disabled,
}: AutocompleteProps) {
  const [text, setText] = useState(value);
  const [items, setItems] = useState<Suggestion[]>([]);
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(-1);
  const listId = useId();
  const inputId = useId();
  const extraKey = JSON.stringify(extraParams ?? {});
  const boxRef = useRef<HTMLDivElement>(null);

  useEffect(() => setText(value), [value]);

  // Debounced suggestion fetch
  useEffect(() => {
    if (!open) return;
    const controller = new AbortController();
    const timer = setTimeout(async () => {
      try {
        const params = new URLSearchParams({ q: text, limit: "8", ...(extraParams ?? {}) });
        const res = await fetch(`${API_URL}${endpoint}?${params}`, { signal: controller.signal });
        if (res.ok) {
          const data = await res.json();
          setItems(data.items ?? []);
          setActive(-1);
        }
      } catch {
        /* aborted or offline - keep previous suggestions */
      }
    }, 200);
    return () => {
      clearTimeout(timer);
      controller.abort();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [text, open, endpoint, extraKey]);

  // Close when clicking outside
  useEffect(() => {
    const onClick = (e: MouseEvent) => {
      if (boxRef.current && !boxRef.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener("mousedown", onClick);
    return () => document.removeEventListener("mousedown", onClick);
  }, []);

  const commit = (v: string) => {
    setText(v);
    setOpen(false);
    if (v !== value) onChange(v);
  };

  const onKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setOpen(true);
      setActive((i) => Math.min(i + 1, items.length - 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setActive((i) => Math.max(i - 1, -1));
    } else if (e.key === "Enter") {
      e.preventDefault();
      commit(active >= 0 && items[active] ? items[active].name : text.trim());
    } else if (e.key === "Escape") {
      setOpen(false);
    }
  };

  return (
    <div ref={boxRef} className="relative min-w-[11rem] flex-1">
      <label htmlFor={inputId} className="block text-xs font-medium text-gray-600 dark:text-gray-400 mb-1">{label}</label>
      <div className="relative">
        <input
          id={inputId}
          type="text"
          role="combobox"
          aria-expanded={open}
          aria-controls={listId}
          aria-autocomplete="list"
          value={text}
          disabled={disabled}
          placeholder={placeholder}
          onChange={(e) => {
            setText(e.target.value);
            setOpen(true);
          }}
          onFocus={() => setOpen(true)}
          onKeyDown={onKeyDown}
          className="w-full px-3 py-2 pr-8 border border-gray-300 dark:border-gray-600 rounded-md text-sm bg-white dark:bg-gray-700 text-gray-900 dark:text-white placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-ring disabled:opacity-50"
        />
        {text && !disabled && (
          <button
            type="button"
            aria-label={`Clear ${label}`}
            onClick={() => commit("")}
            className="absolute right-2 top-1/2 -translate-y-1/2 text-gray-400 hover:text-gray-700 dark:hover:text-gray-200"
          >
            <X className="h-4 w-4" />
          </button>
        )}
      </div>
      {open && items.length > 0 && (
        <ul
          id={listId}
          role="listbox"
          className="absolute z-20 mt-1 w-full max-h-64 overflow-auto rounded-md border border-gray-200 dark:border-gray-600 bg-white dark:bg-gray-800 shadow-lg text-sm"
        >
          {items.map((item, i) => (
            <li
              key={item.name}
              role="option"
              aria-selected={i === active}
              onMouseDown={(e) => {
                e.preventDefault();
                commit(item.name);
              }}
              onMouseEnter={() => setActive(i)}
              className={`flex items-center justify-between gap-3 px-3 py-2 cursor-pointer ${
                i === active ? "bg-primary/10 text-primary" : "text-gray-800 dark:text-gray-200"
              }`}
            >
              <span className="truncate">{item.name}</span>
              <span className="shrink-0 text-xs text-gray-500 dark:text-gray-400">
                {item.count.toLocaleString()} CVEs
              </span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
