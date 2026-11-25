// send-notifications — sends queued customer messages (AceStock, Phase 3E).
//
// Messages are queued in the database (0086): a "ready" notice when a string
// job is marked complete, an emailed receipt (0087). The web app calls this
// right after, with the job or sale (or, for Send again, the one message); it
// then (handler.ts):
//   1. checks the caller is signed in with staff access (their own session);
//   2. claims those queued messages with the service role
//      (claim_notifications, which no signed-in user can call), so two calls
//      never send the same message; a ready message the customer should no
//      longer get is recorded as not sent instead (0088);
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
// Request:  POST { "notification_id"?: uuid, "string_job_id"?: uuid, "sale_id"?: uuid }
//           (none: the oldest queued)
// Response: 200 { sent, failed, skipped, results: [{ id, status, error? }] } | 4xx/5xx { error }

import { createClient } from 'jsr:@supabase/supabase-js@2.118.0';
import { createHandler } from './handler.ts';

Deno.serve(
  createHandler({
    env: (name) => Deno.env.get(name),
    makeClient: (url, key, authorization) =>
      createClient(url, key, {
        ...(authorization !== undefined ? { global: { headers: { Authorization: authorization } } } : {}),
        auth: { persistSession: false, autoRefreshToken: false },
      }),
  }),
);
