import type { PlaceOrderResponse } from "../../api/orders";

export function OrderResult({ response }: { response: PlaceOrderResponse }) {
  if (response.status === "confirmed") {
    return <h2>Thanks! Order {response.orderId} is confirmed.</h2>;
  }
  return <p role="alert">We could not place your order: {response.reason ?? "unknown error"}</p>;
}
