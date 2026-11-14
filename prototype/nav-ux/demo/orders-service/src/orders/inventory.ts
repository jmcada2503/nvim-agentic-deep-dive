import { db } from "./repository";
import type { PricedLine } from "./types";

export async function findUnavailable(lines: PricedLine[]): Promise<string[]> {
  const rows = await db.query("select sku, available from stock where sku = any($1)", [lines.map((l) => l.sku)]);
  const available = new Map(rows.rows.map((r) => [r.sku, r.available as number]));
  return lines.filter((l) => (available.get(l.sku) ?? 0) < l.quantity).map((l) => l.sku);
}

export async function reserveStock(lines: PricedLine[]): Promise<void> {
  for (const line of lines) {
    await db.query("update stock set available = available - $2 where sku = $1", [line.sku, line.quantity]);
  }
}
