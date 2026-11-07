import type { Metadata } from "next";
import { ProductOverview } from "@/components/ProductOverview";

type Params = Promise<{ vendor: string }>;

export async function generateMetadata({ params }: { params: Params }): Promise<Metadata> {
  const { vendor } = await params;
  return { title: `${decodeURIComponent(vendor)} – CVEs | OpenThreat` };
}

export default async function VendorPage({ params }: { params: Params }) {
  const { vendor } = await params;
  return <ProductOverview vendor={decodeURIComponent(vendor)} />;
}
