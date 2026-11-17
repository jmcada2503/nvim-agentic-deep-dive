import { config } from "../config";

export interface ChargeRequest {
  orderId: string;
  amountCents: number;
  token: string;
}

export interface ChargeResult {
  status: "approved" | "declined" | "error";
  chargeId?: string;
  declineReason?: string;
  retryAfterMs?: number;
}

export const billing = {
  async createCharge(req: ChargeRequest): Promise<ChargeResult> {
    try {
      const res = await fetch(`${config.billingUrl}/v1/charges`, {
        method: "POST",
        headers: { "content-type": "application/json", "idempotency-key": req.orderId },
        body: JSON.stringify(req),
      });
      if (res.status >= 500) return { status: "error" };
      if (res.status === 429) return { status: "error", retryAfterMs: Number(res.headers.get("retry-after") ?? "1") * 1000 };
      return (await res.json()) as ChargeResult;
    } catch {
      return { status: "error" };
    }
  },
};
