import type { CheckoutForm } from "./validation";

interface Props {
  form: CheckoutForm;
  onChange(form: CheckoutForm): void;
}

export function AddressFields({ form, onChange }: Props) {
  return (
    <fieldset>
      <label>
        Email
        <input value={form.email} onChange={(e) => onChange({ ...form, email: e.target.value })} />
      </label>
      <label>
        Address
        <textarea value={form.address} onChange={(e) => onChange({ ...form, address: e.target.value })} />
      </label>
    </fieldset>
  );
}
