import { BrowserRouter, Route, Routes } from "react-router-dom";
import { CartPage } from "./features/cart/CartPage";
import { CheckoutPage } from "./features/checkout/CheckoutPage";

export function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<CartPage />} />
        <Route path="/checkout" element={<CheckoutPage />} />
      </Routes>
    </BrowserRouter>
  );
}
