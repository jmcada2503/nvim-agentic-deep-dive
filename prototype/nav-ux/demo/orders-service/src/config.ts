export const config = {
  port: Number(process.env.PORT ?? 4000),
  databaseUrl: process.env.DATABASE_URL ?? "postgres://localhost/orders",
  billingUrl: process.env.BILLING_URL ?? "http://billing-service:8080",
  amqpUrl: process.env.AMQP_URL ?? "amqp://localhost",
  maxChargeAttempts: 3,
};
