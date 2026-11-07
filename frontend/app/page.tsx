"use client";

import { Suspense } from "react";
import { Clock } from "lucide-react";
import { DashboardContent } from "@/components/DashboardContent";

export default function HomePage() {
  // DashboardContent reads its filters from the URL (useSearchParams),
  // which Next.js requires to sit inside a Suspense boundary.
  return (
    <Suspense
      fallback={
        <div className="flex items-center justify-center min-h-screen">
          <Clock className="h-12 w-12 animate-spin text-primary" />
        </div>
      }
    >
      <DashboardContent />
    </Suspense>
  );
}
