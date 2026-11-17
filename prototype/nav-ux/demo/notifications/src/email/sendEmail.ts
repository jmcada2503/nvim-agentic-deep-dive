export async function sendEmail(to: string, template: string, data: Record<string, unknown>): Promise<void> {
  await fetch(`${process.env.MAILER_URL}/send`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ to, template, data }),
  });
}
