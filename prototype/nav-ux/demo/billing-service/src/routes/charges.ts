import { Router } from "express";
import { createCharge } from "../charges/createCharge";

export const chargesRouter = Router();

chargesRouter.post("/v1/charges", async (req, res) => {
  const { orderId, amountCents, token } = req.body;
  if (!orderId || !token || !(amountCents > 0)) {
    res.status(400).json({ status: "error" });
    return;
  }
  const result = await createCharge({ orderId, amountCents, token });
  res.status(200).json(result);
});
