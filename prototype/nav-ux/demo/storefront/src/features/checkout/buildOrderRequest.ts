import type { CartLine } from "../cart/cartStore";
import type { CheckoutForm } from "./validation";
import type { PlaceOrderRequest } from "../../api/orders";

export function buildOrderRequest(cart: { lines: CartLine[] }, form: CheckoutForm): PlaceOrderRequest {
  return {
    email: form.email.trim().toLowerCase(),
    address: form.address.trim(),
    paymentToken: form.cardToken,
    items: cart.lines.map((l) => ({ sku: l.sku, quantity: l.quantity })),
  };
}
