import { Link } from "react-router-dom";
import { useCart } from "./cartStore";
import { formatCents } from "../../lib/money";

export function CartPage() {
  const { lines, remove } = useCart();
  const total = lines.reduce((sum, l) => sum + l.unitPriceCents * l.quantity, 0);
  return (
    <main>
      <h1>Your cart</h1>
      <ul>
        {lines.map((l) => (
          <li key={l.sku}>
            {l.name} x {l.quantity} = {formatCents(l.unitPriceCents * l.quantity)}
            <button onClick={() => remove(l.sku)}>remove</button>
          </li>
        ))}
      </ul>
      <p>Total: {formatCents(total)}</p>
      <Link to="/checkout">Checkout</Link>
    </main>
  );
}
