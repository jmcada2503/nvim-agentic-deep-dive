import { create } from "zustand";

export interface CartLine {
  sku: string;
  name: string;
  quantity: number;
  unitPriceCents: number;
}

interface CartState {
  lines: CartLine[];
  add(line: CartLine): void;
  remove(sku: string): void;
  clear(): void;
}

export const useCart = create<CartState>((set) => ({
  lines: [],
  add: (line) =>
    set((s) => {
      const existing = s.lines.find((l) => l.sku === line.sku);
      if (existing) {
        return { lines: s.lines.map((l) => (l.sku === line.sku ? { ...l, quantity: l.quantity + line.quantity } : l)) };
      }
      return { lines: [...s.lines, line] };
    }),
  remove: (sku) => set((s) => ({ lines: s.lines.filter((l) => l.sku !== sku) })),
  clear: () => set({ lines: [] }),
}));
