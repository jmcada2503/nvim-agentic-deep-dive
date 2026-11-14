import { z } from "zod";
import type { PlaceOrderInput } from "./types";

const PlaceOrderSchema = z.object({
  email: z.string().email(),
  address: z.string().min(8),
  paymentToken: z.string().min(1),
  items: z.array(z.object({ sku: z.string(), quantity: z.number().int().positive() })).min(1),
});

export function parsePlaceOrder(body: unknown): { ok: true; value: PlaceOrderInput } | { ok: false; error: string } {
  const parsed = PlaceOrderSchema.safeParse(body);
  if (!parsed.success) return { ok: false, error: parsed.error.issues[0].message };
  return { ok: true, value: parsed.data };
}
