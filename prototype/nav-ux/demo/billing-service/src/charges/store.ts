import { randomUUID } from "node:crypto";
import type { ChargeRequest } from "./types";

const charges = new Map<string, { orderId: string; amountCents: number; authCode?: string }>();

export async function saveCharge(req: ChargeRequest, authCode?: string): Promise<string> {
  const id = randomUUID();
  charges.set(id, { orderId: req.orderId, amountCents: req.amountCents, authCode });
  return id;
}
