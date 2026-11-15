import { corsHeaders } from './email-sender.ts';

export const INVOICE_PAYMENTS_MODULE = 'invoice_payments';

export const PAYMENT_CORS = corsHeaders();

export const paymentJson = (value: unknown, status = 200) => new Response(
  JSON.stringify(value),
  { status, headers: { ...PAYMENT_CORS, 'Content-Type': 'application/json' } },
);

export function roundCents(value: number): number {
  return Math.round((Number(value) + Number.EPSILON) * 100) / 100;
}

export function calculateCustomerFee(amount: number, settings: any): number {
  const base = Math.max(0, roundCents(amount));
  const mode = String(settings?.fee_mode || 'pass');
  if (mode === 'bear') return 0;

  const percent = Math.max(0, Number(settings?.fee_percent || 0)) / 100;
  const fixed = Math.max(0, Number(settings?.fee_fixed_amount || 0));
  // Gross-up the fee so the configured processing estimate is covered when
  // the business passes it through. Split allocates half of that estimate.
  const grossedUp = percent >= 0.9999 ? fixed : (base * percent + fixed) / (1 - percent);
  return roundCents(mode === 'split' ? grossedUp / 2 : grossedUp);
}

export function appOrigin(): string {
  const configured = Deno.env.get('PUBLIC_APP_URL')?.trim() || 'https://frindly.co.nz';
  const url = new URL(configured);
  if (url.protocol !== 'https:' || url.username || url.password) {
    throw new Error('PUBLIC_APP_URL must be an HTTPS URL without credentials.');
  }
  return url.origin;
}

export function createOpaqueToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

export async function hashOpaqueToken(token: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

export function cents(value: unknown): number {
  return Math.round(Math.max(0, Number(value || 0)) * 100);
}

export function normaliseCurrency(value: unknown): string {
  const currency = String(value || 'nzd').trim().toLowerCase();
  return /^[a-z]{3}$/.test(currency) ? currency : 'nzd';
}

