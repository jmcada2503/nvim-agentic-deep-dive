import pg from "pg";
import { randomUUID } from "node:crypto";
import { config } from "../config";
import type { Order } from "./types";

export const db = new pg.Pool({ connectionString: config.databaseUrl });

export async function insertPendingOrder(data: Omit<Order, "id" | "status">): Promise<Order> {
  const order: Order = { ...data, id: randomUUID(), status: "pending" };
  await db.query("insert into orders (id, status, body) values ($1, $2, $3)", [order.id, order.status, order]);
  return order;
}

export async function markConfirmed(orderId: string, chargeId: string): Promise<void> {
  await db.query("update orders set status = 'confirmed', charge_id = $2 where id = $1", [orderId, chargeId]);
}

export async function markFailed(orderId: string, reason: string): Promise<void> {
  await db.query("update orders set status = 'failed', fail_reason = $2 where id = $1", [orderId, reason]);
}

export async function getOrder(orderId: string): Promise<Order | null> {
  const res = await db.query("select body from orders where id = $1", [orderId]);
  return res.rows[0]?.body ?? null;
}
