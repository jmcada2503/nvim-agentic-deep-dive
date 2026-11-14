import express from "express";
import { config } from "./config";
import { ordersRouter } from "./routes/orders";

const app = express();
app.use(express.json());
app.use(ordersRouter);

app.listen(config.port, () => {
  console.log(`orders-service listening on ${config.port}`);
});
