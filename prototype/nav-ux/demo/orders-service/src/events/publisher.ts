import { getChannel } from "./queue";

export interface OrderPlacedEvent {
  orderId: string;
  total: number;
  email: string;
}

export async function publishOrderPlaced(event: OrderPlacedEvent): Promise<void> {
  const ch = await getChannel();
  ch.publish("orders", "orders.placed", Buffer.from(JSON.stringify(event)), { persistent: true });
}
