import amqp from "amqplib";

export async function subscribe<T>(exchange: string, key: string, handler: (msg: T) => Promise<void>) {
  const ch = await (await amqp.connect(process.env.AMQP_URL ?? "amqp://localhost")).createChannel();
  const q = await ch.assertQueue("notifications." + key);
  await ch.bindQueue(q.queue, exchange, key);
  await ch.consume(q.queue, async (m) => { if (m) { await handler(JSON.parse(m.content.toString())); ch.ack(m); } });
}
