import { useState } from "react";
import { useCart } from "../cart/cartStore";
import { validateCheckout, type CheckoutForm } from "./validation";
import { buildOrderRequest } from "./buildOrderRequest";
import { placeOrder, type PlaceOrderResponse } from "../../api/orders";
import { OrderResult } from "./OrderResult";
import { AddressFields } from "./AddressFields";

const EMPTY: CheckoutForm = { email: "", address: "", cardToken: "" };

export function CheckoutPage() {
  const cart = useCart();
  const [form, setForm] = useState<CheckoutForm>(EMPTY);
  const [errors, setErrors] = useState<string[]>([]);
  const [result, setResult] = useState<PlaceOrderResponse | null>(null);
  const [submitting, setSubmitting] = useState(false);

  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault();
    const problems = validateCheckout(form);
    if (problems.length > 0) {
      setErrors(problems);
      return;
    }
    setSubmitting(true);
    const request = buildOrderRequest(cart, form);
    const response = await placeOrder(request);
    setSubmitting(false);
    setResult(response);
  }

  if (result) return <OrderResult response={result} />;

  return (
    <form onSubmit={handleSubmit}>
      <AddressFields form={form} onChange={setForm} />
      <CardInput onToken={(cardToken) => setForm({ ...form, cardToken })} />
      {errors.map((e) => (
        <p key={e} className="error">{e}</p>
      ))}
      <button disabled={submitting || cart.lines.length === 0}>Place order</button>
    </form>
  );
}

function CardInput({ onToken }: { onToken(token: string): void }) {
  // The payment provider widget posts a token back once the card is tokenized.
  return <div id="card-widget" data-on-token={onToken} />;
}
