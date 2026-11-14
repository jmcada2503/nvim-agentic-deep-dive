import amqp from "amqplib";
import { config } from "../config";

let channel: amqp.Channel | null = null;

export async function getChannel(): Promise<amqp.Channel> {
  if (channel) return channel;
  const conn = await amqp.connect(config.amqpUrl);
  channel = await conn.createChannel();
  await channel.assertExchange("orders", "topic", { durable: true });
  return channel;
}
