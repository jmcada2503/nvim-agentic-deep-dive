import { authorize } from "../acquirer/acquirerClient";
import { saveCharge } from "./store";
import type { ChargeRequest, ChargeResult } from "./types";

export async function createCharge(req: ChargeRequest): Promise<ChargeResult> {
  const auth = await authorize(req.token, req.amountCents);
  if (auth.approved) {
    const chargeId = await saveCharge(req, auth.authCode);
    return { status: "approved", chargeId };
  }
  return { status: "declined", declineReason: auth.reason };
}
