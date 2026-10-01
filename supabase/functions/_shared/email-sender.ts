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
