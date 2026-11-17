export interface ChargeRequest {
  orderId: string;
  amountCents: number;
  token: string;
}

export interface ChargeResult {
  status: "approved" | "declined" | "error";
  chargeId?: string;
  declineReason?: string;
}
