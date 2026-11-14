import type { Order, PlaceOrderInput, PlaceOrderResult } from "./types";
import { priceLines, sumLines } from "./pricing";
import { findUnavailable, reserveStock } from "./inventory";
import { insertPendingOrder, markConfirmed, markFailed } from "./repository";
import { chargeWithRetry } from "../payments/chargeWithRetry";
import type { ChargeResult } from "../payments/billingClient";
import { publishOrderPlaced } from "../events/publisher";

type CreateResult = { ok: true; order: Order } | { ok: false; reason: string };

export async function placeOrder(input: PlaceOrderInput): Promise<PlaceOrderResult> {
  const created = await createPendingOrder(input);
  if (!created.ok) {
    return { httpStatus: 409, body: { status: "failed", reason: created.reason } };
  }
  const charge = await chargeWithRetry(created.order, input.paymentToken);
  if (charge.status === "approved") {
    return confirmOrder(created.order, charge);
  }
  return failOrder(created.order, charge);
}

export async function createPendingOrder(input: PlaceOrderInput): Promise<CreateResult> {
  const lines = await priceLines(input.items);
  const unavailable = await findUnavailable(lines);
  if (unavailable.length > 0) {
    return { ok: false, reason: `out of stock: ${unavailable.join(", ")}` };
  }
  await reserveStock(lines);
  const order = await insertPendingOrder({
    customerEmail: input.email,
    address: input.address,
    lines,
    total: sumLines(lines),
  });
  return { ok: true, order };
}

async function confirmOrder(order: Order, charge: ChargeResult): Promise<PlaceOrderResult> {
  await markConfirmed(order.id, charge.chargeId!);
  await publishOrderPlaced({ orderId: order.id, total: order.total, email: order.customerEmail });
  return { httpStatus: 201, body: { status: "confirmed", orderId: order.id } };
}

async function failOrder(order: Order, charge: ChargeResult): Promise<PlaceOrderResult> {
  const reason = charge.declineReason ?? "payment could not be processed";
  await markFailed(order.id, reason);
  return { httpStatus: 402, body: { status: "failed", orderId: order.id, reason } };
}
