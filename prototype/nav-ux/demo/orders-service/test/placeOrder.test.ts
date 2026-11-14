import { describe, expect, it, vi } from "vitest";
import { placeOrder } from "../src/orders/placeOrder";

vi.mock("../src/payments/chargeWithRetry", () => ({
  chargeWithRetry: vi.fn(async () => ({ status: "declined", declineReason: "insufficient funds" })),
}));

describe("placeOrder", () => {
  it("fails the order when the card is declined", async () => {
    const result = await placeOrder({ email: "a@b.c", address: "1 Long Street", paymentToken: "tok", items: [] });
    expect(result.httpStatus).toBe(402);
    expect(result.body.reason).toBe("insufficient funds");
  });
});
