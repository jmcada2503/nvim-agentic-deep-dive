export interface AuthResult {
  approved: boolean;
  authCode?: string;
  reason?: string;
}

const ACQUIRER_URL = process.env.ACQUIRER_URL ?? "https://api.acquirer.example";

export async function authorize(token: string, amountCents: number): Promise<AuthResult> {
  const res = await fetch(`${ACQUIRER_URL}/v2/authorizations`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ source: token, amount: amountCents, currency: "usd" }),
  });
  if (!res.ok) return { approved: false, reason: `acquirer ${res.status}` };
  return (await res.json()) as AuthResult;
}
