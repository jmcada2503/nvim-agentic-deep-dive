import { config } from "../config";
import { billing, type ChargeResult } from "./billingClient";
import type { Order } from "../orders/types";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const backoffMs = (attempt: number) => 200 * 2 ** (attempt - 1);

export async function chargeWithRetry(order: Order, paymentToken: string): Promise<ChargeResult> {
  let attempt = 0;
  let result: ChargeResult;
  do {
    attempt += 1;
    result = await billing.createCharge({ orderId: order.id, amountCents: order.total, token: paymentToken });
    if (result.status === "error") await sleep(backoffMs(attempt));
  } while (result.status === "error" && attempt < config.maxChargeAttempts);
  return result;
}
