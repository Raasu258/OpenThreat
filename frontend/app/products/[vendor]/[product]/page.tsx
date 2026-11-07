import type { Metadata } from "next";
import { ProductOverview } from "@/components/ProductOverview";

type Params = Promise<{ vendor: string; product: string }>;

export async function generateMetadata({ params }: { params: Params }): Promise<Metadata> {
  const { vendor, product } = await params;
  return { title: `${decodeURIComponent(vendor)} ${decodeURIComponent(product)} – CVEs | OpenThreat` };
}

export default async function ProductPage({ params }: { params: Params }) {
  const { vendor, product } = await params;
  return <ProductOverview vendor={decodeURIComponent(vendor)} product={decodeURIComponent(product)} />;
}
