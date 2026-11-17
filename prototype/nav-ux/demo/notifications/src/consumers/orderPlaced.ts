import { subscribe } from "../queue";
import { sendEmail } from "../email/sendEmail";

export interface OrderPlacedEvent {
  orderId: string;
  total: number;
  email: string;
}

export function startOrderPlacedConsumer() {
  subscribe("orders", "orders.placed", async (event: OrderPlacedEvent) => {
    await sendEmail(event.email, "order-confirmed", { orderId: event.orderId, total: event.total });
  });
}
