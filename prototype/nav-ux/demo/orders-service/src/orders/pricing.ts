import { db } from "./repository";
import type { PricedLine } from "./types";

export async function priceLines(items: { sku: string; quantity: number }[]): Promise<PricedLine[]> {
  const skus = items.map((i) => i.sku);
  const rows = await db.query("select sku, price_cents from products where sku = any($1)", [skus]);
  const price = new Map(rows.rows.map((r) => [r.sku, r.price_cents as number]));
  return items.map((i) => ({ sku: i.sku, quantity: i.quantity, unitPriceCents: price.get(i.sku) ?? 0 }));
}

export function sumLines(lines: PricedLine[]): number {
  return lines.reduce((sum, l) => sum + l.unitPriceCents * l.quantity, 0);
}
