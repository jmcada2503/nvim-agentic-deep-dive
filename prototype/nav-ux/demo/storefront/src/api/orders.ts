import { postJson } from "./client";

export interface PlaceOrderRequest {
  email: string;
  address: string;
  paymentToken: string;
  items: { sku: string; quantity: number }[];
}

export interface PlaceOrderResponse {
  status: "confirmed" | "failed";
  orderId?: string;
  reason?: string;
}

export async function placeOrder(request: PlaceOrderRequest): Promise<PlaceOrderResponse> {
  return postJson<PlaceOrderResponse>("/orders", request);
}
