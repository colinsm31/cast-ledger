// The request handling for send-notifications, with the Supabase client passed
// in, so handler_test.ts can run every path (refusals and failures included)
// with fakes. index.ts wires it to the real client and Deno.serve.
import { parseRequest, resendEmailSender, sendQueued, summarize, type ClaimedMessage, type SendFilter } from './sender.ts';

/** The one thing the handler needs from a Supabase client. */
export interface RpcClient {
  rpc(fn: string, args?: Record<string, unknown>): PromiseLike<{ data: unknown; error: { message: string } | null }>;
}

export interface HandlerDeps {
  env(name: string): string | undefined;
  /** A client for url + key; with `authorization`, it acts as that signed-in caller. */
  makeClient(url: string, key: string, authorization?: string): RpcClient;
  /** Where database errors are written for the logs (staff see a plain message). */
  logError?(message: string): void;
  fetch?: typeof fetch;
}

export const CLAIM_FAILED_MESSAGE =
  "Couldn't reach the message queue. The messages are still waiting; use Send again in a minute.";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

export function createHandler(deps: HandlerDeps): (req: Request) => Promise<Response> {
  const logError = deps.logError ?? ((message: string) => console.error(message));

  return async (req) => {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
    if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

    const supabaseUrl = deps.env('SUPABASE_URL');
    const anonKey = deps.env('SUPABASE_ANON_KEY');
    const serviceRoleKey = deps.env('SUPABASE_SERVICE_ROLE_KEY');
    if (!supabaseUrl || !anonKey || !serviceRoleKey) {
      return json({ error: 'Server is missing its Supabase configuration' }, 500);
    }

    const serviceClient = deps.makeClient(supabaseUrl, serviceRoleKey);
    let filter: SendFilter;
    const sweepSecret = req.headers.get('x-acestock-sweep');
    if (sweepSecret) {
      // 1a. The database's schedule (0107): its secret, checked with the
      // service role, sends whatever has been waiting longest.
      const { data: allowed, error: sweepError } = await serviceClient.rpc('notification_sweep_allowed', {
        p_secret: sweepSecret,
      });
      if (sweepError) logError(`notification_sweep_allowed: ${sweepError.message}`);
      if (sweepError || allowed !== true) return json({ error: 'Not a message sweep from this database' }, 403);
      filter = { stringJobId: null, saleId: null, notificationId: null };
    } else {
      // 1b. Staff only — checked with the caller's own session.
      const callerClient = deps.makeClient(supabaseUrl, anonKey, req.headers.get('Authorization') ?? '');
      const { data: isStaff, error: staffError } = await callerClient.rpc('is_staff');
      if (staffError) logError(`is_staff: ${staffError.message}`);
      if (staffError || isStaff !== true) {
        return json({ error: 'Only staff can send customer messages' }, 403);
      }
      const parsed = parseRequest(await req.json().catch(() => ({})));
      if ('error' in parsed) return json({ error: parsed.error }, 400);
      filter = parsed;
    }

    // 2–3. Claim and send with the service role.
    const apiKey = deps.env('RESEND_API_KEY');
    const from = deps.env('NOTIFY_FROM_EMAIL');
    const replyTo = deps.env('NOTIFY_REPLY_TO') || undefined;

    let claimFailed = false;
    try {
      const results = await sendQueued(filter, {
        claim: async ({ stringJobId, saleId, notificationId }) => {
          const { data, error } = await serviceClient.rpc('claim_notifications', {
            p_string_job_id: stringJobId,
            p_sale_id: saleId,
            p_id: notificationId,
          });
          if (error) {
            claimFailed = true;
            throw new Error(`claim_notifications: ${error.message}`);
          }
          return (data ?? []) as ClaimedMessage[];
        },
        finish: async (id, status, providerId, error, attempt) => {
          const { error: finishError } = await serviceClient.rpc('finish_notification', {
            p_id: id,
            p_status: status,
            p_provider_id: providerId,
            p_error: error,
            p_attempt: attempt,
          });
          // The message stays "sending" and is taken again after 10 minutes,
          // with the same key, so it isn't delivered twice.
          if (finishError) logError(`finish_notification ${id}: ${finishError.message}`);
        },
        sendEmail: apiKey && from ? resendEmailSender({ apiKey, from, replyTo, fetch: deps.fetch }) : undefined,
      });
      return json({ ...summarize(results), results }, 200);
    } catch (err) {
      logError(err instanceof Error ? err.message : String(err));
      return json({ error: claimFailed ? CLAIM_FAILED_MESSAGE : "Something went wrong sending the messages; use Send again in a minute." }, 500);
    }
  };
}
