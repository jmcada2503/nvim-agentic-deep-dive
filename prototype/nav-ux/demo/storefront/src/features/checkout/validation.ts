export interface CheckoutForm {
  email: string;
  address: string;
  cardToken: string;
}

const EMAIL = /^[^@\s]+@[^@\s]+$/;

export function validateCheckout(form: CheckoutForm): string[] {
  const problems: string[] = [];
  if (!EMAIL.test(form.email)) problems.push("Enter a valid email address");
  if (form.address.trim().length < 8) problems.push("Address looks incomplete");
  if (!form.cardToken) problems.push("Add a payment card");
  return problems;
}
