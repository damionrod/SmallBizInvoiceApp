/**
 * Frindly email transport identity.
 *
 * SECURITY / DELIVERABILITY INVARIANT:
 * The physical From address must come only from trusted server-side
 * configuration. Never pass tenant, business, customer, snapshot or other
 * user-controlled email addresses into the From address. Tenant addresses may
 * be used as Reply-To by the calling function.
 */
const FALLBACK_PLATFORM_FROM = 'notifications@frindly.co.nz';
const EMAIL_RE = /^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/;
const TRUSTED_SENDER_DOMAIN = 'frindly.co.nz';

function isTrustedPlatformSender(email: string): boolean {
  if (!EMAIL_RE.test(email)) return false;
  const domain = email.split('@').pop()?.toLowerCase() || '';
  return domain === TRUSTED_SENDER_DOMAIN || domain.endsWith(`.${TRUSTED_SENDER_DOMAIN}`);
}

export function platformFromEmail(): string {
  const configured = String(
    Deno.env.get('RESEND_FROM_EMAIL') ||
    Deno.env.get('EMAIL_FROM_ADDRESS') ||
    ''
  ).trim();
  // Legacy/non-Frindly values (for example a tenant's own domain) are never
  // accepted as transport senders, even if they remain in environment config.
  return isTrustedPlatformSender(configured) ? configured : FALLBACK_PLATFORM_FROM;
}

export function safeSenderName(value: unknown, fallback = 'Frindly'): string {
  const clean = String(value ?? '').replace(/[<>\r\n]/g, '').trim();
  return clean || fallback;
}

export function platformFrom(displayName: unknown, fallbackName = 'Frindly'): string {
  return `${safeSenderName(displayName, fallbackName)} <${platformFromEmail()}>`;
}

export function validReplyTo(value: unknown): string | undefined {
  const email = String(value ?? '').trim();
  return EMAIL_RE.test(email) ? email : undefined;
}

const DEFAULT_ORIGINS = [
  'https://frindly.co.nz',
  'https://www.frindly.co.nz',
  'http://localhost:8888',
  'http://localhost:5173',
  'http://127.0.0.1:8888',
  'http://127.0.0.1:5173',
];

function configuredOrigins() {
  return String(Deno.env.get('ALLOWED_APP_ORIGINS') || Deno.env.get('PUBLIC_APP_URL') || '')
    .split(',')
    .map((x) => x.trim().replace(/\/$/, ''))
    .filter(Boolean);
}

function allowedOrigins() {
  const configured = configuredOrigins();
  return new Set([...DEFAULT_ORIGINS, ...configured]);
}

export function corsHeaders(req?: Request) {
  const origin = String(req?.headers.get('origin') || '').replace(/\/$/, '');
  const allow = allowedOrigins();
  const selected = origin && allow.has(origin) ? origin : (configuredOrigins()[0] || 'https://frindly.co.nz');
  return {
    'Access-Control-Allow-Origin': selected,
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Vary': 'Origin',
  };
}

export function clientIp(req: Request) {
  return String(
    req.headers.get('cf-connecting-ip') ||
    req.headers.get('x-forwarded-for') ||
    req.headers.get('x-real-ip') ||
    'unknown',
  ).split(',')[0].trim().slice(0, 80) || 'unknown';
}

export async function enforceRateLimit(
  admin: any,
  scope: string,
  identifier: unknown,
  limit: number,
  windowSeconds: number,
) {
  const id = String(identifier || 'unknown').trim().slice(0, 160) || 'unknown';
  const { data, error } = await admin.rpc('v61111_check_edge_rate_limit', {
    p_scope: scope,
    p_identifier: id,
    p_limit: limit,
    p_window_seconds: windowSeconds,
  });
  if (error) throw error;
  if (data && data.allowed === false) {
    const err = new Error(`Too many requests. Please try again after ${data.reset_at || 'a short wait'}.`);
    (err as any).status = 429;
    throw err;
  }
  return data;
}
