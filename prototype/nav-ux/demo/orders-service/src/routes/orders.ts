import { Router } from "express";
import { parsePlaceOrder } from "../orders/schema";
import { placeOrder } from "../orders/placeOrder";
import { getOrder } from "../orders/repository";

export const ordersRouter = Router();

ordersRouter.post("/orders", async (req, res) => {
  const input = parsePlaceOrder(req.body);
  if (!input.ok) {
    return res.status(400).json({ status: "failed", reason: input.error });
  }
  const result = await placeOrder(input.value);
  res.status(result.httpStatus).json(result.body);
});

ordersRouter.get("/orders/:id", async (req, res) => {
  const order = await getOrder(req.params.id);
  if (!order) return res.status(404).end();
  res.json(order);
});
