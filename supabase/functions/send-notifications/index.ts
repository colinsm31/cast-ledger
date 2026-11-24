// send-notifications — sends queued customer messages (AceStock, Phase 3E).
//
// Messages are queued in the database (0086): a "ready" notice when a string
// job is marked complete, an emailed receipt (0087). The web app calls this
// right after, with the job or sale; it then:
//   1. checks the caller is signed in with staff access (their own session);
//   2. claims that job's or sale's queued messages with the service role
//      (claim_notifications, which no signed-in user can call), so two calls
//      never send the same message;
//   3. sends each email through Resend, and records sent / failed / skipped
//      (finish_notification). Texts are recorded as skipped until texting is
//      set up. Without the email secrets it runs in test mode: nothing leaves,
//      and each message is recorded as skipped with the reason.
//
// Secrets (Edge Function secrets in the dashboard; locally the gitignored
// supabase/functions/.env), never in the repo:
//   RESEND_API_KEY      the Resend API key
//   NOTIFY_FROM_EMAIL   "Shop Name <service@shop.com>", on a domain verified in Resend
//   NOTIFY_REPLY_TO     optional: where customers' replies go
//
// Request:  POST { "string_job_id"?: uuid, "sale_id"?: uuid }  (neither: the oldest queued)
// Response: 200 { sent, failed, skipped, results: [{ id, status, error? }] } | 4xx/5xx { error }

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { parseRequest, resendEmailSender, sendQueued, summarize, type ClaimedMessage } from './sender.ts';

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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return json({ error: 'Server is missing its Supabase configuration' }, 500);
  }

  // 1. Staff only — checked with the caller's own session.
  const callerClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: isStaff, error: staffError } = await callerClient.rpc('is_staff');
  if (staffError || isStaff !== true) {
    return json({ error: 'Only staff can send customer messages' }, 403);
  }

  const filter = parseRequest(await req.json().catch(() => ({})));
  if ('error' in filter) return json({ error: filter.error }, 400);

  // 2–3. Claim and send with the service role.
  const serviceClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const apiKey = Deno.env.get('RESEND_API_KEY');
  const from = Deno.env.get('NOTIFY_FROM_EMAIL');
  const replyTo = Deno.env.get('NOTIFY_REPLY_TO') || undefined;

  try {
    const results = await sendQueued(filter, {
      claim: async ({ stringJobId, saleId }) => {
        const { data, error } = await serviceClient.rpc('claim_notifications', {
          p_string_job_id: stringJobId,
          p_sale_id: saleId,
        });
        if (error) throw new Error(`Couldn't take the queued messages: ${error.message}`);
        return (data ?? []) as ClaimedMessage[];
      },
      finish: async (id, status, providerId, error) => {
        const { error: finishError } = await serviceClient.rpc('finish_notification', {
          p_id: id,
          p_status: status,
          p_provider_id: providerId,
          p_error: error,
        });
        // The message stays "sending" and is taken again after 10 minutes.
        if (finishError) console.error(`finish_notification ${id}: ${finishError.message}`);
      },
      sendEmail: apiKey && from ? resendEmailSender({ apiKey, from, replyTo }) : undefined,
    });
    return json({ ...summarize(results), results }, 200);
  } catch (err) {
    return json({ error: err instanceof Error ? err.message : String(err) }, 500);
  }
});
