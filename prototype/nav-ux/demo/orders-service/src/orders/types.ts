export interface PlaceOrderInput {
  email: string;
  address: string;
  paymentToken: string;
  items: { sku: string; quantity: number }[];
}

export interface PricedLine {
  sku: string;
  quantity: number;
  unitPriceCents: number;
}

export interface Order {
  id: string;
  status: "pending" | "confirmed" | "failed";
  customerEmail: string;
  address: string;
  lines: PricedLine[];
  total: number;
}

export interface PlaceOrderResult {
  httpStatus: number;
  body: { status: "confirmed" | "failed"; orderId?: string; reason?: string };
}
