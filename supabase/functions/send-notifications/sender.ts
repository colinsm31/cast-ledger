// The sending logic for send-notifications, kept free of Supabase and network
// imports so `deno test` can run it with fakes (sender_test.ts).

/** A queued message as claim_notifications (0086) returns it. */
export interface ClaimedMessage {
  id: string;
  kind: 'job_ready' | 'receipt';
  channel: 'email' | 'sms';
  to_address: string;
  subject: string | null;
  body: string;
  html: string | null;
  attempts: number;
}

export type Outcome = 'sent' | 'failed' | 'skipped';

export interface SendResult {
  id: string;
  status: Outcome;
  error?: string;
}

/** Sends one email; resolves to the provider's message id or throws a readable error. */
export type EmailSender = (message: ClaimedMessage) => Promise<string>;

export interface SenderDeps {
  claim(filter: { stringJobId: string | null; saleId: string | null }): Promise<ClaimedMessage[]>;
  finish(id: string, status: Outcome, providerId: string | null, error: string | null): Promise<void>;
  /** Missing when email isn't set up (test mode): nothing leaves, the log says so. */
  sendEmail?: EmailSender;
}

export const TEST_MODE_MESSAGE = "Test mode: email isn't set up for this shop yet, so nothing was sent";
export const NO_TEXTING_MESSAGE = "Texting isn't set up yet, so nothing was sent";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Which queued messages to send: one job's, one sale's, or the oldest of any. */
export function parseRequest(body: unknown): { stringJobId: string | null; saleId: string | null } | { error: string } {
  const value = (body ?? {}) as Record<string, unknown>;
  const stringJobId = value.string_job_id ?? null;
  const saleId = value.sale_id ?? null;
  for (const [name, id] of [['string_job_id', stringJobId], ['sale_id', saleId]] as const) {
    if (id !== null && (typeof id !== 'string' || !UUID.test(id))) return { error: `${name} must be an id` };
  }
  return { stringJobId: stringJobId as string | null, saleId: saleId as string | null };
}

/** Claim the queued messages and send each, recording every outcome. */
export async function sendQueued(
  filter: { stringJobId: string | null; saleId: string | null },
  deps: SenderDeps,
): Promise<SendResult[]> {
  const messages = await deps.claim(filter);
  const results: SendResult[] = [];
  for (const message of messages) {
    let result: SendResult;
    let providerId: string | null = null;
    if (message.channel === 'sms') {
      result = { id: message.id, status: 'skipped', error: NO_TEXTING_MESSAGE };
    } else if (!deps.sendEmail) {
      result = { id: message.id, status: 'skipped', error: TEST_MODE_MESSAGE };
    } else {
      try {
        providerId = await deps.sendEmail(message);
        result = { id: message.id, status: 'sent' };
      } catch (err) {
        result = { id: message.id, status: 'failed', error: err instanceof Error ? err.message : String(err) };
      }
    }
    await deps.finish(message.id, result.status, providerId, result.error ?? null);
    results.push(result);
  }
  return results;
}

/** e.g. { sent: 1, failed: 0, skipped: 1 }. */
export function summarize(results: SendResult[]): Record<Outcome, number> {
  const counts: Record<Outcome, number> = { sent: 0, failed: 0, skipped: 0 };
  for (const result of results) counts[result.status] += 1;
  return counts;
}

// ---------------------------------------------------------------------------
// Resend (https://resend.com/docs/api-reference/emails/send-email)
// ---------------------------------------------------------------------------
export interface ResendConfig {
  apiKey: string;
  /** "Shop Name <service@shop.com>" or a bare address on a verified domain. */
  from: string;
  replyTo?: string;
  fetch?: typeof fetch;
  timeoutMs?: number;
}

export function resendEmailSender(config: ResendConfig): EmailSender {
  const doFetch = config.fetch ?? fetch;
  return async (message) => {
    let response: Response;
    try {
      response = await doFetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${config.apiKey}`,
          'Content-Type': 'application/json',
          // The same attempt is never sent twice, even if this request is retried.
          'Idempotency-Key': `acestock-${message.id}-${message.attempts}`,
        },
        body: JSON.stringify({
          from: config.from,
          to: [message.to_address],
          subject: message.subject ?? '',
          text: message.body,
          ...(message.html ? { html: message.html } : {}),
          ...(config.replyTo ? { reply_to: config.replyTo } : {}),
        }),
        signal: AbortSignal.timeout(config.timeoutMs ?? 15000),
      });
    } catch (err) {
      throw new Error(`The email service didn't answer: ${err instanceof Error ? err.message : String(err)}`);
    }
    const payload = (await response.json().catch(() => null)) as { id?: string; message?: string } | null;
    if (!response.ok || !payload?.id) {
      throw new Error(`The email service refused it (${response.status}): ${payload?.message ?? 'no reason given'}`);
    }
    return payload.id;
  };
}
